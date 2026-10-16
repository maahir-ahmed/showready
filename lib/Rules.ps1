# ShowReady - lib\Rules.ps1
# Verdict engine. Defines Get-SRVerdict (plus SRV_* helper functions). No side effects when dot-sourced.
# Windows PowerShell 5.1 compatible. Pure ASCII on purpose (PS 5.1 reads BOM-less files as the ANSI code page).
# No Set-StrictMode, no ternary / ?? / ?., no -Parallel. All number formatting uses the invariant culture.

# ---------------------------------------------------------------------------------------------
# Generic helpers
# ---------------------------------------------------------------------------------------------

function SRV_Inv { return [System.Globalization.CultureInfo]::InvariantCulture }

# Safe nested property lookup: works on PSCustomObject and on hashtables, case-insensitive, never throws.
function SRV_Get {
    param($Obj, [string[]]$Path)
    $cur = $Obj
    foreach ($p in $Path) {
        if ($null -eq $cur) { return $null }
        if ($cur -is [System.Collections.IDictionary]) {
            $found = $false
            foreach ($k in @($cur.Keys)) {
                if (([string]$k) -ieq $p) { $cur = $cur[$k]; $found = $true; break }
            }
            if (-not $found) { return $null }
        }
        else {
            $prop = $null
            try { $prop = $cur.PSObject.Properties[$p] } catch { $prop = $null }
            if ($null -eq $prop) { return $null }
            $cur = $prop.Value
        }
    }
    return $cur
}

# Always returns an object[] with no $null elements (use: $a = SRV_Arr (SRV_Get ...)).
function SRV_Arr {
    param($v)
    $r = New-Object System.Collections.ArrayList
    if ($null -ne $v) {
        foreach ($x in @($v)) { if ($null -ne $x) { [void]$r.Add($x) } }
    }
    return ,$r.ToArray()
}

# To double, or $null (also for NaN / Infinity / non-numeric).
function SRV_Num {
    param($v)
    if ($null -eq $v) { return $null }
    $d = 0.0
    if ($v -is [double] -or $v -is [single] -or $v -is [decimal] -or $v -is [int] -or $v -is [long] -or $v -is [int16] -or $v -is [byte] -or $v -is [uint32] -or $v -is [uint64]) {
        $d = [double]$v
    }
    else {
        $s = ([string]$v).Trim()
        if (-not [double]::TryParse($s, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $null }
    }
    if ([double]::IsNaN($d) -or [double]::IsInfinity($d)) { return $null }
    return $d
}

function SRV_Bool {
    param($v)
    if ($null -eq $v) { return $null }
    if ($v -is [bool]) { return $v }
    $s = ([string]$v).Trim().ToLowerInvariant()
    if ($s -eq 'true' -or $s -eq '1' -or $s -eq 'yes' -or $s -eq 'on') { return $true }
    if ($s -eq 'false' -or $s -eq '0' -or $s -eq 'no' -or $s -eq 'off') { return $false }
    return $null
}

function SRV_Str {
    param($v)
    if ($null -eq $v) { return '' }
    return ([string]$v).Trim()
}

# 1,234 (thousands separator, d decimals)
function SRV_N {
    param($v, [int]$d = 0)
    $n = SRV_Num $v
    if ($null -eq $n) { return '?' }
    return $n.ToString(('N' + $d), (SRV_Inv))
}

# 1234.5 (no thousands separator, d decimals)
function SRV_F {
    param($v, [int]$d = 1)
    $n = SRV_Num $v
    if ($null -eq $n) { return '?' }
    return $n.ToString(('F' + $d), (SRV_Inv))
}

# Throughput: >= 100 -> no decimals, else one decimal.
function SRV_Mbps {
    param($v)
    $n = SRV_Num $v
    if ($null -eq $n) { return '?' }
    if ([math]::Abs($n) -ge 100) { return $n.ToString('F0', (SRV_Inv)) }
    return $n.ToString('F1', (SRV_Inv))
}

# Up to 2 decimals, trailing zeros trimmed (10 -> "10", 8.5 -> "8.5").
function SRV_T {
    param($v)
    $n = SRV_Num $v
    if ($null -eq $n) { return '?' }
    return $n.ToString('0.##', (SRV_Inv))
}

function SRV_Ms {
    param($v)
    return ((SRV_F $v 0) + ' ms')
}

# ratio helper, capped so JSON never sees Infinity; $null when not computable.
function SRV_Margin {
    param($num, $den)
    $n = SRV_Num $num
    $d = SRV_Num $den
    if ($null -eq $n -or $null -eq $d) { return $null }
    if ($d -le 0) {
        if ($n -le 0) { return $null }
        return [double]10
    }
    $m = $n / $d
    if ($m -gt 10) { $m = 10 }
    if ($m -lt 0) { $m = 0 }
    return [math]::Round($m, 2)
}

function SRV_RoundUp {
    param([double]$x, [double]$step)
    if ($step -le 0) { return $x }
    return ([math]::Ceiling([math]::Round(($x / $step), 9)) * $step)
}

function SRV_Percentile {
    param($vals, [double]$p)
    $list = New-Object System.Collections.ArrayList
    foreach ($x in @($vals)) {
        $n = SRV_Num $x
        if ($null -ne $n) { [void]$list.Add($n) }
    }
    if ($list.Count -eq 0) { return $null }
    $a = @($list.ToArray() | Sort-Object)
    $rank = [math]::Ceiling($p / 100.0 * $a.Count)
    if ($rank -lt 1) { $rank = 1 }
    if ($rank -gt $a.Count) { $rank = $a.Count }
    return [double]$a[[int]$rank - 1]
}

function SRV_Median {
    param($vals)
    $list = New-Object System.Collections.ArrayList
    foreach ($x in @($vals)) {
        $n = SRV_Num $x
        if ($null -ne $n) { [void]$list.Add($n) }
    }
    $cnt = $list.Count
    if ($cnt -eq 0) { return $null }
    $a = @($list.ToArray() | Sort-Object)
    if (($cnt % 2) -eq 1) { return [double]$a[[int](($cnt - 1) / 2)] }
    return (([double]$a[($cnt / 2) - 1] + [double]$a[$cnt / 2]) / 2)
}

function SRV_Th {
    param($Thr, [string[]]$Path)
    return (SRV_Num (SRV_Get $Thr $Path))
}

# lower-is-better grade. Exclusive: v < warn PASS, v < fail WARN. Inclusive: v <= warn PASS, v <= fail WARN.
function SRV_GradeLow {
    param($v, $warn, $fail, [switch]$Inclusive)
    if ($null -eq $v -or $null -eq $warn -or $null -eq $fail) { return 'INFO' }
    if ($Inclusive) {
        if ($v -le $warn) { return 'PASS' }
        if ($v -le $fail) { return 'WARN' }
        return 'FAIL'
    }
    if ($v -lt $warn) { return 'PASS' }
    if ($v -lt $fail) { return 'WARN' }
    return 'FAIL'
}

# higher-is-better grade: v >= pass PASS, v >= warn WARN, else FAIL.
function SRV_GradeHigh {
    param($v, $pass, $warn)
    if ($null -eq $v -or $null -eq $pass -or $null -eq $warn) { return 'INFO' }
    if ($v -ge $pass) { return 'PASS' }
    if ($v -ge $warn) { return 'WARN' }
    return 'FAIL'
}

function SRV_JoinNames {
    param($names, [int]$Max = 6)
    $a = @($names | Where-Object { $null -ne $_ -and ([string]$_) -ne '' })
    if ($a.Count -eq 0) { return '' }
    if ($a.Count -le $Max) { return ($a -join ', ') }
    $first = @($a | Select-Object -First $Max)
    return (($first -join ', ') + ' and ' + ($a.Count - $Max) + ' more')
}

# ---------------------------------------------------------------------------------------------
# Check catalogue (id -> section, title). Order here = order of the final checks array.
# ---------------------------------------------------------------------------------------------
function SRV_Meta {
    $m = [ordered]@{}
    $m['fr_reach']            = @('france',   'France reachable')
    $m['fr_rtt']              = @('france',   'Round-trip time to France (p95)')
    $m['fr_rtt_spread']       = @('france',   'Round-trip stability (p99 - p50)')
    $m['fr_icmp_loss']        = @('france',   'Ping loss to France')
    $m['fr_udp_loss']         = @('france',   'UDP loss at SRT bitrate')
    $m['fr_udp_bursts']       = @('france',   'UDP loss bursts')
    $m['uplink_capacity']     = @('uplink',   'Upload capacity vs. show needs')
    $m['uplink_wifi']         = @('uplink',   'Internet connection type')
    $m['ingest_youtube']      = @('ingest',   'YouTube ingest reachable')
    $m['ingest_twitch']       = @('ingest',   'Twitch ingest reachable')
    $m['lan_wired']           = @('lan',      'Wired network connection')
    $m['lan_headroom']        = @('lan',      'LAN headroom for incoming feeds')
    $m['lan_virtual_adapters'] = @('lan',     'Virtual network adapters')
    $m['lan_profile']         = @('lan',      'Windows network profile')
    $m['lan_eee']             = @('lan',      'Energy-Efficient Ethernet')
    $m['lan_sources_found']   = @('lan',      'Incoming feeds found on the network')
    $m['lan_partner_throughput'] = @('lan',   'Network throughput from source PCs')
    $m['lan_hosts']           = @('lan',      'Devices on the local network')
    $m['hw_cpu_threads']      = @('hardware', 'CPU threads')
    $m['hw_ram']              = @('hardware', 'RAM')
    $m['hw_gpu']              = @('hardware', 'Dedicated GPU')
    $m['hw_nvenc_sessions']   = @('hardware', 'NVENC encode sessions')
    $m['hw_power']            = @('hardware', 'Power plan and mains power')
    $m['hw_gpu_driver_age']   = @('hardware', 'GPU driver age')
    $m['hw_disk']             = @('hardware', 'System drive free space')
    $m['hw_pending_reboot']   = @('hardware', 'Pending Windows reboot')
    $m['load_encoder']        = @('load',     'Hardware video encoder')
    $m['load_realtime']       = @('load',     'Real-time 2 in + 3 out')
    $m['load_cpu']            = @('load',     'CPU load during test')
    $m['load_gpu_encode']     = @('load',     'GPU encoder load during test')
    $m['load_throttle']       = @('load',     'CPU clock throttling')
    $m['sw_mixer']            = @('software', 'vMix or OBS installed')
    $m['sw_ndi']              = @('software', 'NDI / OMT software')
    $m['sw_background']       = @('software', 'Background apps')
    return $m
}

function SRV_NewCheck {
    param([string]$Id, [string]$Section, [string]$Title, [string]$Status, [string]$Value, [string]$Limit, $Margin, [string]$Detail, [string]$Fix)
    $mg = $null
    $mn = SRV_Num $Margin
    if ($null -ne $mn) { $mg = $mn }
    return [pscustomobject][ordered]@{
        id      = $Id
        section = $Section
        title   = $Title
        status  = $Status
        value   = $Value
        limit   = $Limit
        margin  = $mg
        detail  = $Detail
        fix     = $Fix
    }
}

# Short "weakest link" sentence for a check.
function SRV_Lead {
    param($c, [string]$Prefix)
    $s = $Prefix + $c.title
    $inner = ''
    if ($c.value -ne '') { $inner = [string]$c.value }
    if ($c.limit -ne '') {
        if ($inner -ne '') { $inner = $inner + '; needs ' + $c.limit } else { $inner = 'needs ' + $c.limit }
    }
    if ($inner -ne '') { $s = $s + ' (' + $inner + ')' }
    if ($c.fix -ne '') { $s = $s + ' - ' + $c.fix }
    return $s
}

function SRV_NvDriver {
    param($g)
    $d = SRV_Num (SRV_Get $g 'nvidia_driver')
    if ($null -ne $d) { return $d }
    $dv = SRV_Str (SRV_Get $g 'driver_version')
    if ($dv -ne '') {
        $digits = ($dv -replace '[^0-9]', '')
        if ($digits.Length -ge 5) {
            $l5 = $digits.Substring($digits.Length - 5)
            $txt = $l5.Substring(0, 3) + '.' + $l5.Substring(3)
            $out = 0.0
            if ([double]::TryParse($txt, [System.Globalization.NumberStyles]::Float, (SRV_Inv), [ref]$out)) { return $out }
        }
    }
    return $null
}

function SRV_IsDedicated {
    param($g)
    $integ = SRV_Bool (SRV_Get $g 'integrated')
    if ($integ -eq $true) { return $false }
    $v = (SRV_Str (SRV_Get $g 'vendor')).ToUpperInvariant()
    if ($v -eq 'NVIDIA' -or $v -eq 'AMD') { return $true }
    if ($v -eq 'INTEL') { return ((SRV_Str (SRV_Get $g 'name')) -match '\bArc\b') }
    return $false
}

# Did this probe target answer at all (ICMP reply or TCP connect)?
function SRV_TgtAnswered {
    param($t)
    $rx = SRV_Num (SRV_Get $t 'icmp', 'received')
    if ($null -ne $rx -and $rx -gt 0) { return $true }
    $ok = SRV_Num (SRV_Get $t 'tcp', 'ok')
    if ($null -ne $ok -and $ok -gt 0) { return $true }
    return $false
}

# p95 RTT of a target: ICMP p95 where it answered, else TCP connect p95, else $null.
function SRV_TgtP95 {
    param($t)
    $rx = SRV_Num (SRV_Get $t 'icmp', 'received')
    $blocked = SRV_Bool (SRV_Get $t 'icmp', 'blocked')
    $p = SRV_Num (SRV_Get $t 'icmp', 'p95_ms')
    if ($null -ne $p -and $blocked -ne $true -and ($null -eq $rx -or $rx -gt 0)) { return $p }
    $ok = SRV_Num (SRV_Get $t 'tcp', 'ok')
    $p = SRV_Num (SRV_Get $t 'tcp', 'p95_ms')
    if ($null -ne $p -and ($null -eq $ok -or $ok -gt 0)) { return $p }
    return $null
}

function SRV_TgtName {
    param($t)
    $n = SRV_Str (SRV_Get $t 'name')
    if ($n -ne '') { return $n }
    return (SRV_Str (SRV_Get $t 'host'))
}

function SRV_StripExe {
    param([string]$n)
    return ($n -replace '(?i)\.exe$', '').Trim()
}

# ---------------------------------------------------------------------------------------------
# Get-SRVerdict
# ---------------------------------------------------------------------------------------------
function Get-SRVerdict {
    [CmdletBinding()]
    param($Config, $Hardware, $Network, $LoadTest, $Lan = $null, [datetime]$Now = [datetime]::Now)

    $inv = SRV_Inv
    $meta = SRV_Meta
    $checks = New-Object System.Collections.ArrayList
    $settings = New-Object System.Collections.ArrayList
    $errs = New-Object System.Collections.ArrayList
    $notTested = New-Object System.Collections.ArrayList
    $calc = [ordered]@{}

    # Contract constants (RULES section): SRT rtt floor 20 ms, long-haul above 150 ms forces >= 4x, assumed loss 1 %.
    $RTT_FLOOR_MS = 20
    $LONGHAUL_RTT_MS = 150
    $LONGHAUL_MULT = 4
    $ASSUMED_LOSS_PCT = 1
    # Installed RAM reads a few percent below the nominal module size (reserved memory), so 32 GB shows as ~31.7.
    $RAM_TOLERANCE = 0.95

    $hasHw = ($null -ne $Hardware)
    $hasNet = ($null -ne $Network)
    $hasLoad = ($null -ne $LoadTest)
    $hasLan = ($null -ne $Lan)
    $Thr = SRV_Get $Config 'thresholds'

    function AddCheck {
        param([string]$Id, [string]$Status, [string]$Value = '', [string]$Limit = '', $Margin = $null, [string]$Detail = '', [string]$Fix = '')
        $sec = 'other'
        $ttl = $Id
        if ($meta.Contains($Id)) { $sec = $meta[$Id][0]; $ttl = $meta[$Id][1] }
        [void]$checks.Add((SRV_NewCheck -Id $Id -Section $sec -Title $ttl -Status $Status -Value $Value -Limit $Limit -Margin $Margin -Detail $Detail -Fix $Fix))
    }
    function SkipIds {
        param([string[]]$Ids, [string]$Why)
        foreach ($i in $Ids) { AddCheck -Id $i -Status 'SKIP' -Detail $Why }
    }
    function AddSetting {
        param([string]$Id, [string]$Label, [string]$Value, [string]$Why = '')
        [void]$settings.Add([pscustomobject][ordered]@{ id = $Id; label = $Label; value = $Value; why = $Why })
    }

    # ---- show profile ----
    $inCount = SRV_Num (SRV_Get $Config 'show', 'inputs', 'count')
    $proto = SRV_Str (SRV_Get $Config 'show', 'inputs', 'protocol')
    $outputs = SRV_Arr (SRV_Get $Config 'show', 'outputs')
    $outSrt = $null
    foreach ($o in $outputs) { if ((SRV_Str (SRV_Get $o 'id')).ToLowerInvariant() -eq 'srt') { $outSrt = $o; break } }

    $rttP95 = $null
    $ovhPct = $null
    $ovhAssumed = $false
    $needMbps = $null
    $intakeMbps = $null
    $udpMeasured = $false
    $udpLoss = $null
    $icmpLoss = $null
    $lossyTotal = 0

    # =========================================================================================
    # FRANCE
    # =========================================================================================
    $frIds = @('fr_reach', 'fr_rtt', 'fr_rtt_spread', 'fr_icmp_loss', 'fr_udp_loss', 'fr_udp_bursts')
    if (-not $hasNet) {
        SkipIds $frIds 'Network test was not run.'
        [void]$notTested.Add('network')
    }
    else {
        try {
            $targets = SRV_Arr (SRV_Get $Network 'targets')
            $frList = New-Object System.Collections.ArrayList
            foreach ($t in $targets) {
                if ((SRV_Str (SRV_Get $t 'group')).ToLowerInvariant() -eq 'france') { [void]$frList.Add($t) }
            }
            $frAll = $frList.ToArray()

            # chosen target: the SRT destination when set and measured, else all France targets
            $destHost = SRV_Str (SRV_Get $Config 'show', 'srt_destination_host')
            $destT = $null
            if ($destHost -ne '') {
                foreach ($t in $targets) {
                    $h = SRV_Str (SRV_Get $t 'host')
                    $nm = SRV_Str (SRV_Get $t 'name')
                    if (($h -ieq $destHost) -or ($nm -ieq 'SRT destination')) {
                        if (SRV_TgtAnswered $t) { $destT = $t; break }
                    }
                }
            }
            if ($null -ne $destT) { $chosen = @($destT) } else { $chosen = $frAll }

            # ---- fr_reach ----
            if ($frAll.Count -eq 0) {
                AddCheck -Id 'fr_reach' -Status 'SKIP' -Detail 'No France targets in the network results.'
            }
            else {
                $answered = @($frAll | Where-Object { SRV_TgtAnswered $_ })
                $ansNames = @($answered | ForEach-Object { SRV_TgtName $_ })
                $silentNames = @($frAll | Where-Object { -not (SRV_TgtAnswered $_) } | ForEach-Object { SRV_TgtName $_ })
                $val = ([string]$answered.Count + ' of ' + [string]$frAll.Count + ' France targets answered')
                if ($answered.Count -gt 0) {
                    $det = 'Answered: ' + (SRV_JoinNames $ansNames 8) + '.'
                    if ($silentNames.Count -gt 0) { $det = $det + ' No answer: ' + (SRV_JoinNames $silentNames 8) + '.' }
                    AddCheck -Id 'fr_reach' -Status 'PASS' -Value $val -Limit '>= 1 target' -Margin ([double]$answered.Count) -Detail $det
                }
                else {
                    AddCheck -Id 'fr_reach' -Status 'FAIL' -Value 'no France target answered' -Limit '>= 1 target' -Margin 0 `
                        -Detail ('Nothing answered ping or TCP: ' + (SRV_JoinNames $silentNames 8) + '.') `
                        -Fix 'Check the show PC has working internet (cable, captive portal, firewall) and run ShowReady again.'
                }
            }

            # ---- fr_rtt ----
            $p95s = New-Object System.Collections.ArrayList
            $p95Names = @{}
            foreach ($t in $chosen) {
                $p = SRV_TgtP95 $t
                if ($null -ne $p) { [void]$p95s.Add($p); $p95Names[[string]$p] = (SRV_TgtName $t) }
            }
            if ($p95s.Count -gt 0) {
                if ($null -ne $destT) { $rttP95 = [double]$p95s[0] } else { $rttP95 = SRV_Median $p95s.ToArray() }
                $minP = ($p95s.ToArray() | Measure-Object -Minimum).Minimum
                $maxP = ($p95s.ToArray() | Measure-Object -Maximum).Maximum
                if ($null -ne $destT) {
                    $det = 'Measured to the SRT destination ' + (SRV_Str (SRV_Get $destT 'host')) + ' (p95 ' + (SRV_Ms $rttP95) + '). The SRT latency below is computed from this exact path.'
                }
                else {
                    $det = 'Median of the p95 values of ' + $p95s.Count + ' France targets; they range from ' + (SRV_Ms $minP) + ' (' + $p95Names[[string]$minP] + ') to ' + (SRV_Ms $maxP) + ' (' + $p95Names[[string]$maxP] + '). The SRT latency below is computed from this; re-run with -SrtHost <partner IP> for the exact path.'
                    if ($destHost -ne '') { $det = 'The SRT destination ' + $destHost + ' did not answer ping or TCP, so the France targets are used instead. ' + $det }
                }
                AddCheck -Id 'fr_rtt' -Status 'INFO' -Value (SRV_Ms $rttP95) -Detail $det
            }
            else {
                AddCheck -Id 'fr_rtt' -Status 'SKIP' -Detail 'No France target returned an RTT sample (ICMP and TCP both silent).'
            }

            # ---- fr_rtt_spread (p99 - p50, worst over chosen targets with ICMP replies) ----
            $worstSpread = $null
            $worstName = ''
            foreach ($t in $chosen) {
                $rx = SRV_Num (SRV_Get $t 'icmp', 'received')
                $blocked = SRV_Bool (SRV_Get $t 'icmp', 'blocked')
                if ($blocked -eq $true -or ($null -ne $rx -and $rx -le 0)) { continue }
                $samples = SRV_Get $t 'icmp', 'samples_ms'
                $p50 = SRV_Num (SRV_Get $t 'icmp', 'p50_ms')
                $p99 = SRV_Num (SRV_Get $t 'icmp', 'p99_ms')
                if ($null -eq $p50) { $p50 = SRV_Percentile $samples 50 }
                if ($null -eq $p99) { $p99 = SRV_Percentile $samples 99 }
                if ($null -eq $p50 -or $null -eq $p99) { continue }
                $sp = $p99 - $p50
                if ($null -eq $worstSpread -or $sp -gt $worstSpread) { $worstSpread = $sp; $worstName = SRV_TgtName $t }
            }
            if ($null -eq $worstSpread) {
                AddCheck -Id 'fr_rtt_spread' -Status 'SKIP' -Detail 'No ICMP replies to measure RTT spread (hosts ignore ping).'
            }
            else {
                $w = SRV_Th $Thr 'rtt_spread_ms', 'warn'
                $f = SRV_Th $Thr 'rtt_spread_ms', 'fail'
                $st = SRV_GradeLow $worstSpread $w $f
                $fix = ''
                if ($st -eq 'WARN' -or $st -eq 'FAIL') { $fix = 'The path to France is unstable: stop other traffic on the venue line (updates, uploads), use wired Ethernet, and re-run at show time.' }
                AddCheck -Id 'fr_rtt_spread' -Status $st -Value ((SRV_F $worstSpread 0) + ' ms') -Limit ('< ' + (SRV_T $w) + ' ms') -Margin (SRV_Margin $w $worstSpread) `
                    -Detail ('Worst spread between the typical (p50) and slowest 1 % (p99) ping: ' + $worstName + '. Big spread means jitter that SRT must absorb.') -Fix $fix
            }

            # ---- fr_icmp_loss (pooled, blocked hosts excluded) ----
            $sumSent = 0.0
            $sumRecv = 0.0
            $blockedNames = New-Object System.Collections.ArrayList
            $usedIcmp = 0
            foreach ($t in $chosen) {
                $sent = SRV_Num (SRV_Get $t 'icmp', 'sent')
                $rx = SRV_Num (SRV_Get $t 'icmp', 'received')
                $blocked = SRV_Bool (SRV_Get $t 'icmp', 'blocked')
                if ($null -eq $sent -and $null -eq $rx -and $blocked -ne $true) { continue }
                if ($blocked -eq $true -or ($null -ne $rx -and $rx -le 0)) { [void]$blockedNames.Add((SRV_TgtName $t)); continue }
                if ($null -eq $sent -or $null -eq $rx -or $sent -le 0) { continue }
                $sumSent += $sent
                $sumRecv += $rx
                $usedIcmp++
            }
            if ($sumSent -gt 0) {
                $icmpLoss = [math]::Max([double]0, [double](($sumSent - $sumRecv) / $sumSent * 100))
                $w = SRV_Th $Thr 'icmp_loss_pct', 'warn'
                $f = SRV_Th $Thr 'icmp_loss_pct', 'fail'
                $st = SRV_GradeLow $icmpLoss $w $f
                $det = 'Pooled over ' + $usedIcmp + ' target(s): ' + (SRV_F ($sumSent - $sumRecv) 0) + ' of ' + (SRV_F $sumSent 0) + ' pings lost.'
                if ($blockedNames.Count -gt 0) { $det = $det + ' Ignores ping (not a fault): ' + (SRV_JoinNames $blockedNames.ToArray() 8) + '.' }
                $fix = ''
                if ($st -eq 'WARN' -or $st -eq 'FAIL') { $fix = 'Packets are being lost on the way out: check the cable/switch, stop other heavy traffic, and ask venue IT to check the internet line.' }
                AddCheck -Id 'fr_icmp_loss' -Status $st -Value ((SRV_F $icmpLoss 1) + ' %') -Limit ('< ' + (SRV_T $w) + ' %') -Margin (SRV_Margin $w $icmpLoss) -Detail $det -Fix $fix
            }
            else {
                $det = 'No ping results to pool.'
                if ($blockedNames.Count -gt 0) { $det = 'All hosts ignore ping (not a fault): ' + (SRV_JoinNames $blockedNames.ToArray() 8) + '.' }
                AddCheck -Id 'fr_icmp_loss' -Status 'SKIP' -Detail $det
            }

            # ---- UDP (receiver side, iperf3) ----
            $udpAll = SRV_Arr (SRV_Get $Network 'udp')
            $udpPick = New-Object System.Collections.ArrayList
            $udpErrs = New-Object System.Collections.ArrayList
            foreach ($u in $udpAll) {
                $uerr = SRV_Str (SRV_Get $u 'error')
                $pk = SRV_Num (SRV_Get $u 'packets')
                if ($uerr -eq '' -and $null -ne $pk -and $pk -gt 0) { [void]$udpPick.Add($u) }
                elseif ($uerr -ne '') { [void]$udpErrs.Add((SRV_Str (SRV_Get $u 'host')) + ': ' + $uerr) }
            }
            $udpUse = $udpPick.ToArray()
            if ($null -ne $destT -and $destHost -ne '') {
                $own = @($udpUse | Where-Object { (SRV_Str (SRV_Get $_ 'host')) -ieq $destHost })
                if ($own.Count -gt 0) { $udpUse = $own }
            }
            if ($udpUse.Count -gt 0) {
                $udpMeasured = $true
                $sumP = 0.0
                $sumL = 0.0
                $worstInt = 0.0
                $udpDesc = New-Object System.Collections.ArrayList
                $burstPct = SRV_Th $Thr 'srt_burst_interval_loss_pct'
                foreach ($u in $udpUse) {
                    $pk = SRV_Num (SRV_Get $u 'packets')
                    $ls = SRV_Num (SRV_Get $u 'lost')
                    $lp = SRV_Num (SRV_Get $u 'loss_pct')
                    if ($null -eq $ls) { if ($null -ne $lp) { $ls = $pk * $lp / 100 } else { $ls = 0 } }
                    $sumP += $pk
                    $sumL += $ls
                    $ints = SRV_Arr (SRV_Get $u 'intervals')
                    $lossyU = SRV_Num (SRV_Get $u 'lossy_intervals')
                    $worstU = SRV_Num (SRV_Get $u 'worst_interval_loss_pct')
                    if ($null -eq $lossyU -or $null -eq $worstU) {
                        $cLossy = 0
                        $cWorst = 0.0
                        foreach ($iv in $ints) {
                            $ip = SRV_Num (SRV_Get $iv 'packets')
                            $il = SRV_Num (SRV_Get $iv 'lost')
                            if ($null -ne $ip -and $ip -gt 0 -and $null -ne $il) {
                                $ipct = $il / $ip * 100
                                if ($ipct -gt $cWorst) { $cWorst = $ipct }
                                if ($null -ne $burstPct -and $ipct -gt $burstPct) { $cLossy++ }
                            }
                        }
                        if ($null -eq $lossyU) { $lossyU = $cLossy }
                        if ($null -eq $worstU) { $worstU = $cWorst }
                    }
                    $lossyTotal += [int]$lossyU
                    if ($worstU -gt $worstInt) { $worstInt = $worstU }
                    $pctU = 0.0
                    if ($pk -gt 0) { $pctU = $ls / $pk * 100 }
                    [void]$udpDesc.Add((SRV_Str (SRV_Get $u 'host')) + ' ' + (SRV_F $pctU 2) + ' %')
                }
                $udpLoss = 0.0
                if ($sumP -gt 0) { $udpLoss = [math]::Max([double]0, [double]($sumL / $sumP * 100)) }
                $tmbps = SRV_Num (SRV_Get $udpUse[0] 'target_mbps')
                $secs = SRV_Num (SRV_Get $udpUse[0] 'seconds')
                $w = SRV_Th $Thr 'udp_loss_pct', 'warn'
                $f = SRV_Th $Thr 'udp_loss_pct', 'fail'
                $st = SRV_GradeLow $udpLoss $w $f -Inclusive
                $det = 'Receiver-side loss over ' + $udpUse.Count + ' iperf3 test(s)'
                if ($null -ne $tmbps) { $det = $det + ' at ' + (SRV_Mbps $tmbps) + ' Mbps' }
                if ($null -ne $secs) { $det = $det + ' for ' + (SRV_F $secs 0) + ' s each' }
                $det = $det + ': ' + (SRV_JoinNames $udpDesc.ToArray() 8) + '.'
                $fix = ''
                if ($st -eq 'WARN') { $fix = 'Some SRT packets will be lost: use the higher SRT latency/overhead below and re-run at show time.' }
                if ($st -eq 'FAIL') { $fix = 'The line to France drops too many packets for SRT: ask venue IT to check the internet line, use wired Ethernet, or switch to another ISP/line.' }
                AddCheck -Id 'fr_udp_loss' -Status $st -Value ((SRV_F $udpLoss 2) + ' %') -Limit ('<= ' + (SRV_T $w) + ' %') -Margin (SRV_Margin $w $udpLoss) -Detail $det -Fix $fix

                # ---- fr_udp_bursts ----
                if ($lossyTotal -ge 1) {
                    AddCheck -Id 'fr_udp_bursts' -Status 'WARN' -Value ([string]$lossyTotal + ' lossy interval(s)') -Limit '0' -Margin 0 `
                        -Detail ('Worst 1 s interval lost ' + (SRV_F $worstInt 1) + ' %' + $(if ($null -ne $burstPct) { ' (an interval above ' + (SRV_T $burstPct) + ' % counts as lossy)' } else { '' }) + '. Bursty loss hurts SRT more than the average suggests, so the latency below is raised.') `
                        -Fix 'Loss comes in bursts: use the raised SRT latency below, keep Wi-Fi and other heavy traffic off the line, and re-run at show time.'
                }
                else {
                    AddCheck -Id 'fr_udp_bursts' -Status 'PASS' -Value '0 lossy intervals' -Limit '0' `
                        -Detail ('No 1 s interval lost more than ' + $(if ($null -ne $burstPct) { (SRV_T $burstPct) } else { '?' }) + ' % of its packets.')
                }
            }
            else {
                $det = 'UDP path not measured - ping only.'
                if ($udpErrs.Count -gt 0) { $det = $det + ' First problem: ' + $udpErrs[0] + '.' }
                $fixU = 'Re-run (the shared iperf3 test servers are sometimes busy), or run full mode. Until the UDP loss is measured, the SRT latency uses the safe 4x minimum.'
                AddCheck -Id 'fr_udp_loss' -Status 'SKIP' -Value 'not measured' -Detail $det -Fix $fixU
                AddCheck -Id 'fr_udp_bursts' -Status 'SKIP' -Value 'not measured' -Detail 'UDP path not measured - ping only.'
                [void]$notTested.Add('UDP loss at SRT bitrate')
            }

            # ---- SRT settings ----
            $tblRaw = SRV_Arr (SRV_Get $Thr 'srt_rtt_multiplier_table')
            $tbl = @($tblRaw | Sort-Object -Property @{ Expression = { SRV_Num (SRV_Get $_ 'max_loss_pct') } })
            $minMultCfg = SRV_Th $Thr 'srt_min_multiplier_when_unmeasured_or_bursty'
            $roundMs = SRV_Th $Thr 'srt_latency_round_ms'
            if ($null -eq $roundMs -or $roundMs -le 0) { $roundMs = 1 }
            $maxMs = SRV_Th $Thr 'srt_latency_max_ms'

            if ($tbl.Count -gt 0) {
                # fallback overhead for the uplink need when no RTT is available (4x floor)
                $ovhFallback = [math]::Ceiling(100 / $LONGHAUL_MULT)
                $r0 = SRV_Num (SRV_Get $tbl[0] 'overhead_pct')
                if ($null -ne $r0 -and $r0 -gt $ovhFallback) { $ovhFallback = $r0 }
                $ovhPct = $ovhFallback
                $ovhAssumed = $true
            }
            if ($null -ne $rttP95 -and $tbl.Count -gt 0) {
                $rttCalc = [math]::Max([double]$rttP95, [double]$RTT_FLOOR_MS)
                $lossSrc = 'assumed'
                if ($udpMeasured) { $lossUse = $udpLoss; $lossSrc = 'udp' }
                elseif ($null -ne $icmpLoss) { $lossUse = $icmpLoss; $lossSrc = 'icmp' }
                else { $lossUse = $ASSUMED_LOSS_PCT }

                $row = $null
                foreach ($r in $tbl) {
                    $ml = SRV_Num (SRV_Get $r 'max_loss_pct')
                    if ($null -ne $ml -and $lossUse -le $ml) { $row = $r; break }
                }
                if ($null -eq $row) { $row = $tbl[$tbl.Count - 1] }
                $multTable = SRV_Num (SRV_Get $row 'multiplier')
                $rowOvh = SRV_Num (SRV_Get $row 'overhead_pct')
                $rowMax = SRV_Num (SRV_Get $row 'max_loss_pct')
                if ($null -eq $multTable) { $multTable = $LONGHAUL_MULT }
                if ($null -eq $rowOvh) { $rowOvh = 0 }

                $mult = $multTable
                $reasons = New-Object System.Collections.ArrayList
                if (-not $udpMeasured -and $null -ne $minMultCfg) {
                    if ($minMultCfg -gt $mult) { $mult = $minMultCfg }
                    [void]$reasons.Add('UDP loss was not measured')
                }
                if ($lossyTotal -ge 1 -and $null -ne $minMultCfg) {
                    if ($minMultCfg -gt $mult) { $mult = $minMultCfg }
                    [void]$reasons.Add('lossy intervals were seen')
                }
                if ($rttCalc -gt $LONGHAUL_RTT_MS) {
                    if ($LONGHAUL_MULT -gt $mult) { $mult = $LONGHAUL_MULT }
                    [void]$reasons.Add('the path is long-haul (RTT > ' + $LONGHAUL_RTT_MS + ' ms) and short probes miss rare bursts')
                }

                $latTableRaw = $multTable * $rttCalc
                $latRaw = $mult * $rttCalc
                $latTable = SRV_RoundUp $latTableRaw $roundMs
                $lat = SRV_RoundUp $latRaw $roundMs
                $capped = $false
                if ($null -ne $maxMs -and $lat -gt $maxMs) { $lat = $maxMs; $capped = $true }
                if ($null -ne $maxMs -and $latTable -gt $maxMs) { $latTable = $maxMs }
                $ovhPct = [math]::Max([double]$rowOvh, [double][math]::Ceiling(100 / $mult))
                $ovhAssumed = $false

                $loBound = ''
                if ($null -ne $rowMax) { $loBound = ' for loss <= ' + (SRV_T $rowMax) + ' %' }
                $why = '~' + (SRV_T $mult) + ' x p95 RTT ' + (SRV_F $rttCalc 0) + ' ms = ' + (SRV_F $latRaw 0) + ' ms, rounded up to ' + (SRV_N $lat 0) + ' ms'
                if ($capped) { $why = $why + ' (capped at the maximum)' }
                $why = $why + '. Haivision table minimum ' + (SRV_N $latTable 0) + ' ms (' + (SRV_T $multTable) + ' x' + $loBound + ')'
                if ($mult -gt $multTable) { $why = $why + '; raised to ' + (SRV_T $mult) + ' x because ' + ($reasons.ToArray() -join ' and ') }
                $why = $why + '. SRT needs several round trips to resend lost packets'
                if ($lat -gt 125) { $why = $why + '; the 120-125 ms encoder default will drop video on this path' }
                $why = $why + '.'

                $calc['srt'] = [pscustomobject][ordered]@{
                    rtt_p95_ms = [math]::Round($rttP95, 1)
                    rtt_calc_ms = [math]::Round($rttCalc, 1)
                    loss_pct = [math]::Round($lossUse, 3)
                    loss_source = $lossSrc
                    udp_measured = $udpMeasured
                    lossy_intervals = $lossyTotal
                    mult_table = $multTable
                    mult = $mult
                    latency_table_ms = $latTable
                    latency_raw_ms = [math]::Round($latRaw, 1)
                    latency_ms = $lat
                    overhead_pct = $ovhPct
                    reasons = $reasons.ToArray()
                }
                AddSetting -Id 'srt_latency' -Label 'SRT latency (both ends)' -Value ((SRV_N $lat 0) + ' ms') -Why $why
                AddSetting -Id 'srt_overhead' -Label 'SRT bandwidth overhead' -Value ((SRV_T $ovhPct) + ' %') `
                    -Why ('Haivision rule: at least the table overhead (' + (SRV_T $rowOvh) + ' %) and never below 100 / ' + (SRV_T $mult) + ' = ' + (SRV_T ([math]::Ceiling(100 / $mult))) + ' %.')
                $vkbps = SRV_Num (SRV_Get $outSrt 'video_kbps')
                if ($null -ne $vkbps) {
                    AddSetting -Id 'srt_bitrate' -Label 'SRT video bitrate' -Value ((SRV_T ($vkbps / 1000)) + ' Mbps video CBR, keyframe 2 s') -Why 'Constant bitrate keeps the SRT overhead calculation valid; a 2 s keyframe interval is what the partner decoder expects.'
                }
                $pkt = SRV_Num (SRV_Get $Config 'network', 'udp_packet_bytes')
                if ($null -eq $pkt) { $pkt = 1316 }
                AddSetting -Id 'srt_mode' -Label 'SRT mode' -Value ('caller, packet size ' + (SRV_F $pkt 0) + ', same latency on both ends (receiver latency wins if higher)') `
                    -Why 'The Seoul PC calls out to the partner in France; both sides must be set so the higher latency is not a surprise.'
            }
            else {
                if ($null -ne $rttP95) { [void]$errs.Add('thresholds.srt_rtt_multiplier_table missing; SRT settings not produced.') }
            }
        }
        catch {
            [void]$errs.Add('france section: ' + $_.Exception.Message)
        }
    }

    # =========================================================================================
    # UPLINK
    # =========================================================================================
    try {
        # need_mbps = sum of outputs; SRT output carries the overhead (assume the 4x-floor overhead when no RTT was measured)
        if ($null -eq $ovhPct) { $ovhPct = [math]::Ceiling(100 / $LONGHAUL_MULT); $ovhAssumed = $true }
        if ($outputs.Count -gt 0) {
            $needMbps = 0.0
            foreach ($o in $outputs) {
                $v = SRV_Num (SRV_Get $o 'video_kbps')
                $a = SRV_Num (SRV_Get $o 'audio_kbps')
                if ($null -eq $v) { $v = 0 }
                if ($null -eq $a) { $a = 0 }
                $m = ($v + $a) / 1000
                if ((SRV_Str (SRV_Get $o 'id')).ToLowerInvariant() -eq 'srt') {
                    $oh = $ovhPct
                    if ($null -eq $oh) { $oh = [math]::Ceiling(100 / $LONGHAUL_MULT) }
                    $m = $m * (1 + $oh / 100)
                }
                $needMbps += $m
            }
        }
        if ($null -ne $needMbps) { $calc['need_mbps'] = [math]::Round($needMbps, 3) } else { $calc['need_mbps'] = $null }

        if (-not $hasNet) {
            AddCheck -Id 'uplink_capacity' -Status 'SKIP' -Detail 'Network test was not run.'
        }
        else {
            $upMbps = SRV_Num (SRV_Get $Network 'upload', 'mbps')
            $upErr = SRV_Str (SRV_Get $Network 'upload', 'error')
            if ($null -eq $upMbps -or ($upMbps -le 0 -and $upErr -ne '')) {
                $det = 'Upload speed was not measured.'
                if ($upErr -ne '') { $det = $det + ' ' + $upErr }
                AddCheck -Id 'uplink_capacity' -Status 'SKIP' -Value 'not measured' -Detail $det -Fix 'Run ShowReady again (the upload test needs access to speed.cloudflare.com).'
                [void]$notTested.Add('upload capacity')
            }
            elseif ($null -eq $needMbps -or $needMbps -le 0) {
                AddCheck -Id 'uplink_capacity' -Status 'INFO' -Value ((SRV_Mbps $upMbps) + ' Mbps') -Detail 'Show outputs are missing from config.json, so the needed bandwidth cannot be computed.'
            }
            else {
                $pass = SRV_Th $Thr 'uplink_ratio', 'pass'
                $warn = SRV_Th $Thr 'uplink_ratio', 'warn'
                $ratio = $upMbps / $needMbps
                $st = SRV_GradeHigh $ratio $pass $warn
                $lim = ''
                if ($null -ne $pass) { $lim = '>= ' + (SRV_T $pass) + ' x ' + (SRV_Mbps $needMbps) + ' Mbps' }
                $det = 'Measured upload to a nearby Cloudflare PoP: ' + (SRV_Mbps $upMbps) + ' Mbps. The show needs ' + (SRV_Mbps $needMbps) + ' Mbps (SRT video+audio with ' + (SRV_T $ovhPct) + ' % overhead, YouTube, Twitch), ratio ' + (SRV_F $ratio 1) + ' x.'
                if ($ovhAssumed) { $det = $det + ' SRT overhead assumed ' + (SRV_T $ovhPct) + ' % because no RTT was measured.' }
                $fix = ''
                if ($st -eq 'WARN' -or $st -eq 'FAIL') {
                    $want = ''
                    if ($null -ne $pass) { $want = (SRV_Mbps ($pass * $needMbps)) + ' Mbps' }
                    $fix = 'Get an uplink of at least ' + $want + ' (ask venue IT for a dedicated line), or lower the YouTube and Twitch bitrates.'
                }
                AddCheck -Id 'uplink_capacity' -Status $st -Value ((SRV_Mbps $upMbps) + ' Mbps') -Limit $lim -Margin (SRV_Margin $ratio $pass) -Detail $det -Fix $fix
            }
        }
    }
    catch { [void]$errs.Add('uplink capacity: ' + $_.Exception.Message) }

    # ---- uplink_wifi (needs hardware) ----
    try {
        if (-not $hasHw) {
            AddCheck -Id 'uplink_wifi' -Status 'SKIP' -Detail 'Hardware scan was not run.'
        }
        else {
            $nicsRaw = SRV_Get $Hardware 'nics'
            if ($null -eq $nicsRaw) {
                AddCheck -Id 'uplink_wifi' -Status 'SKIP' -Detail 'Network adapter list unavailable.'
            }
            else {
                $nics = SRV_Arr $nicsRaw
                $defN = @($nics | Where-Object { (SRV_Bool (SRV_Get $_ 'default_route')) -eq $true })
                $defUp = @($defN | Where-Object { (SRV_Str (SRV_Get $_ 'status')) -ieq 'Up' })
                if ($defUp.Count -gt 0) { $defN = $defUp }
                $wiredUp = @($nics | Where-Object { (SRV_Str (SRV_Get $_ 'kind')) -ieq 'wired' -and (SRV_Str (SRV_Get $_ 'status')) -ieq 'Up' })
                $wifiUp = @($nics | Where-Object { (SRV_Str (SRV_Get $_ 'kind')) -ieq 'wifi' -and (SRV_Str (SRV_Get $_ 'status')) -ieq 'Up' })
                $defWired = @($defN | Where-Object { (SRV_Str (SRV_Get $_ 'kind')) -ieq 'wired' })
                $defWifi = @($defN | Where-Object { (SRV_Str (SRV_Get $_ 'kind')) -ieq 'wifi' })
                $fixWifi = 'Plug the PC into the venue network with an Ethernet cable and turn Wi-Fi off.'
                if ($defWired.Count -gt 0) {
                    $det = 'Internet traffic leaves through ' + (SRV_Str (SRV_Get $defWired[0] 'name')) + '.'
                    if ($wifiUp.Count -gt 0) { $det = $det + ' Wi-Fi is also connected; turn it off so the stream cannot fall back onto it.' }
                    AddCheck -Id 'uplink_wifi' -Status 'PASS' -Value 'wired' -Limit 'wired' -Detail $det
                }
                elseif ($defWifi.Count -gt 0) {
                    AddCheck -Id 'uplink_wifi' -Status 'FAIL' -Value 'Wi-Fi' -Limit 'wired' -Margin 0 `
                        -Detail ('The default route (internet) goes through the Wi-Fi adapter ' + (SRV_Str (SRV_Get $defWifi[0] 'name')) + '.') -Fix $fixWifi
                }
                elseif ($defN.Count -gt 0) {
                    $dn = SRV_Str (SRV_Get $defN[0] 'name')
                    if ($wiredUp.Count -gt 0) {
                        AddCheck -Id 'uplink_wifi' -Status 'WARN' -Value 'virtual adapter' -Limit 'wired' `
                            -Detail ('The default route goes through the virtual adapter ' + $dn + '. A wired adapter is up, but confirm the virtual adapter is bridged to it and not to Wi-Fi.') `
                            -Fix 'Open the adapter list (ncpa.cpl) and check that the virtual switch uses the wired Ethernet adapter, or remove it for the show.'
                    }
                    elseif ($wifiUp.Count -gt 0) {
                        AddCheck -Id 'uplink_wifi' -Status 'FAIL' -Value 'Wi-Fi (via virtual adapter)' -Limit 'wired' -Margin 0 `
                            -Detail ('The default route goes through the virtual adapter ' + $dn + ' and only Wi-Fi is connected, so the stream rides on Wi-Fi.') -Fix $fixWifi
                    }
                    else {
                        AddCheck -Id 'uplink_wifi' -Status 'INFO' -Value 'virtual adapter' -Detail ('The default route goes through ' + $dn + '; no wired or Wi-Fi adapter is up.')
                    }
                }
                else {
                    if ($wiredUp.Count -eq 0 -and $wifiUp.Count -gt 0) {
                        AddCheck -Id 'uplink_wifi' -Status 'FAIL' -Value 'Wi-Fi' -Limit 'wired' -Margin 0 -Detail 'Only a Wi-Fi adapter is connected.' -Fix $fixWifi
                    }
                    else {
                        AddCheck -Id 'uplink_wifi' -Status 'INFO' -Value 'unknown' -Detail 'No adapter is marked as the default route.'
                    }
                }
            }
        }
    }
    catch { [void]$errs.Add('uplink_wifi: ' + $_.Exception.Message) }

    # =========================================================================================
    # INGEST
    # =========================================================================================
    $bestTwitchHost = ''
    try {
        $targetsAll = SRV_Arr (SRV_Get $Network 'targets')
        foreach ($svc in @('youtube', 'twitch')) {
            $id = 'ingest_' + $svc
            $svcName = 'YouTube'
            if ($svc -eq 'twitch') { $svcName = 'Twitch' }
            if (-not $hasNet) { AddCheck -Id $id -Status 'SKIP' -Detail 'Network test was not run.'; continue }
            $svcT = @($targetsAll | Where-Object { (SRV_Str (SRV_Get $_ 'service')).ToLowerInvariant() -eq $svc })
            $twNote = ' Reachability only - Twitch closed its Korean business in Feb 2024; do a 30-second test stream with the real key from this venue.'
            if ($svcT.Count -eq 0) {
                $d = 'No ' + $svcName + ' ingest targets in the network results.'
                if ($svc -eq 'twitch') { $d = $d + $twNote }
                AddCheck -Id $id -Status 'SKIP' -Detail $d
                continue
            }
            $bestP = $null
            $bestHost = ''
            $parts = New-Object System.Collections.ArrayList
            foreach ($t in $svcT) {
                $ok = SRV_Num (SRV_Get $t 'tcp', 'ok')
                $p = SRV_Num (SRV_Get $t 'tcp', 'p95_ms')
                if ($null -eq $p) { $p = SRV_Num (SRV_Get $t 'tcp', 'p50_ms') }
                if ($null -ne $ok -and $ok -gt 0 -and $null -ne $p) {
                    [void]$parts.Add((SRV_TgtName $t) + ' ' + (SRV_F $p 0) + ' ms')
                    if ($null -eq $bestP -or $p -lt $bestP) { $bestP = $p; $bestHost = SRV_Str (SRV_Get $t 'host') }
                }
                else { [void]$parts.Add((SRV_TgtName $t) + ' unreachable') }
            }
            if ($svc -eq 'twitch' -and $bestHost -ne '') { $bestTwitchHost = $bestHost }
            $w = SRV_Th $Thr 'ingest_tcp_p95_ms', 'warn'
            $det = 'TCP connect p95 per ingest (port ' + (SRV_Str (SRV_Get $svcT[0] 'tcp', 'port')) + '): ' + ($parts.ToArray() -join ', ') + '.'
            if ($svc -eq 'twitch') { $det = $det + $twNote }
            if ($null -eq $bestP) {
                AddCheck -Id $id -Status 'FAIL' -Value 'unreachable' -Limit ($(if ($null -ne $w) { '<= ' + (SRV_T $w) + ' ms' } else { '' })) -Margin 0 -Detail $det `
                    -Fix ('Ask venue IT to allow outbound TCP 1935 (RTMP) to ' + $svcName + ', or use the RTMPS option on port 443 in vMix/OBS.')
            }
            else {
                $st = 'PASS'
                if ($null -ne $w -and $bestP -gt $w) { $st = 'WARN' }
                $fix = ''
                if ($st -eq 'WARN') { $fix = 'The ' + $svcName + ' ingest answers slowly: pick another ingest server, check for congestion, and verify with a real test stream.' }
                AddCheck -Id $id -Status $st -Value ((SRV_F $bestP 0) + ' ms') -Limit ($(if ($null -ne $w) { '<= ' + (SRV_T $w) + ' ms' } else { '' })) -Margin (SRV_Margin $w $bestP) -Detail $det -Fix $fix
            }
        }
        if ($hasNet) {
            $twPart = 'pick the nearest ingest in the Twitch dashboard (not measured)'
            if ($bestTwitchHost -ne '') { $twPart = $bestTwitchHost }
            AddSetting -Id 'ingest_servers' -Label 'Ingest servers' -Value ('YouTube: rtmp://a.rtmp.youtube.com/live2 (auto-nearest) | Twitch: ' + $twPart) `
                -Why 'The Twitch host is the one with the fastest TCP connect from this venue.'
        }
    }
    catch { [void]$errs.Add('ingest: ' + $_.Exception.Message) }

    # =========================================================================================
    # LAN
    # =========================================================================================
    $lanIds = @('lan_wired', 'lan_headroom', 'lan_virtual_adapters', 'lan_profile', 'lan_eee')
    try {
        $nicsRaw = SRV_Get $Hardware 'nics'
        if (-not $hasHw) { SkipIds $lanIds 'Hardware scan was not run.' }
        elseif ($null -eq $nicsRaw) { SkipIds $lanIds 'Network adapter list unavailable.' }
        else {
            $nics = SRV_Arr $nicsRaw
            $wiredUp = @($nics | Where-Object { (SRV_Str (SRV_Get $_ 'kind')) -ieq 'wired' -and (SRV_Str (SRV_Get $_ 'status')) -ieq 'Up' })
            $virtUp = @($nics | Where-Object { (SRV_Str (SRV_Get $_ 'kind')) -ieq 'virtual' -and (SRV_Str (SRV_Get $_ 'status')) -ieq 'Up' })

            # intake bandwidth
            $perFeed = SRV_Num (SRV_Get $Config 'show', 'inputs', 'mbps_per_feed', $proto)
            if ($null -eq $perFeed -and $proto -ne '') { $perFeed = SRV_Num (SRV_Get $Config 'show', 'inputs', 'mbps_per_feed', ($proto -replace '\s+', '-')) }
            if ($null -eq $perFeed -and $proto -match '^(?i)NDI') { $perFeed = SRV_Num (SRV_Get $Config 'show', 'inputs', 'mbps_per_feed', 'NDI') }
            if ($null -ne $perFeed -and $null -ne $inCount) { $intakeMbps = $inCount * $perFeed }
            $calc['intake_mbps'] = $intakeMbps

            # ---- lan_wired ----
            if ($wiredUp.Count -gt 0) {
                $best = $wiredUp | Sort-Object -Property @{ Expression = { $x = SRV_Num (SRV_Get $_ 'link_mbps'); if ($null -eq $x) { -1 } else { $x } } } -Descending | Select-Object -First 1
                $lm = SRV_Num (SRV_Get $best 'link_mbps')
                $val = 'wired Ethernet up'
                if ($null -ne $lm) { $val = (SRV_Str (SRV_Get $best 'name')) + ' at ' + (SRV_F $lm 0) + ' Mbps' }
                AddCheck -Id 'lan_wired' -Status 'PASS' -Value $val -Limit 'wired adapter up' -Detail ('Wired adapter(s) up: ' + (SRV_JoinNames @($wiredUp | ForEach-Object { SRV_Str (SRV_Get $_ 'name') }) 6) + '.')
            }
            else {
                $others = SRV_JoinNames @($nics | Where-Object { (SRV_Str (SRV_Get $_ 'status')) -ieq 'Up' } | ForEach-Object { (SRV_Str (SRV_Get $_ 'name')) + ' [' + (SRV_Str (SRV_Get $_ 'kind')) + ']' }) 6
                $det = 'No wired network adapter is connected. Wi-Fi cannot carry 2x 1080p60 OMT/NDI reliably.'
                if ($others -ne '') { $det = $det + ' Adapters up: ' + $others + '.' }
                AddCheck -Id 'lan_wired' -Status 'FAIL' -Value 'no wired adapter up' -Limit 'wired adapter up' -Margin 0 -Detail $det `
                    -Fix 'Connect the PC to the production switch with an Ethernet cable (2.5 GbE or faster) for the NDI/OMT feeds.'
            }

            # ---- lan_headroom ----
            $hrStatus = 'SKIP'
            $hrRatio = $null
            if ($wiredUp.Count -eq 0) {
                AddCheck -Id 'lan_headroom' -Status 'FAIL' -Value 'no wired link' -Limit '' -Margin 0 -Detail 'No wired adapter is up, so there is no usable path for the incoming feeds.' -Fix 'Connect a wired Ethernet adapter first.'
                $hrStatus = 'FAIL'
            }
            elseif ($null -eq $intakeMbps) {
                AddCheck -Id 'lan_headroom' -Status 'INFO' -Detail 'Input bandwidth per feed is not defined for the configured protocol in config.json.'
                $hrStatus = 'INFO'
            }
            else {
                $bestRatio = $null
                $bestNic = $null
                $bestDemand = $null
                foreach ($n in $wiredUp) {
                    $lm = SRV_Num (SRV_Get $n 'link_mbps')
                    if ($null -eq $lm -or $lm -le 0) { continue }
                    $demand = $intakeMbps
                    if ((SRV_Bool (SRV_Get $n 'default_route')) -eq $true -and $null -ne $needMbps) { $demand = $intakeMbps + $needMbps }
                    $r = $lm / $demand
                    if ($null -eq $bestRatio -or $r -gt $bestRatio) { $bestRatio = $r; $bestNic = $n; $bestDemand = $demand }
                }
                if ($null -eq $bestRatio) {
                    AddCheck -Id 'lan_headroom' -Status 'INFO' -Detail 'The link speed of the wired adapter is unknown.'
                    $hrStatus = 'INFO'
                }
                else {
                    $pass = SRV_Th $Thr 'lan_ratio', 'pass'
                    $warn = SRV_Th $Thr 'lan_ratio', 'warn'
                    $hrStatus = SRV_GradeHigh $bestRatio $pass $warn
                    $hrRatio = $bestRatio
                    $lm = SRV_Num (SRV_Get $bestNic 'link_mbps')
                    $det = (SRV_Str (SRV_Get $bestNic 'name')) + ' links at ' + (SRV_F $lm 0) + ' Mbps; ' + (SRV_F $inCount 0) + ' x ' + $proto + ' feeds need ' + (SRV_Mbps $intakeMbps) + ' Mbps'
                    if ($bestDemand -gt $intakeMbps) { $det = $det + ' plus ' + (SRV_Mbps $needMbps) + ' Mbps of outgoing streams on the same adapter' }
                    $det = $det + ', ratio ' + (SRV_F $bestRatio 1) + ' x.'
                    $fix = ''
                    if ($hrStatus -eq 'WARN' -or $hrStatus -eq 'FAIL') { $fix = 'Use a faster link (2.5 GbE or 10 GbE) or a separate adapter for the incoming feeds, or switch the feeds to NDI HX3 / OMT Low.' }
                    $limTxt = ''
                    if ($null -ne $pass) { $limTxt = '>= ' + (SRV_T $pass) + ' x ' + (SRV_Mbps $bestDemand) + ' Mbps' }
                    AddCheck -Id 'lan_headroom' -Status $hrStatus -Value ((SRV_F $lm 0) + ' Mbps link') -Limit $limTxt -Margin (SRV_Margin $bestRatio $pass) -Detail $det -Fix $fix
                }
            }
            if ($hrStatus -eq 'PASS') { AddSetting -Id 'input_protocol' -Label 'Input protocol' -Value 'OMT (Medium) or full NDI' -Why ('The wired link has ' + (SRV_F $hrRatio 1) + ' x the bandwidth the feeds need.') }
            elseif ($hrStatus -eq 'WARN') { AddSetting -Id 'input_protocol' -Label 'Input protocol' -Value 'NDI HX3 or OMT Low' -Why ('The wired link only has ' + (SRV_F $hrRatio 1) + ' x the bandwidth the feeds need; use a lighter protocol.') }
            elseif ($hrStatus -eq 'FAIL') { AddSetting -Id 'input_protocol' -Label 'Input protocol' -Value 'fix the network first' -Why 'There is no wired link with enough capacity for the incoming feeds.' }

            # ---- lan_virtual_adapters ----
            if ($virtUp.Count -gt 0) {
                $vn = SRV_JoinNames @($virtUp | ForEach-Object { SRV_Str (SRV_Get $_ 'name') }) 6
                AddCheck -Id 'lan_virtual_adapters' -Status 'WARN' -Value ([string]$virtUp.Count + ' virtual adapter(s) up') -Limit 'none' `
                    -Detail ('NDI/OMT discovery may bind to ' + $vn + '.') `
                    -Fix 'Disable the virtual adapters for the show, or pin the adapter in NDI Access Manager / vMix.'
            }
            else {
                AddCheck -Id 'lan_virtual_adapters' -Status 'PASS' -Value 'none up' -Limit 'none' -Detail 'No virtual, VPN or Hyper-V adapters are up.'
            }

            # ---- lan_profile ----
            if ($wiredUp.Count -eq 0) { AddCheck -Id 'lan_profile' -Status 'SKIP' -Detail 'No wired adapter is up.' }
            else {
                $pub = @($wiredUp | Where-Object { (SRV_Str (SRV_Get $_ 'network_category')) -ieq 'Public' })
                $unk = @($wiredUp | Where-Object { (SRV_Str (SRV_Get $_ 'network_category')) -eq '' })
                if ($pub.Count -gt 0) {
                    AddCheck -Id 'lan_profile' -Status 'WARN' -Value 'Public' -Limit 'Private' `
                        -Detail ((SRV_Str (SRV_Get $pub[0] 'name')) + ' is on a Public network profile, so Windows Firewall blocks NDI/OMT discovery.') `
                        -Fix 'Set the wired network to Private (Settings > Network & Internet > Ethernet > Network profile type) so Windows Firewall allows NDI/OMT discovery.'
                }
                elseif ($unk.Count -eq $wiredUp.Count) {
                    AddCheck -Id 'lan_profile' -Status 'INFO' -Value 'unknown' -Limit 'Private' -Detail 'The network profile could not be read.'
                }
                else {
                    AddCheck -Id 'lan_profile' -Status 'PASS' -Value (SRV_Str (SRV_Get $wiredUp[0] 'network_category')) -Limit 'Private' -Detail 'The wired network is not on a Public profile.'
                }
            }

            # ---- lan_eee ----
            if ($wiredUp.Count -eq 0) { AddCheck -Id 'lan_eee' -Status 'SKIP' -Detail 'No wired adapter is up.' }
            else {
                $eeeOn = @($wiredUp | Where-Object { (SRV_Str (SRV_Get $_ 'eee')) -ieq 'on' })
                $eeeOff = @($wiredUp | Where-Object { (SRV_Str (SRV_Get $_ 'eee')) -ieq 'off' })
                if ($eeeOn.Count -gt 0) {
                    AddCheck -Id 'lan_eee' -Status 'WARN' -Value 'on' -Limit 'off' `
                        -Detail ('Energy-Efficient Ethernet is enabled on ' + (SRV_Str (SRV_Get $eeeOn[0] 'name')) + ' and can cause micro-drops in live video.') `
                        -Fix 'Turn off Energy-Efficient Ethernet in the adapter properties (Device Manager > adapter > Advanced).'
                }
                elseif ($eeeOff.Count -eq $wiredUp.Count) {
                    AddCheck -Id 'lan_eee' -Status 'PASS' -Value 'off' -Limit 'off' -Detail 'Energy-Efficient Ethernet is off.'
                }
                else {
                    AddCheck -Id 'lan_eee' -Status 'INFO' -Value 'unknown' -Limit 'off' -Detail 'Could not read the Energy-Efficient Ethernet setting (needs admin or adapter does not expose it).'
                }
            }
        }
    }
    catch { [void]$errs.Add('lan: ' + $_.Exception.Message) }

    # =========================================================================================
    # LAN STEP (-Lan)
    # =========================================================================================
    $lanStepIds = @('lan_sources_found', 'lan_partner_throughput', 'lan_hosts')
    try {
        if (-not $hasLan) {
            AddCheck -Id 'lan_sources_found' -Status 'SKIP' -Detail 'The local network step was not run.'
            AddCheck -Id 'lan_partner_throughput' -Status 'SKIP' -Detail 'The local network step was not run.'
            AddCheck -Id 'lan_hosts' -Status 'SKIP' -Detail 'The local network step was not run.'
            if (-not $notTested.Contains('local network')) { [void]$notTested.Add('local network') }
        }
        else {
            $lanP = if ($proto -match '^(?i)OMT') { 'OMT' } else { 'NDI' }
            $lanQ = if ($lanP -eq 'OMT') { 'NDI' } else { 'OMT' }
            $lanPl = $lanP.ToLowerInvariant()

            $expected = $inCount
            if ($null -eq $expected) { $expected = SRV_Num (SRV_Get $Config 'show', 'inputs', 'count') }
            if ($null -eq $expected) { $expected = 2 }

            if ($null -eq $perFeed) {
                $perFeed = SRV_Num (SRV_Get $Config 'show', 'inputs', 'mbps_per_feed', $proto)
                if ($null -eq $perFeed -and $proto -ne '') { $perFeed = SRV_Num (SRV_Get $Config 'show', 'inputs', 'mbps_per_feed', ($proto -replace '\s+', '-')) }
                if ($null -eq $perFeed -and $proto -match '^(?i)NDI') { $perFeed = SRV_Num (SRV_Get $Config 'show', 'inputs', 'mbps_per_feed', 'NDI') }
                if ($null -eq $perFeed) { $perFeed = SRV_Num (SRV_Get $Config 'show', 'inputs', 'mbps_per_feed', $lanP) }
            }
            if ($null -eq $intakeMbps -and $null -ne $perFeed -and $null -ne $inCount) {
                $intakeMbps = $inCount * $perFeed
                $calc['intake_mbps'] = $intakeMbps
            }

            # ---- Sources classification ----
            $allSources = SRV_Arr (SRV_Get $Lan 'sources')
            $countedSources = New-Object System.Collections.ArrayList
            $qSources = New-Object System.Collections.ArrayList
            $localSources = New-Object System.Collections.ArrayList

            foreach ($src in $allSources) {
                $sProto = (SRV_Str (SRV_Get $src 'protocol')).ToUpperInvariant()
                $sLocal = (SRV_Bool (SRV_Get $src 'local')) -eq $true

                if ($sLocal) {
                    [void]$localSources.Add($src)
                }
                elseif ($sProto -eq $lanP) {
                    [void]$countedSources.Add($src)
                }
                elseif ($sProto -eq $lanQ) {
                    [void]$qSources.Add($src)
                }
            }

            $counted = $countedSources.Count
            $nQ = $qSources.Count

            $formatSrcItem = {
                param($s)
                $nm = SRV_Str (SRV_Get $s 'name')
                $ip = SRV_Str (SRV_Get $s 'ip')
                $port = SRV_Str (SRV_Get $s 'port')
                if ($ip -ne '' -and $port -ne '') { return ($nm + ' (' + $ip + ':' + $port + ')') }
                if ($ip -ne '') { return ($nm + ' (' + $ip + ')') }
                return $nm
            }

            $countedList = SRV_JoinNames @($countedSources | ForEach-Object { & $formatSrcItem $_ }) 6
            $qList = SRV_JoinNames @($qSources | ForEach-Object { & $formatSrcItem $_ }) 6

            $extras = ''
            if ($nQ -gt 0) {
                $extras = $extras + ' Also on the network: ' + $nQ + ' ' + $lanQ + ' source(s).'
            }
            if ($localSources.Count -gt 0) {
                $localNames = SRV_JoinNames @($localSources | ForEach-Object { SRV_Str (SRV_Get $_ 'name') }) 6
                $extras = $extras + ' On this PC (not counted): ' + $localNames + '.'
            }

            # ---- lan_sources_found ----
            $mdnsOk = SRV_Bool (SRV_Get $Lan 'mdns', 'query_ok')
            $limSources = '>= ' + (SRV_T $expected) + ' ' + $lanP + ' sources'
            $reqSourcesVal = SRV_Get $Config 'lan', 'require_sources'
            $reqSources = ($null -ne $reqSourcesVal) -and ($reqSourcesVal -is [bool]) -and ($reqSourcesVal -eq $true)

            if ($mdnsOk -ne $true) {
                # Case 2: mdns.query_ok != true
                $mErr = $null
                foreach ($meth in (SRV_Arr (SRV_Get $Lan 'mdns', 'methods'))) {
                    $e = SRV_Str (SRV_Get $meth 'error')
                    if ($e -ne '') { $mErr = $e; break }
                }
                if ($null -eq $mErr -or $mErr -eq '') {
                    $lErrs = SRV_Arr (SRV_Get $Lan 'errors')
                    if ($lErrs.Count -gt 0) { $mErr = SRV_Str $lErrs[0] }
                }
                if ($null -eq $mErr -or $mErr -eq '') { $mErr = 'mDNS query failed' }

                AddCheck -Id 'lan_sources_found' -Status 'SKIP' -Detail ('Could not query the network for NDI/OMT sources: ' + $mErr + '.')
                if ($reqSources) {
                    if (-not $notTested.Contains('NDI/OMT discovery')) { [void]$notTested.Add('NDI/OMT discovery') }
                }
            }
            elseif ($counted -ge $expected) {
                # Case 3: counted >= expected
                $val = ([string]$counted + ' ' + $lanP + ' sources')
                $det = 'Found: ' + $countedList + '.' + $extras
                AddCheck -Id 'lan_sources_found' -Status 'PASS' -Value $val -Limit $limSources -Margin (SRV_Margin $counted $expected) -Detail $det
            }
            elseif ($counted -ge 1) {
                # Case 4: 1 <= counted < expected
                $val = ([string]$counted + ' ' + $lanP + ' source(s)')
                $det = 'Found only: ' + $countedList + '. The show needs ' + (SRV_T $expected) + ' incoming ' + $lanP + ' feeds.' + $extras

                if ($reqSources) {
                    $cidr = SRV_Str (SRV_Get $Lan 'sweep', 'cidr')
                    if ($cidr -eq '') {
                        $aIp = SRV_Str (SRV_Get $Lan 'adapter', 'ipv4')
                        $aPfx = SRV_Str (SRV_Get $Lan 'adapter', 'prefix_length')
                        if ($aIp -ne '' -and $aPfx -ne '') { $cidr = $aIp + '/' + $aPfx }
                        elseif ($aIp -ne '') { $cidr = $aIp }
                        else { $cidr = 'local subnet' }
                    }

                    $fix = 'Start the missing sender(s) on the source PCs and make sure they are on the same switch and subnet as this PC (' + $cidr + '). A source on another subnet or VLAN is not found by mDNS; add it by IP in vMix/OBS.'
                    AddCheck -Id 'lan_sources_found' -Status 'WARN' -Value $val -Limit $limSources -Margin (SRV_Margin $counted $expected) -Detail $det -Fix $fix
                }
                else {
                    $detNotReq = $det + ' This check does not count yet (lan.require_sources is false in config.json).'
                    AddCheck -Id 'lan_sources_found' -Status 'INFO' -Value $val -Limit $limSources -Margin $null -Detail $detNotReq -Fix ''
                }
            }
            elseif ($nQ -gt 0) {
                # Case 5: counted = 0 and m non-local Q sources > 0
                $val = '0 ' + $lanP + ', ' + $nQ + ' ' + $lanQ
                $det = 'No ' + $lanP + ' sources answered, but ' + $nQ + ' ' + $lanQ + ' source(s) did: ' + $qList + '. config.json expects ' + $lanP + '.'
                if ($reqSources) {
                    $fix = 'Switch the senders to ' + $lanP + ', or set show.inputs.protocol to "' + $lanQ + '" in config.json if the show runs on ' + $lanQ + '.'
                    AddCheck -Id 'lan_sources_found' -Status 'WARN' -Value $val -Limit $limSources -Margin 0 -Detail $det -Fix $fix
                }
                else {
                    $detNotReq = $det + ' This check does not count yet (lan.require_sources is false in config.json).'
                    AddCheck -Id 'lan_sources_found' -Status 'INFO' -Value $val -Limit $limSources -Margin $null -Detail $detNotReq -Fix ''
                }
            }
            else {
                # Check discovery_servers.<p>
                $dservers = SRV_Arr (SRV_Get $Lan 'discovery_servers', $lanPl)
                if ($dservers.Count -gt 0) {
                    # Case 6: counted = 0 and discovery_servers.<p> is not empty
                    $srvList = ($dservers | ForEach-Object { SRV_Str $_ } | Where-Object { $_ -ne '' }) -join ', '
                    $val = '0 ' + $lanP + ' sources (mDNS)'
                    $det = 'No ' + $lanP + ' sources answered mDNS. This PC is set to use a ' + $lanP + ' Discovery Server (' + $srvList + '); senders registered there do not answer mDNS.'
                    if ($reqSources) {
                        $fix = 'Confirm both feeds in vMix/OBS (they use the Discovery Server) and check that the Discovery Server is running and reachable.'
                        AddCheck -Id 'lan_sources_found' -Status 'WARN' -Value $val -Limit $limSources -Margin 0 -Detail $det -Fix $fix
                    }
                    else {
                        $detNotReq = $det + ' This check does not count yet (lan.require_sources is false in config.json).'
                        AddCheck -Id 'lan_sources_found' -Status 'INFO' -Value $val -Limit $limSources -Margin $null -Detail $detNotReq -Fix ''
                    }
                }
                else {
                    # Case 7: otherwise
                    $adName = SRV_Str (SRV_Get $Lan 'adapter', 'name')
                    if ($adName -eq '') { $adName = 'the network adapter' }
                    $lms = SRV_Num (SRV_Get $Lan 'mdns', 'listen_ms')
                    $secStr = if ($null -ne $lms) { SRV_T ($lms / 1000) } else { '3' }

                    $localIps = SRV_Arr (SRV_Get $Lan 'adapter', 'local_ips')
                    $responders = SRV_Arr (SRV_Get $Lan 'mdns', 'responders')
                    $k = 0
                    foreach ($r in $responders) {
                        $rip = SRV_Str $r
                        if ($rip -eq '') { continue }
                        $isLoc = $false
                        foreach ($lip in $localIps) {
                            if ((SRV_Str $lip) -ieq $rip) { $isLoc = $true; break }
                        }
                        if (-not $isLoc) { $k++ }
                    }

                    $detEnd = ''
                    if ($k -gt 0) {
                        $detEnd = ' ' + $k + ' other device(s) answered mDNS, so discovery itself works.'
                    }
                    else {
                        $detEnd = ' No device answered mDNS at all: the switch or Wi-Fi may block multicast, or Windows Firewall blocks it on a Public network.'
                    }

                    $val = '0 ' + $lanP + ' sources'
                    if ($reqSources) {
                        $det = 'No ' + $lanP + ' source answered an mDNS query (_' + $lanPl + '._tcp.local) on ' + $adName + ' within ' + $secStr + ' s.' + $detEnd
                        $fix = 'Start ' + $lanP + ' output on both source PCs, connect them to the same switch and subnet as this PC, and set every PC''s network profile to Private. Sources registered only with an NDI Discovery Server (TCP 5959) or OMT Discovery Server (TCP 6399) do not show up here.'
                        AddCheck -Id 'lan_sources_found' -Status 'FAIL' -Value $val -Limit $limSources -Margin 0 -Detail $det -Fix $fix
                    }
                    else {
                        $det = 'No ' + $lanP + ' senders yet, which is expected until NDI/OMT is installed on the source PCs.' + $detEnd + ' Once the senders are installed, run this again; set lan.require_sources to true in config.json to make this check count.'
                        AddCheck -Id 'lan_sources_found' -Status 'INFO' -Value $val -Limit $limSources -Margin $null -Detail $det -Fix ''
                    }
                }
            }

            # ---- lan_partner_throughput ----
            $partners = SRV_Arr (SRV_Get $Lan 'partners')
            $passRatio = SRV_Th $Thr 'lan_partner_ratio', 'pass'
            $warnRatio = SRV_Th $Thr 'lan_partner_ratio', 'warn'
            $passLoss = SRV_Th $Thr 'lan_partner_udp_loss_pct', 'pass'
            $warnLoss = SRV_Th $Thr 'lan_partner_udp_loss_pct', 'warn'

            $need = $null
            if ($null -ne $perFeed -and $null -ne $passRatio) { $need = $perFeed * $passRatio }
            $limitThroughput = '>= ' + (SRV_Mbps $need) + ' Mbps, < ' + (SRV_T $passLoss) + ' % UDP loss'

            if ($partners.Count -eq 0) {
                # Case 2: no partners -> SKIP (NOT added to not_tested)
                $det = 'Optional test, not run. To measure the source PCs: run Run-Observer.cmd on each, then run here: Run-ShowReady.cmd -LanHosts <IP 1>,<IP 2>.'
                AddCheck -Id 'lan_partner_throughput' -Status 'SKIP' -Detail $det
            }
            else {
                $measuredPartners = New-Object System.Collections.ArrayList
                $unmeasuredPartners = New-Object System.Collections.ArrayList

                foreach ($pt in $partners) {
                    $ptErr = SRV_Str (SRV_Get $pt 'error')
                    $ptTcp = SRV_Num (SRV_Get $pt 'tcp', 'mbps')
                    $ptHost = SRV_Str (SRV_Get $pt 'host')
                    if ($ptHost -eq '') { $ptHost = SRV_Str (SRV_Get $pt 'ip') }

                    if ($ptErr -ne '' -or $null -eq $ptTcp) {
                        $eMsg = $ptErr
                        if ($eMsg -eq '') { $eMsg = SRV_Str (SRV_Get $pt 'tcp', 'error') }
                        if ($eMsg -eq '') { $eMsg = 'TCP throughput not measured' }
                        [void]$unmeasuredPartners.Add([pscustomobject]@{
                            partner = $pt
                            host    = $ptHost
                            error   = $eMsg
                        })
                    }
                    else {
                        $ptLoss = SRV_Num (SRV_Get $pt 'udp', 'loss_pct')
                        $ratio = 0.0
                        if ($null -ne $perFeed -and $perFeed -gt 0) { $ratio = $ptTcp / $perFeed }

                        $grade = 'FAIL'
                        if ($ratio -ge $passRatio -and ($null -ne $ptLoss) -and ($ptLoss -lt $passLoss)) {
                            $grade = 'PASS'
                        }
                        elseif ($ratio -ge $warnRatio -and (($null -eq $ptLoss) -or ($ptLoss -lt $warnLoss))) {
                            $grade = 'WARN'
                        }

                        $margin = SRV_Margin $ratio $passRatio
                        [void]$measuredPartners.Add([pscustomobject]@{
                            partner = $pt
                            host    = $ptHost
                            tcp     = $ptTcp
                            loss    = $ptLoss
                            ratio   = $ratio
                            grade   = $grade
                            margin  = $margin
                        })
                    }
                }

                if ($measuredPartners.Count -eq 0) {
                    # Case 3: all partners unmeasured -> WARN
                    $detParts = New-Object System.Collections.ArrayList
                    $hostList = New-Object System.Collections.ArrayList
                    foreach ($u in $unmeasuredPartners) {
                        [void]$detParts.Add(('Could not test ' + $u.host + ': ' + $u.error + '.'))
                        [void]$hostList.Add($u.host)
                    }
                    $det = $detParts.ToArray() -join ' '
                    $fix = 'Make sure Run-Observer.cmd (or Run-LanPartner.cmd) is still waiting on ' + ($hostList.ToArray() -join ', ') + ' and that Windows Firewall on that PC allowed iperf3 on Private networks, then run again.'
                    AddCheck -Id 'lan_partner_throughput' -Status 'WARN' -Value 'not measured' -Limit $limitThroughput -Margin $null -Detail $det -Fix $fix
                }
                else {
                    # Case 4: at least one measured partner
                    $hasFail = @($measuredPartners | Where-Object { $_.grade -eq 'FAIL' }).Count -gt 0
                    $hasWarn = @($measuredPartners | Where-Object { $_.grade -eq 'WARN' }).Count -gt 0

                    $st = 'PASS'
                    if ($hasFail) { $st = 'FAIL' }
                    elseif ($hasWarn) { $st = 'WARN' }

                    # Both at once (C = lan.combined; ignored when missing or null)
                    $cObj = SRV_Get $Lan 'combined'
                    $hasCombined = ($null -ne $cObj)
                    $cMeasured = $false
                    $cGrade = $null
                    $cMargin = $null
                    $cratio = $null
                    $cper = $null
                    $nCHosts = 0
                    $cTcp = $null
                    $cUdpMbps = $null
                    $cLoss = $null
                    $cErr = ''

                    if ($hasCombined) {
                        $cHosts = SRV_Arr (SRV_Get $cObj 'hosts')
                        $nCHosts = $cHosts.Count
                        $cTcp = SRV_Num (SRV_Get $cObj 'tcp', 'mbps')
                        $cUdpMbps = SRV_Num (SRV_Get $cObj 'udp', 'mbps')
                        $cLoss = SRV_Num (SRV_Get $cObj 'udp', 'loss_pct')
                        $cErr = SRV_Str (SRV_Get $cObj 'error')
                        if ($cErr -eq '') { $cErr = SRV_Str (SRV_Get $cObj 'tcp', 'error') }
                        if ($cErr -eq '') { $cErr = 'could not measure throughput' }

                        $cMeasured = ($null -ne $cTcp)
                        if ($cMeasured) {
                            $cper = $nCHosts * $perFeed
                            $cratio = if ($null -ne $cper -and $cper -gt 0) { $cTcp / $cper } else { 0.0 }
                            $cGrade = 'FAIL'
                            if ($cratio -ge $passRatio -and ($null -ne $cLoss) -and ($cLoss -lt $passLoss)) {
                                $cGrade = 'PASS'
                            }
                            elseif ($cratio -ge $warnRatio -and (($null -eq $cLoss) -or ($cLoss -lt $warnLoss))) {
                                $cGrade = 'WARN'
                            }
                            $cMargin = SRV_Margin $cratio $passRatio

                            if ($cGrade -eq 'FAIL') { $st = 'FAIL' }
                            elseif ($cGrade -eq 'WARN' -and $st -ne 'FAIL') { $st = 'WARN' }
                        }
                        else {
                            if ($st -eq 'PASS') { $st = 'WARN' }
                        }
                    }

                    if ($unmeasuredPartners.Count -gt 0 -and $st -eq 'PASS') {
                        $st = 'WARN'
                    }

                    $gradeOrder = @{ 'FAIL' = 0; 'WARN' = 1; 'PASS' = 2 }
                    $sortedMeasured = @($measuredPartners.ToArray() | Sort-Object -Property @{
                        Expression = { $gradeOrder[$_.grade] }
                    }, @{
                        Expression = { if ($null -eq $_.margin) { 0 } else { $_.margin } }
                    }, @{
                        Expression = { if ($null -eq $_.loss) { 9999 } else { -$_.loss } }
                    })
                    $worstMeasured = $sortedMeasured[0]

                    # Margin = min of the partner margins and SRV_Margin(cratio, pass)
                    $minMargin = $null
                    foreach ($m in $measuredPartners) {
                        if ($null -eq $minMargin -or $m.margin -lt $minMargin) { $minMargin = $m.margin }
                    }
                    if ($hasCombined -and $cMeasured -and ($null -ne $cMargin)) {
                        if ($null -eq $minMargin -or $cMargin -lt $minMargin) {
                            $minMargin = $cMargin
                        }
                    }

                    # Determine if C's grade is strictly worse than every measured partner's grade
                    $cStrictlyWorse = $false
                    if ($hasCombined -and $cMeasured) {
                        $gradeScore = @{ 'PASS' = 0; 'WARN' = 1; 'FAIL' = 2 }
                        $cScore = $gradeScore[$cGrade]
                        $maxPartnerScore = -1
                        foreach ($m in $measuredPartners) {
                            $pScore = $gradeScore[$m.grade]
                            if ($pScore -gt $maxPartnerScore) { $maxPartnerScore = $pScore }
                        }
                        if ($cScore -gt $maxPartnerScore) {
                            $cStrictlyWorse = $true
                        }
                    }

                    $val = ''
                    $fix = ''
                    if ($cStrictlyWorse) {
                        if ($null -ne $cLoss) {
                            $val = (SRV_Mbps $cTcp) + ' Mbps TCP together, ' + (SRV_F $cLoss 2) + ' % UDP loss'
                        }
                        else {
                            $val = (SRV_Mbps $cTcp) + ' Mbps TCP together, UDP not measured'
                        }
                        $fix = 'Each source PC passes on its own but not together, so the link into this PC (or the switch uplink) is the bottleneck. Use a 2.5 GbE link to this PC, or lighter feeds (NDI HX3 / OMT Low).'
                    }
                    else {
                        if ($null -ne $worstMeasured.loss) {
                            $val = (SRV_Mbps $worstMeasured.tcp) + ' Mbps TCP, ' + (SRV_F $worstMeasured.loss 2) + ' % UDP loss'
                        }
                        else {
                            $val = (SRV_Mbps $worstMeasured.tcp) + ' Mbps TCP, UDP not measured'
                        }

                        if ($st -eq 'WARN' -or $st -eq 'FAIL') {
                            if ((SRV_Bool (SRV_Get $worstMeasured.partner 'loopback')) -eq $true) {
                                $fix = 'That was a loopback test (this PC to itself): it measures this PC, not the network. Run Run-Observer.cmd on each source PC, then run here: Run-ShowReady.cmd -LanHosts <IP 1>,<IP 2>.'
                            }
                            else {
                                $fix = 'Check the cable, switch port and link speed between this PC and ' + $worstMeasured.host + '; avoid chained or unmanaged desktop switches; turn off Energy-Efficient Ethernet on both PCs. If it stays low, use NDI HX3 / OMT Low for that feed.'
                            }
                        }
                    }

                    $testTarget = SRV_Num (SRV_Get $Lan 'test', 'target_mbps')
                    $testSec = SRV_Num (SRV_Get $Lan 'test', 'seconds')
                    if ($null -eq $testTarget) {
                        $testMult = SRV_Num (SRV_Get $Config 'lan', 'test_multiplier')
                        if ($null -eq $testMult) { $testMult = 2 }
                        if ($null -ne $perFeed) { $testTarget = $perFeed * $testMult } else { $testTarget = 400 }
                    }
                    if ($null -eq $testSec) {
                        $testSec = SRV_Num (SRV_Get $Config 'lan', 'test_seconds')
                        if ($null -eq $testSec) { $testSec = 10 }
                    }

                    $det = 'Per feed ' + (SRV_Mbps $perFeed) + ' Mbps (' + $lanP + '), tested at ' + (SRV_Mbps $testTarget) + ' Mbps for ' + (SRV_T $testSec) + ' s, source PC to this PC.'

                    foreach ($pt in $partners) {
                        $mObj = $null
                        foreach ($m in $measuredPartners) { if ($m.partner -eq $pt) { $mObj = $m; break } }

                        if ($null -ne $mObj) {
                            $retrans = SRV_Num (SRV_Get $pt 'tcp', 'retransmits')
                            $retStr = ''
                            if ($null -ne $retrans) { $retStr = ', ' + (SRV_F $retrans 0) + ' retransmits' }
                            $udpM = SRV_Num (SRV_Get $pt 'udp', 'mbps')
                            $udpL = SRV_Num (SRV_Get $pt 'udp', 'loss_pct')
                            $udpJ = SRV_Num (SRV_Get $pt 'udp', 'jitter_ms')
                            $isLoop = (SRV_Bool (SRV_Get $pt 'loopback')) -eq $true

                            $udpPart = ''
                            if ($null -ne $udpL -and $null -ne $udpM) {
                                $udpPart = '; UDP ' + (SRV_Mbps $udpM) + ' Mbps received, ' + (SRV_F $udpL 2) + ' % loss'
                                if ($null -ne $udpJ) { $udpPart = $udpPart + ', jitter ' + (SRV_F $udpJ 2) + ' ms' }
                                $udpPart = $udpPart + '.'
                            }
                            else {
                                $udpPart = '; UDP not measured.'
                            }

                            $pDet = ' ' + $mObj.host + ': TCP ' + (SRV_Mbps $mObj.tcp) + ' Mbps' + $retStr + $udpPart
                            if ($isLoop) {
                                $pDet = $pDet + ' (loopback: measures this PC only, not the network)'
                            }
                            $det = $det + $pDet
                        }
                        else {
                            $uObj = $null
                            foreach ($u in $unmeasuredPartners) { if ($u.partner -eq $pt) { $uObj = $u; break } }
                            if ($null -ne $uObj) {
                                $det = $det + ' Could not test ' + $uObj.host + ': ' + $uObj.error + '.'
                            }
                        }
                    }

                    if ($hasCombined) {
                        if ($cMeasured) {
                            $cNeed = $cper * $passRatio
                            $udpCStr = ''
                            if ($null -ne $cLoss) {
                                $udpCStr = ', UDP ' + (SRV_Mbps $cUdpMbps) + ' Mbps received, ' + (SRV_F $cLoss 2) + ' % loss'
                            }
                            else {
                                $udpCStr = ', UDP not measured'
                            }
                            $det = $det + ' Both at once (' + $nCHosts + ' source PCs): TCP ' + (SRV_Mbps $cTcp) + ' Mbps' + $udpCStr + '; needs >= ' + (SRV_Mbps $cNeed) + ' Mbps together.'
                        }
                        else {
                            $det = $det + ' Could not test both at once: ' + $cErr + '.'
                        }
                    }

                    AddCheck -Id 'lan_partner_throughput' -Status $st -Value $val -Limit $limitThroughput -Margin $minMargin -Detail $det -Fix $fix
                }
            }

            # ---- lan_hosts ----
            $sweep = SRV_Get $Lan 'sweep'
            $skipReason = SRV_Str (SRV_Get $sweep 'skipped_reason')

            if ($null -eq $sweep -or $skipReason -ne '') {
                # Case 2: sweep missing or sweep.skipped_reason set -> SKIP
                if ($skipReason -eq '') { $skipReason = 'sweep was not run' }
                AddCheck -Id 'lan_hosts' -Status 'SKIP' -Detail ('Not scanned: ' + $skipReason + '.')
            }
            else {
                # Case 3: INFO
                $alive = SRV_Num (SRV_Get $sweep 'alive')
                $cidr = SRV_Str (SRV_Get $sweep 'cidr')
                $valHosts = ([string](SRV_Num $alive)) + ' devices on ' + $cidr

                $hosts = SRV_Arr (SRV_Get $Lan 'hosts')

                # Part 1: Gateway
                $p1 = ''
                $gwHost = $null
                foreach ($h in $hosts) {
                    if ((SRV_Bool (SRV_Get $h 'is_gateway')) -eq $true) { $gwHost = $h; break }
                }
                if ($null -eq $gwHost) {
                    $gwIpVal = SRV_Str (SRV_Get $Lan 'adapter', 'gateway')
                    if ($gwIpVal -ne '') {
                        foreach ($h in $hosts) {
                            if ((SRV_Str (SRV_Get $h 'ip')) -ieq $gwIpVal) { $gwHost = $h; break }
                        }
                    }
                }
                if ($null -ne $gwHost) {
                    $gwIp = SRV_Str (SRV_Get $gwHost 'ip')
                    $gwV = SRV_Str (SRV_Get $gwHost 'vendor')
                    if ($gwV -eq '') { $gwV = 'unknown vendor' }
                    $p1 = 'Gateway: ' + $gwIp + ' (' + $gwV + ').'
                }

                # Part 2: Network gear (excluding gateway)
                $p2 = ''
                $netItems = New-Object System.Collections.ArrayList
                foreach ($h in $hosts) {
                    if ($h -eq $gwHost) { continue }
                    if ((SRV_Bool (SRV_Get $h 'is_gateway')) -eq $true) { continue }
                    if ((SRV_Str (SRV_Get $h 'category')).ToLowerInvariant() -eq 'network') {
                        $v = SRV_Str (SRV_Get $h 'vendor')
                        if ($v -eq '') { $v = 'unknown' }
                        $ip = SRV_Str (SRV_Get $h 'ip')
                        [void]$netItems.Add(($v + ' (' + $ip + ')'))
                    }
                }
                if ($netItems.Count -gt 0) {
                    $p2 = 'Network gear: ' + ($netItems.ToArray() -join ', ') + '.'
                }

                # Part 3: PCs
                $p3 = ''
                $pcCount = 0
                $pcVendors = New-Object System.Collections.ArrayList
                foreach ($h in $hosts) {
                    if ((SRV_Bool (SRV_Get $h 'is_self')) -eq $true) { continue }
                    if ((SRV_Str (SRV_Get $h 'category')).ToLowerInvariant() -eq 'pc') {
                        $pcCount++
                        $v = SRV_Str (SRV_Get $h 'vendor')
                        if ($v -ne '' -and -not $pcVendors.Contains($v)) { [void]$pcVendors.Add($v) }
                    }
                }
                if ($pcCount -gt 0) {
                    $vStr = ($pcVendors.ToArray() -join ', ')
                    if ($vStr -eq '') { $vStr = 'unknown' }
                    $p3 = 'PCs: ' + $pcCount + ' (' + $vStr + ').'
                }

                # Part 4: Broadcast gear
                $p4 = ''
                $bcastItems = New-Object System.Collections.ArrayList
                foreach ($h in $hosts) {
                    if ((SRV_Str (SRV_Get $h 'category')).ToLowerInvariant() -eq 'broadcast') {
                        $v = SRV_Str (SRV_Get $h 'vendor')
                        if ($v -eq '') { $v = 'unknown' }
                        $ip = SRV_Str (SRV_Get $h 'ip')
                        [void]$bcastItems.Add(($v + ' (' + $ip + ')'))
                    }
                }
                if ($bcastItems.Count -gt 0) {
                    $p4 = 'Broadcast gear: ' + ($bcastItems.ToArray() -join ', ') + '.'
                }

                # Part 5: Source PCs
                $p5 = ''
                $srcItems = New-Object System.Collections.ArrayList
                foreach ($h in $hosts) {
                    $sc = (SRV_Arr (SRV_Get $h 'sources')).Count
                    if ($sc -gt 0) {
                        $ip = SRV_Str (SRV_Get $h 'ip')
                        [void]$srcItems.Add(($ip + ' (' + $sc + ' source(s))'))
                    }
                }
                if ($srcItems.Count -gt 0) {
                    $p5 = 'Source PCs: ' + ($srcItems.ToArray() -join ', ') + '.'
                }

                # Part 6: Unknown vendor
                $p6 = ''
                $unkCount = 0
                $randCount = 0
                foreach ($h in $hosts) {
                    if ((SRV_Bool (SRV_Get $h 'is_self')) -eq $true) { continue }
                    $v = SRV_Str (SRV_Get $h 'vendor')
                    if ($v -eq '') {
                        $unkCount++
                        if ((SRV_Bool (SRV_Get $h 'randomized_mac')) -eq $true) { $randCount++ }
                    }
                }
                if ($unkCount -gt 0) {
                    $p6 = 'Unknown vendor: ' + $unkCount + ' (' + $randCount + ' with a private/randomised MAC).'
                }

                # Part 7: Non-wired adapter note
                $p7 = ''
                $adKind = (SRV_Str (SRV_Get $Lan 'adapter', 'kind')).ToLowerInvariant()
                $adName = SRV_Str (SRV_Get $Lan 'adapter', 'name')
                if ($adKind -ne '' -and $adKind -ne 'wired') {
                    $p7 = 'Scanned the ' + $adKind + ' adapter ' + $adName + ' because no wired adapter is up; on show day run this on the production network.'
                }

                # Part 8: Always last
                $p8 = 'Managed switches only appear if they have a management IP on this subnet.'

                $detailParts = New-Object System.Collections.ArrayList
                foreach ($pt in @($p1, $p2, $p3, $p4, $p5, $p6, $p7, $p8)) {
                    if ($pt -ne '') { [void]$detailParts.Add($pt) }
                }
                $detHosts = $detailParts.ToArray() -join ' '

                AddCheck -Id 'lan_hosts' -Status 'INFO' -Value $valHosts -Limit '' -Margin $null -Detail $detHosts
            }
        }
    }
    catch { [void]$errs.Add('lan_step: ' + $_.Exception.Message) }

    # =========================================================================================
    # HARDWARE
    # =========================================================================================
    $hwIds = @('hw_cpu_threads', 'hw_ram', 'hw_gpu', 'hw_nvenc_sessions', 'hw_power', 'hw_gpu_driver_age', 'hw_disk', 'hw_pending_reboot')
    $dedicated = @()
    if (-not $hasHw) {
        SkipIds $hwIds 'Hardware scan was not run.'
        [void]$notTested.Add('hardware')
    }
    else {
        # ---- hw_cpu_threads ----
        try {
            $threads = SRV_Num (SRV_Get $Hardware 'cpu', 'threads')
            $cpuName = SRV_Str (SRV_Get $Hardware 'cpu', 'name')
            if ($null -eq $threads) { AddCheck -Id 'hw_cpu_threads' -Status 'SKIP' -Detail 'CPU thread count unavailable.' }
            else {
                $pass = SRV_Th $Thr 'threads', 'pass'
                $warn = SRV_Th $Thr 'threads', 'warn'
                $st = SRV_GradeHigh $threads $pass $warn
                $det = $cpuName
                if ($cpuName -cmatch '\d{4,5}(U|P|Y)\b' -or $cpuName -match 'Celeron|Pentium|Atom') {
                    if ($det -ne '') { $det = $det + ' - ' }
                    $det = $det + 'low-power laptop CPU'
                }
                $cores = SRV_Num (SRV_Get $Hardware 'cpu', 'cores')
                if ($null -ne $cores) { $det = $det + ' (' + (SRV_F $cores 0) + ' cores)' }
                $fix = ''
                if ($st -eq 'WARN' -or $st -eq 'FAIL') { $fix = 'Use a desktop/workstation CPU with at least ' + (SRV_T $pass) + ' threads for 2 decodes + 3 encodes plus vMix/OBS.' }
                AddCheck -Id 'hw_cpu_threads' -Status $st -Value ((SRV_F $threads 0) + ' threads') -Limit ($(if ($null -ne $pass) { '>= ' + (SRV_T $pass) + ' threads' } else { '' })) -Margin (SRV_Margin $threads $pass) -Detail $det -Fix $fix
            }
        }
        catch { [void]$errs.Add('hw_cpu_threads: ' + $_.Exception.Message) }

        # ---- hw_ram ----
        try {
            $ram = SRV_Num (SRV_Get $Hardware 'ram_gb')
            if ($null -eq $ram) { AddCheck -Id 'hw_ram' -Status 'SKIP' -Detail 'RAM size unavailable.' }
            else {
                $pass = SRV_Th $Thr 'ram_gb', 'pass'
                $warn = SRV_Th $Thr 'ram_gb', 'warn'
                $pT = $null
                $wT = $null
                if ($null -ne $pass) { $pT = $pass * $RAM_TOLERANCE }
                if ($null -ne $warn) { $wT = $warn * $RAM_TOLERANCE }
                $st = SRV_GradeHigh $ram $pT $wT
                $fix = ''
                if ($st -eq 'WARN' -or $st -eq 'FAIL') { $fix = 'Install at least ' + (SRV_T $pass) + ' GB of RAM (64 GB is comfortable for vMix with 2 feeds).' }
                AddCheck -Id 'hw_ram' -Status $st -Value ((SRV_F $ram 1) + ' GB') -Limit ($(if ($null -ne $pass) { '>= ' + (SRV_T $pass) + ' GB' } else { '' })) -Margin (SRV_Margin $ram $pT) `
                    -Detail ('Installed RAM reads a few percent below its nominal size, so ' + (SRV_T $pass) + ' GB is matched from ' + (SRV_F $pT 1) + ' GB.') -Fix $fix
            }
        }
        catch { [void]$errs.Add('hw_ram: ' + $_.Exception.Message) }

        # ---- hw_gpu ----
        try {
            $gpusRaw = SRV_Get $Hardware 'gpus'
            $vmixV = SRV_Str (SRV_Get $Hardware 'software', 'vmix')
            $obsV = SRV_Str (SRV_Get $Hardware 'software', 'obs')
            if ($null -eq $gpusRaw) { AddCheck -Id 'hw_gpu' -Status 'SKIP' -Detail 'GPU list unavailable.' }
            else {
                $gpus = SRV_Arr $gpusRaw
                $dedicated = @($gpus | Where-Object { SRV_IsDedicated $_ })
                if ($dedicated.Count -gt 0) {
                    $names = SRV_JoinNames @($dedicated | ForEach-Object {
                            $vr = SRV_Num (SRV_Get $_ 'vram_gb')
                            $nm = SRV_Str (SRV_Get $_ 'name')
                            if ($null -ne $vr -and $vr -gt 0) { $nm + ' (' + (SRV_T $vr) + ' GB)' } else { $nm }
                        }) 4
                    AddCheck -Id 'hw_gpu' -Status 'PASS' -Value $names -Limit 'dedicated NVIDIA/AMD GPU' -Detail 'A dedicated GPU provides the hardware video encoders for the three outputs.'
                }
                else {
                    $gn = SRV_JoinNames @($gpus | ForEach-Object { SRV_Str (SRV_Get $_ 'name') }) 4
                    $det = 'no dedicated GPU - vMix at 1080p60 with 3 encodes is not supported on integrated graphics.'
                    if ($gn -ne '') { $det = 'Found: ' + $gn + '; ' + $det }
                    $vmixSet = ($vmixV -ne '')
                    $obsSet = ($obsV -ne '')
                    if ($obsSet -and -not $vmixSet) {
                        AddCheck -Id 'hw_gpu' -Status 'WARN' -Value 'no dedicated GPU' -Limit 'dedicated NVIDIA/AMD GPU' -Detail ($det + ' OBS alone may cope at lower settings, but expect dropped frames.') `
                            -Fix 'Use a PC with an NVIDIA RTX or AMD Radeon GPU for the show.'
                    }
                    else {
                        $extra = ''
                        if (-not $vmixSet -and -not $obsSet) { $extra = ' Neither vMix nor OBS was detected.' }
                        AddCheck -Id 'hw_gpu' -Status 'FAIL' -Value 'no dedicated GPU' -Limit 'dedicated NVIDIA/AMD GPU' -Margin 0 -Detail ($det + $extra) `
                            -Fix 'Use a PC with a dedicated NVIDIA RTX or AMD Radeon GPU for the show.'
                    }
                }
            }
        }
        catch { [void]$errs.Add('hw_gpu: ' + $_.Exception.Message) }

        # ---- hw_nvenc_sessions ----
        try {
            $gpusRaw = SRV_Get $Hardware 'gpus'
            if ($null -eq $gpusRaw) { AddCheck -Id 'hw_nvenc_sessions' -Status 'SKIP' -Detail 'GPU list unavailable.' }
            else {
                $gpus = SRV_Arr $gpusRaw
                $nv = @($gpus | Where-Object { (SRV_Str (SRV_Get $_ 'vendor')).ToUpperInvariant() -eq 'NVIDIA' })
                $nvPick = $null
                foreach ($g in $nv) { if (SRV_IsDedicated $g) { $nvPick = $g; break } }
                if ($null -eq $nvPick -and $nv.Count -gt 0) { $nvPick = $nv[0] }
                if ($null -eq $nvPick) {
                    AddCheck -Id 'hw_nvenc_sessions' -Status 'INFO' -Value 'not NVIDIA' -Detail 'No NVIDIA GPU: the NVENC session limit does not apply.'
                }
                else {
                    $drv = SRV_NvDriver $nvPick
                    $d8 = SRV_Th $Thr 'nvenc_8_session_driver'
                    $d5 = SRV_Th $Thr 'nvenc_5_session_driver'
                    $outCount = $outputs.Count
                    if ($outCount -le 0) { $outCount = 3 }
                    if ($null -eq $drv -or $null -eq $d8 -or $null -eq $d5) {
                        AddCheck -Id 'hw_nvenc_sessions' -Status 'INFO' -Value 'driver unknown' -Detail 'The NVIDIA driver version could not be read.'
                    }
                    elseif ($drv -ge $d8) {
                        AddCheck -Id 'hw_nvenc_sessions' -Status 'PASS' -Value ('8 sessions (driver ' + (SRV_F $drv 2) + ')') -Limit ('driver >= ' + (SRV_F $d8 2) + ' for 8') -Margin (SRV_Margin 8 $outCount) -Detail 'This driver allows 8 simultaneous NVENC sessions: 3 outputs plus recording or a spare.'
                    }
                    elseif ($drv -ge $d5) {
                        AddCheck -Id 'hw_nvenc_sessions' -Status 'PASS' -Value ('5 sessions (driver ' + (SRV_F $drv 2) + ')') -Limit ('driver >= ' + (SRV_F $d5 2) + ' for 5') -Margin (SRV_Margin 5 $outCount) -Detail ('This driver allows 5 simultaneous NVENC sessions; updating past ' + (SRV_F $d8 2) + ' raises it to 8.')
                    }
                    else {
                        AddCheck -Id 'hw_nvenc_sessions' -Status 'WARN' -Value ('3 sessions (driver ' + (SRV_F $drv 2) + ')') -Limit ('driver >= ' + (SRV_F $d5 2) + ' for 5') -Margin (SRV_Margin 3 $outCount) `
                            -Detail '3-session limit: exactly enough for 3 outputs, no recording.' -Fix ('Update the NVIDIA driver to ' + (SRV_F $d8 2) + ' or newer (raises the limit to 8 sessions).')
                    }
                }
            }
        }
        catch { [void]$errs.Add('hw_nvenc_sessions: ' + $_.Exception.Message) }

        # ---- hw_power ----
        try {
            $plan = (SRV_Str (SRV_Get $Hardware 'power', 'plan')).ToLowerInvariant()
            $onBat = SRV_Bool (SRV_Get $Hardware 'power', 'on_battery')
            $batPct = SRV_Num (SRV_Get $Hardware 'power', 'battery_pct')
            $planLabel = $plan
            if ($plan -eq 'high_performance') { $planLabel = 'High performance' }
            elseif ($plan -eq 'ultimate') { $planLabel = 'Ultimate performance' }
            elseif ($plan -eq 'balanced') { $planLabel = 'Balanced' }
            elseif ($plan -eq 'power_saver') { $planLabel = 'Power saver' }
            elseif ($plan -eq 'custom') { $planLabel = 'custom plan' }
            $fixPlan = 'Set the Windows power plan to High performance (Control Panel > Power Options) and set sleep to Never.'
            if ($onBat -eq $true) {
                $bt = ''
                if ($null -ne $batPct) { $bt = ' (' + (SRV_F $batPct 0) + ' % left)' }
                AddCheck -Id 'hw_power' -Status 'FAIL' -Value ('on battery' + $bt) -Limit 'on mains power' -Margin 0 -Detail ('The PC is running on battery; Windows throttles the CPU/GPU. Power plan: ' + $planLabel + '.') -Fix 'Plug in the charger (and use High performance) before the show.'
            }
            elseif ($plan -eq 'high_performance' -or $plan -eq 'ultimate') {
                AddCheck -Id 'hw_power' -Status 'PASS' -Value ($planLabel + ', mains') -Limit 'High performance or Ultimate' -Detail 'Power plan keeps the CPU at full speed.'
            }
            elseif ($plan -eq 'balanced') {
                AddCheck -Id 'hw_power' -Status 'WARN' -Value $planLabel -Limit 'High performance or Ultimate' -Detail 'The Balanced plan lets the CPU slow down under bursty load, which shows up as dropped frames.' -Fix $fixPlan
            }
            elseif ($plan -eq 'power_saver') {
                AddCheck -Id 'hw_power' -Status 'FAIL' -Value $planLabel -Limit 'High performance or Ultimate' -Margin 0 -Detail 'Power saver caps CPU speed far below what the show needs.' -Fix $fixPlan
            }
            elseif ($plan -eq 'custom') {
                AddCheck -Id 'hw_power' -Status 'INFO' -Value 'custom plan' -Limit 'High performance or Ultimate' -Detail 'A custom power plan is active; check it keeps the CPU at 100 % minimum state.' -Fix $fixPlan
            }
            else {
                AddCheck -Id 'hw_power' -Status 'INFO' -Value 'unknown' -Detail 'The power plan could not be read.'
            }
        }
        catch { [void]$errs.Add('hw_power: ' + $_.Exception.Message) }

        # ---- hw_gpu_driver_age ----
        try {
            if ($null -eq (SRV_Get $Hardware 'gpus')) { AddCheck -Id 'hw_gpu_driver_age' -Status 'SKIP' -Detail 'GPU list unavailable.' }
            elseif ($dedicated.Count -eq 0) { AddCheck -Id 'hw_gpu_driver_age' -Status 'SKIP' -Detail 'No dedicated GPU.' }
            else {
                $newest = $null
                foreach ($g in $dedicated) {
                    $ds = SRV_Str (SRV_Get $g 'driver_date')
                    $dt = [datetime]::MinValue
                    if ($ds -ne '' -and [datetime]::TryParseExact($ds, 'yyyy-MM-dd', $inv, [System.Globalization.DateTimeStyles]::None, [ref]$dt)) {
                        if ($null -eq $newest -or $dt -gt $newest) { $newest = $dt }
                    }
                }
                $warnDays = SRV_Th $Thr 'gpu_driver_age_days', 'warn'
                if ($null -eq $newest) { AddCheck -Id 'hw_gpu_driver_age' -Status 'INFO' -Value 'unknown' -Detail 'The GPU driver date could not be read.' }
                else {
                    $age = [math]::Floor(($Now.Date - $newest.Date).TotalDays)
                    $st = 'PASS'
                    if ($null -ne $warnDays -and $age -gt $warnDays) { $st = 'WARN' }
                    $fix = ''
                    if ($st -eq 'WARN') { $fix = 'Install the current GPU driver from NVIDIA/AMD at least a few days before the show, then re-run ShowReady.' }
                    AddCheck -Id 'hw_gpu_driver_age' -Status $st -Value ((SRV_F $age 0) + ' days old') -Limit ($(if ($null -ne $warnDays) { '<= ' + (SRV_T $warnDays) + ' days' } else { '' })) -Margin (SRV_Margin $warnDays $age) `
                        -Detail ('Newest dedicated GPU driver is dated ' + $newest.ToString('yyyy-MM-dd', $inv) + '.') -Fix $fix
                }
            }
        }
        catch { [void]$errs.Add('hw_gpu_driver_age: ' + $_.Exception.Message) }

        # ---- hw_disk ----
        try {
            $free = SRV_Num (SRV_Get $Hardware 'disk', 'free_gb')
            if ($null -eq $free) { AddCheck -Id 'hw_disk' -Status 'SKIP' -Detail 'Disk space unavailable.' }
            else {
                $warn = SRV_Th $Thr 'disk_free_gb', 'warn'
                $st = 'PASS'
                if ($null -ne $warn -and $free -lt $warn) { $st = 'WARN' }
                $fix = ''
                if ($st -eq 'WARN') { $fix = 'Free up space on the system drive (recordings, logs and Windows need room); keep at least ' + (SRV_T $warn) + ' GB free.' }
                $drv = SRV_Str (SRV_Get $Hardware 'disk', 'system_drive')
                AddCheck -Id 'hw_disk' -Status $st -Value ((SRV_F $free 0) + ' GB free') -Limit ($(if ($null -ne $warn) { '>= ' + (SRV_T $warn) + ' GB' } else { '' })) -Margin (SRV_Margin $free $warn) -Detail ('System drive ' + $drv + '.') -Fix $fix
            }
        }
        catch { [void]$errs.Add('hw_disk: ' + $_.Exception.Message) }

        # ---- hw_pending_reboot ----
        try {
            $pr = SRV_Bool (SRV_Get $Hardware 'windows', 'pending_reboot')
            if ($null -eq $pr) { AddCheck -Id 'hw_pending_reboot' -Status 'INFO' -Value 'unknown' -Detail 'Could not tell if a reboot is pending.' }
            elseif ($pr) { AddCheck -Id 'hw_pending_reboot' -Status 'WARN' -Value 'reboot pending' -Limit 'none' -Detail 'Windows is waiting for a restart (updates or driver install).' -Fix 'Reboot before the show, not during it.' }
            else { AddCheck -Id 'hw_pending_reboot' -Status 'PASS' -Value 'none pending' -Limit 'none' -Detail 'No restart is waiting.' }
        }
        catch { [void]$errs.Add('hw_pending_reboot: ' + $_.Exception.Message) }
    }
    AddSetting -Id 'power_plan' -Label 'Windows power plan' -Value 'High performance (or Ultimate), on mains power, sleep off' -Why 'The default Balanced plan lets the CPU clock drop under bursty live-video load.'

    # =========================================================================================
    # LOAD
    # =========================================================================================
    $loadIds = @('load_encoder', 'load_realtime', 'load_cpu', 'load_gpu_encode', 'load_throttle')
    $chosenEnc = ''
    $fellBack = $false
    $nvGpus = @($dedicated | Where-Object { (SRV_Str (SRV_Get $_ 'vendor')).ToUpperInvariant() -eq 'NVIDIA' })
    $amdGpus = @($dedicated | Where-Object { (SRV_Str (SRV_Get $_ 'vendor')).ToUpperInvariant() -eq 'AMD' })
    $ffFound = SRV_Bool (SRV_Get $LoadTest 'ffmpeg', 'found')
    if (-not $hasLoad) {
        SkipIds $loadIds 'Load test was not run.'
        [void]$notTested.Add('load test')
    }
    elseif ($ffFound -eq $false) {
        SkipIds $loadIds 'ffmpeg was not found in the bin folder, so the load test could not run.'
        [void]$notTested.Add('load test (ffmpeg missing)')
    }
    else {
        # Helper to extract error lines from a tested encoder entry
        $getEncoderLines = {
            param($enc)
            $lines = SRV_Arr (SRV_Get $enc 'error_lines')
            if ($lines.Count -gt 0) {
                $out = New-Object System.Collections.ArrayList
                foreach ($l in $lines) {
                    $s = SRV_Str $l
                    if ($s -ne '') { [void]$out.Add($s) }
                }
                if ($out.Count -gt 0) { return ,$out.ToArray() }
            }
            $e = SRV_Str (SRV_Get $enc 'error')
            if ($e -ne '') { return ,@($e) }
            return ,@()
        }

        $chosenEnc = SRV_Str (SRV_Get $LoadTest 'encoders', 'chosen')
        $tested = SRV_Arr (SRV_Get $LoadTest 'encoders', 'tested')

        $nvT = $null
        $amfT = $null
        foreach ($entry in $tested) {
            $eNm = SRV_Str (SRV_Get $entry 'name')
            if ($eNm -ieq 'h264_nvenc') { $nvT = $entry }
            elseif ($eNm -ieq 'h264_amf') { $amfT = $entry }
        }

        $nvTReq = SRV_Num (SRV_Get $nvT 'driver_required')
        $nvTLines = if ($null -ne $nvT) { & $getEncoderLines $nvT } else { @() }
        $nvHasMatch = $false
        foreach ($l in $nvTLines) {
            if ($l -match '(?i)nvenc API version|minimum required Nvidia driver') {
                $nvHasMatch = $true
                break
            }
        }
        $nvDriverIssue = ($null -ne $nvT) -and ((SRV_Bool (SRV_Get $nvT 'ok')) -ne $true) -and (($null -ne $nvTReq) -or $nvHasMatch)

        $installed = $null
        foreach ($g in $nvGpus) {
            $drv = SRV_NvDriver $g
            if ($null -ne $drv) {
                if ($null -eq $installed -or $drv -gt $installed) {
                    $installed = $drv
                }
            }
        }

        $isChosenX264OrEmpty = ($chosenEnc -match 'x264' -or $chosenEnc -eq '')
        $hasDedicated = ($nvGpus.Count + $amdGpus.Count) -gt 0
        $fellBack = $isChosenX264OrEmpty -and $hasDedicated

        $failedList = New-Object System.Collections.ArrayList
        foreach ($entry in $tested) {
            if ((SRV_Bool (SRV_Get $entry 'ok')) -ne $true) {
                $nm = SRV_Str (SRV_Get $entry 'name')
                $eLines = & $getEncoderLines $entry
                if ($eLines.Count -gt 0 -and $eLines[0] -ne '') {
                    [void]$failedList.Add($nm + ' (' + $eLines[0] + ')')
                }
                else {
                    [void]$failedList.Add($nm)
                }
            }
        }
        $failedStr = $failedList.ToArray() -join ', '

        # ---- load_encoder ----
        try {
            if ($chosenEnc -match 'nvenc|amf|qsv') {
                # Case a
                $det = 'The test encoded with ' + $chosenEnc + '.'
                if ($failedStr -ne '') {
                    $det = $det + ' Encoders that did not work: ' + $failedStr + '.'
                }
                if ($nvGpus.Count -gt 0 -and $chosenEnc -notmatch 'nvenc') {
                    $nvLine0 = if ($nvTLines.Count -gt 0) { $nvTLines[0] } else { 'check the driver' }
                    $det = $det + ' An NVIDIA GPU is present but NVENC failed: ' + $nvLine0 + '.'
                }
                AddCheck -Id 'load_encoder' -Status 'PASS' -Value $chosenEnc -Limit 'hardware encoder' -Detail $det.Trim()
            }
            elseif ($nvGpus.Count -gt 0 -and $nvDriverIssue) {
                # Case b
                $instStr = if ($null -ne $installed) { SRV_F $installed 2 } else { 'unknown' }
                $val = ''
                if ($null -ne $nvTReq) {
                    $val = 'NVIDIA driver ' + $instStr + ' is older than ' + (SRV_T $nvTReq) + ' needed by this test'
                }
                else {
                    $val = 'NVIDIA driver ' + $instStr + ' is too old for this test''s NVENC'
                }
                $nvErrLinesStr = if ($nvTLines.Count -gt 0) { $nvTLines -join ' / ' } else { 'no error text' }
                $fallbackEnc = if ($chosenEnc -ne '') { $chosenEnc } else { 'no encoder' }
                $det = 'h264_nvenc failed: ' + $nvErrLinesStr + '. The test fell back to ' + $fallbackEnc + ', so the load figures are not representative.'
                $fix = 'vMix/OBS can usually still use NVENC on this driver. To run this test, update to the current NVIDIA Studio driver, or check NVENC in vMix/OBS by hand.'
                AddCheck -Id 'load_encoder' -Status 'WARN' -Value $val -Limit 'hardware encoder' -Margin $null -Detail $det -Fix $fix
            }
            elseif ($nvGpus.Count -gt 0 -or $amdGpus.Count -gt 0) {
                # Case c
                $vend = if ($nvGpus.Count -gt 0) { 'NVIDIA' } else { 'AMD' }
                $val = $vend + ' GPU encoder failed in this test'
                $targetT = if ($nvGpus.Count -gt 0) { $nvT } else { $amfT }
                $targetName = if ($nvGpus.Count -gt 0) { 'h264_nvenc' } else { 'h264_amf' }
                $tLines = if ($null -ne $targetT) { & $getEncoderLines $targetT } else { @() }
                $tLinesStr = if ($tLines.Count -gt 0) { $tLines -join ' / ' } else { 'no error text' }
                $fallbackEnc = if ($chosenEnc -ne '') { $chosenEnc } else { 'no encoder' }
                $det = $targetName + ' failed: ' + $tLinesStr + '. The test fell back to ' + $fallbackEnc + ', so the load figures are not representative.'
                $fix = 'Update or reinstall the ' + $vend + ' GPU driver and run again. Meanwhile check in vMix/OBS that the GPU encoder (NVENC/AMF) works.'
                AddCheck -Id 'load_encoder' -Status 'WARN' -Value $val -Limit 'hardware encoder' -Margin $null -Detail $det -Fix $fix
            }
            elseif ($chosenEnc -match 'x264') {
                # Case d
                $det = '3 software 1080p60 encodes on the CPU will not hold.'
                if ($failedStr -ne '') {
                    $det = $det + ' Encoders that did not work: ' + $failedStr + '.'
                }
                $fix = 'Use a PC with an NVIDIA (NVENC) or AMD (AMF) GPU, or install the GPU driver.'
                AddCheck -Id 'load_encoder' -Status 'FAIL' -Value 'software only (libx264)' -Limit 'hardware encoder' -Margin 0 -Detail $det.Trim() -Fix $fix
            }
            else {
                # Case e
                $det = 'No H.264 encoder passed the 1-second test.'
                if ($failedStr -ne '') {
                    $det = $det + ' Encoders that did not work: ' + $failedStr + '.'
                }
                $fix = 'Install or repair the GPU driver, then run ShowReady again.'
                AddCheck -Id 'load_encoder' -Status 'FAIL' -Value 'no working H.264 encoder' -Limit 'hardware encoder' -Margin 0 -Detail $det.Trim() -Fix $fix
            }
        }
        catch { [void]$errs.Add('load_encoder: ' + $_.Exception.Message) }

        if ($fellBack) {
            $fbDetail = 'Not representative: the test fell back to CPU encoding, but vMix/OBS would use the GPU.'
            AddCheck -Id 'load_realtime'   -Status 'SKIP' -Detail $fbDetail
            AddCheck -Id 'load_cpu'        -Status 'SKIP' -Detail $fbDetail
            AddCheck -Id 'load_gpu_encode' -Status 'SKIP' -Detail $fbDetail
            AddCheck -Id 'load_throttle'   -Status 'SKIP' -Detail $fbDetail
            if (-not $notTested.Contains('load test (fell back to CPU encoding)')) {
                [void]$notTested.Add('load test (fell back to CPU encoding)')
            }
        }
        else {
            # ---- load_realtime ----
            try {
                $streams = SRV_Arr (SRV_Get $LoadTest 'streams')
                $speedMin = SRV_Th $Thr 'load_speed_min'
                if ($streams.Count -eq 0) { AddCheck -Id 'load_realtime' -Status 'SKIP' -Detail 'The load test returned no stream results.' }
                else {
                    $bad = New-Object System.Collections.ArrayList
                    $worstSp = $null
                    foreach ($s in $streams) {
                        $ok = SRV_Bool (SRV_Get $s 'ok')
                        $sp = SRV_Num (SRV_Get $s 'speed_min')
                        if ($null -eq $sp) { $sp = SRV_Num (SRV_Get $s 'speed_p50') }
                        if ($null -eq $ok -and $null -ne $sp -and $null -ne $speedMin) { $ok = ($sp -ge $speedMin) }
                        if ($null -ne $sp -and ($null -eq $worstSp -or $sp -lt $worstSp)) { $worstSp = $sp }
                        if ($ok -ne $true) {
                            $lbl = SRV_Str (SRV_Get $s 'role')
                            if ($null -ne $sp) { $lbl = $lbl + ' (' + (SRV_F $sp 2) + ' x)' }
                            $se = SRV_Str (SRV_Get $s 'error')
                            if ($se -ne '') { $lbl = $lbl + ' [' + $se + ']' }
                            [void]$bad.Add($lbl)
                        }
                    }
                    $total = $streams.Count
                    $limTxt = ''
                    if ($null -ne $speedMin) { $limTxt = 'speed >= ' + (SRV_F $speedMin 2) + ' x' }
                    if ($bad.Count -eq 0) {
                        AddCheck -Id 'load_realtime' -Status 'PASS' -Value ([string]$total + ' of ' + [string]$total + ' streams real-time') -Limit $limTxt -Margin (SRV_Margin $worstSp $speedMin) `
                            -Detail ('All decodes and encodes kept up with real time. Slowest stream ran at ' + (SRV_F $worstSp 2) + ' x.')
                    }
                    else {
                        $good = $total - $bad.Count
                        AddCheck -Id 'load_realtime' -Status 'FAIL' -Value ([string]$good + ' of ' + [string]$total + ' streams real-time') -Limit $limTxt -Margin (SRV_Margin $worstSp $speedMin) `
                            -Detail ('Too slow for real time: ' + ($bad.ToArray() -join ', ') + '.') `
                            -Fix 'This PC cannot decode 2 feeds and encode 3 outputs in real time: use a stronger PC, or reduce outputs and bitrates.'
                    }
                }
            }
            catch { [void]$errs.Add('load_realtime: ' + $_.Exception.Message) }

            # ---- load_cpu ----
            try {
                $cpu95 = SRV_Num (SRV_Get $LoadTest 'system', 'cpu_p95')
                if ($null -eq $cpu95) { AddCheck -Id 'load_cpu' -Status 'SKIP' -Detail 'CPU load was not sampled.' }
                else {
                    $w = SRV_Th $Thr 'load_cpu_p95', 'warn'
                    $f = SRV_Th $Thr 'load_cpu_p95', 'fail'
                    $st = SRV_GradeLow $cpu95 $w $f
                    $fix = ''
                    if ($st -eq 'WARN' -or $st -eq 'FAIL') { $fix = 'The CPU is already busy before vMix/OBS compositing is added: use a faster CPU or lower the encoder load.' }
                    $cmax = SRV_Num (SRV_Get $LoadTest 'system', 'cpu_max')
                    $det = 'CPU p95 during the test; vMix/OBS compositing is not included.'
                    if ($null -ne $cmax) { $det = $det + ' Peak ' + (SRV_F $cmax 0) + ' %.' }
                    AddCheck -Id 'load_cpu' -Status $st -Value ((SRV_F $cpu95 0) + ' %') -Limit ('< ' + (SRV_T $w) + ' %') -Margin (SRV_Margin $w $cpu95) -Detail $det -Fix $fix
                }
            }
            catch { [void]$errs.Add('load_cpu: ' + $_.Exception.Message) }

            # ---- load_gpu_encode ----
            try {
                $g95 = SRV_Num (SRV_Get $LoadTest 'system', 'gpu_enc_p95')
                if ($null -eq $g95) { AddCheck -Id 'load_gpu_encode' -Status 'INFO' -Value 'not sampled' -Detail 'GPU encoder load was not available (older Windows build or no GPU engine counters).' }
                else {
                    $w = SRV_Th $Thr 'load_gpu_enc_p95', 'warn'
                    $f = SRV_Th $Thr 'load_gpu_enc_p95', 'fail'
                    $st = SRV_GradeLow $g95 $w $f
                    $fix = ''
                    if ($st -eq 'WARN' -or $st -eq 'FAIL') { $fix = 'The GPU video encoder is close to its limit: lower the output bitrates/preset or use a stronger GPU.' }
                    AddCheck -Id 'load_gpu_encode' -Status $st -Value ((SRV_F $g95 0) + ' %') -Limit ('< ' + (SRV_T $w) + ' %') -Margin (SRV_Margin $w $g95) -Detail 'GPU video-encode engine load (p95) while encoding the three outputs.' -Fix $fix
                }
            }
            catch { [void]$errs.Add('load_gpu_encode: ' + $_.Exception.Message) }

            # ---- load_throttle ----
            try {
                $ps = SRV_Num (SRV_Get $LoadTest 'system', 'perf_start')
                $pm = SRV_Num (SRV_Get $LoadTest 'system', 'perf_min')
                if ($null -eq $ps -or $null -eq $pm -or $ps -le 0) { AddCheck -Id 'load_throttle' -Status 'INFO' -Value 'not sampled' -Detail 'CPU clock performance was not available.' }
                else {
                    $drop = ($ps - $pm) / $ps * 100
                    if ($drop -lt 0) { $drop = 0 }
                    $w = SRV_Th $Thr 'load_perf_drop_pct', 'warn'
                    $st = 'PASS'
                    if ($null -ne $w -and $drop -gt $w) { $st = 'WARN' }
                    $fix = ''
                    if ($st -eq 'WARN') { $fix = 'The CPU slowed down under load (heat or power limit): set High performance, clean/cool the PC, plug in power, and re-run.' }
                    AddCheck -Id 'load_throttle' -Status $st -Value ((SRV_F $drop 0) + ' % drop') -Limit ($(if ($null -ne $w) { '<= ' + (SRV_T $w) + ' %' } else { '' })) -Margin (SRV_Margin $w $drop) `
                        -Detail ('CPU performance went from ' + (SRV_F $ps 0) + ' % at the start to ' + (SRV_F $pm 0) + ' % at its lowest.') -Fix $fix
                }
            }
            catch { [void]$errs.Add('load_throttle: ' + $_.Exception.Message) }
        }
    }

    # ---- encoder setting ----
    try {
        $encText = ''
        $encWhy = ''
        if ($fellBack) {
            $fbVend = if ($nvGpus.Count -gt 0) { 'NVIDIA' } else { 'AMD' }
            if ($fbVend -eq 'NVIDIA') {
                $encText = 'NVENC H.264 (h264_nvenc), preset P4, CBR, keyframe 2 s - same for all three outputs'
            }
            else {
                $encText = 'AMD AMF H.264 (h264_amf), Speed quality preset, CBR, keyframe 2 s - same for all three outputs'
            }
            $encWhy = 'Based on the ' + $fbVend + ' GPU; the load test could not confirm it.'
        }
        elseif ($chosenEnc -match 'nvenc') { $encText = 'NVENC H.264 (h264_nvenc), preset P4, CBR, keyframe 2 s - same for all three outputs'; $encWhy = 'Chosen by the load test (first hardware encoder that worked).' }
        elseif ($chosenEnc -match 'amf') { $encText = 'AMD AMF H.264 (h264_amf), Speed quality preset, CBR, keyframe 2 s - same for all three outputs'; $encWhy = 'Chosen by the load test (first hardware encoder that worked).' }
        elseif ($chosenEnc -match 'qsv') { $encText = 'Intel Quick Sync H.264 (h264_qsv), veryfast preset, CBR, keyframe 2 s - same for all three outputs'; $encWhy = 'Chosen by the load test (first hardware encoder that worked).' }
        elseif ($chosenEnc -match 'x264') { $encText = 'x264 on the CPU (libx264), veryfast, CBR, keyframe 2 s - NOT recommended for 3 outputs on this PC'; $encWhy = 'No hardware encoder worked in the load test.' }
        elseif ($hasHw -and $dedicated.Count -gt 0) {
            $vend = (SRV_Str (SRV_Get $dedicated[0] 'vendor')).ToUpperInvariant()
            if ($vend -eq 'NVIDIA') { $encText = 'NVENC H.264 (h264_nvenc), preset P4, CBR, keyframe 2 s - same for all three outputs'; $encWhy = 'Based on the NVIDIA GPU; the load test did not confirm it.' }
            elseif ($vend -eq 'AMD') { $encText = 'AMD AMF H.264 (h264_amf), Speed quality preset, CBR, keyframe 2 s - same for all three outputs'; $encWhy = 'Based on the AMD GPU; the load test did not confirm it.' }
        }
        if ($encText -ne '') { AddSetting -Id 'encoder' -Label 'Video encoder' -Value $encText -Why $encWhy }
    }
    catch { [void]$errs.Add('encoder setting: ' + $_.Exception.Message) }

    # =========================================================================================
    # SOFTWARE
    # =========================================================================================
    $swIds = @('sw_mixer', 'sw_ndi', 'sw_background')
    if (-not $hasHw) { SkipIds $swIds 'Hardware scan was not run.' }
    else {
        try {
            $sw = SRV_Get $Hardware 'software'
            $vmixV = SRV_Str (SRV_Get $sw 'vmix')
            $obsV = SRV_Str (SRV_Get $sw 'obs')
            $ndiRt = SRV_Str (SRV_Get $sw 'ndi_runtime')
            $ndiTools = SRV_Str (SRV_Get $sw 'ndi_tools')
            $distro = SRV_Str (SRV_Get $sw 'distroav')
            $omtV = SRV_Str (SRV_Get $sw 'omt')

            # ---- sw_mixer ----
            if ($null -eq $sw) { AddCheck -Id 'sw_mixer' -Status 'SKIP' -Detail 'Software inventory unavailable.' }
            else {
                $mx = New-Object System.Collections.ArrayList
                if ($vmixV -ne '') { [void]$mx.Add('vMix ' + $vmixV) }
                if ($obsV -ne '') { [void]$mx.Add('OBS ' + $obsV) }
                if ($mx.Count -gt 0) { AddCheck -Id 'sw_mixer' -Status 'PASS' -Value ($mx.ToArray() -join ', ') -Limit 'vMix or OBS' -Detail 'A production mixer is installed.' }
                else { AddCheck -Id 'sw_mixer' -Status 'WARN' -Value 'neither detected' -Limit 'vMix or OBS' -Detail 'Neither vMix nor OBS Studio was found in the installed programs.' -Fix 'Install vMix or OBS Studio on this PC (or run ShowReady on the PC that will run the show).' }
            }

            # ---- sw_ndi ----
            if ($null -eq $sw) { AddCheck -Id 'sw_ndi' -Status 'SKIP' -Detail 'Software inventory unavailable.' }
            else {
                $parts = New-Object System.Collections.ArrayList
                if ($ndiRt -ne '') { [void]$parts.Add('NDI runtime ' + $ndiRt) } else { [void]$parts.Add('NDI runtime not found') }
                if ($ndiTools -ne '') { [void]$parts.Add('NDI Tools ' + $ndiTools) }
                if ($distro -ne '') { [void]$parts.Add('DistroAV ' + $distro) } elseif ($obsV -ne '') { [void]$parts.Add('DistroAV not found') }
                if ($omtV -ne '') { [void]$parts.Add('OMT ' + $omtV) } else { [void]$parts.Add('OMT not found') }
                $valTxt = ($parts.ToArray() -join ', ')
                if ($proto -match '^(?i)NDI') {
                    $probs = New-Object System.Collections.ArrayList
                    if ($ndiRt -eq '') { [void]$probs.Add('the NDI runtime is not installed') }
                    if ($obsV -ne '' -and $distro -eq '') { [void]$probs.Add('OBS has no DistroAV (NDI) plugin') }
                    if ($probs.Count -gt 0) {
                        AddCheck -Id 'sw_ndi' -Status 'WARN' -Value $valTxt -Limit 'NDI runtime + DistroAV for OBS' -Detail ('The show uses ' + $proto + ', but ' + ($probs.ToArray() -join ' and ') + '.') `
                            -Fix 'Install NDI Tools / the NDI runtime, and DistroAV for OBS, before the show.'
                    }
                    else { AddCheck -Id 'sw_ndi' -Status 'INFO' -Value $valTxt -Detail ('The show uses ' + $proto + '; the NDI runtime is installed.') }
                }
                else {
                    AddCheck -Id 'sw_ndi' -Status 'INFO' -Value $valTxt -Detail ('The show uses ' + $proto + '; make sure the sending PCs and vMix/OBS support it.')
                }
            }

            # ---- sw_background ----
            $runRaw = SRV_Get $Hardware 'processes', 'running'
            if ($null -eq (SRV_Get $Hardware 'processes')) { AddCheck -Id 'sw_background' -Status 'SKIP' -Detail 'Process list unavailable.' }
            else {
                $run = SRV_Arr $runRaw
                $noisy = New-Object System.Collections.ArrayList
                foreach ($r in $run) {
                    $n = SRV_StripExe ([string]$r)
                    if ($n -eq '') { continue }
                    if ($n -match '^(?i)(vmix|vmix64|obs|obs64)$') { continue }
                    if ($n -match '^(?i)(NDI|OMT)') { continue }
                    if (-not $noisy.Contains($n)) { [void]$noisy.Add($n) }
                }
                if ($noisy.Count -gt 0) {
                    $nl = ($noisy.ToArray() -join ', ')
                    AddCheck -Id 'sw_background' -Status 'WARN' -Value ([string]$noisy.Count + ' running') -Limit 'none' -Detail ('These programs compete for CPU, GPU or network: ' + $nl + '.') -Fix ('Close: ' + $nl + '.')
                }
                else { AddCheck -Id 'sw_background' -Status 'PASS' -Value 'none running' -Limit 'none' -Detail 'No known background apps (OneDrive, Teams, Discord, browsers, game launchers) are running.' }
            }
        }
        catch { [void]$errs.Add('software: ' + $_.Exception.Message) }
    }

    # =========================================================================================
    # Assemble: sort, overall verdict, headline, weakest
    # =========================================================================================
    $order = @{}
    $ix = 0
    foreach ($k in $meta.Keys) { $order[[string]$k] = $ix; $ix++ }
    $sorted = @($checks.ToArray() | Sort-Object -Property @{ Expression = { if ($order.ContainsKey([string]$_.id)) { $order[[string]$_.id] } else { 9999 } } })

    $fails = @($sorted | Where-Object { $_.status -eq 'FAIL' })
    $warns = @($sorted | Where-Object { $_.status -eq 'WARN' })
    $overall = 'GO'
    if ($fails.Count -gt 0) { $overall = 'NO-GO' }
    elseif ($warns.Count -gt 0) { $overall = 'CAUTION' }

    $weakest = $null
    $headline = ''
    if ($fails.Count -gt 0) {
        $weakest = $fails[0].id
        $headline = SRV_Lead $fails[0] 'Weakest link: '
        if ($fails.Count -gt 1) { $headline = $headline + ' (+' + ($fails.Count - 1) + ' more blocking problem(s))' }
    }
    elseif ($warns.Count -gt 0) {
        $weakest = $warns[0].id
        $headline = SRV_Lead $warns[0] 'Weakest link (warning): '
        if ($warns.Count -gt 1) { $headline = $headline + ' (+' + ($warns.Count - 1) + ' more warning(s))' }
    }

    # Safety net: never say GO when parts of the test could not be measured.
    $partial = $false
    if ($overall -eq 'GO' -and $notTested.Count -gt 0) {
        $overall = 'CAUTION'
        $partial = $true
        $nt = ($notTested.ToArray() -join ', ')
        if (-not $hasHw -and -not $hasNet -and -not $hasLoad -and -not $hasLan) { $headline = 'Nothing was tested - run ShowReady without -Skip so there is something to judge.' }
        else { $headline = 'Partial run - not tested: ' + $nt + '. Everything that was measured passed, but GO cannot be confirmed.' }
    }
    elseif ($overall -eq 'GO') {
        $tight = $null
        foreach ($c in $sorted) {
            if ($c.status -eq 'PASS' -and $null -ne $c.margin -and $c.margin -lt 10 -and $c.id -ne 'load_realtime' -and $c.id -ne 'fr_reach') {
                if ($null -eq $tight -or $c.margin -lt $tight.margin) { $tight = $c }
            }
        }
        if ($null -ne $tight) { $headline = 'All checks passed; tightest margin: ' + (SRV_Lead $tight '') + '.' }
        else { $headline = 'All checks passed.' }
    }

    $manual = @(
        [pscustomobject][ordered]@{ id = 'mc_partner_latency'; text = "Confirm the French partner's receive latency matches the SRT latency above (the higher of the two ends wins)." }
        [pscustomobject][ordered]@{ id = 'mc_twitch_test'; text = 'Twitch from Korea: do a 30-second test stream with the real stream key from this venue before show day.' }
        [pscustomobject][ordered]@{ id = 'mc_same_time'; text = 'Re-run ShowReady at the same time of day as the show (evening congestion differs from daytime).' }
        [pscustomobject][ordered]@{ id = 'mc_rehearsal'; text = 'Run a 30-minute rehearsal with the real vMix/OBS scene and both real feeds; watch vMix/OBS dropped frames.' }
        [pscustomobject][ordered]@{ id = 'mc_srthost'; text = 'When the partner sends their SRT IP, run: Run-ShowReady.cmd -SrtHost <their IP>.' }
    )

    return [pscustomobject][ordered]@{
        overall       = $overall
        headline      = $headline
        weakest       = $weakest
        partial       = $partial
        not_tested    = $notTested.ToArray()
        checks        = $sorted
        settings      = $settings.ToArray()
        manual_checks = $manual
        calc          = [pscustomobject]$calc
        errors        = $errs.ToArray()
    }
}
