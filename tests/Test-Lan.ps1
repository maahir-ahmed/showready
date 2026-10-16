# ShowReady - tests\Test-Lan.ps1
# Plain PowerShell assertions (no Pester) for the offline parts of lib\Lan.ps1: DNS query/parse, NDI/OMT source
# extraction, MAC vendors, iperf3 JSON, plus one end-to-end discovery window against a fake responder on 127.0.0.1.
# -Live also runs the "both at once" iperf3 test against two servers on 127.0.0.1 and 127.0.0.2 (about 20 s).
# Run:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Test-Lan.ps1 [-Live]
# Exit code 0 = all assertions passed, 1 = at least one failed. Pure ASCII, works on Windows PowerShell 5.1 and pwsh.
param([switch]$Live)

$ErrorActionPreference = 'Continue'
$testsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$kit = Split-Path -Parent $testsDir
$fx = Join-Path $testsDir 'fixtures'
$lanPath = Join-Path $kit 'lib\Lan.ps1'
$script:nPass = 0
$script:nFail = 0

function Assert-That {
    param([string]$Name, $Condition, [string]$Detail = '')
    if ($Condition -eq $true) {
        $script:nPass++
        Write-Host ('  PASS  ' + $Name) -ForegroundColor Green
    }
    else {
        $script:nFail++
        $d = ''
        if ($Detail -ne '') { $d = '  -> ' + $Detail }
        Write-Host ('  FAIL  ' + $Name + $d) -ForegroundColor Red
    }
}

function ToHex { param([byte[]]$B) return (($B | ForEach-Object { $_.ToString('x2') }) -join ' ') }

Write-Host ''
Write-Host 'ShowReady Lan tests' -ForegroundColor Cyan
Write-Host ('  PowerShell ' + $PSVersionTable.PSVersion.ToString()) -ForegroundColor DarkGray

# =============================================================================================
Write-Host 'a: dot-sourcing' -ForegroundColor Cyan
$dotOut = @(. $lanPath)
Assert-That 'a: dot-sourcing Lan.ps1 prints nothing' ($dotOut.Count -eq 0) ('output count ' + $dotOut.Count)
Assert-That 'a: Invoke-SRLan is defined' ($null -ne (Get-Command Invoke-SRLan -CommandType Function -ErrorAction SilentlyContinue))
$src = [System.IO.File]::ReadAllText($lanPath)
Assert-That 'a: Lan.ps1 is pure ASCII' (-not [regex]::IsMatch($src, '[^\x00-\x7F]'))
Assert-That 'a: Lan.ps1 never binds UDP 5353' (-not [regex]::IsMatch($src, 'IPEndPoint\([^)]*,\s*5353\)\)') -and -not [regex]::IsMatch($src, '(?i)JoinMulticastGroup'))
Assert-That 'a: OMT service type is cited' ($src -match '_omt\._tcp' -and $src -match 'libomtnet')

# =============================================================================================
Write-Host 'b: SRL_NewDnsQuery' -ForegroundColor Cyan
$q = SRL_NewDnsQuery -Names @('_omt._tcp.local') -Types @(12) -QU
$expect = '00 00 00 00 00 01 00 00 00 00 00 00 04 5f 6f 6d 74 04 5f 74 63 70 05 6c 6f 63 61 6c 00 00 0c 80 01'
Assert-That 'b: one PTR question with the QU bit, exact bytes' ((ToHex $q) -eq $expect) (ToHex $q)
$q3 = SRL_NewDnsQuery -Names @('_ndi._tcp.local', 'SRC-PC1 (vMix Output 1)._omt._tcp.local', 'SRC-PC1.local') -Types @(12, 33, 1)
$pq = SRL_ParseDnsMessage $q3
Assert-That 'b: query round-trips: 3 questions, not a response' ($null -ne $pq -and @($pq.questions).Count -eq 3 -and -not $pq.is_response)
Assert-That 'b: per-name types PTR/SRV/A' ((@($pq.questions | ForEach-Object { [string]$_.type }) -join ',') -eq 'PTR,SRV,A') (@($pq.questions | ForEach-Object { [string]$_.type }) -join ',')
Assert-That 'b: instance label with spaces and brackets survives' ($pq.questions[1].name -eq 'SRC-PC1 (vMix Output 1)._omt._tcp.local') $pq.questions[1].name
$qd = SRL_NewDnsQuery -Names @('Studio\.A (Cam)._ndi._tcp.local')
$pd = SRL_ParseDnsMessage $qd
Assert-That 'b: escaped dot stays inside one label' ($qd[12] -eq 14 -and $pd.questions[0].name -eq 'Studio\.A (Cam)._ndi._tcp.local') ($pd.questions[0].name)

# =============================================================================================
# Hand-built mDNS response with name compression (pointer to pointer included):
#   answers:    PTR _omt._tcp.local -> SRC-PC1 (vMix Output 1)._omt._tcp.local
#               PTR _ndi._tcp.local -> SRC-PC2 (OBS)._ndi._tcp.local
#   additional: SRV SRC-PC1 (...) 6400 -> SRC-PC1.local, TXT v=1, A SRC-PC1.local 192.168.10.31,
#               SRV SRC-PC2 (OBS) 5961 -> SRC-PC2.local (no A record: the reply's source IP is used)
Write-Host 'c: SRL_ParseDnsMessage + SRL_SourcesFromRecords' -ForegroundColor Cyan
$m = New-Object System.Collections.Generic.List[byte]
function W { param([byte[]]$B) $m.AddRange($B) }
function Lab { param([string]$S) $b = [System.Text.Encoding]::UTF8.GetBytes($S); return , ([byte[]](@([byte]$b.Length) + $b)) }
function Ptr { param([int]$O) return , ([byte[]]@([byte](0xC0 -bor ($O -shr 8)), [byte]($O -band 255))) }
function U16 { param([int]$V) return , ([byte[]]@([byte](($V -shr 8) -band 255), [byte]($V -band 255))) }
function RrHead { param([int]$Type) W (U16 $Type); W (U16 0x8001); W ([byte[]]@(0, 0, 0x11, 0x94)) }

W ([byte[]]@(0, 0, 0x84, 0, 0, 0, 0, 2, 0, 0, 0, 4))
$oOmt = $m.Count; W (Lab '_omt'); $oTcp = $m.Count; W (Lab '_tcp'); $oLocal = $m.Count; W (Lab 'local'); W ([byte[]]@(0))
RrHead 12
$rd = [byte[]]((Lab 'SRC-PC1 (vMix Output 1)') + (Ptr $oOmt)); W (U16 $rd.Length); $oInst1 = $m.Count; W $rd
$oNdi = $m.Count; W (Lab '_ndi'); W (Ptr $oTcp)
RrHead 12
$rd = [byte[]]((Lab 'SRC-PC2 (OBS)') + (Ptr $oNdi)); W (U16 $rd.Length); $oInst2 = $m.Count; W $rd
W (Ptr $oInst1); RrHead 33
$rd = [byte[]]((U16 0) + (U16 0) + (U16 6400) + (Lab 'SRC-PC1') + (Ptr $oLocal)); W (U16 $rd.Length); $oTarget1 = $m.Count + 6; W $rd
W (Ptr $oInst1); RrHead 16
$rd = [byte[]](Lab 'v=1'); W (U16 $rd.Length); W $rd
W (Ptr $oTarget1); RrHead 1
W (U16 4); W ([byte[]]@(192, 168, 10, 31))
W (Ptr $oInst2); RrHead 33
$rd = [byte[]]((U16 0) + (U16 0) + (U16 5961) + (Lab 'SRC-PC2') + (Ptr $oLocal)); W (U16 $rd.Length); W $rd
$pktA = $m.ToArray()

$msg = SRL_ParseDnsMessage $pktA
Assert-That 'c: parses as a complete response' ($null -ne $msg -and $msg.is_response -and -not $msg.truncated)
Assert-That 'c: 2 answers, 4 additional' (@($msg.answers).Count -eq 2 -and @($msg.additional).Count -eq 4) ('answers ' + @($msg.answers).Count + ', additional ' + @($msg.additional).Count)
Assert-That 'c: compressed PTR target' ($msg.answers[0].type -eq 'PTR' -and $msg.answers[0].data -eq 'SRC-PC1 (vMix Output 1)._omt._tcp.local') ([string]$msg.answers[0].data)
Assert-That 'c: name built from label + pointer (_ndi -> _tcp.local)' ($msg.answers[1].name -eq '_ndi._tcp.local') $msg.answers[1].name
$srv = $msg.additional[0]
Assert-That 'c: SRV port and compressed target' ($srv.type -eq 'SRV' -and $srv.data.port -eq 6400 -and $srv.data.target -eq 'SRC-PC1.local') ($srv | ConvertTo-Json -Compress -Depth 4)
Assert-That 'c: TXT strings' ($msg.additional[1].type -eq 'TXT' -and @($msg.additional[1].data)[0] -eq 'v=1')
Assert-That 'c: A record name via pointer-to-pointer' ($msg.additional[2].type -eq 'A' -and $msg.additional[2].name -eq 'SRC-PC1.local' -and $msg.additional[2].data -eq '192.168.10.31') ($msg.additional[2] | ConvertTo-Json -Compress)
Assert-That 'c: cache-flush class bit does not break parsing; ttl read' ($msg.answers[0].ttl -eq 4500)

$recs = @($msg.answers) + @($msg.authority) + @($msg.additional)
# These helpers return one array object (return , $x); assign them directly, never wrap them in @().
$srcs = SRL_SourcesFromRecords $recs '192.168.10.99' 'unicast'
Assert-That 'c: SourcesFromRecords returns a flat array of 2' ($srcs.Count -eq 2 -and $srcs[0] -isnot [array]) ('count ' + $srcs.Count)
$omt = @($srcs | Where-Object { $_.protocol -eq 'OMT' })
$ndi = @($srcs | Where-Object { $_.protocol -eq 'NDI' })
Assert-That 'c: one OMT and one NDI source' ($omt.Count -eq 1 -and $ndi.Count -eq 1) ('OMT ' + $omt.Count + ', NDI ' + $ndi.Count)
if ($omt.Count -eq 1) {
    $o = $omt[0]
    Assert-That 'c: OMT name/machine/source split' ($o.name -eq 'SRC-PC1 (vMix Output 1)' -and $o.machine -eq 'SRC-PC1' -and $o.source -eq 'vMix Output 1') ($o | ConvertTo-Json -Compress)
    Assert-That 'c: OMT host/port/ip from SRV + A' ($o.host -eq 'SRC-PC1.local' -and $o.port -eq 6400 -and $o.ip -eq '192.168.10.31') ($o | ConvertTo-Json -Compress)
    Assert-That 'c: found_by and instance' ((@($o.found_by) -join ',') -eq 'unicast' -and $o.instance -eq 'SRC-PC1 (vMix Output 1)._omt._tcp.local')
}
if ($ndi.Count -eq 1) {
    $n = $ndi[0]
    Assert-That 'c: NDI without A record falls back to the reply source IP' ($n.port -eq 5961 -and $n.ip -eq '192.168.10.99' -and $n.machine -eq 'SRC-PC2' -and $n.source -eq 'OBS') ($n | ConvertTo-Json -Compress)
}
$svcTypes = (SRL_ServiceTypesFromRecords @([pscustomobject]@{ name = '_services._dns-sd._udp.local'; type = 'PTR'; data = '_omt._tcp.local' }, [pscustomobject]@{ name = '_services._dns-sd._udp.local'; type = 'PTR'; data = '_googlecast._tcp.local' }))
Assert-That 'c: service types from _services._dns-sd._udp' (($svcTypes -join ',') -eq '_omt._tcp,_googlecast._tcp') ($svcTypes -join ',')

# Korean source name (UTF-8 label) and a dot inside the instance label.
$kor = 'SRC-PC4 (' + [char]0xCE74 + [char]0xBA54 + [char]0xB77C + ' 1)'
$m = New-Object System.Collections.Generic.List[byte]
W ([byte[]]@(0, 0, 0x84, 0, 0, 0, 0, 2, 0, 0, 0, 0))
$oOmt = $m.Count; W (Lab '_omt'); W (Lab '_tcp'); W (Lab 'local'); W ([byte[]]@(0))
RrHead 12; $rd = [byte[]]((Lab $kor) + (Ptr $oOmt)); W (U16 $rd.Length); W $rd
W (Ptr $oOmt); RrHead 12; $rd = [byte[]]((Lab 'Studio.A (Cam 2)') + (Ptr $oOmt)); W (U16 $rd.Length); W $rd
$pktK = $m.ToArray()
$sk = SRL_SourcesFromRecords (SRL_ParseDnsMessage $pktK).answers '10.1.1.1' 'unicast'
Assert-That 'c: Korean source name decoded from UTF-8' (@($sk | Where-Object { $_.name -eq $kor }).Count -eq 1) (($sk | ForEach-Object { $_.name }) -join ' | ')
Assert-That 'c: dot inside an instance label is kept' (@($sk | Where-Object { $_.name -eq 'Studio.A (Cam 2)' -and $_.machine -eq 'Studio.A' }).Count -eq 1) (($sk | ForEach-Object { $_.name }) -join ' | ')

# Merge: same source seen by both methods fills gaps and unions found_by.
$dict = [ordered]@{}
SRL_MergeSource $dict ([pscustomobject][ordered]@{ protocol = 'OMT'; name = 'A (B)'; machine = 'A'; source = 'B'; host = $null; port = $null; ip = $null; local = $false; found_by = @('windows'); instance = 'A (B)._omt._tcp.local' })
SRL_MergeSource $dict ([pscustomobject][ordered]@{ protocol = 'OMT'; name = 'a (b)'; machine = 'A'; source = 'B'; host = 'A.local'; port = 6400; ip = '10.0.0.5'; local = $false; found_by = @('unicast'); instance = 'a (b)._omt._tcp.local' })
$mv = @($dict.Values)
Assert-That 'c: merge keeps one source, fills port/ip, both methods' ($mv.Count -eq 1 -and $mv[0].port -eq 6400 -and $mv[0].ip -eq '10.0.0.5' -and (@($mv[0].found_by) -join ',') -eq 'windows,unicast') ($mv | ConvertTo-Json -Compress)
$dict = [ordered]@{}
SRL_MergeSource $dict ([pscustomobject][ordered]@{ protocol = 'NDI'; name = 'X (Y)'; machine = 'X'; source = 'Y'; host = $null; port = $null; ip = '10.0.0.9'; local = $false; found_by = @('unicast'); instance = 'X (Y)._ndi._tcp.local'; ip_from_reply = $true })
SRL_MergeSource $dict ([pscustomobject][ordered]@{ protocol = 'NDI'; name = 'X (Y)'; machine = 'X'; source = 'Y'; host = 'X.local'; port = 5961; ip = '10.0.0.10'; local = $false; found_by = @('unicast'); instance = 'X (Y)._ndi._tcp.local'; ip_from_reply = $false })
$mv = @($dict.Values)
Assert-That 'c: an A-record IP replaces the reply sender IP' ($mv.Count -eq 1 -and $mv[0].ip -eq '10.0.0.10' -and $mv[0].port -eq 5961) ($mv | ConvertTo-Json -Compress)

# Windows DNS-SD rows -> records -> sources
$wr = SRL_RecordsFromRows @("PTR`t_omt._tcp.local`tSRC-PC5 (Out 1)._omt._tcp.local", "SRV`tSRC-PC5 (Out 1)._omt._tcp.local`tSRC-PC5.local.`t6401", "A`tSRC-PC5.local`t10.0.0.55", 'garbage')
$ws = SRL_SourcesFromRecords $wr '' 'windows'
Assert-That 'c: windows rows give a full source' ($ws.Count -eq 1 -and $ws[0].port -eq 6401 -and $ws[0].ip -eq '10.0.0.55' -and $ws[0].host -eq 'SRC-PC5.local') ($ws | ConvertTo-Json -Compress)

# =============================================================================================
Write-Host 'd: malformed input never throws' -ForegroundColor Cyan
$threw = $false
try {
    for ($len = 0; $len -lt $pktA.Length; $len++) {
        $cut = New-Object byte[] $len
        [Array]::Copy($pktA, $cut, $len)
        $r = SRL_ParseDnsMessage $cut
        if ($len -ge 12 -and $null -eq $r) { throw ('null at length ' + $len) }
    }
}
catch { $threw = $true; Write-Host ('        ' + $_.Exception.Message) -ForegroundColor DarkGray }
Assert-That 'd: every truncation of the packet parses without throwing' (-not $threw)
$cut = New-Object byte[] 60
[Array]::Copy($pktA, $cut, 60)
Assert-That 'd: a cut packet is flagged truncated' ((SRL_ParseDnsMessage $cut).truncated -eq $true)
$loop = [byte[]]@(0, 0, 0x84, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0xC0, 0x0C, 0, 12, 0, 1, 0, 0, 0, 1, 0, 0)
$lr = SRL_ParseDnsMessage $loop
Assert-That 'd: self-pointing name (pointer loop) ends safely' ($null -ne $lr -and $lr.truncated -and @($lr.answers).Count -eq 0)
$loop2 = [byte[]]@(0, 0, 0x84, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0xC0, 0x0E, 0xC0, 0x0C, 0, 12, 0, 1, 0, 0, 0, 1, 0, 0)
Assert-That 'd: two pointers pointing at each other end safely' ((SRL_ParseDnsMessage $loop2).truncated -eq $true)
$rng = New-Object System.Random 42
$threw = $false
try {
    for ($i = 0; $i -lt 300; $i++) {
        $g = New-Object byte[] ($rng.Next(0, 200))
        $rng.NextBytes($g)
        if ($g.Length -gt 3) { $g[2] = 0x84 }
        [void](SRL_ParseDnsMessage $g)
        [void](SRL_SourcesFromRecords @() '' 'unicast')
    }
}
catch { $threw = $true }
Assert-That 'd: 300 random packets parse without throwing' (-not $threw)
Assert-That 'd: null / short input returns null' ($null -eq (SRL_ParseDnsMessage $null) -and $null -eq (SRL_ParseDnsMessage ([byte[]]@(1, 2, 3))))

# =============================================================================================
Write-Host 'e: SRL_GetVendor' -ForegroundColor Cyan
$v = SRL_GetVendor '00-0C-17-12-34-56'
Assert-That 'e: AJA OUI -> broadcast' ($v.vendor -eq 'AJA Video Systems' -and $v.category -eq 'broadcast' -and -not $v.randomized_mac) ($v | ConvertTo-Json -Compress)
$v = SRL_GetVendor '7c:2e:0d:aa:bb:cc'
Assert-That 'e: colon notation, lower case (Blackmagic)' ($v.vendor -eq 'Blackmagic Design')
$v = SRL_GetVendor '00-00-0C-01-02-03'
Assert-That 'e: Cisco -> network' ($v.vendor -eq 'Cisco' -and $v.category -eq 'network')
$v = SRL_GetVendor 'F2-11-22-33-44-55'
Assert-That 'e: locally administered MAC -> randomized, no vendor' ($v.randomized_mac -and $null -eq $v.vendor)
$v = SRL_GetVendor '10-34-56-78-9A-BC'
Assert-That 'e: unknown OUI -> null vendor, not randomized' ($null -eq $v.vendor -and -not $v.randomized_mac)
$v = SRL_GetVendor ''
Assert-That 'e: empty MAC -> nulls' ($null -eq $v.vendor -and -not $v.randomized_mac)
$tbl = SRL_OuiTable
Assert-That 'e: OUI table loaded (> 100 entries, all 6 hex digits)' ($tbl.Count -gt 100 -and @($tbl.Keys | Where-Object { $_ -notmatch '^[0-9A-F]{6}$' }).Count -eq 0) ('entries ' + $tbl.Count)

# =============================================================================================
Write-Host 'f: SRL_ParseIperfJson' -ForegroundColor Cyan
$tj = [System.IO.File]::ReadAllText((Join-Path $fx 'iperf3_tcp_reverse.json'))
$t = SRL_ParseIperfJson $tj
Assert-That 'f: TCP -R receiver Mbps from end.sum_received' ($t.mbps -eq 398.2 -and $t.seconds -eq 3 -and $null -eq $t.error) ($t | ConvertTo-Json -Compress)
Assert-That 'f: TCP retransmits null when the build does not report them' ($null -eq $t.retransmits)
$uj = [System.IO.File]::ReadAllText((Join-Path $fx 'iperf3_udp_reverse.json'))
$u = SRL_ParseIperfJson $uj -Udp
Assert-That 'f: UDP -R receiver numbers' ($u.target_mbps -eq 400 -and $u.mbps -eq 399.1 -and $u.packets -eq 107168 -and $u.lost -eq 42 -and $u.loss_pct -eq 0.039 -and $u.jitter_ms -eq 0.01) ($u | ConvertTo-Json -Compress)
$e = SRL_ParseIperfJson '{"start":{},"intervals":[],"end":{},"error":"unable to connect to server - server may have stopped running or use a different port, firewall issue, etc.: Connection refused"}'
Assert-That 'f: iperf3 error is reported, numbers stay null' ($e.error -match 'unable to connect' -and $null -eq $e.mbps) ($e | ConvertTo-Json -Compress)
$e = SRL_ParseIperfJson 'iperf3: error - the server is busy running a test. try again later'
Assert-That 'f: non-JSON output is an error, not an exception' ($e.error -match 'not JSON')
$nan = SRL_ParseIperfJson '{"end":{"sum":{"seconds":10,"bits_per_second":1000000,"jitter_ms":-nan,"lost_packets":0,"packets":10,"lost_percent":0}}}' -Udp
Assert-That 'f: -nan from cygwin iperf3 becomes null' ($null -eq $nan.jitter_ms -and $nan.mbps -eq 1 -and $nan.loss_pct -eq 0) ($nan | ConvertTo-Json -Compress)
Assert-That 'f: empty output' ((SRL_ParseIperfJson '').error -eq 'iperf3 gave no output')

# =============================================================================================
# End-to-end discovery window: a fake responder on 127.0.0.1 answers the PTR query with a PTR only (no SRV/A),
# then answers the SRV follow-up with SRV + A. Binding loopback does not raise a firewall prompt.
Write-Host 'g: SRL_MdnsUnicast against a fake responder on loopback' -ForegroundColor Cyan
$m = New-Object System.Collections.Generic.List[byte]
W ([byte[]]@(0, 0, 0x84, 0, 0, 0, 0, 2, 0, 0, 0, 0))
$oOmt = $m.Count; W (Lab '_omt'); W (Lab '_tcp'); $oLocal = $m.Count; W (Lab 'local'); W ([byte[]]@(0))
RrHead 12; $rd = [byte[]]((Lab 'SRC-PC3 (Cam 3)') + (Ptr $oOmt)); W (U16 $rd.Length); W $rd
W (Lab '_services'); W (Lab '_dns-sd'); W (Lab '_udp'); W (Ptr $oLocal); RrHead 12; $rd = [byte[]](Ptr $oOmt); W (U16 $rd.Length); W $rd
$r1 = $m.ToArray()
$m = New-Object System.Collections.Generic.List[byte]
W ([byte[]]@(0, 0, 0x84, 0, 0, 0, 0, 2, 0, 0, 0, 0))
$oInst = $m.Count; W (Lab 'SRC-PC3 (Cam 3)'); W (Lab '_omt'); W (Lab '_tcp'); $oLocal = $m.Count; W (Lab 'local'); W ([byte[]]@(0))
RrHead 33; $rd = [byte[]]((U16 0) + (U16 0) + (U16 6402) + (Lab 'SRC-PC3') + (Ptr $oLocal)); W (U16 $rd.Length); $oT = $m.Count + 6; W $rd
W (Ptr $oT); RrHead 1; W (U16 4); W ([byte[]]@(10, 0, 0, 33))
$r2 = $m.ToArray()

$state = [hashtable]::Synchronized(@{ Port = 0; Ptr = 0; Srv = 0; Err = $null })
$ps = [powershell]::Create()
[void]$ps.AddScript({
        param($LanPath, $State, $R1, $R2)
        try {
            . $LanPath
            $u = New-Object System.Net.Sockets.UdpClient (New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Loopback, 0))
            $State.Port = ([System.Net.IPEndPoint]$u.Client.LocalEndPoint).Port
            $u.Client.ReceiveTimeout = 200
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            while ($sw.Elapsed.TotalSeconds -lt 6) {
                $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
                $data = $null
                try { $data = $u.Receive([ref]$ep) } catch { continue }
                $qm = SRL_ParseDnsMessage $data
                if ($null -eq $qm -or $qm.is_response) { continue }
                $types = @($qm.questions | ForEach-Object { [string]$_.type })
                if ($types -contains 'SRV') { [void]$u.Send($R2, $R2.Length, $ep); $State.Srv++ }
                elseif ($types -contains 'PTR') { [void]$u.Send($R1, $R1.Length, $ep); $State.Ptr++ }
            }
            $u.Close()
        }
        catch { $State.Err = $_.Exception.Message }
    }).AddArgument($lanPath).AddArgument($state).AddArgument($r1).AddArgument($r2)
$handle = $ps.BeginInvoke()
$wait = [System.Diagnostics.Stopwatch]::StartNew()
while ($state.Port -eq 0 -and $null -eq $state.Err -and $wait.ElapsedMilliseconds -lt 8000) { Start-Sleep -Milliseconds 50 }
if ($state.Port -gt 0) {
    $merged = [ordered]@{}
    $resp = New-Object System.Collections.ArrayList
    $seenT = New-Object System.Collections.ArrayList
    $res = SRL_MdnsUnicast -LocalIp '127.0.0.1' -ListenMs 2600 -Merged $merged -Responders $resp -TypesSeen $seenT -DestIp '127.0.0.1' -DestPort $state.Port
    $found = @($merged.Values)
    Assert-That 'g: method ok, answers counted' ($res.ok -and $res.answers -ge 3) ($res | ConvertTo-Json -Compress)
    Assert-That 'g: query re-sent every second (>= 3 PTR queries in 2.6 s)' ($state.Ptr -ge 3) ('PTR queries ' + $state.Ptr)
    Assert-That 'g: exactly one SRV follow-up for the incomplete instance' ($state.Srv -eq 1) ('SRV queries ' + $state.Srv)
    Assert-That 'g: source completed by the follow-up (port 6402, ip 10.0.0.33)' ($found.Count -eq 1 -and $found[0].port -eq 6402 -and $found[0].ip -eq '10.0.0.33' -and $found[0].host -eq 'SRC-PC3.local' -and $found[0].name -eq 'SRC-PC3 (Cam 3)') ($found | ConvertTo-Json -Compress)
    Assert-That 'g: responder and service type recorded' ($resp.Contains('127.0.0.1') -and $seenT.Contains('_omt._tcp')) (($resp -join ',') + ' / ' + ($seenT -join ','))
}
else { Assert-That 'g: fake responder started' $false ([string]$state.Err) }
try { [void]$ps.EndInvoke($handle) } catch { }
$ps.Dispose()
Assert-That 'g: fake responder ran without error' ($null -eq $state.Err) ([string]$state.Err)

# =============================================================================================
Write-Host 'h: both at once (SRL_CombineResults)' -ForegroundColor Cyan
$ips2 = [string[]]@('10.0.0.11', '10.0.0.12')
$t1 = [pscustomobject]@{ mbps = 300.5; retransmits = $null; seconds = 10; error = $null }
$t2 = [pscustomobject]@{ mbps = 180.0; retransmits = $null; seconds = 10; error = $null }
$u1 = [pscustomobject]@{ target_mbps = 400; mbps = 399.0; packets = 1000; lost = 10; loss_pct = 1.0; jitter_ms = 0.5; seconds = 10; error = $null }
$u2 = [pscustomobject]@{ target_mbps = 400; mbps = 380.0; packets = 3000; lost = 2; loss_pct = 0.067; jitter_ms = 1.25; seconds = 10; error = $null }
$cb = SRL_CombineResults -Ips $ips2 -Seconds 10 -TcpResults @($t1, $t2) -UdpResults @($u1, $u2) -TargetMbps 400
Assert-That 'h: tcp mbps is the sum' ($cb.tcp.mbps -eq 480.5) ([string]$cb.tcp.mbps)
Assert-That 'h: per_host in order' ($cb.tcp.per_host.Count -eq 2 -and $cb.tcp.per_host[0].ip -ceq '10.0.0.11' -and $cb.tcp.per_host[1].mbps -eq 180) ($cb.tcp.per_host | ConvertTo-Json -Compress)
Assert-That 'h: udp target summed, packets/lost summed, loss from totals' ($cb.udp.target_mbps -eq 800 -and $cb.udp.packets -eq 4000 -and $cb.udp.lost -eq 12 -and $cb.udp.loss_pct -eq 0.3) ($cb.udp | ConvertTo-Json -Compress)
Assert-That 'h: udp mbps summed, jitter is the highest' ($cb.udp.mbps -eq 779 -and $cb.udp.jitter_ms -eq 1.25) ($cb.udp | ConvertTo-Json -Compress)
Assert-That 'h: no errors, hosts and seconds kept' ($null -eq $cb.error -and $null -eq $cb.tcp.error -and $null -eq $cb.udp.error -and $cb.hosts.Count -eq 2 -and $cb.seconds -eq 10)
$t2e = [pscustomobject]@{ mbps = $null; retransmits = $null; seconds = $null; error = 'iperf3: unable to connect to server' }
$cb2 = SRL_CombineResults -Ips $ips2 -Seconds 10 -TcpResults @($t1, $t2e) -UdpResults @($u1, $u2) -TargetMbps 400
Assert-That 'h: a failed client -> error names it, sum covers the rest' ($cb2.tcp.mbps -eq 300.5 -and $cb2.tcp.error -ceq '10.0.0.12: iperf3: unable to connect to server' -and $cb2.error -ceq $cb2.tcp.error -and $null -eq $cb2.tcp.per_host[1].mbps) ($cb2 | ConvertTo-Json -Depth 4 -Compress)
$cb3 = SRL_CombineResults -Ips $ips2 -Seconds 10 -TcpResults $null -UdpResults $null -TargetMbps 400
Assert-That 'h: nothing ran -> nulls and an error, no throw' ($null -eq $cb3.tcp.mbps -and $null -eq $cb3.udp.mbps -and $null -eq $cb3.udp.loss_pct -and $cb3.error -match 'not run') ($cb3 | ConvertTo-Json -Depth 4 -Compress)
$cbJson = $cb | ConvertTo-Json -Depth 6 -Compress
Assert-That 'h: serialises with the contract keys' ($cbJson -match '"hosts"' -and $cbJson -match '"per_host"' -and $cbJson -match '"target_mbps"') $cbJson
$lanSrc = [System.IO.File]::ReadAllText($lanPath)
Assert-That 'h: Invoke-SRLan output has combined before test' ($lanSrc -match '(?s)partners\s+=\s+\$partners\.ToArray\(\)\s+combined\s+=\s+\$combined\s+test\s+=')

# =============================================================================================
Write-Host 'i: proxy ARP (SRL_DropProxyArp)' -ForegroundColor Cyan
$pm = @{}
for ($i = 2; $i -le 254; $i++) { $pm['172.30.2.' + $i] = 'ec-fc-c6-c8-63-52' }
$pm['172.30.2.40'] = 'aa-bb-cc-00-00-40'
$pm['172.30.2.41'] = 'aa-bb-cc-00-00-41'
$pings = @{ '172.30.2.7' = 3; '172.30.2.40' = 2 }
$perr = New-Object System.Collections.ArrayList
$nDrop = SRL_DropProxyArp $pm $pings '172.30.2.1' $perr
Assert-That 'i: neighbour-only entries under the shared MAC dropped' ($nDrop -eq 250 -and $pm.Count -eq 3) ('dropped ' + $nDrop + ', left ' + $pm.Count)
Assert-That 'i: pinged host, other MACs kept' ($pm.ContainsKey('172.30.2.7') -and $pm.ContainsKey('172.30.2.40') -and $pm.ContainsKey('172.30.2.41'))
$pm2 = @{ '172.30.2.1' = 'ec-fc-c6-c8-63-52' }
for ($i = 2; $i -le 9; $i++) { $pm2['172.30.2.' + $i] = 'ec-fc-c6-c8-63-52' }
[void](SRL_DropProxyArp $pm2 @{} '172.30.2.1' $null)
Assert-That 'i: gateway kept even when it shares the MAC; null errors ok' ($pm2.Count -eq 1 -and $pm2.ContainsKey('172.30.2.1')) ($pm2.Keys -join ',')
Assert-That 'i: one note names the MAC and counts' ($perr.Count -eq 1 -and $perr[0] -ceq 'neighbour table: 251 addresses share MAC ec-fc-c6-c8-63-52 (proxy ARP); 250 that did not answer ping are not counted') ($perr -join ' | ')
$pm3 = @{ '10.0.0.5' = 'aa'; '10.0.0.6' = 'aa'; '10.0.0.7' = 'aa' }
Assert-That 'i: a few addresses on one MAC are left alone' ((SRL_DropProxyArp $pm3 @{} '10.0.0.1' $null) -eq 0 -and $pm3.Count -eq 3)

if ($Live) {
    Write-Host 'h: live - two iperf3 servers on 127.0.0.1 / 127.0.0.2 port 5299' -ForegroundColor Cyan
    $exe = Join-Path $kit 'bin\iperf3.exe'
    $srv = @()
    foreach ($bindIp in '127.0.0.1', '127.0.0.2') {
        $srv += Start-Process -FilePath $exe -ArgumentList @('-s', '-B', $bindIp, '-p', '5299') -WorkingDirectory $env:TEMP -WindowStyle Hidden -PassThru
    }
    try {
        Start-Sleep -Milliseconds 1500
        $liveIps = [string[]]@('127.0.0.1', '127.0.0.2')
        $lt = SRL_RunIperfTogether -Exe $exe -Ips $liveIps -Port 5299 -Seconds 4 -TargetMbps 200
        Start-Sleep -Milliseconds 700
        $lu = SRL_RunIperfTogether -Exe $exe -Ips $liveIps -Port 5299 -Seconds 4 -TargetMbps 200 -Udp
        Assert-That 'h: live - two results each, flat arrays' ($lt.Count -eq 2 -and $lu.Count -eq 2 -and $null -ne $lt[0].PSObject.Properties['mbps']) ('tcp ' + $lt.Count + ', udp ' + $lu.Count)
        $lc = SRL_CombineResults -Ips $liveIps -Seconds 4 -TcpResults $lt -UdpResults $lu -TargetMbps 200
        Assert-That 'h: live - both TCP clients measured' ($null -ne $lc.tcp.per_host[0].mbps -and $null -ne $lc.tcp.per_host[1].mbps -and $null -eq $lc.error) ($lc | ConvertTo-Json -Depth 4 -Compress)
        Assert-That 'h: live - TCP total is about 2 x 200 Mbps' ($lc.tcp.mbps -ge 360 -and $lc.tcp.mbps -le 440) ([string]$lc.tcp.mbps)
        Assert-That 'h: live - UDP target 400, packets counted' ($lc.udp.target_mbps -eq 400 -and $lc.udp.packets -gt 0 -and $null -ne $lc.udp.loss_pct) ($lc.udp | ConvertTo-Json -Compress)
        Write-Host ('    together: TCP ' + $lc.tcp.mbps + ' Mbps (' + $lc.tcp.per_host[0].mbps + ' + ' + $lc.tcp.per_host[1].mbps + '), UDP ' + $lc.udp.mbps + ' Mbps, loss ' + $lc.udp.loss_pct + ' %') -ForegroundColor DarkGray
    }
    finally {
        foreach ($sp in $srv) { try { if (-not $sp.HasExited) { $sp.Kill() } } catch { } }
    }
}

# =============================================================================================
Write-Host ''
$col = 'Green'
if ($script:nFail -gt 0) { $col = 'Red' }
Write-Host ('Lan tests: ' + $script:nPass + ' passed, ' + $script:nFail + ' failed') -ForegroundColor $col
if ($script:nFail -gt 0) { exit 1 }
exit 0
