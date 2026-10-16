# ShowReady - lib\Lan.ps1
# Local network step: are the incoming NDI/OMT feeds visible, and can the LAN carry them?
# Defines Invoke-SRLan plus SRL_* helpers. No side effects when dot-sourced.
# Windows PowerShell 5.1 compatible. Pure ASCII on purpose (PS 5.1 reads BOM-less files as the ANSI code page).
#
# DNS-SD service types (RFC 6763):
#   NDI  _ndi._tcp.local   senders on TCP 5960+, NDI Discovery Server on TCP 5959
#   OMT  _omt._tcp.local   libomtnet PROTOCOL.md: "Open Media Transport uses the service type _omt._tcp", instance
#                          names "HOSTNAME (Source Name)._omt._tcp.local"; src/win32/OMTDiscoveryWin32.cs queries
#                          "_omt._tcp.local". Senders on TCP 6400-6600 (OMTConstants.cs), Discovery Server TCP 6399.
#                          https://github.com/openmediatransport/libomtnet
#
# Discovery never binds UDP 5353 or any other fixed port: that can raise a Windows Firewall prompt, and a non-admin
# "Cancel" creates block rules (a system change). Two methods instead:
#   unicast  raw mDNS query from an ephemeral socket. Responders answer a query from a port other than 5353 by unicast
#            to that port (RFC 6762 section 6.7), and Windows Firewall lets unicast replies to our own multicast in.
#   windows  DnsServiceBrowse (dnsapi.dll, Windows 10 1809+): Windows' own mDNS service does the listening.

# ---------------------------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------------------------

# Safe property lookup on PSCustomObject or hashtable; $null when missing. Never throws.
function SRL_P {
    param($Obj, [string]$Name)
    if ($null -eq $Obj) { return $null }
    try {
        if ($Obj -is [System.Collections.IDictionary]) {
            if ($Obj.Contains($Name)) { return $Obj[$Name] }
            return $null
        }
        $p = $Obj.PSObject.Properties[$Name]
        if ($null -ne $p) { return $p.Value }
    }
    catch { }
    return $null
}

function SRL_Num {
    param($v)
    if ($null -eq $v) { return $null }
    $d = 0.0
    if ([double]::TryParse([string]$v, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d)) {
        if ([double]::IsNaN($d) -or [double]::IsInfinity($d)) { return $null }
        return $d
    }
    return $null
}

function SRL_IpToInt {
    param([string]$Ip)
    $b = [System.Net.IPAddress]::Parse($Ip).GetAddressBytes()
    return ([int64]$b[0] * 16777216) + ([int64]$b[1] * 65536) + ([int64]$b[2] * 256) + [int64]$b[3]
}

function SRL_IntToIp {
    param([int64]$N)
    return ([string](($N -shr 24) -band 255) + '.' + [string](($N -shr 16) -band 255) + '.' + [string](($N -shr 8) -band 255) + '.' + [string]($N -band 255))
}

function SRL_Short {
    param($s, [int]$Max = 160)
    $t = (([string]$s) -replace '\s+', ' ').Trim()
    if ($t.Length -gt $Max) { $t = $t.Substring(0, $Max - 3) + '...' }
    return $t
}

# ---------------------------------------------------------------------------------------------
# DNS message encoding / decoding (RFC 1035 + mDNS)
# ---------------------------------------------------------------------------------------------

# Split a DNS name into labels. A dot inside a label is written "\." (RFC 6763 section 4.3).
function SRL_SplitDnsName {
    param([string]$Name)
    $n = ([string]$Name).TrimEnd('.')
    $out = New-Object System.Collections.ArrayList
    foreach ($part in [regex]::Split($n, '(?<!\\)\.')) {
        if ($part -ne '') { [void]$out.Add($part.Replace('\.', '.')) }
    }
    return , $out.ToArray()
}

# Build a DNS query. -Types: one type for every name, or one type per name. -QU sets the unicast-response bit.
function SRL_NewDnsQuery {
    param([string[]]$Names, [int[]]$Types = @(12), [switch]$QU, [int]$Id = 0)
    $names = @($Names)
    $ms = New-Object System.IO.MemoryStream
    $n = $names.Count
    $hdr = [byte[]]@([byte](($Id -shr 8) -band 255), [byte]($Id -band 255), 0, 0, [byte](($n -shr 8) -band 255), [byte]($n -band 255), 0, 0, 0, 0, 0, 0)
    $ms.Write($hdr, 0, 12)
    $cls = 1
    if ($QU) { $cls = 0x8001 }
    for ($i = 0; $i -lt $n; $i++) {
        $t = 12
        if (@($Types).Count -eq 1) { $t = [int]$Types[0] }
        elseif (@($Types).Count -gt $i) { $t = [int]$Types[$i] }
        foreach ($label in (SRL_SplitDnsName $names[$i])) {
            $lb = [System.Text.Encoding]::UTF8.GetBytes([string]$label)
            $len = $lb.Length
            if ($len -gt 63) { $len = 63 }
            $ms.WriteByte([byte]$len)
            $ms.Write($lb, 0, $len)
        }
        $ms.WriteByte(0)
        $ms.WriteByte([byte](($t -shr 8) -band 255)); $ms.WriteByte([byte]($t -band 255))
        $ms.WriteByte([byte](($cls -shr 8) -band 255)); $ms.WriteByte([byte]($cls -band 255))
    }
    return , $ms.ToArray()
}

# Read a (possibly compressed) name at $Pos. Returns @(name, positionAfterName) or $null on malformed input.
function SRL_ReadDnsName {
    param([byte[]]$B, [int]$Pos)
    $labels = New-Object System.Collections.ArrayList
    $p = $Pos
    $after = -1
    $jumps = 0
    while ($true) {
        if ($p -lt 0 -or $p -ge $B.Length) { return $null }
        $len = [int]$B[$p]
        if ($len -eq 0) {
            if ($after -lt 0) { $after = $p + 1 }
            break
        }
        if (($len -band 0xC0) -eq 0xC0) {
            if ($p + 1 -ge $B.Length) { return $null }
            if ($after -lt 0) { $after = $p + 2 }
            $jumps++
            if ($jumps -gt 32) { return $null }
            $p = (($len -band 0x3F) * 256) + [int]$B[$p + 1]
            continue
        }
        if (($len -band 0xC0) -ne 0) { return $null }
        if ($p + 1 + $len -gt $B.Length) { return $null }
        if ($labels.Count -ge 128) { return $null }
        $label = [System.Text.Encoding]::UTF8.GetString($B, $p + 1, $len)
        [void]$labels.Add($label.Replace('.', '\.'))
        $p = $p + 1 + $len
    }
    return , @((($labels.ToArray()) -join '.'), $after)
}

function SRL_TypeName {
    param([int]$T)
    if ($T -eq 1) { return 'A' }
    if ($T -eq 12) { return 'PTR' }
    if ($T -eq 16) { return 'TXT' }
    if ($T -eq 28) { return 'AAAA' }
    if ($T -eq 33) { return 'SRV' }
    return $T
}

# Parse a DNS message. Returns { id, is_response, truncated, questions, answers, authority, additional } where each record
# is { name, type, ttl, data }, or $null when the header is unusable. Malformed or cut-off input ends parsing early
# (truncated = true) and never throws.
function SRL_ParseDnsMessage {
    param([byte[]]$Bytes)
    if ($null -eq $Bytes -or $Bytes.Length -lt 12) { return $null }
    $b = $Bytes
    $res = [ordered]@{ id = 0; is_response = $false; truncated = $false; questions = @(); answers = @(); authority = @(); additional = @() }
    try {
        $res.id = ([int]$b[0] * 256) + [int]$b[1]
        $flags = ([int]$b[2] * 256) + [int]$b[3]
        $res.is_response = (($flags -band 0x8000) -ne 0)
        $qd = ([int]$b[4] * 256) + [int]$b[5]
        $counts = @((([int]$b[6] * 256) + [int]$b[7]), (([int]$b[8] * 256) + [int]$b[9]), (([int]$b[10] * 256) + [int]$b[11]))
        $pos = 12
        $qs = New-Object System.Collections.ArrayList
        for ($i = 0; $i -lt $qd; $i++) {
            $rn = SRL_ReadDnsName $b $pos
            if ($null -eq $rn -or $rn[1] + 4 -gt $b.Length) { $res.truncated = $true; $res.questions = $qs.ToArray(); return [pscustomobject]$res }
            $p2 = $rn[1]
            [void]$qs.Add([pscustomobject][ordered]@{ name = $rn[0]; type = (SRL_TypeName ((([int]$b[$p2] * 256) + [int]$b[$p2 + 1]))) })
            $pos = $p2 + 4
        }
        $res.questions = $qs.ToArray()
        $secNames = @('answers', 'authority', 'additional')
        for ($s = 0; $s -lt 3; $s++) {
            $list = New-Object System.Collections.ArrayList
            for ($i = 0; $i -lt $counts[$s]; $i++) {
                $rn = SRL_ReadDnsName $b $pos
                if ($null -eq $rn) { $res.truncated = $true; break }
                $p2 = $rn[1]
                if ($p2 + 10 -gt $b.Length) { $res.truncated = $true; break }
                $type = ([int]$b[$p2] * 256) + [int]$b[$p2 + 1]
                $ttl = ([int64]$b[$p2 + 4] * 16777216) + ([int64]$b[$p2 + 5] * 65536) + ([int64]$b[$p2 + 6] * 256) + [int64]$b[$p2 + 7]
                $rdlen = ([int]$b[$p2 + 8] * 256) + [int]$b[$p2 + 9]
                $rd = $p2 + 10
                if ($rd + $rdlen -gt $b.Length) { $res.truncated = $true; break }
                $data = $null
                if ($type -eq 12) {
                    $t = SRL_ReadDnsName $b $rd
                    if ($null -ne $t) { $data = $t[0] }
                }
                elseif ($type -eq 33 -and $rdlen -ge 7) {
                    $t = SRL_ReadDnsName $b ($rd + 6)
                    $target = $null
                    if ($null -ne $t) { $target = $t[0] }
                    $data = [pscustomobject][ordered]@{
                        priority = ([int]$b[$rd] * 256) + [int]$b[$rd + 1]
                        weight   = ([int]$b[$rd + 2] * 256) + [int]$b[$rd + 3]
                        port     = ([int]$b[$rd + 4] * 256) + [int]$b[$rd + 5]
                        target   = $target
                    }
                }
                elseif ($type -eq 16) {
                    $txt = New-Object System.Collections.ArrayList
                    $q = $rd
                    while ($q -lt $rd + $rdlen) {
                        $l = [int]$b[$q]
                        if ($q + 1 + $l -gt $rd + $rdlen) { break }
                        if ($l -gt 0) { [void]$txt.Add([System.Text.Encoding]::UTF8.GetString($b, $q + 1, $l)) }
                        $q = $q + 1 + $l
                    }
                    $data = $txt.ToArray()
                }
                elseif ($type -eq 1 -and $rdlen -eq 4) {
                    $data = [string]$b[$rd] + '.' + [string]$b[$rd + 1] + '.' + [string]$b[$rd + 2] + '.' + [string]$b[$rd + 3]
                }
                elseif ($type -eq 28 -and $rdlen -eq 16) {
                    $sub = New-Object byte[] 16
                    [Array]::Copy($b, $rd, $sub, 0, 16)
                    $data = (New-Object System.Net.IPAddress -ArgumentList (, $sub)).ToString()
                }
                [void]$list.Add([pscustomobject][ordered]@{ name = $rn[0]; type = (SRL_TypeName $type); ttl = $ttl; data = $data })
                $pos = $rd + $rdlen
            }
            $res[$secNames[$s]] = $list.ToArray()
            if ($res.truncated) { break }
        }
    }
    catch { $res.truncated = $true }
    return [pscustomobject]$res
}

function SRL_Services {
    return [ordered]@{ '_ndi._tcp.local' = 'NDI'; '_omt._tcp.local' = 'OMT' }
}

# NDI/OMT sources described by a set of records (PTR -> SRV -> A). $SourceIp is the replying host, used when no A
# record names the SRV target. Each source also carries 'instance' (the full DNS-SD name) for follow-up queries.
function SRL_SourcesFromRecords {
    param($Records, [string]$SourceIp = '', [string]$Method = 'unicast')
    $recs = @(@($Records) | Where-Object { $null -ne $_ })
    $svcs = SRL_Services
    $inst = [ordered]@{}
    foreach ($r in $recs) {
        $nm = ([string](SRL_P $r 'name')).TrimEnd('.')
        $ty = [string](SRL_P $r 'type')
        if ($ty -eq 'PTR') {
            $lower = $nm.ToLowerInvariant()
            if ($svcs.Contains($lower)) {
                $target = ([string](SRL_P $r 'data')).TrimEnd('.')
                if ($target -ne '' -and $target.ToLowerInvariant().EndsWith('.' + $lower)) {
                    if (-not $inst.Contains($target.ToLowerInvariant())) { $inst[$target.ToLowerInvariant()] = @($target, $lower) }
                }
            }
        }
        elseif ($ty -eq 'SRV' -or $ty -eq 'TXT') {
            $lower = $nm.ToLowerInvariant()
            foreach ($svc in $svcs.Keys) {
                if ($lower.EndsWith('.' + $svc) -and $lower.Length -gt ($svc.Length + 1)) {
                    if (-not $inst.Contains($lower)) { $inst[$lower] = @($nm, $svc) }
                }
            }
        }
    }
    $out = New-Object System.Collections.ArrayList
    foreach ($key in $inst.Keys) {
        $full = [string]$inst[$key][0]
        $svc = [string]$inst[$key][1]
        $label = $full.Substring(0, $full.Length - $svc.Length - 1)
        $display = $label.Replace('\.', '.')
        $machine = $display
        $source = $null
        $m = [regex]::Match($display, '^(.*?) \((.*)\)$')
        if ($m.Success) { $machine = $m.Groups[1].Value; $source = $m.Groups[2].Value }
        $hostName = $null
        $port = $null
        foreach ($r in $recs) {
            if ([string](SRL_P $r 'type') -eq 'SRV' -and ([string](SRL_P $r 'name')).TrimEnd('.') -ieq $full) {
                $d = SRL_P $r 'data'
                $hostName = ([string](SRL_P $d 'target')).TrimEnd('.')
                if ($hostName -eq '') { $hostName = $null }
                $pn = SRL_Num (SRL_P $d 'port')
                if ($null -ne $pn) { $port = [int]$pn }
                break
            }
        }
        $ip = $null
        if ($null -ne $hostName) {
            foreach ($r in $recs) {
                if ([string](SRL_P $r 'type') -eq 'A' -and ([string](SRL_P $r 'name')).TrimEnd('.') -ieq $hostName) { $ip = [string](SRL_P $r 'data'); break }
            }
        }
        $ipFromReply = $false
        if (($null -eq $ip -or $ip -eq '') -and $SourceIp -ne '') { $ip = $SourceIp; $ipFromReply = $true }
        if ($ip -eq '') { $ip = $null }
        [void]$out.Add([pscustomobject][ordered]@{
                protocol = $svcs[$svc]
                name     = $display
                machine  = $machine
                source   = $source
                host     = $hostName
                port     = $port
                ip       = $ip
                local    = $false
                found_by = @($Method)
                instance = $full
                ip_from_reply = $ipFromReply
            })
    }
    return , $out.ToArray()
}

# Service types announced under _services._dns-sd._udp.local, without ".local".
function SRL_ServiceTypesFromRecords {
    param($Records)
    $out = New-Object System.Collections.ArrayList
    foreach ($r in @(@($Records) | Where-Object { $null -ne $_ })) {
        if ([string](SRL_P $r 'type') -eq 'PTR' -and ([string](SRL_P $r 'name')).TrimEnd('.') -ieq '_services._dns-sd._udp.local') {
            $t = ([string](SRL_P $r 'data')).TrimEnd('.') -replace '(?i)\.local$', ''
            if ($t -ne '' -and -not $out.Contains($t)) { [void]$out.Add($t) }
        }
    }
    return , $out.ToArray()
}

# Merge one source into a dictionary keyed protocol|name: fill missing fields, union found_by. An IP from an A record
# replaces one that was only the reply's sender address (internal 'ip_from_reply', dropped with 'instance' later).
function SRL_MergeSource {
    param($Dict, $Src)
    $key = [string]$Src.protocol + '|' + ([string]$Src.name).ToLowerInvariant()
    if (-not $Dict.Contains($key)) { $Dict[$key] = $Src; return }
    $cur = $Dict[$key]
    foreach ($f in @('machine', 'source', 'host', 'port', 'ip', 'instance')) {
        if ($null -eq $cur.$f -and $null -ne $Src.$f) { $cur.$f = $Src.$f }
    }
    if ((SRL_P $cur 'ip_from_reply') -eq $true -and $null -ne $Src.ip -and (SRL_P $Src 'ip_from_reply') -ne $true) {
        $cur.ip = $Src.ip
        if ($null -ne $cur.PSObject.Properties['ip_from_reply']) { $cur.ip_from_reply = $false }
    }
    $fb = @($cur.found_by)
    foreach ($x in @($Src.found_by)) { if ($fb -notcontains $x) { $fb += $x } }
    $cur.found_by = $fb
}

# One "unicast" discovery window: query from an ephemeral socket bound to $LocalIp, re-sent every second, replies
# merged into $Merged (protocol|name -> source); responder IPs and service types are added to the two lists.
# $DestIp/$DestPort exist for tests\Test-Lan.ps1 (a fake responder on loopback). Returns { ok, answers, error }.
function SRL_MdnsUnicast {
    param([string]$LocalIp, [int]$ListenMs, $Merged, $Responders, $TypesSeen, [string]$DestIp = '224.0.0.251', [int]$DestPort = 5353)
    $res = [ordered]@{ ok = $false; answers = 0; error = $null }
    $sock = $null
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $localAddr = [System.Net.IPAddress]::Parse($LocalIp)
        $sock = New-Object System.Net.Sockets.Socket([System.Net.Sockets.AddressFamily]::InterNetwork, [System.Net.Sockets.SocketType]::Dgram, [System.Net.Sockets.ProtocolType]::Udp)
        $sock.Bind((New-Object System.Net.IPEndPoint($localAddr, 0)))
        $sock.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::IP, [System.Net.Sockets.SocketOptionName]::MulticastInterface, $localAddr.GetAddressBytes())
        $sock.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::IP, [System.Net.Sockets.SocketOptionName]::MulticastTimeToLive, 255)
        $dest = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($DestIp), $DestPort)
        $query = SRL_NewDnsQuery -Names @('_ndi._tcp.local', '_omt._tcp.local', '_services._dns-sd._udp.local') -Types @(12) -QU
        $buf = New-Object byte[] 9216
        $followed = @{}
        $nextSend = 0
        $sendOk = 0
        while ($sw.ElapsedMilliseconds -lt $ListenMs) {
            if ($sw.ElapsedMilliseconds -ge $nextSend) {
                try { [void]$sock.SendTo($query, $dest); $sendOk++ } catch { $res.error = SRL_Short ('send: ' + $_.Exception.Message) 160 }
                $nextSend += 1000
            }
            # One SRV (or A) follow-up for instances that arrived without them, sent as soon as they are seen.
            $fuNames = New-Object System.Collections.ArrayList
            $fuTypes = New-Object System.Collections.ArrayList
            foreach ($s in @($Merged.Values)) {
                if ($null -eq $s.instance -or $followed.ContainsKey($s.instance)) { continue }
                if ($null -eq $s.port -or $null -eq $s.host) { [void]$fuNames.Add($s.instance); [void]$fuTypes.Add(33); $followed[$s.instance] = $true }
                elseif ($null -eq $s.ip) { [void]$fuNames.Add($s.host); [void]$fuTypes.Add(1); $followed[$s.instance] = $true }
            }
            if ($fuNames.Count -gt 0) {
                try { [void]$sock.SendTo((SRL_NewDnsQuery -Names ([string[]]$fuNames.ToArray()) -Types ([int[]]$fuTypes.ToArray()) -QU), $dest) } catch { }
            }
            if (-not $sock.Poll(100000, [System.Net.Sockets.SelectMode]::SelectRead)) { continue }
            $ep = [System.Net.EndPoint](New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0))
            $n = 0
            try { $n = $sock.ReceiveFrom($buf, [ref]$ep) } catch { continue }
            if ($n -le 0) { continue }
            $pkt = New-Object byte[] $n
            [Array]::Copy($buf, $pkt, $n)
            $msg = SRL_ParseDnsMessage $pkt
            if ($null -eq $msg -or -not $msg.is_response) { continue }
            $from = ([System.Net.IPEndPoint]$ep).Address.ToString()
            $res.answers++
            if (-not $Responders.Contains($from)) { [void]$Responders.Add($from) }
            $recs = @($msg.answers) + @($msg.authority) + @($msg.additional)
            foreach ($t in (SRL_ServiceTypesFromRecords $recs)) { if (-not $TypesSeen.Contains($t)) { [void]$TypesSeen.Add($t) } }
            foreach ($s in (SRL_SourcesFromRecords $recs $from 'unicast')) { SRL_MergeSource $Merged $s }
        }
        if ($sendOk -gt 0) { $res.ok = $true; $res.error = $null }
        elseif ($null -eq $res.error) { $res.error = 'the query could not be sent' }
    }
    catch { $res.error = SRL_Short ([string]$_.Exception.Message) 160 }
    finally { if ($null -ne $sock) { try { $sock.Close() } catch { } } }
    return [pscustomobject]$res
}

# ---------------------------------------------------------------------------------------------
# MAC vendor lookup (small embedded OUI table; every entry checked against the IEEE registry via macvendors.com)
# ---------------------------------------------------------------------------------------------
function SRL_OuiTable {
    if ($null -ne $script:SRL_OuiCache) { return $script:SRL_OuiCache }
    # OUI|vendor|category   category: network = switches/routers/Wi-Fi, pc = PC/NIC makers, broadcast = video/audio gear
    $raw = @'
00000C|Cisco|network
000142|Cisco|network
004096|Cisco|network
00180A|Cisco Meraki|network
E0553D|Cisco Meraki|network
000B86|Aruba (HPE)|network
001A1E|Aruba (HPE)|network
24DEC6|Aruba (HPE)|network
000585|Juniper|network
288A1C|Juniper|network
000496|Extreme Networks|network
00090F|Fortinet|network
00156D|Ubiquiti|network
002722|Ubiquiti|network
24A43C|Ubiquiti|network
44D9E7|Ubiquiti|network
687251|Ubiquiti|network
7483C2|Ubiquiti|network
788A20|Ubiquiti|network
802AA8|Ubiquiti|network
B4FBE4|Ubiquiti|network
F09FC2|Ubiquiti|network
FCECDA|Ubiquiti|network
E063DA|Ubiquiti|network
000C42|MikroTik|network
4C5E0C|MikroTik|network
6C3B6B|MikroTik|network
744D28|MikroTik|network
B869F4|MikroTik|network
CC2DE0|MikroTik|network
D4CA6D|MikroTik|network
E48D8C|MikroTik|network
00095B|Netgear|network
00146C|Netgear|network
001B2F|Netgear|network
001E2A|Netgear|network
00223F|Netgear|network
0024B2|Netgear|network
204E7F|Netgear|network
28C68E|Netgear|network
9C3DCF|Netgear|network
A040A0|Netgear|network
C03F0E|Netgear|network
001478|TP-Link|network
14CC20|TP-Link|network
50C7BF|TP-Link|network
60E327|TP-Link|network
98DAC4|TP-Link|network
C04A00|TP-Link|network
EC086B|TP-Link|network
F4F26D|TP-Link|network
00055D|D-Link|network
000D88|D-Link|network
001195|D-Link|network
001346|D-Link|network
1C7EE5|D-Link|network
001349|Zyxel|network
00A0C5|Zyxel|network
000EA6|ASUS|pc
00112F|ASUS|pc
0015F2|ASUS|pc
04D9F5|ASUS|pc
2C56DC|ASUS|pc
001B21|Intel|pc
000E0C|Intel|pc
001320|Intel|pc
A0369F|Intel|pc
6805CA|Intel|pc
00E04C|Realtek|pc
001422|Dell|pc
F8BC12|Dell|pc
1866DA|Dell|pc
B083FE|Dell|pc
D4BED9|Dell|pc
0026B9|Dell|pc
0024E8|Dell|pc
3CD92B|HP|pc
9C8E99|HP|pc
0017A4|HP|pc
705A0F|HP|pc
480FCF|HP|pc
10604B|HP|pc
ECB1D7|HP|pc
70106F|HPE|network
98FA9B|Lenovo|pc
507B9D|Lenovo|pc
E86A64|Lenovo|pc
8C1645|Lenovo|pc
002590|Supermicro|pc
0CC47A|Supermicro|pc
AC1F6B|Supermicro|pc
00241D|Gigabyte|pc
1C1B0D|Gigabyte|pc
74D435|Gigabyte|pc
E0D55E|Gigabyte|pc
B42E99|Gigabyte|pc
002522|ASRock|pc
7085C2|ASRock|pc
BC5FF4|ASRock|pc
D05099|ASRock|pc
00D861|MSI|pc
4CCC6A|MSI|pc
D8CB8A|MSI|pc
448A5B|MSI|pc
0050F2|Microsoft|pc
281878|Microsoft|pc
7C1E52|Microsoft|pc
00155D|Microsoft Hyper-V|other
000393|Apple|mobile
000A95|Apple|mobile
0017F2|Apple|mobile
3C0754|Apple|mobile
A483E7|Apple|mobile
F01898|Apple|mobile
B827EB|Raspberry Pi|other
DCA632|Raspberry Pi|other
E45F01|Raspberry Pi|other
005056|VMware|other
000C29|VMware|other
080027|VirtualBox|other
000C17|AJA Video Systems|broadcast
7C2E0D|Blackmagic Design|broadcast
0002C5|Evertz|broadcast
000F9B|Ross Video|broadcast
00A0DE|Yamaha|broadcast
001DC1|Audinate (Dante)|broadcast
000EDD|Shure|broadcast
00014A|Sony|broadcast
0013A9|Sony|broadcast
080046|Sony|broadcast
AC9B0A|Sony|broadcast
008045|Panasonic|broadcast
0080F0|Panasonic|broadcast
0000F0|Samsung|mobile
'@
    $t = @{}
    foreach ($line in ($raw -split "`r?`n")) {
        $parts = $line.Split('|')
        if ($parts.Count -ge 3 -and $parts[0].Trim().Length -eq 6) { $t[$parts[0].Trim().ToUpperInvariant()] = @($parts[1].Trim(), $parts[2].Trim()) }
    }
    $script:SRL_OuiCache = $t
    return $t
}

# { vendor, category, randomized_mac } for a MAC in any common notation.
function SRL_GetVendor {
    param([string]$Mac)
    $res = [ordered]@{ vendor = $null; category = $null; randomized_mac = $false }
    $hex = (([string]$Mac) -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
    if ($hex.Length -lt 6) { return [pscustomobject]$res }
    $first = [Convert]::ToInt32($hex.Substring(0, 2), 16)
    if (($first -band 2) -ne 0) { $res.randomized_mac = $true; return [pscustomobject]$res }
    $t = SRL_OuiTable
    $e = $t[$hex.Substring(0, 6)]
    if ($null -ne $e) { $res.vendor = $e[0]; $res.category = $e[1] }
    return [pscustomobject]$res
}

# ---------------------------------------------------------------------------------------------
# iperf3
# ---------------------------------------------------------------------------------------------

# Receiver-side numbers from iperf3 -J output of a reverse (-R) run. With -R the client is the receiver:
# TCP end.sum_received; UDP end.sum (falls back to end.sum_received) - both checked against iperf3 3.22.
function SRL_ParseIperfJson {
    param([string]$Json, [switch]$Udp)
    if ($Udp) { $o = [ordered]@{ target_mbps = $null; mbps = $null; packets = $null; lost = $null; loss_pct = $null; jitter_ms = $null; seconds = $null; error = $null } }
    else { $o = [ordered]@{ mbps = $null; retransmits = $null; seconds = $null; error = $null } }
    $txt = [string]$Json
    if ($txt.Trim() -eq '') { $o.error = 'iperf3 gave no output'; return [pscustomobject]$o }
    # cygwin iperf3 can print -nan / inf, which is not JSON.
    $txt = [regex]::Replace($txt, '(?<=[:\[,]\s*)-?(nan|inf)\b', 'null')
    $j = $null
    try { $j = $txt | ConvertFrom-Json } catch { $o.error = 'iperf3 output is not JSON'; return [pscustomobject]$o }
    $err = [string](SRL_P $j 'error')
    if ($err -ne '') { $o.error = SRL_Short ('iperf3: ' + $err) 160 }
    $end = SRL_P $j 'end'
    $tbps = SRL_Num (SRL_P (SRL_P (SRL_P $j 'start') 'test_start') 'target_bitrate')
    if ($Udp) {
        if ($null -ne $tbps -and $tbps -gt 0) { $o.target_mbps = [math]::Round($tbps / 1e6, 1) }
        $sum = SRL_P $end 'sum'
        $rcv = SRL_P $end 'sum_received'
        if ($null -eq $sum) { $sum = $rcv }
        if ($null -ne $sum) {
            $bps = SRL_Num (SRL_P $rcv 'bits_per_second')
            if ($null -eq $bps) { $bps = SRL_Num (SRL_P $sum 'bits_per_second') }
            if ($null -ne $bps) { $o.mbps = [math]::Round($bps / 1e6, 1) }
            $v = SRL_Num (SRL_P $sum 'packets'); if ($null -ne $v) { $o.packets = [int64]$v }
            $v = SRL_Num (SRL_P $sum 'lost_packets'); if ($null -ne $v) { $o.lost = [int64]$v }
            $v = SRL_Num (SRL_P $sum 'lost_percent'); if ($null -ne $v) { $o.loss_pct = [math]::Round($v, 3) }
            $v = SRL_Num (SRL_P $sum 'jitter_ms'); if ($null -ne $v) { $o.jitter_ms = [math]::Round($v, 3) }
            $v = SRL_Num (SRL_P $sum 'seconds'); if ($null -ne $v) { $o.seconds = [math]::Round($v, 1) }
        }
    }
    else {
        $rcv = SRL_P $end 'sum_received'
        if ($null -eq $rcv) { $rcv = SRL_P $end 'sum' }
        $bps = SRL_Num (SRL_P $rcv 'bits_per_second')
        if ($null -ne $bps) { $o.mbps = [math]::Round($bps / 1e6, 1) }
        $v = SRL_Num (SRL_P $rcv 'seconds'); if ($null -ne $v) { $o.seconds = [math]::Round($v, 1) }
        # Retransmits are counted by the sender (the server with -R); cygwin builds on Windows usually report none.
        $rt = SRL_Num (SRL_P (SRL_P $end 'sum_sent') 'retransmits')
        if ($null -eq $rt) { $rt = SRL_Num (SRL_P (SRL_P (SRL_P (SRL_P $j 'server_output_json') 'end') 'sum_sent') 'retransmits') }
        if ($null -ne $rt) { $o.retransmits = [int64]$rt }
    }
    return [pscustomobject]$o
}

# Start one iperf3 -R client (hidden, output to temp files). SRL_FinishIperf waits for it and parses the result.
function SRL_StartIperf {
    param([string]$Exe, [string]$Ip, [int]$Port, [int]$Seconds, [double]$TargetMbps, [switch]$Udp)
    $ipArgs = @('-c', $Ip, '-p', [string]$Port, '-R', '-t', [string]$Seconds, '-b', ([string][int][math]::Round($TargetMbps) + 'M'), '-J', '--connect-timeout', '3000')
    # 1400-byte datagrams: the default length follows the path MTU (64 KB on loopback, which fragments and loses).
    if ($Udp) { $ipArgs += @('-u', '-l', '1400') }
    $outFile = Join-Path $env:TEMP ('showready-iperf-' + [guid]::NewGuid().ToString('N') + '.json')
    $h = [pscustomobject]@{ ip = $Ip; udp = [bool]$Udp; seconds = $Seconds; out = $outFile; err = $outFile + '.err'; proc = $null; error = $null }
    try {
        $h.proc = Start-Process -FilePath $Exe -ArgumentList $ipArgs -WorkingDirectory $env:TEMP -WindowStyle Hidden -PassThru -RedirectStandardOutput $h.out -RedirectStandardError $h.err
    }
    catch { $h.error = SRL_Short ('could not run iperf3: ' + $_.Exception.Message) 160 }
    return $h
}

function SRL_FinishIperf {
    param($H)
    $udpSw = [bool]$H.udp
    $json = ''
    $r = $null
    try {
        if ($null -ne $H.error) {
            $r = SRL_ParseIperfJson '' -Udp:$udpSw
            $r.error = $H.error
        }
        elseif (-not $H.proc.WaitForExit(($H.seconds + 15) * 1000)) {
            try { $H.proc.Kill() } catch { }
            $r = SRL_ParseIperfJson '' -Udp:$udpSw
            $r.error = 'iperf3 did not finish within ' + ($H.seconds + 15) + ' s'
        }
        else {
            Start-Sleep -Milliseconds 100
            if (Test-Path -LiteralPath $H.out) { $json = [System.IO.File]::ReadAllText($H.out) }
            if ($json.Trim() -eq '' -and (Test-Path -LiteralPath $H.err)) {
                $r = SRL_ParseIperfJson '' -Udp:$udpSw
                $r.error = SRL_Short ('iperf3: ' + [System.IO.File]::ReadAllText($H.err)) 160
            }
            else { $r = SRL_ParseIperfJson $json -Udp:$udpSw }
        }
    }
    catch {
        $r = SRL_ParseIperfJson '' -Udp:$udpSw
        $r.error = SRL_Short ('could not run iperf3: ' + $_.Exception.Message) 160
    }
    finally {
        if ($null -ne $H.proc) { try { if (-not $H.proc.HasExited) { $H.proc.Kill() } } catch { } }
        foreach ($f in @($H.out, $H.err)) { try { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } } catch { } }
    }
    return $r
}

function SRL_RunIperf {
    param([string]$Exe, [string]$Ip, [int]$Port, [int]$Seconds, [double]$TargetMbps, [switch]$Udp)
    $tries = 0
    while ($true) {
        $tries++
        $r = SRL_FinishIperf (SRL_StartIperf -Exe $Exe -Ip $Ip -Port $Port -Seconds $Seconds -TargetMbps $TargetMbps -Udp:$Udp)
        if ($tries -eq 1 -and $null -ne $r.error -and $r.error -match '(?i)busy') { Start-Sleep -Seconds 2; continue }
        return $r
    }
}

# "Both at once": one client per host, all started together; returns the per-host results in the same order.
function SRL_RunIperfTogether {
    param([string]$Exe, [string[]]$Ips, [int]$Port, [int]$Seconds, [double]$TargetMbps, [switch]$Udp)
    $tries = 0
    while ($true) {
        $tries++
        $handles = @()
        foreach ($ip in $Ips) { $handles += SRL_StartIperf -Exe $Exe -Ip $ip -Port $Port -Seconds $Seconds -TargetMbps $TargetMbps -Udp:$Udp }
        $res = @()
        foreach ($hd in $handles) { $res += SRL_FinishIperf $hd }
        $busy = @($res | Where-Object { $null -ne $_.error -and $_.error -match '(?i)busy' })
        if ($tries -eq 1 -and $busy.Count -gt 0) { Start-Sleep -Seconds 2; continue }
        return , $res
    }
}

# Sum the per-host results of SRL_RunIperfTogether into the contract's combined object.
function SRL_CombineResults {
    param([string[]]$Ips, [int]$Seconds, $TcpResults, $UdpResults, $TargetMbps)
    $tcpSum = 0.0; $tcpN = 0; $tcpErr = $null
    $perHost = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $Ips.Count; $i++) {
        $t = $null
        if ($null -ne $TcpResults -and $i -lt @($TcpResults).Count) { $t = @($TcpResults)[$i] }
        $m = $null
        if ($null -ne $t) { $m = $t.mbps }
        if ($null -ne $m) { $tcpSum += [double]$m; $tcpN++ }
        if ($null -ne $t -and $null -ne $t.error -and $null -eq $tcpErr) { $tcpErr = $Ips[$i] + ': ' + $t.error }
        if ($null -eq $t -and $null -eq $tcpErr) { $tcpErr = $Ips[$i] + ': not run' }
        [void]$perHost.Add([pscustomobject][ordered]@{ ip = $Ips[$i]; mbps = $m })
    }
    $tcpMbps = $null
    if ($tcpN -gt 0) { $tcpMbps = [math]::Round($tcpSum, 1) }
    $pk = [int64]0; $lo = [int64]0; $um = 0.0; $uN = 0; $jit = $null; $udpErr = $null; $havePk = $false
    for ($i = 0; $i -lt $Ips.Count; $i++) {
        $u = $null
        if ($null -ne $UdpResults -and $i -lt @($UdpResults).Count) { $u = @($UdpResults)[$i] }
        if ($null -eq $u) { if ($null -eq $udpErr) { $udpErr = $Ips[$i] + ': not run' }; continue }
        if ($null -ne $u.error -and $null -eq $udpErr) { $udpErr = $Ips[$i] + ': ' + $u.error }
        if ($null -ne $u.mbps) { $um += [double]$u.mbps; $uN++ }
        if ($null -ne $u.packets) { $pk += [int64]$u.packets; $havePk = $true }
        if ($null -ne $u.lost) { $lo += [int64]$u.lost }
        if ($null -ne $u.jitter_ms -and ($null -eq $jit -or [double]$u.jitter_ms -gt $jit)) { $jit = [double]$u.jitter_ms }
    }
    $udpObj = [ordered]@{ target_mbps = $null; mbps = $null; packets = $null; lost = $null; loss_pct = $null; jitter_ms = $jit; error = $udpErr }
    if ($null -ne $TargetMbps) { $udpObj.target_mbps = [math]::Round([double]$TargetMbps * $Ips.Count, 1) }
    if ($uN -gt 0) { $udpObj.mbps = [math]::Round($um, 1) }
    if ($havePk) {
        $udpObj.packets = $pk; $udpObj.lost = $lo
        if ($pk -gt 0) { $udpObj.loss_pct = [math]::Round(100.0 * $lo / $pk, 2) }
    }
    $err = $null
    if ($null -ne $tcpErr) { $err = $tcpErr } elseif ($null -ne $udpErr) { $err = $udpErr }
    return [pscustomobject][ordered]@{
        hosts   = @($Ips)
        seconds = $Seconds
        tcp     = [pscustomobject][ordered]@{ mbps = $tcpMbps; per_host = $perHost.ToArray(); error = $tcpErr }
        udp     = [pscustomobject]$udpObj
        error   = $err
    }
}

function SRL_TestTcp {
    param([string]$Ip, [int]$Port, [int]$TimeoutMs)
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $ar = $c.BeginConnect($Ip, $Port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $c.EndConnect($ar)
        return $c.Connected
    }
    catch { return $false }
    finally { try { $c.Close() } catch { } }
}

# ---------------------------------------------------------------------------------------------
# Windows DNS-SD browse (dnsapi.dll DnsServiceBrowse) through Add-Type. Returns $null when ready, else an error string.
# ---------------------------------------------------------------------------------------------
function SRL_InitDnsSd {
    if ($null -ne ('SRLanDnsSdBrowser' -as [type])) { return $null }
    $cs = @'
using System;
using System.Collections.Generic;
using System.Runtime.ExceptionServices;
using System.Runtime.InteropServices;
using System.Security;

public class SRLanDnsSdBrowser
{
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate void BrowseCallback(uint status, IntPtr context, IntPtr records);

    [StructLayout(LayoutKind.Sequential)]
    private struct BrowseRequest
    {
        public uint Version;
        public uint InterfaceIndex;
        public IntPtr QueryName;
        public IntPtr Callback;
        public IntPtr Context;
    }

    // Both pointers must stay valid until the browse is cancelled (dnsapi keeps them), so they live in unmanaged memory.
    [DllImport("dnsapi.dll", ExactSpelling = true)]
    private static extern int DnsServiceBrowse(IntPtr request, IntPtr cancel);
    [DllImport("dnsapi.dll", ExactSpelling = true)]
    private static extern int DnsServiceBrowseCancel(IntPtr cancel);
    [DllImport("dnsapi.dll", ExactSpelling = true)]
    private static extern void DnsFree(IntPtr data, int freeType);

    // Callbacks can arrive after Stop(); keep every delegate and native buffer alive for the process lifetime (a few
    // hundred bytes per run).
    private static readonly List<object> KeepAlive = new List<object>();

    private readonly object sync = new object();
    private readonly List<string> rows = new List<string>();
    private BrowseCallback callback;
    private IntPtr cancelPtr = IntPtr.Zero;
    private bool started;
    public uint LastStatus;

    [HandleProcessCorruptedStateExceptions, SecurityCritical]
    public int Start(string queryName, uint interfaceIndex)
    {
        try
        {
            callback = new BrowseCallback(OnBrowse);
            IntPtr namePtr = Marshal.StringToHGlobalUni(queryName);
            BrowseRequest req = new BrowseRequest();
            req.Version = 1;
            req.InterfaceIndex = interfaceIndex;
            req.QueryName = namePtr;
            req.Callback = Marshal.GetFunctionPointerForDelegate(callback);
            req.Context = IntPtr.Zero;
            IntPtr reqPtr = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(BrowseRequest)));
            Marshal.StructureToPtr(req, reqPtr, false);
            cancelPtr = Marshal.AllocHGlobal(IntPtr.Size * 2);
            Marshal.WriteIntPtr(cancelPtr, 0, IntPtr.Zero);
            Marshal.WriteIntPtr(cancelPtr, IntPtr.Size, IntPtr.Zero);
            lock (KeepAlive) { KeepAlive.Add(callback); KeepAlive.Add(namePtr); KeepAlive.Add(reqPtr); KeepAlive.Add(cancelPtr); KeepAlive.Add(this); }
            int rc = DnsServiceBrowse(reqPtr, cancelPtr);
            started = (rc == 9506);
            return rc;
        }
        catch (Exception) { started = false; return -1; }
    }

    [HandleProcessCorruptedStateExceptions, SecurityCritical]
    public void Stop()
    {
        if (!started) return;
        started = false;
        try { DnsServiceBrowseCancel(cancelPtr); } catch (Exception) { }
    }

    public string[] Rows()
    {
        lock (sync) { return rows.ToArray(); }
    }

    private static string Str(IntPtr p)
    {
        if (p == IntPtr.Zero) return "";
        return Marshal.PtrToStringUni(p) ?? "";
    }

    [HandleProcessCorruptedStateExceptions, SecurityCritical]
    private void OnBrowse(uint status, IntPtr context, IntPtr records)
    {
        try
        {
            LastStatus = status;
            if (status != 0 || records == IntPtr.Zero) return;
            int dataOffset = 2 * IntPtr.Size + 16;
            IntPtr p = records;
            int guard = 0;
            while (p != IntPtr.Zero && guard++ < 256)
            {
                IntPtr next = Marshal.ReadIntPtr(p, 0);
                string name = Str(Marshal.ReadIntPtr(p, IntPtr.Size));
                int type = (ushort)Marshal.ReadInt16(p, 2 * IntPtr.Size);
                IntPtr data = new IntPtr(p.ToInt64() + dataOffset);
                string row = null;
                if (type == 12) row = "PTR\t" + name + "\t" + Str(Marshal.ReadIntPtr(data, 0));
                else if (type == 33) row = "SRV\t" + name + "\t" + Str(Marshal.ReadIntPtr(data, 0)) + "\t" + (ushort)Marshal.ReadInt16(data, IntPtr.Size + 4);
                else if (type == 1)
                {
                    byte[] b = new byte[4];
                    Marshal.Copy(data, b, 0, 4);
                    row = "A\t" + name + "\t" + b[0] + "." + b[1] + "." + b[2] + "." + b[3];
                }
                if (row != null) { lock (sync) { rows.Add(row); } }
                p = next;
            }
        }
        catch (Exception) { }
        finally
        {
            if (records != IntPtr.Zero) { try { DnsFree(records, 1); } catch (Exception) { } }
        }
    }
}
'@
    try {
        # -IgnoreWarnings: pwsh flags HandleProcessCorruptedStateExceptions as obsolete (it only matters on PS 5.1).
        Add-Type -TypeDefinition $cs -Language CSharp -IgnoreWarnings -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null
        return $null
    }
    catch { return (SRL_Short ('Windows DNS-SD unavailable: ' + $_.Exception.Message) 160) }
}

# Rows from SRLanDnsSdBrowser ("PTR\tname\ttarget", "SRV\tname\ttarget\tport", "A\tname\tip") as parsed records.
function SRL_RecordsFromRows {
    param([string[]]$Rows)
    $out = New-Object System.Collections.ArrayList
    foreach ($row in @($Rows)) {
        $f = ([string]$row).Split("`t")
        if ($f.Count -lt 3) { continue }
        if ($f[0] -eq 'PTR') { [void]$out.Add([pscustomobject][ordered]@{ name = $f[1].TrimEnd('.'); type = 'PTR'; ttl = $null; data = $f[2].TrimEnd('.') }) }
        elseif ($f[0] -eq 'SRV' -and $f.Count -ge 4) {
            $port = SRL_Num $f[3]
            if ($null -ne $port) { $port = [int]$port }
            [void]$out.Add([pscustomobject][ordered]@{ name = $f[1].TrimEnd('.'); type = 'SRV'; ttl = $null; data = [pscustomobject][ordered]@{ priority = $null; weight = $null; port = $port; target = $f[2].TrimEnd('.') } })
        }
        elseif ($f[0] -eq 'A') { [void]$out.Add([pscustomobject][ordered]@{ name = $f[1].TrimEnd('.'); type = 'A'; ttl = $null; data = $f[2] }) }
    }
    return , $out.ToArray()
}

# ---------------------------------------------------------------------------------------------
# Adapter, discovery-server config, sweep
# ---------------------------------------------------------------------------------------------
function SRL_VirtualRegex { return 'Hyper-V|Virtual|vEthernet|VPN|TAP|WireGuard|Tailscale|ZeroTier|VMware|VirtualBox|Loopback|WAN Miniport|Bluetooth' }

# The adapter the feeds arrive on: Up, not virtual, usable IPv4; wired first (fastest), else the default-route adapter.
# Returns @(adapterObject, ifIndex, macAddress) or $null.
function SRL_SelectAdapter {
    param($Errors)
    $rx = SRL_VirtualRegex
    $defIdx = $null
    $gwByIdx = @{}
    try {
        $routes = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -AddressFamily IPv4 -ErrorAction SilentlyContinue)
        foreach ($r in $routes) { if (-not $gwByIdx.ContainsKey([int]$r.InterfaceIndex)) { $gwByIdx[[int]$r.InterfaceIndex] = [string]$r.NextHop } }
        if ($routes.Count -gt 0) { $defIdx = [int](($routes | Sort-Object RouteMetric | Select-Object -First 1).InterfaceIndex) }
    }
    catch { [void]$Errors.Add('default route: ' + $_.Exception.Message) }

    $cands = New-Object System.Collections.ArrayList
    foreach ($a in @(Get-NetAdapter -ErrorAction Stop)) {
        if ([string]$a.Status -ne 'Up') { continue }
        $name = [string]$a.Name
        $desc = [string]$a.InterfaceDescription
        if (-not $a.HardwareInterface -or $a.Virtual -or $desc -match $rx -or $name -match $rx) { continue }
        $kind = 'other'
        if ([string]$a.PhysicalMediaType -match '802\.11' -or [string]$a.MediaType -match '802\.11' -or $desc -match 'Wi-?Fi|Wireless|802\.11') { $kind = 'wifi' }
        elseif ([string]$a.PhysicalMediaType -match '802\.3|Ethernet' -or [string]$a.MediaType -match '802\.3' -or $desc -match 'Ethernet|Gigabit|GbE|LAN|Realtek|Intel\(R\) Ethernet') { $kind = 'wired' }
        $ip = $null
        $prefix = $null
        foreach ($x in @(Get-NetIPAddress -InterfaceIndex $a.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
            if ([string]$x.IPAddress -notlike '169.254.*' -and [string]$x.IPAddress -ne '') { $ip = [string]$x.IPAddress; $prefix = [int]$x.PrefixLength; break }
        }
        if ($null -eq $ip) { continue }
        $link = $null
        if ($null -ne $a.Speed -and [double]$a.Speed -gt 0) { $link = [int64][math]::Round([double]$a.Speed / 1000000) }
        $gw = $null
        if ($gwByIdx.ContainsKey([int]$a.InterfaceIndex)) { $gw = $gwByIdx[[int]$a.InterfaceIndex] }
        if ($gw -eq '0.0.0.0' -or $gw -eq '') { $gw = $null }
        [void]$cands.Add([pscustomobject]@{ a = $a; kind = $kind; ip = $ip; prefix = $prefix; link = $link; gw = $gw; idx = [int]$a.InterfaceIndex })
    }
    $pick = $null
    $why = $null
    $wired = @($cands | Where-Object { $_.kind -eq 'wired' } | Sort-Object -Property @{ Expression = { if ($null -eq $_.link) { -1 } else { $_.link } } } -Descending)
    if ($wired.Count -gt 0) { $pick = $wired[0]; $why = 'wired' }
    elseif ($null -ne $defIdx) {
        foreach ($c in $cands) { if ($c.idx -eq $defIdx) { $pick = $c; $why = 'default_route'; break } }
    }
    if ($null -eq $pick) { return $null }
    $local = New-Object System.Collections.ArrayList
    try {
        foreach ($x in @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue)) { $s = [string]$x.IPAddress; if ($s -ne '' -and -not $local.Contains($s)) { [void]$local.Add($s) } }
    }
    catch { }
    $obj = [pscustomobject][ordered]@{
        name           = [string]$pick.a.Name
        description    = [string]$pick.a.InterfaceDescription
        kind           = $pick.kind
        chosen_because = $why
        ipv4           = $pick.ip
        prefix_length  = $pick.prefix
        gateway        = $pick.gw
        link_mbps      = $pick.link
        local_ips      = $local.ToArray()
    }
    $mac = ([string]$pick.a.MacAddress).ToLowerInvariant()
    return , @($obj, $pick.idx, $mac)
}

function SRL_ReadDiscoveryServers {
    param($Errors)
    $res = [ordered]@{ ndi = @(); omt = @(); ndi_config_path = $null; omt_settings_path = $null }
    try {
        $dirs = @($env:NDI_CONFIG_DIR, (Join-Path ([string]$env:APPDATA) 'NDI'), (Join-Path ([string]$env:ProgramData) 'NDI'))
        foreach ($d in $dirs) {
            if ([string]::IsNullOrEmpty($d)) { continue }
            $f = Join-Path $d 'ndi-config.v1.json'
            if (-not (Test-Path -LiteralPath $f)) { continue }
            $res.ndi_config_path = $f
            $j = [System.IO.File]::ReadAllText($f) | ConvertFrom-Json
            $disc = [string](SRL_P (SRL_P (SRL_P $j 'ndi') 'networks') 'discovery')
            $res.ndi = @($disc.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
            break
        }
    }
    catch { [void]$Errors.Add('NDI config: ' + (SRL_Short $_.Exception.Message 120)) }
    try {
        $dir = [string]$env:OMT_STORAGE_PATH
        if ($dir -eq '') { $dir = Join-Path ([string]$env:ProgramData) 'OMT' }
        $f = Join-Path $dir 'settings.xml'
        if (Test-Path -LiteralPath $f) {
            $res.omt_settings_path = $f
            $x = New-Object System.Xml.XmlDocument
            $x.Load($f)
            $n = $x.SelectSingleNode('//DiscoveryServer')
            if ($null -ne $n -and ([string]$n.InnerText).Trim() -ne '') { $res.omt = @(([string]$n.InnerText).Trim()) }
        }
    }
    catch { [void]$Errors.Add('OMT settings: ' + (SRL_Short $_.Exception.Message 120)) }
    return [pscustomobject]$res
}

# Proxy ARP (seen on venue Wi-Fi): the access point answers ARP for every address, so the neighbour table lists the
# whole subnet under one MAC. Drops neighbour-only entries (no ping answer, not the gateway) whose MAC is shared by
# 8 or more addresses. $Macs is ip -> mac and is changed in place; returns the number of entries dropped.
function SRL_DropProxyArp {
    param([hashtable]$Macs, [hashtable]$PingMs, [string]$Gateway, $Errors)
    $byMac = @{}
    foreach ($ip in @($Macs.Keys)) {
        $m = [string]$Macs[$ip]
        if (-not $byMac.ContainsKey($m)) { $byMac[$m] = New-Object System.Collections.ArrayList }
        [void]$byMac[$m].Add($ip)
    }
    $dropped = 0
    foreach ($m in @($byMac.Keys)) {
        $ips = $byMac[$m]
        if ($ips.Count -lt 8) { continue }
        $n = 0
        foreach ($ip in $ips) {
            if ($ip -eq $Gateway) { continue }
            if ($null -ne $PingMs -and $PingMs.ContainsKey($ip)) { continue }
            $Macs.Remove($ip)
            $n++
        }
        if ($n -gt 0 -and $null -ne $Errors) {
            [void]$Errors.Add('neighbour table: ' + $ips.Count + ' addresses share MAC ' + $m + ' (proxy ARP); ' + $n + ' that did not answer ping are not counted')
        }
        $dropped += $n
    }
    return $dropped
}

# ICMP sweep of the adapter's subnet, capped at /24. Returns @(sweepObject, hashtable ip -> rtt_ms).
function SRL_Sweep {
    param([string]$Ip, [int]$Prefix, [int]$TimeoutMs, $Errors)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $eff = $Prefix
    if ($eff -lt 24) { $eff = 24 }
    $alive = @{}
    if ($eff -ge 31) {
        return , @([pscustomobject][ordered]@{ cidr = ($Ip + '/' + $Prefix); scanned = 0; alive = 0; seconds = 0; skipped_reason = 'point-to-point link (/' + $Prefix + '), nothing to scan' }, $alive)
    }
    $ipN = SRL_IpToInt $Ip
    $size = [int64][math]::Pow(2, 32 - $eff)
    $net = $ipN - ($ipN % $size)
    $cidr = (SRL_IntToIp $net) + '/' + $eff
    $targets = New-Object System.Collections.ArrayList
    for ($n = $net + 1; $n -lt $net + $size - 1; $n++) { if ($n -ne $ipN) { [void]$targets.Add((SRL_IntToIp $n)) } }
    for ($i = 0; $i -lt $targets.Count; $i += 64) {
        $batch = @($targets.GetRange($i, [math]::Min(64, $targets.Count - $i)))
        $pings = New-Object System.Collections.ArrayList
        $tasks = New-Object System.Collections.ArrayList
        foreach ($t in $batch) {
            try {
                $p = New-Object System.Net.NetworkInformation.Ping
                [void]$pings.Add($p)
                [void]$tasks.Add(@($t, $p.SendPingAsync($t, $TimeoutMs)))
            }
            catch { }
        }
        try {
            $arr = [System.Threading.Tasks.Task[]]@($tasks | ForEach-Object { $_[1] })
            [void][System.Threading.Tasks.Task]::WaitAll($arr, $TimeoutMs + 1500)
        }
        catch { }
        foreach ($pair in $tasks) {
            try {
                $task = $pair[1]
                if ($task.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion -and $task.Result.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                    $alive[[string]$pair[0]] = [int64]$task.Result.RoundtripTime
                }
            }
            catch { }
        }
        foreach ($p in $pings) { try { $p.Dispose() } catch { } }
    }
    $sw.Stop()
    $obj = [pscustomobject][ordered]@{ cidr = $cidr; scanned = $targets.Count; alive = 0; seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1); skipped_reason = $null }
    return , @($obj, $alive)
}

# ---------------------------------------------------------------------------------------------
# Invoke-SRLan
# ---------------------------------------------------------------------------------------------
function Invoke-SRLan {
    [CmdletBinding()]
    param($Config, [string]$BinDir, [string]$Mode = 'quick', [scriptblock]$Log)

    $errors = New-Object System.Collections.ArrayList
    $say = { param($m) if ($null -ne $Log) { try { & $Log $m } catch { } } }
    if ($Mode -ne 'full') { $Mode = 'quick' }

    $lanCfg = SRL_P $Config 'lan'
    $listenMs = SRL_Num (SRL_P (SRL_P $lanCfg 'mdns_listen_ms') $Mode)
    if ($null -eq $listenMs -or $listenMs -lt 500) { $listenMs = 3000 }
    $listenMs = [int]$listenMs
    $port = SRL_Num (SRL_P $lanCfg 'partner_port'); if ($null -eq $port) { $port = 5201 }; $port = [int]$port
    $testSec = SRL_Num (SRL_P $lanCfg 'test_seconds'); if ($null -eq $testSec -or $testSec -lt 1) { $testSec = 10 }; $testSec = [int]$testSec
    $mult = SRL_Num (SRL_P $lanCfg 'test_multiplier'); if ($null -eq $mult -or $mult -le 0) { $mult = 2 }
    $sweepOn = $true
    if ($null -ne (SRL_P $lanCfg 'sweep') -and -not [bool](SRL_P $lanCfg 'sweep')) { $sweepOn = $false }
    $sweepTimeout = SRL_Num (SRL_P $lanCfg 'sweep_timeout_ms'); if ($null -eq $sweepTimeout -or $sweepTimeout -lt 100) { $sweepTimeout = 600 }; $sweepTimeout = [int]$sweepTimeout
    $autoPartners = $true
    if ($null -ne (SRL_P $lanCfg 'auto_partners') -and -not [bool](SRL_P $lanCfg 'auto_partners')) { $autoPartners = $false }

    # ---- test profile (same per-feed lookup as the lan_headroom rule) ----
    $proto = [string](SRL_P (SRL_P (SRL_P $Config 'show') 'inputs') 'protocol')
    $mpf = SRL_P (SRL_P (SRL_P $Config 'show') 'inputs') 'mbps_per_feed'
    $perFeed = SRL_Num (SRL_P $mpf $proto)
    if ($null -eq $perFeed -and $proto -ne '') { $perFeed = SRL_Num (SRL_P $mpf ($proto -replace '\s+', '-')) }
    if ($null -eq $perFeed -and $proto -match '^(?i)NDI') { $perFeed = SRL_Num (SRL_P $mpf 'NDI') }
    $family = 'NDI'
    if ($proto -match '^(?i)OMT') { $family = 'OMT' }
    $target = $null
    if ($null -ne $perFeed) { $target = [math]::Round($perFeed * $mult, 0) }
    $test = [pscustomobject][ordered]@{ protocol = $family; per_feed_mbps = $perFeed; target_mbps = $target; seconds = $testSec }

    # ---- adapter ----
    $adapter = $null
    $ifIdx = 0
    $ownMac = $null
    try {
        $sel = SRL_SelectAdapter $errors
        if ($null -ne $sel) { $adapter = $sel[0]; $ifIdx = [int]$sel[1]; $ownMac = $sel[2] }
        else { [void]$errors.Add('no usable network adapter (Up, not virtual, with an IPv4 address)') }
    }
    catch { [void]$errors.Add('adapter: ' + (SRL_Short $_.Exception.Message 120)) }
    if ($null -ne $adapter) {
        & $say ('Adapter ' + $adapter.name + ' (' + $adapter.kind + ') ' + $adapter.ipv4 + '/' + $adapter.prefix_length)
    }
    $localIps = @()
    if ($null -ne $adapter) { $localIps = @($adapter.local_ips) }

    # ---- discovery servers ----
    $ds = SRL_ReadDiscoveryServers $errors

    # ---- mDNS: windows browse runs while the unicast loop runs ----
    & $say ('Looking for NDI/OMT sources (mDNS, ' + [math]::Round($listenMs / 1000, 1) + ' s)')
    $merged = [ordered]@{}
    $responders = New-Object System.Collections.ArrayList
    $typesSeen = New-Object System.Collections.ArrayList
    $mUni = [ordered]@{ name = 'unicast'; ok = $false; answers = 0; error = $null }
    $mWin = [ordered]@{ name = 'windows'; ok = $false; answers = 0; error = $null }

    $browsers = @()
    $initErr = $null
    try { $initErr = SRL_InitDnsSd } catch { $initErr = SRL_Short ('Windows DNS-SD unavailable: ' + $_.Exception.Message) 160 }
    if ($null -eq $initErr) {
        foreach ($t in @('_ndi._tcp.local', '_omt._tcp.local')) {
            try {
                $br = New-Object SRLanDnsSdBrowser
                $rc = $br.Start($t, [uint32]$ifIdx)
                if ($rc -eq 9506) { $browsers += $br }
                else { $mWin.error = 'DnsServiceBrowse returned ' + $rc }
            }
            catch { $mWin.error = SRL_Short ('DnsServiceBrowse: ' + $_.Exception.Message) 160 }
        }
        if ($browsers.Count -gt 0) { $mWin.ok = $true; $mWin.error = $null }
    }
    else { $mWin.error = $initErr }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    if ($null -eq $adapter) { $mUni.error = 'no usable network adapter' }
    else {
        $u = SRL_MdnsUnicast -LocalIp $adapter.ipv4 -ListenMs $listenMs -Merged $merged -Responders $responders -TypesSeen $typesSeen
        $mUni.ok = $u.ok; $mUni.answers = $u.answers; $mUni.error = $u.error
    }
    # The windows browse gets the full window even when the unicast loop could not run.
    $left = $listenMs - [int]$sw.ElapsedMilliseconds
    if ($browsers.Count -gt 0 -and $left -gt 0) { Start-Sleep -Milliseconds $left }
    foreach ($br in $browsers) {
        try {
            $br.Stop()
            $rows = @($br.Rows())
            $mWin.answers += $rows.Count
            foreach ($s in (SRL_SourcesFromRecords (SRL_RecordsFromRows $rows) '' 'windows')) { SRL_MergeSource $merged $s }
        }
        catch { $mWin.error = SRL_Short ('browse: ' + $_.Exception.Message) 160 }
    }

    # Sources: mark the ones on this PC, drop the internal 'instance' field, sort.
    $sources = New-Object System.Collections.ArrayList
    foreach ($s in @($merged.Values | Sort-Object -Property protocol, name)) {
        $isLocal = $false
        if ($null -ne $s.ip -and (($localIps -contains [string]$s.ip) -or ([string]$s.ip -like '127.*'))) { $isLocal = $true }
        if ([string]$s.machine -ieq [string]$env:COMPUTERNAME) { $isLocal = $true }
        [void]$sources.Add([pscustomobject][ordered]@{
                protocol = $s.protocol; name = $s.name; machine = $s.machine; source = $s.source
                host = $s.host; port = $s.port; ip = $s.ip; local = $isLocal; found_by = @($s.found_by)
            })
    }
    $mdns = [pscustomobject][ordered]@{
        query_ok           = ($mUni.ok -or $mWin.ok)
        listen_ms          = $listenMs
        methods            = @([pscustomobject]$mUni, [pscustomobject]$mWin)
        responders         = $responders.ToArray()
        service_types_seen = $typesSeen.ToArray()
    }
    $nNdi = @($sources | Where-Object { $_.protocol -eq 'NDI' }).Count
    $nOmt = @($sources | Where-Object { $_.protocol -eq 'OMT' }).Count
    & $say ('mDNS: ' + $nOmt + ' OMT + ' + $nNdi + ' NDI source(s), ' + $responders.Count + ' device(s) answered')

    # ---- sweep + neighbour table ----
    $sweep = $null
    $hosts = New-Object System.Collections.ArrayList
    try {
        $reason = $null
        if ($null -eq $adapter) { $reason = 'no usable network adapter' }
        elseif (-not $sweepOn) { $reason = 'turned off in config.json (lan.sweep)' }
        elseif ($adapter.kind -eq 'other') { $reason = 'the adapter is neither wired nor Wi-Fi' }
        if ($null -ne $reason) {
            $sweep = [pscustomobject][ordered]@{ cidr = $null; scanned = 0; alive = 0; seconds = 0; skipped_reason = $reason }
        }
        else {
            & $say ('Scanning the local subnet for devices')
            $sr = SRL_Sweep $adapter.ipv4 ([int]$adapter.prefix_length) $sweepTimeout $errors
            $sweep = $sr[0]
            $pingMs = $sr[1]
            if ($null -eq $sweep.skipped_reason) {
                $parts = $sweep.cidr.Split('/')
                $netN = SRL_IpToInt $parts[0]
                $size = [int64][math]::Pow(2, 32 - [int]$parts[1])
                $macs = @{}
                try {
                    foreach ($nb in @(Get-NetNeighbor -AddressFamily IPv4 -InterfaceIndex $ifIdx -ErrorAction Stop)) {
                        $st = [string]$nb.State
                        if ($st -ne 'Reachable' -and $st -ne 'Stale' -and $st -ne 'Delay' -and $st -ne 'Probe') { continue }
                        $nip = [string]$nb.IPAddress
                        $mac = ([string]$nb.LinkLayerAddress).ToLowerInvariant()
                        if ($mac -eq '' -or $mac -eq '00-00-00-00-00-00' -or $mac -eq 'ff-ff-ff-ff-ff-ff') { continue }
                        $nn = SRL_IpToInt $nip
                        if ($nn -le $netN -or $nn -ge $netN + $size - 1) { continue }
                        $macs[$nip] = $mac
                    }
                }
                catch { [void]$errors.Add('neighbour table: ' + (SRL_Short $_.Exception.Message 120)) }
                try { [void](SRL_DropProxyArp $macs $pingMs ([string]$adapter.gateway) $errors) } catch { }
                $all = @{}
                foreach ($k in $pingMs.Keys) { $all[$k] = $true }
                foreach ($k in $macs.Keys) { $all[$k] = $true }
                $all[$adapter.ipv4] = $true
                foreach ($hip in @($all.Keys | Sort-Object -Property @{ Expression = { SRL_IpToInt $_ } })) {
                    $isSelf = ($hip -eq $adapter.ipv4)
                    $mac = $null
                    if ($isSelf) { $mac = $ownMac } elseif ($macs.ContainsKey($hip)) { $mac = $macs[$hip] }
                    $v = SRL_GetVendor $mac
                    $ping = $null
                    if ($pingMs.ContainsKey($hip)) { $ping = $pingMs[$hip] }
                    $srcNames = @($sources | Where-Object { [string]$_.ip -eq $hip } | ForEach-Object { [string]$_.name })
                    [void]$hosts.Add([pscustomobject][ordered]@{
                            ip = $hip; mac = $mac; vendor = $v.vendor; category = $v.category; randomized_mac = $v.randomized_mac
                            ping_ms = $ping; is_self = $isSelf; is_gateway = ($hip -eq [string]$adapter.gateway); sources = $srcNames
                        })
                }
                $sweep.alive = @($hosts | Where-Object { -not $_.is_self }).Count
                & $say ('Found ' + $sweep.alive + ' device(s) on ' + $sweep.cidr)
            }
        }
    }
    catch {
        [void]$errors.Add('sweep: ' + (SRL_Short $_.Exception.Message 120))
        if ($null -eq $sweep) { $sweep = [pscustomobject][ordered]@{ cidr = $null; scanned = 0; alive = 0; seconds = 0; skipped_reason = 'scan failed' } }
    }

    # ---- iperf3 partners ----
    $plist = New-Object System.Collections.ArrayList
    $seen = @{}
    $addPartner = {
        param([string]$h, [string]$origin)
        $h = $h.Trim()
        if ($h -eq '') { return }
        $ip = $null
        $tmp = $null
        if ([System.Net.IPAddress]::TryParse($h, [ref]$tmp) -and $tmp.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) { $ip = $tmp.ToString() }
        else {
            try { foreach ($a in [System.Net.Dns]::GetHostAddresses($h)) { if ($a.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) { $ip = $a.ToString(); break } } } catch { }
        }
        $key = $h.ToLowerInvariant()
        if ($null -ne $ip) { $key = $ip }
        if ($seen.ContainsKey($key)) { return }
        $seen[$key] = $true
        [void]$plist.Add(@($h, $ip, $origin))
    }
    foreach ($h in @(SRL_P $lanCfg 'partner_hosts')) { if ($null -ne $h) { & $addPartner ([string]$h) 'config' } }
    foreach ($h in @(SRL_P $lanCfg 'cli_hosts')) { if ($null -ne $h) { & $addPartner ([string]$h) 'cli' } }
    if ($autoPartners) {
        foreach ($s in $sources) {
            if ($s.local -or $null -eq $s.ip -or $seen.ContainsKey([string]$s.ip)) { continue }
            if (SRL_TestTcp ([string]$s.ip) $port 500) { & $addPartner ([string]$s.ip) 'auto' }
        }
    }
    $partners = New-Object System.Collections.ArrayList
    $exe = Join-Path $BinDir 'iperf3.exe'
    foreach ($pp in $plist) {
        $h = [string]$pp[0]; $ip = $pp[1]; $origin = [string]$pp[2]
        $rec = [ordered]@{ host = $h; ip = $ip; port = $port; origin = $origin; loopback = ([string]$ip -like '127.*'); direction = 'to_this_pc'; tcp = $null; udp = $null; error = $null }
        try {
            if ($null -eq $ip) { $rec.error = 'cannot resolve ' + $h }
            elseif (-not (Test-Path -LiteralPath $exe)) { $rec.error = 'bin\iperf3.exe not found' }
            elseif ($null -eq $target) { $rec.error = 'no per-feed bitrate for ' + $proto + ' in config.json' }
            elseif (-not (SRL_TestTcp $ip $port 1500)) { $rec.error = 'cannot connect to ' + $ip + ':' + $port + ' (is Run-Observer.cmd or Run-LanPartner.cmd still waiting?)' }
            else {
                & $say ('iperf3 TCP from ' + $h + ' (' + $testSec + ' s at ' + $target + ' Mbps)')
                $rec.tcp = SRL_RunIperf -Exe $exe -Ip $ip -Port $port -Seconds $testSec -TargetMbps $target
                Start-Sleep -Milliseconds 700
                & $say ('iperf3 UDP from ' + $h + ' (' + $testSec + ' s at ' + $target + ' Mbps)')
                $rec.udp = SRL_RunIperf -Exe $exe -Ip $ip -Port $port -Seconds $testSec -TargetMbps $target -Udp
                if ($null -eq $rec.udp.target_mbps) { $rec.udp.target_mbps = $target }
                if ($null -eq $rec.tcp.mbps -and $null -eq $rec.udp.mbps) {
                    $rec.error = $rec.tcp.error
                    if ($null -eq $rec.error) { $rec.error = $rec.udp.error }
                    if ($null -eq $rec.error) { $rec.error = 'iperf3 measured nothing' }
                }
                $msgLine = $h + ': TCP ' + [string]$rec.tcp.mbps + ' Mbps, UDP loss ' + [string]$rec.udp.loss_pct + ' %'
                & $say $msgLine
            }
        }
        catch { $rec.error = SRL_Short ('iperf3: ' + $_.Exception.Message) 160 }
        [void]$partners.Add([pscustomobject]$rec)
    }

    # ---- both at once: the prod NIC receives every feed together ----
    $combined = $null
    $combinedOn = $true
    if ($null -ne (SRL_P $lanCfg 'combined_test') -and -not [bool](SRL_P $lanCfg 'combined_test')) { $combinedOn = $false }
    $cIps = @($partners | Where-Object { $null -ne $_.tcp -and $null -ne $_.tcp.mbps } | ForEach-Object { [string]$_.ip })
    if ($combinedOn -and $cIps.Count -ge 2 -and $null -ne $target) {
        try {
            Start-Sleep -Milliseconds 700
            & $say ('iperf3 TCP from ' + $cIps.Count + ' source PCs at once (' + $testSec + ' s at ' + $target + ' Mbps each)')
            $cTcp = SRL_RunIperfTogether -Exe $exe -Ips $cIps -Port $port -Seconds $testSec -TargetMbps $target
            Start-Sleep -Milliseconds 700
            & $say ('iperf3 UDP from ' + $cIps.Count + ' source PCs at once (' + $testSec + ' s at ' + $target + ' Mbps each)')
            $cUdp = SRL_RunIperfTogether -Exe $exe -Ips $cIps -Port $port -Seconds $testSec -TargetMbps $target -Udp
            $combined = SRL_CombineResults -Ips $cIps -Seconds $testSec -TcpResults $cTcp -UdpResults $cUdp -TargetMbps $target
            & $say ('Both at once: TCP ' + [string]$combined.tcp.mbps + ' Mbps, UDP loss ' + [string]$combined.udp.loss_pct + ' %')
        }
        catch {
            [void]$errors.Add('combined test: ' + (SRL_Short $_.Exception.Message 120))
            $combined = SRL_CombineResults -Ips $cIps -Seconds $testSec -TcpResults $null -UdpResults $null -TargetMbps $target
            $combined.error = SRL_Short ('combined test: ' + $_.Exception.Message) 160
        }
    }

    return [pscustomobject][ordered]@{
        adapter           = $adapter
        mdns              = $mdns
        sources           = $sources.ToArray()
        discovery_servers = $ds
        sweep             = $sweep
        hosts             = $hosts.ToArray()
        partners          = $partners.ToArray()
        combined          = $combined
        test              = $test
        errors            = $errors.ToArray()
    }
}
