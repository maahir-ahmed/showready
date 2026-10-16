# ShowReady - lib\ObserverRules.ps1
# Verdict engine for observer (source) PCs. Defines Get-SRObserverVerdict (plus SRO_* helper functions).
# Needs lib\Rules.ps1 dot-sourced first. No side effects when dot-sourced.
# Windows PowerShell 5.1 compatible. Pure ASCII on purpose (PS 5.1 reads BOM-less files as the ANSI code page).
# No Set-StrictMode, no ternary / ?? / ?., no -Parallel. All number formatting uses the invariant culture.

# ---------------------------------------------------------------------------------------------
# Check catalogue (id -> section, title). Order here = order of the final checks array.
# ---------------------------------------------------------------------------------------------
function SRO_Meta {
    $m = [ordered]@{}
    $m['lan_wired']            = @('lan',      'Wired network connection')
    $m['obs_link']             = @('lan',      'Wired link speed')
    $m['lan_virtual_adapters'] = @('lan',      'Virtual network adapters')
    $m['lan_profile']          = @('lan',      'Windows network profile')
    $m['lan_eee']              = @('lan',      'Energy-Efficient Ethernet')
    $m['hw_power']             = @('hardware', 'Power plan and mains power')
    $m['hw_pending_reboot']    = @('hardware', 'Pending Windows reboot')
    $m['sw_background']        = @('software', 'Background apps')
    $m['sender_realtime']      = @('sender',   'Sender encode in real time')
    $m['sender_cpu']           = @('sender',   'CPU load during sender test')
    $m['sender_throttle']      = @('sender',   'CPU clock throttling')
    return $m
}

function SRO_NewCheck {
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

# ---------------------------------------------------------------------------------------------
# Get-SRObserverVerdict
# ---------------------------------------------------------------------------------------------
function Get-SRObserverVerdict {
    [CmdletBinding()]
    param(
        $Config,
        $Hardware,
        $Sender,
        $Now = $null
    )

    $nowDt = [datetime]::Now
    if ($null -ne $Now -and ($Now -is [datetime])) {
        $nowDt = $Now
    }

    $base = $null
    try {
        $base = Get-SRVerdict -Config $Config -Hardware $Hardware -Network $null -LoadTest $null -Lan $null -Now $nowDt
    }
    catch {
        $base = [pscustomobject]@{
            checks   = @()
            settings = @()
            errors   = @('base verdict error: ' + $_.Exception.Message)
        }
    }

    $meta = SRO_Meta
    $checks = New-Object System.Collections.ArrayList
    $settings = New-Object System.Collections.ArrayList
    $errs = New-Object System.Collections.ArrayList
    $notTested = New-Object System.Collections.ArrayList

    # Copy any base errors
    if ($null -ne $base -and $null -ne $base.errors) {
        foreach ($e in @($base.errors)) {
            if ($null -ne $e -and ([string]$e) -ne '') { [void]$errs.Add([string]$e) }
        }
    }

    $hasHw = ($null -ne $Hardware)
    $hasSender = ($null -ne $Sender)
    $Thr = SRV_Get $Config 'thresholds'

    function AddCheck {
        param([string]$Id, [string]$Status, [string]$Value = '', [string]$Limit = '', $Margin = $null, [string]$Detail = '', [string]$Fix = '')
        $sec = 'other'
        $ttl = $Id
        if ($meta.Contains($Id)) { $sec = $meta[$Id][0]; $ttl = $meta[$Id][1] }
        [void]$checks.Add((SRO_NewCheck -Id $Id -Section $sec -Title $ttl -Status $Status -Value $Value -Limit $Limit -Margin $Margin -Detail $Detail -Fix $Fix))
    }

    if (-not $hasHw) {
        [void]$notTested.Add('hardware scan')
    }

    $baseMap = @{}
    if ($null -ne $base -and $null -ne $base.checks) {
        foreach ($c in @($base.checks)) {
            if ($null -ne $c -and $null -ne $c.id) {
                $baseMap[[string]$c.id] = $c
            }
        }
    }

    # =========================================================================================
    # LAN & HARDWARE CHECKS FROM BASE
    # =========================================================================================

    # ---- lan_wired ----
    try {
        if ($baseMap.ContainsKey('lan_wired')) {
            $bc = $baseMap['lan_wired']
            if ($bc.status -eq 'FAIL') {
                $det = 'No wired network adapter is connected. Wi-Fi cannot carry a 1080p60 OMT/NDI feed reliably.'
                if ($bc.detail -match '( Adapters up: .*)') {
                    $det = $det + $Matches[1]
                }
                $fix = 'Connect this PC to the production switch with an Ethernet cable (1 GbE or faster).'
                AddCheck -Id 'lan_wired' -Status 'FAIL' -Value $bc.value -Limit $bc.limit -Margin $bc.margin -Detail $det -Fix $fix
            }
            else {
                AddCheck -Id 'lan_wired' -Status $bc.status -Value $bc.value -Limit $bc.limit -Margin $bc.margin -Detail $bc.detail -Fix $bc.fix
            }
        }
        else {
            AddCheck -Id 'lan_wired' -Status 'SKIP' -Detail 'Hardware scan was not run.'
        }
    }
    catch {
        [void]$errs.Add('lan_wired: ' + $_.Exception.Message)
    }

    # ---- obs_link ----
    try {
        if (-not $hasHw) {
            AddCheck -Id 'obs_link' -Status 'SKIP' -Detail 'Hardware scan was not run.'
        }
        else {
            $nicsRaw = SRV_Get $Hardware 'nics'
            $nics = SRV_Arr $nicsRaw
            $wiredUp = @($nics | Where-Object { (SRV_Str (SRV_Get $_ 'kind')) -ieq 'wired' -and (SRV_Str (SRV_Get $_ 'status')) -ieq 'Up' })
            if ($wiredUp.Count -eq 0) {
                AddCheck -Id 'obs_link' -Status 'SKIP' -Detail 'No wired adapter is up.'
            }
            else {
                $bestNic = $wiredUp | Sort-Object -Property @{ Expression = { $x = SRV_Num (SRV_Get $_ 'link_mbps'); if ($null -eq $x) { -1 } else { $x } } } -Descending | Select-Object -First 1
                $lm = SRV_Num (SRV_Get $bestNic 'link_mbps')
                $nicName = SRV_Str (SRV_Get $bestNic 'name')
                if ($nicName -eq '') { $nicName = 'Wired adapter' }

                $passLink = SRV_Th $Thr 'observer_link_mbps', 'pass'
                if ($null -eq $passLink) { $passLink = 1000 }
                $limLink = '>= ' + (SRV_F $passLink 0) + ' Mbps'

                if ($null -eq $lm) {
                    AddCheck -Id 'obs_link' -Status 'INFO' -Value 'unknown' -Limit $limLink -Detail ($nicName + ' link speed is unknown.')
                }
                elseif ($lm -ge $passLink) {
                    $valLink = (SRV_F $lm 0) + ' Mbps'
                    $mgLink = SRV_Margin $lm $passLink
                    AddCheck -Id 'obs_link' -Status 'PASS' -Value $valLink -Limit $limLink -Margin $mgLink -Detail ($nicName + ' links at ' + $valLink + '.')
                }
                else {
                    $valLink = (SRV_F $lm 0) + ' Mbps'
                    $mgLink = SRV_Margin $lm $passLink
                    $fixLink = 'Use a Cat5e/Cat6 cable and a gigabit switch port; a link below 1 Gbps usually means a bad cable or an old switch.'
                    AddCheck -Id 'obs_link' -Status 'FAIL' -Value $valLink -Limit $limLink -Margin $mgLink -Detail ($nicName + ' links at only ' + $valLink + '.') -Fix $fixLink
                }
            }
        }
    }
    catch {
        [void]$errs.Add('obs_link: ' + $_.Exception.Message)
    }

    # ---- other base checks ----
    $baseKeepIds = @('lan_virtual_adapters', 'lan_profile', 'lan_eee', 'hw_power', 'hw_pending_reboot')
    foreach ($kid in $baseKeepIds) {
        try {
            if ($baseMap.ContainsKey($kid)) {
                $bc = $baseMap[$kid]
                AddCheck -Id $kid -Status $bc.status -Value $bc.value -Limit $bc.limit -Margin $bc.margin -Detail $bc.detail -Fix $bc.fix
            }
            else {
                AddCheck -Id $kid -Status 'SKIP' -Detail 'Hardware scan was not run.'
            }
        }
        catch {
            [void]$errs.Add($kid + ': ' + $_.Exception.Message)
        }
    }

    # ---- sw_background: as Rules.ps1, but game launchers are expected on an observer PC ----
    try {
        if (-not $baseMap.ContainsKey('sw_background')) {
            AddCheck -Id 'sw_background' -Status 'SKIP' -Detail 'Hardware scan was not run.'
        }
        elseif ($null -eq (SRV_Get $Hardware 'processes')) {
            $bc = $baseMap['sw_background']
            AddCheck -Id 'sw_background' -Status $bc.status -Value $bc.value -Limit $bc.limit -Margin $bc.margin -Detail $bc.detail -Fix $bc.fix
        }
        else {
            $bgList = New-Object System.Collections.ArrayList
            foreach ($rp in (SRV_Arr (SRV_Get $Hardware 'processes', 'running'))) {
                $pn = SRV_StripExe ([string]$rp)
                if ($pn -eq '') { continue }
                if ($pn -match '^(?i)(vmix|vmix64|obs|obs64|steam|EpicGamesLauncher)$') { continue }
                if ($pn -match '^(?i)(NDI|OMT)') { continue }
                if (-not $bgList.Contains($pn)) { [void]$bgList.Add($pn) }
            }
            if ($bgList.Count -gt 0) {
                $bgNames = ($bgList.ToArray() -join ', ')
                AddCheck -Id 'sw_background' -Status 'WARN' -Value ([string]$bgList.Count + ' running') -Limit 'none' -Detail ('These programs compete for CPU, GPU or network: ' + $bgNames + '.') -Fix ('Close: ' + $bgNames + '.')
            }
            else {
                AddCheck -Id 'sw_background' -Status 'PASS' -Value 'none running' -Limit 'none' -Detail 'No known background apps (OneDrive, Teams, Discord, browsers) are running. Game launchers are expected on an observer PC.'
            }
        }
    }
    catch {
        [void]$errs.Add('sw_background: ' + $_.Exception.Message)
    }

    # =========================================================================================
    # SENDER CHECKS
    # =========================================================================================

    # ---- sender_realtime ----
    try {
        if (-not $hasSender) {
            AddCheck -Id 'sender_realtime' -Status 'SKIP' -Detail 'The sender test was not run.'
            [void]$notTested.Add('sender test')
        }
        else {
            $ffFound = SRV_Bool (SRV_Get $Sender 'ffmpeg', 'found')
            if ($ffFound -eq $false) {
                AddCheck -Id 'sender_realtime' -Status 'SKIP' -Detail 'ffmpeg was not found in the bin folder, so the sender test could not run.'
                [void]$notTested.Add('sender test (ffmpeg missing)')
            }
            else {
                $speedMin = SRV_Num (SRV_Get $Sender 'stream', 'speed_min')
                if ($null -eq $speedMin) {
                    $stErr = SRV_Str (SRV_Get $Sender 'stream', 'error')
                    if ($stErr -eq '') {
                        $errList = SRV_Arr (SRV_Get $Sender 'errors')
                        if ($errList.Count -gt 0) { $stErr = SRV_Str $errList[0] }
                    }
                    if ($stErr -eq '') { $stErr = 'unknown error' }
                    $errClean = $stErr.TrimEnd('.')
                    $det = 'The sender test returned no speed: ' + $errClean + '.'
                    AddCheck -Id 'sender_realtime' -Status 'SKIP' -Detail $det
                    [void]$notTested.Add('sender test')
                }
                else {
                    $speedMinTh = SRV_Th $Thr 'load_speed_min'
                    if ($null -eq $speedMinTh) { $speedMinTh = 0.97 }
                    $valRt = (SRV_F $speedMin 2) + ' x'
                    $limRt = '>= ' + (SRV_F $speedMinTh 2) + ' x'
                    $mgRt = SRV_Margin $speedMin $speedMinTh
                    $maxSpeed = SRV_Num (SRV_Get $Sender 'max_speed')
                    $unpacedText = ''
                    if ($null -ne $maxSpeed) {
                        $unpacedText = ' Unpaced it ran at ' + (SRV_F $maxSpeed 2) + ' x real time.'
                    }

                    if ($speedMin -ge $speedMinTh) {
                        $det = 'One 1080p60 SpeedHQ encode kept up with real time (slowest ' + (SRV_F $speedMin 2) + ' x).' + $unpacedText
                        AddCheck -Id 'sender_realtime' -Status 'PASS' -Value $valRt -Limit $limRt -Margin $mgRt -Detail $det
                    }
                    else {
                        # WARN, not FAIL: ffmpeg's SpeedHQ encoder is single-threaded ("Threading capabilities: none"),
                        # while the NDI/OMT sender spreads its encode over several cores.
                        $det = 'One 1080p60 SpeedHQ encode fell behind real time (slowest ' + (SRV_F $speedMin 2) + ' x).' + $unpacedText + " ffmpeg's SpeedHQ encoder uses one CPU core; the NDI/OMT sender spreads the work over several, so the real sender may still keep up."
                        $fix = "Close other programs and lower the game's graphics load, then re-run. If it still falls behind, check the real NDI/OMT sender on this PC for dropped frames before show day."
                        AddCheck -Id 'sender_realtime' -Status 'WARN' -Value $valRt -Limit $limRt -Margin $mgRt -Detail $det -Fix $fix
                    }
                }
            }
        }
    }
    catch {
        [void]$errs.Add('sender_realtime: ' + $_.Exception.Message)
    }

    # ---- sender_cpu ----
    try {
        if (-not $hasSender) {
            AddCheck -Id 'sender_cpu' -Status 'SKIP' -Detail 'The sender test was not run.'
        }
        else {
            $cpuP95 = SRV_Num (SRV_Get $Sender 'system', 'cpu_p95')
            if ($null -eq $cpuP95) {
                AddCheck -Id 'sender_cpu' -Status 'SKIP' -Detail 'CPU load was not sampled.'
            }
            else {
                $warnCpu = SRV_Th $Thr 'sender_cpu_p95', 'warn'
                $failCpu = SRV_Th $Thr 'sender_cpu_p95', 'fail'
                if ($null -eq $warnCpu) { $warnCpu = 70 }
                if ($null -eq $failCpu) { $failCpu = 90 }
                $stCpu = SRV_GradeLow $cpuP95 $warnCpu $failCpu
                $valCpu = (SRV_F $cpuP95 0) + ' %'
                $limCpu = '< ' + (SRV_T $warnCpu) + ' %'
                $mgCpu = SRV_Margin $warnCpu $cpuP95
                $cpuMax = SRV_Num (SRV_Get $Sender 'system', 'cpu_max')
                $detCpu = 'CPU p95 while the game/observer client and one 1080p60 SpeedHQ encode ran together.'
                if ($null -ne $cpuMax) {
                    $detCpu = $detCpu + ' Peak ' + (SRV_F $cpuMax 0) + ' %.'
                }
                $fixCpu = ''
                if ($stCpu -eq 'WARN' -or $stCpu -eq 'FAIL') {
                    $fixCpu = "Little CPU headroom left for the sender: close background programs, cap the game's frame rate, or use a stronger CPU."
                }
                AddCheck -Id 'sender_cpu' -Status $stCpu -Value $valCpu -Limit $limCpu -Margin $mgCpu -Detail $detCpu -Fix $fixCpu
            }
        }
    }
    catch {
        [void]$errs.Add('sender_cpu: ' + $_.Exception.Message)
    }

    # ---- sender_throttle ----
    try {
        if (-not $hasSender) {
            AddCheck -Id 'sender_throttle' -Status 'SKIP' -Detail 'The sender test was not run.'
        }
        else {
            $ps = SRV_Num (SRV_Get $Sender 'system', 'perf_start')
            $pm = SRV_Num (SRV_Get $Sender 'system', 'perf_min')
            if ($null -eq $ps -or $null -eq $pm -or $ps -le 0) {
                AddCheck -Id 'sender_throttle' -Status 'INFO' -Value 'not sampled' -Detail 'CPU clock performance was not available.'
            }
            else {
                $drop = ($ps - $pm) / $ps * 100
                if ($drop -lt 0) { $drop = 0 }
                $wDrop = SRV_Th $Thr 'load_perf_drop_pct', 'warn'
                if ($null -eq $wDrop) { $wDrop = 15 }
                $stDrop = 'PASS'
                if ($null -ne $wDrop -and $drop -gt $wDrop) { $stDrop = 'WARN' }
                $fixDrop = ''
                if ($stDrop -eq 'WARN') {
                    $fixDrop = 'The CPU slowed down under load (heat or power limit): set High performance, clean/cool the PC, plug in power, and re-run.'
                }
                $limDrop = ''
                if ($null -ne $wDrop) { $limDrop = '<= ' + (SRV_T $wDrop) + ' %' }
                AddCheck -Id 'sender_throttle' -Status $stDrop -Value ((SRV_F $drop 0) + ' % drop') -Limit $limDrop -Margin (SRV_Margin $wDrop $drop) `
                    -Detail ('CPU performance went from ' + (SRV_F $ps 0) + ' % at the start to ' + (SRV_F $pm 0) + ' % at its lowest.') -Fix $fixDrop
            }
        }
    }
    catch {
        [void]$errs.Add('sender_throttle: ' + $_.Exception.Message)
    }

    # =========================================================================================
    # SETTINGS & MANUAL CHECKS
    # =========================================================================================

    if ($null -ne $base -and $null -ne $base.settings) {
        foreach ($s in @($base.settings)) {
            if ((SRV_Str (SRV_Get $s 'id')) -ieq 'power_plan') {
                [void]$settings.Add($s)
            }
        }
    }

    $manual = @(
        [pscustomobject][ordered]@{ id = 'mc_obs_wait'; text = 'Leave Run-Observer.cmd waiting until the prod PC has finished its LAN test (Run-ShowReady.cmd -LanHosts <this PC''s IP>,<other observer''s IP>).' }
        [pscustomobject][ordered]@{ id = 'mc_obs_sender'; text = 'Before show day, install the NDI/OMT sender (or turn on NDI/OMT output in the observer client) and check that the feed arrives in vMix/OBS on the prod PC.' }
        [pscustomobject][ordered]@{ id = 'mc_obs_rehearsal'; text = 'Run a 30-minute rehearsal with the game/observer client and the real NDI/OMT output; watch for dropped frames on the prod PC.' }
    )

    # =========================================================================================
    # ASSEMBLE: SORT, OVERALL VERDICT, HEADLINE, WEAKEST, PARTIAL
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

    $partial = $false
    if ($overall -eq 'GO' -and $notTested.Count -gt 0) {
        $overall = 'CAUTION'
        $partial = $true
        $nt = ($notTested.ToArray() -join ', ')
        if (-not $hasHw -and -not $hasSender) {
            $headline = 'Nothing was tested - run ShowReady without -Skip so there is something to judge.'
        }
        else {
            $headline = 'Partial run - not tested: ' + $nt + '. Everything that was measured passed, but GO cannot be confirmed.'
        }
    }
    elseif ($overall -eq 'GO') {
        $tight = $null
        foreach ($c in $sorted) {
            if ($c.status -eq 'PASS' -and $null -ne $c.margin -and $c.margin -lt 10) {
                if ($null -eq $tight -or $c.margin -lt $tight.margin) { $tight = $c }
            }
        }
        if ($null -ne $tight) {
            $headline = 'All checks passed; tightest margin: ' + (SRV_Lead $tight '') + '.'
        }
        else {
            $headline = 'All checks passed.'
        }
    }

    return [pscustomobject][ordered]@{
        role          = 'observer'
        overall       = $overall
        headline      = $headline
        weakest       = $weakest
        partial       = $partial
        not_tested    = $notTested.ToArray()
        checks        = $sorted
        settings      = $settings.ToArray()
        manual_checks = $manual
        calc          = [pscustomobject]@{}
        errors        = $errs.ToArray()
    }
}
