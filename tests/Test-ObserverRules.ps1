# ShowReady - tests\Test-ObserverRules.ps1
# Plain PowerShell assertions (no Pester) for lib\ObserverRules.ps1 (Get-SRObserverVerdict).
# Run:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Test-ObserverRules.ps1
# Exit code 0 = all assertions passed, 1 = at least one failed. Pure ASCII, works on Windows PowerShell 5.1 and pwsh.

$ErrorActionPreference = 'Continue'
$testsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$kit = Split-Path -Parent $testsDir
$fx = Join-Path $testsDir 'fixtures'
$script:nPass = 0
$script:nFail = 0

# Dot-source Rules.ps1 with retry if another agent is editing it
$rulesPath = Join-Path $kit 'lib\Rules.ps1'
$obsRulesPath = Join-Path $kit 'lib\ObserverRules.ps1'

$maxAttempts = 3
for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    try {
        . $rulesPath
        break
    }
    catch {
        if ($attempt -lt $maxAttempts) {
            Write-Host ('Waiting for Rules.ps1 (attempt ' + $attempt + ' failed)...') -ForegroundColor Yellow
            Start-Sleep -Seconds 60
        }
        else {
            throw $_
        }
    }
}
. $obsRulesPath

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

function Read-Json {
    param([string]$Path)
    $txt = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    return ($txt | ConvertFrom-Json)
}

function Get-Cfg { return (Read-Json (Join-Path $kit 'config.json')) }
function Get-Fx { param([string]$Name) return (Read-Json (Join-Path $fx $Name)) }
function Get-Chk { param($V, [string]$Id) foreach ($c in @($V.checks)) { if ($c.id -eq $Id) { return $c } } return $null }
function Get-Set { param($V, [string]$Id) foreach ($s in @($V.settings)) { if ($s.id -eq $Id) { return $s } } return $null }
function Show { param($V) $V.checks | ForEach-Object { Write-Host ('        {0,-5} {1,-22} {2}' -f $_.status, $_.id, $_.value) -ForegroundColor DarkGray } }

$fixedNow = [datetime]::new(2026, 10, 16)

function Run-ObsVerdict {
    param($Config, $Hardware, $Sender)
    return (Get-SRObserverVerdict -Config $Config -Hardware $Hardware -Sender $Sender -Now $fixedNow)
}

$contractIds = @(
    'lan_wired',
    'obs_link',
    'lan_virtual_adapters',
    'lan_profile',
    'lan_eee',
    'hw_power',
    'hw_pending_reboot',
    'sw_background',
    'sender_realtime',
    'sender_cpu',
    'sender_throttle'
)

$expectedSections = @{
    'lan_wired'            = 'lan'
    'obs_link'             = 'lan'
    'lan_virtual_adapters' = 'lan'
    'lan_profile'          = 'lan'
    'lan_eee'              = 'lan'
    'hw_power'             = 'hardware'
    'hw_pending_reboot'    = 'hardware'
    'sw_background'        = 'software'
    'sender_realtime'      = 'sender'
    'sender_cpu'           = 'sender'
    'sender_throttle'      = 'sender'
}

$validStatus = @('PASS', 'WARN', 'FAIL', 'INFO', 'SKIP')
$validSections = @('lan', 'hardware', 'software', 'sender')

Write-Host ''
Write-Host 'ShowReady ObserverRules tests' -ForegroundColor Cyan
Write-Host ('  PowerShell ' + $PSVersionTable.PSVersion.ToString()) -ForegroundColor DarkGray

# =============================================================================================
Write-Host ''
Write-Host '(a) wired observer PC + sender_ok -> GO' -ForegroundColor Cyan
$v = $null
$threw = $false
try {
    $v = Run-ObsVerdict (Get-Cfg) (Get-Fx 'observer_hw_wired.json') (Get-Fx 'sender_ok.json')
}
catch {
    $threw = $true
    Write-Host ('        exception: ' + $_.Exception.Message) -ForegroundColor Red
}

Assert-That 'a: Get-SRObserverVerdict does not throw' (-not $threw -and $null -ne $v)
if ($null -ne $v) {
    Assert-That 'a: role is "observer"' ($v.role -ceq 'observer') ('role = ' + $v.role)
    Assert-That 'a: overall is GO' ($v.overall -ceq 'GO') ('overall = ' + $v.overall)
    Assert-That 'a: partial is false' ($v.partial -eq $false)

    # All 11 ids present
    $actualIds = @($v.checks | ForEach-Object { $_.id })
    Assert-That 'a: exactly 11 checks present' ($actualIds.Count -eq 11) ('count = ' + $actualIds.Count)
    Assert-That 'a: all 11 ids in contract order' (($actualIds -join ',') -ceq ($contractIds -join ',')) ('order = ' + ($actualIds -join ','))

    # No forbidden ids
    $forbidden = @($actualIds | Where-Object { $_ -match '^(fr_|uplink_|ingest_|load_|lan_sources|lan_partner|lan_hosts)' })
    Assert-That 'a: no fr_*/uplink_*/ingest_*/load_*/lan_sources/partner/hosts ids' ($forbidden.Count -eq 0) ('forbidden: ' + ($forbidden -join ', '))

    # Check sections
    $secMismatch = @()
    foreach ($chk in $v.checks) {
        $expSec = $expectedSections[$chk.id]
        if ($chk.section -cne $expSec) {
            $secMismatch += ($chk.id + ': ' + $chk.section + ' != ' + $expSec)
        }
    }
    Assert-That 'a: all checks have the right sections' ($secMismatch.Count -eq 0) ($secMismatch -join '; ')

    # All pass
    $fails = @($v.checks | Where-Object { $_.status -eq 'FAIL' })
    $warns = @($v.checks | Where-Object { $_.status -eq 'WARN' })
    Assert-That 'a: no FAIL checks' ($fails.Count -eq 0) ('failing: ' + (($fails | ForEach-Object { $_.id }) -join ', '))
    Assert-That 'a: no WARN checks' ($warns.Count -eq 0) ('warning: ' + (($warns | ForEach-Object { $_.id }) -join ', '))

    # Check specific values
    $obsLink = Get-Chk $v 'obs_link'
    Assert-That 'a: obs_link status is PASS' ($obsLink.status -ceq 'PASS')
    Assert-That 'a: obs_link value is "1000 Mbps"' ($obsLink.value -ceq '1000 Mbps')
    Assert-That 'a: obs_link limit is ">= 1000 Mbps"' ($obsLink.limit -ceq '>= 1000 Mbps')
    Assert-That 'a: obs_link margin is 1.0' ($obsLink.margin -eq 1.0)
    Assert-That 'a: obs_link detail contains "links at 1000 Mbps."' ($obsLink.detail -cmatch 'links at 1000 Mbps\.')

    $sRt = Get-Chk $v 'sender_realtime'
    Assert-That 'a: sender_realtime status is PASS' ($sRt.status -ceq 'PASS')
    Assert-That 'a: sender_realtime value is "1.01 x"' ($sRt.value -ceq '1.01 x')
    Assert-That 'a: sender_realtime limit is ">= 0.97 x"' ($sRt.limit -ceq '>= 0.97 x')
    Assert-That 'a: sender_realtime detail mentions kept up and unpaced 1.99 x' (($sRt.detail -cmatch 'One 1080p60 SpeedHQ encode kept up with real time \(slowest 1\.01 x\)\.') -and ($sRt.detail -cmatch 'Unpaced it ran at 1\.99 x real time\.'))

    $sCpu = Get-Chk $v 'sender_cpu'
    Assert-That 'a: sender_cpu status is PASS' ($sCpu.status -ceq 'PASS')
    Assert-That 'a: sender_cpu value is "48 %"' ($sCpu.value -ceq '48 %')
    Assert-That 'a: sender_cpu limit is "< 70 %"' ($sCpu.limit -ceq '< 70 %')
    Assert-That 'a: sender_cpu detail mentions CPU p95 and Peak 61 %' (($sCpu.detail -cmatch 'CPU p95 while the game/observer client and one 1080p60 SpeedHQ encode ran together\.') -and ($sCpu.detail -cmatch 'Peak 61 %\.'))

    $sThrot = Get-Chk $v 'sender_throttle'
    Assert-That 'a: sender_throttle status is PASS' ($sThrot.status -ceq 'PASS')
    Assert-That 'a: sender_throttle value is "5 % drop"' ($sThrot.value -ceq '5 % drop')
    Assert-That 'a: sender_throttle limit is "<= 15 %"' ($sThrot.limit -ceq '<= 15 %')

    # Settings and manual checks
    Assert-That 'a: settings count is 1' (@($v.settings).Count -eq 1)
    Assert-That 'a: settings contain only power_plan' ($v.settings[0].id -ceq 'power_plan')
    Assert-That 'a: manual_checks has 3 items' (@($v.manual_checks).Count -eq 3)
    $mcIds = @($v.manual_checks | ForEach-Object { $_.id })
    Assert-That 'a: manual_checks are the 3 ids' (($mcIds -join ',') -ceq 'mc_obs_wait,mc_obs_sender,mc_obs_rehearsal')
    Assert-That 'a: not_tested is empty' (@($v.not_tested).Count -eq 0)

    # JSON serialization
    $jsonOk = $false
    try {
        $j = ConvertTo-Json -InputObject $v -Depth 12
        $back = $j | ConvertFrom-Json
        $jsonOk = (@($back.checks).Count -eq 11) -and ($back.role -eq 'observer')
    }
    catch {
        $jsonOk = $false
    }
    Assert-That 'a: verdict serialises to JSON (Depth 12) and round-trips' $jsonOk

    Show $v
}

# =============================================================================================
Write-Host ''
Write-Host '(b) sender_slow -> realtime WARN, cpu FAIL, throttle WARN, overall NO-GO' -ForegroundColor Cyan
$v = $null
$threw = $false
try {
    $v = Run-ObsVerdict (Get-Cfg) (Get-Fx 'observer_hw_wired.json') (Get-Fx 'sender_slow.json')
}
catch {
    $threw = $true
}
Assert-That 'b: Get-SRObserverVerdict does not throw' (-not $threw -and $null -ne $v)
if ($null -ne $v) {
    Assert-That 'b: overall is NO-GO' ($v.overall -ceq 'NO-GO') ('overall = ' + $v.overall)

    $sRt = Get-Chk $v 'sender_realtime'
    Assert-That 'b: sender_realtime status is WARN (ffmpeg SpeedHQ is single-threaded)' ($sRt.status -ceq 'WARN')
    Assert-That 'b: sender_realtime exact value "0.71 x"' ($sRt.value -ceq '0.71 x')
    Assert-That 'b: sender_realtime limit is ">= 0.97 x"' ($sRt.limit -ceq '>= 0.97 x')
    Assert-That 'b: sender_realtime detail mentions fell behind and unpaced 0.74 x' (($sRt.detail -cmatch 'One 1080p60 SpeedHQ encode fell behind real time \(slowest 0\.71 x\)\.') -and ($sRt.detail -cmatch 'Unpaced it ran at 0\.74 x real time\.'))
    Assert-That 'b: sender_realtime explains the single-core encoder' ($sRt.detail -cmatch "ffmpeg's SpeedHQ encoder uses one CPU core; the NDI/OMT sender spreads the work over several, so the real sender may still keep up\.$") $sRt.detail
    Assert-That 'b: sender_realtime exact fix' ($sRt.fix -ceq "Close other programs and lower the game's graphics load, then re-run. If it still falls behind, check the real NDI/OMT sender on this PC for dropped frames before show day.")

    $sCpu = Get-Chk $v 'sender_cpu'
    Assert-That 'b: sender_cpu status is FAIL' ($sCpu.status -ceq 'FAIL')
    Assert-That 'b: sender_cpu value is "99 %"' ($sCpu.value -ceq '99 %')
    Assert-That 'b: sender_cpu limit is "< 70 %"' ($sCpu.limit -ceq '< 70 %')
    Assert-That 'b: sender_cpu exact fix' ($sCpu.fix -ceq "Little CPU headroom left for the sender: close background programs, cap the game's frame rate, or use a stronger CPU.")

    $sThrot = Get-Chk $v 'sender_throttle'
    Assert-That 'b: sender_throttle status is WARN' ($sThrot.status -ceq 'WARN')
    Assert-That 'b: sender_throttle value is "30 % drop"' ($sThrot.value -ceq '30 % drop')
    Assert-That 'b: sender_throttle limit is "<= 15 %"' ($sThrot.limit -ceq '<= 15 %')
    Assert-That 'b: sender_throttle exact fix' ($sThrot.fix -ceq 'The CPU slowed down under load (heat or power limit): set High performance, clean/cool the PC, plug in power, and re-run.')

    Assert-That 'b: weakest is sender_cpu (the only FAIL)' ($v.weakest -ceq 'sender_cpu') ([string]$v.weakest)
    Assert-That 'b: headline names the CPU load' ($v.headline -cmatch '^Weakest link: CPU load during sender test') $v.headline

    Show $v
}

# =============================================================================================
Write-Host ''
Write-Host '(c) sender_nodata -> sender_realtime SKIP and overall not GO' -ForegroundColor Cyan
$v = $null
$threw = $false
try {
    $v = Run-ObsVerdict (Get-Cfg) (Get-Fx 'observer_hw_wired.json') (Get-Fx 'sender_nodata.json')
}
catch {
    $threw = $true
}
Assert-That 'c: Get-SRObserverVerdict does not throw' (-not $threw -and $null -ne $v)
if ($null -ne $v) {
    $sRt = Get-Chk $v 'sender_realtime'
    Assert-That 'c: sender_realtime status is SKIP' ($sRt.status -ceq 'SKIP')
    Assert-That 'c: sender_realtime detail has stream error' ($sRt.detail -ceq 'The sender test returned no speed: Process failed with exit code 1.') $sRt.detail
    Assert-That 'c: overall is not GO' ($v.overall -cne 'GO') ('overall = ' + $v.overall)
    Assert-That 'c: overall is CAUTION' ($v.overall -ceq 'CAUTION')
    Assert-That 'c: partial is true' ($v.partial -eq $true)
    Assert-That 'c: not_tested contains "sender test"' ($v.not_tested -contains 'sender test')
    Show $v
}

# =============================================================================================
Write-Host ''
Write-Host '(d) Sender null -> SKIPs, not_tested "sender test"' -ForegroundColor Cyan
$v = $null
$threw = $false
try {
    $v = Run-ObsVerdict (Get-Cfg) (Get-Fx 'observer_hw_wired.json') $null
}
catch {
    $threw = $true
}
Assert-That 'd1: Sender null does not throw' (-not $threw -and $null -ne $v)
if ($null -ne $v) {
    Assert-That 'd1: sender_realtime is SKIP' ((Get-Chk $v 'sender_realtime').status -ceq 'SKIP')
    Assert-That 'd1: sender_cpu is SKIP' ((Get-Chk $v 'sender_cpu').status -ceq 'SKIP')
    Assert-That 'd1: sender_throttle is SKIP' ((Get-Chk $v 'sender_throttle').status -ceq 'SKIP')
    Assert-That 'd1: sender_realtime detail exact' ((Get-Chk $v 'sender_realtime').detail -ceq 'The sender test was not run.')
    Assert-That 'd1: not_tested contains "sender test"' ($v.not_tested -contains 'sender test')
    Assert-That 'd1: overall is CAUTION (partial)' (($v.overall -ceq 'CAUTION') -and ($v.partial -eq $true))
    Assert-That 'd1: headline mentions partial run not tested sender test' ($v.headline -cmatch 'Partial run - not tested: sender test\.')
}

Write-Host ''
Write-Host '(d2) Hardware null and Sender null -> "Nothing was tested" headline' -ForegroundColor Cyan
$v = $null
$threw = $false
try {
    $v = Run-ObsVerdict (Get-Cfg) $null $null
}
catch {
    $threw = $true
}
Assert-That 'd2: both null does not throw' (-not $threw -and $null -ne $v)
if ($null -ne $v) {
    $nonSkip = @($v.checks | Where-Object { $_.status -ne 'SKIP' })
    Assert-That 'd2: all 11 checks are SKIP' (($v.checks.Count -eq 11) -and ($nonSkip.Count -eq 0))
    Assert-That 'd2: not_tested contains hardware scan' ($v.not_tested -contains 'hardware scan')
    Assert-That 'd2: not_tested contains sender test' ($v.not_tested -contains 'sender test')
    Assert-That 'd2: overall is CAUTION' ($v.overall -ceq 'CAUTION')
    Assert-That 'd2: partial is true' ($v.partial -eq $true)
    Assert-That 'd2: headline is exact "Nothing was tested..."' ($v.headline -ceq 'Nothing was tested - run ShowReady without -Skip so there is something to judge.') $v.headline
    Assert-That 'd2: weakest is null' ($null -eq $v.weakest)
}

Write-Host ''
Write-Host '(d3) ffmpeg not found in sender test' -ForegroundColor Cyan
$senderNoFf = Get-Fx 'sender_ok.json'
$senderNoFf.ffmpeg.found = $false
$v = Run-ObsVerdict (Get-Cfg) (Get-Fx 'observer_hw_wired.json') $senderNoFf
Assert-That 'd3: sender_realtime is SKIP' ((Get-Chk $v 'sender_realtime').status -ceq 'SKIP')
Assert-That 'd3: detail mentions ffmpeg was not found' ((Get-Chk $v 'sender_realtime').detail -cmatch 'ffmpeg was not found in the bin folder')
Assert-That 'd3: not_tested contains "sender test (ffmpeg missing)"' ($v.not_tested -contains 'sender test (ffmpeg missing)')

# =============================================================================================
Write-Host ''
Write-Host '(e) obs_link variants (1000 PASS, 100 FAIL with exact fix, no wired -> SKIP and lan_wired FAIL, link null -> INFO)' -ForegroundColor Cyan

# 1000 PASS
$hw1000 = Get-Fx 'observer_hw_wired.json'
$v = Run-ObsVerdict (Get-Cfg) $hw1000 (Get-Fx 'sender_ok.json')
$chk = Get-Chk $v 'obs_link'
Assert-That 'e: obs_link 1000 status is PASS' ($chk.status -ceq 'PASS')
Assert-That 'e: obs_link 1000 value is "1000 Mbps"' ($chk.value -ceq '1000 Mbps')
Assert-That 'e: obs_link 1000 limit is ">= 1000 Mbps"' ($chk.limit -ceq '>= 1000 Mbps')
Assert-That 'e: obs_link 1000 margin is 1.0' ($chk.margin -eq 1.0)
Assert-That 'e: obs_link 1000 detail has NIC name and 1000 Mbps' ($chk.detail -cmatch 'Ethernet links at 1000 Mbps\.')

# 100 FAIL with exact fix
$hw100 = Get-Fx 'observer_hw_wired.json'
$hw100.nics[0].link_mbps = 100
$v = Run-ObsVerdict (Get-Cfg) $hw100 (Get-Fx 'sender_ok.json')
$chk = Get-Chk $v 'obs_link'
Assert-That 'e: obs_link 100 status is FAIL' ($chk.status -ceq 'FAIL')
Assert-That 'e: obs_link 100 value is "100 Mbps"' ($chk.value -ceq '100 Mbps')
Assert-That 'e: obs_link 100 limit is ">= 1000 Mbps"' ($chk.limit -ceq '>= 1000 Mbps')
Assert-That 'e: obs_link 100 margin is 0.1' ($chk.margin -eq 0.1)
Assert-That 'e: obs_link 100 detail has "links at only 100 Mbps."' ($chk.detail -cmatch 'Ethernet links at only 100 Mbps\.')
Assert-That 'e: obs_link 100 exact fix' ($chk.fix -ceq 'Use a Cat5e/Cat6 cable and a gigabit switch port; a link below 1 Gbps usually means a bad cable or an old switch.')

# no wired -> SKIP and lan_wired FAIL with observer detail and fix
$hwNoWired = Get-Fx 'observer_hw_wired.json'
$hwNoWired.nics = @(
    [pscustomobject]@{
        name             = 'Wi-Fi'
        description      = 'Wi-Fi 6'
        status           = 'Up'
        link_mbps        = 866
        kind             = 'wifi'
        default_route    = $true
        ipv4             = @('192.168.1.50')
        network_category = 'Private'
        eee              = 'unknown'
    }
)
$v = Run-ObsVerdict (Get-Cfg) $hwNoWired (Get-Fx 'sender_ok.json')
$chkLink = Get-Chk $v 'obs_link'
$chkWired = Get-Chk $v 'lan_wired'
Assert-That 'e: obs_link no wired status is SKIP' ($chkLink.status -ceq 'SKIP')
Assert-That 'e: obs_link no wired detail is exact' ($chkLink.detail -ceq 'No wired adapter is up.')
Assert-That 'e: lan_wired no wired status is FAIL' ($chkWired.status -ceq 'FAIL')
Assert-That 'e: lan_wired detail has observer 1080p60 copy and Adapters up sentence' (($chkWired.detail -cmatch '^No wired network adapter is connected\. Wi-Fi cannot carry a 1080p60 OMT/NDI feed reliably\.') -and ($chkWired.detail -cmatch 'Adapters up: Wi-Fi \[wifi\]\.')) $chkWired.detail
Assert-That 'e: lan_wired exact observer fix' ($chkWired.fix -ceq 'Connect this PC to the production switch with an Ethernet cable (1 GbE or faster).')

# link null -> INFO
$hwLinkNull = Get-Fx 'observer_hw_wired.json'
$hwLinkNull.nics[0].link_mbps = $null
$v = Run-ObsVerdict (Get-Cfg) $hwLinkNull (Get-Fx 'sender_ok.json')
$chkNull = Get-Chk $v 'obs_link'
Assert-That 'e: obs_link link null status is INFO' ($chkNull.status -ceq 'INFO')
Assert-That 'e: obs_link link null value is "unknown"' ($chkNull.value -ceq 'unknown')
Assert-That 'e: obs_link link null detail mentions unknown' ($chkNull.detail -cmatch 'Ethernet link speed is unknown\.')

# =============================================================================================
Write-Host ''
Write-Host '(f) Wi-Fi-only weak_hardware.json -> NO-GO; settings contain only power_plan; manual_checks are the 3 ids' -ForegroundColor Cyan
$v = $null
$threw = $false
try {
    $v = Run-ObsVerdict (Get-Cfg) (Get-Fx 'weak_hardware.json') (Get-Fx 'sender_ok.json')
}
catch {
    $threw = $true
}
Assert-That 'f: weak_hardware run does not throw' (-not $threw -and $null -ne $v)
if ($null -ne $v) {
    Assert-That 'f: overall is NO-GO' ($v.overall -ceq 'NO-GO') ('overall = ' + $v.overall)
    Assert-That 'f: lan_wired is FAIL' ((Get-Chk $v 'lan_wired').status -ceq 'FAIL')
    Assert-That 'f: obs_link is SKIP' ((Get-Chk $v 'obs_link').status -ceq 'SKIP')
    Assert-That 'f: lan_virtual_adapters is WARN' ((Get-Chk $v 'lan_virtual_adapters').status -ceq 'WARN')
    Assert-That 'f: hw_power is WARN' ((Get-Chk $v 'hw_power').status -ceq 'WARN')
    Assert-That 'f: hw_pending_reboot is WARN' ((Get-Chk $v 'hw_pending_reboot').status -ceq 'WARN')
    Assert-That 'f: sw_background is WARN' ((Get-Chk $v 'sw_background').status -ceq 'WARN')
    Assert-That 'f: settings count is 1' (@($v.settings).Count -eq 1)
    Assert-That 'f: settings contains only power_plan' ($v.settings[0].id -ceq 'power_plan')
    Assert-That 'f: manual_checks count is 3' (@($v.manual_checks).Count -eq 3)
    $mcList = @($v.manual_checks | ForEach-Object { $_.id })
    Assert-That 'f: manual_checks are the 3 ids' (($mcList -join ',') -ceq 'mc_obs_wait,mc_obs_sender,mc_obs_rehearsal')
    Show $v
}

# =============================================================================================
Write-Host ''
Write-Host '(f2) slow ffmpeg encode with CPU headroom -> CAUTION; game launchers are not background apps' -ForegroundColor Cyan
$hwL = Get-Fx 'observer_hw_wired.json'
$hwL.processes = [pscustomobject]@{ running = @('Steam', 'EpicGamesLauncher.exe', 'vMix64') }
$snd = Get-Fx 'sender_ok.json'
$snd.stream.speed_min = 0.9
$v = Run-ObsVerdict (Get-Cfg) $hwL $snd
Assert-That 'f2: sender_realtime WARN, value "0.90 x"' ((Get-Chk $v 'sender_realtime').status -ceq 'WARN' -and (Get-Chk $v 'sender_realtime').value -ceq '0.90 x')
Assert-That 'f2: overall CAUTION, not NO-GO' ($v.overall -ceq 'CAUTION') ('overall = ' + $v.overall)
$bgc = Get-Chk $v 'sw_background'
Assert-That 'f2: Steam/Epic ignored -> sw_background PASS' ($bgc.status -ceq 'PASS' -and $bgc.detail -ceq 'No known background apps (OneDrive, Teams, Discord, browsers) are running. Game launchers are expected on an observer PC.') ($bgc | ConvertTo-Json -Compress)
$hwL.processes = [pscustomobject]@{ running = @('Steam', 'Discord') }
$v = Run-ObsVerdict (Get-Cfg) $hwL (Get-Fx 'sender_ok.json')
$bgc = Get-Chk $v 'sw_background'
Assert-That 'f2: Discord still flagged, Steam left out' ($bgc.status -ceq 'WARN' -and $bgc.value -ceq '1 running' -and $bgc.fix -ceq 'Close: Discord.') ($bgc | ConvertTo-Json -Compress)
$hwL.processes = $null
$v = Run-ObsVerdict (Get-Cfg) $hwL (Get-Fx 'sender_ok.json')
Assert-That 'f2: no process list -> base SKIP kept' ((Get-Chk $v 'sw_background').status -ceq 'SKIP')

# =============================================================================================
Write-Host ''
Write-Host '(g) Hashtable-shaped inputs and malformed inputs' -ForegroundColor Cyan

# Hashtable-shaped inputs work
$cfgHash = @{
    thresholds = @{
        load_speed_min     = 0.97
        sender_cpu_p95     = @{ warn = 70; fail = 90 }
        load_perf_drop_pct = @{ warn = 15 }
        observer_link_mbps = @{ pass = 1000 }
    }
}
$hwHash = @{
    nics = @(
        @{
            name             = 'Ethernet'
            status           = 'Up'
            kind             = 'wired'
            link_mbps        = 1000
            network_category = 'Private'
            eee              = 'off'
        }
    )
    power = @{
        plan        = 'high_performance'
        on_battery  = $false
        battery_pct = $null
    }
    windows = @{
        pending_reboot = $false
    }
    processes = @{
        running = @()
    }
}
$senderHash = @{
    ffmpeg = @{ found = $true }
    stream = @{ speed_min = 1.05; ok = $true; error = $null }
    max_speed = 2.0
    system = @{
        cpu_p95    = 45.0
        cpu_max    = 55.0
        perf_start = 100.0
        perf_min   = 98.0
    }
}

$vHash = $null
$threwHash = $false
try {
    $vHash = Get-SRObserverVerdict -Config $cfgHash -Hardware $hwHash -Sender $senderHash -Now $fixedNow
}
catch {
    $threwHash = $true
}
Assert-That 'g: hashtable-shaped inputs do not throw' (-not $threwHash -and $null -ne $vHash)
if ($null -ne $vHash) {
    Assert-That 'g: hashtable overall is GO' ($vHash.overall -ceq 'GO')
    Assert-That 'g: hashtable produces 11 checks' (@($vHash.checks).Count -eq 11)
}

# Malformed inputs do not throw
$threwBad = $false
$vBad = $null
try {
    $vBad = Get-SRObserverVerdict -Config 'not-a-config' -Hardware 'not-hardware' -Sender 'not-sender'
}
catch {
    $threwBad = $true
}
Assert-That 'g: string inputs where objects expected do not throw' (-not $threwBad -and $null -ne $vBad)
if ($null -ne $vBad) {
    Assert-That 'g: string inputs produce 11 checks' (@($vBad.checks).Count -eq 11)
}

$threwEmpty = $false
$vEmpty = $null
try {
    $vEmpty = Get-SRObserverVerdict -Config @{} -Hardware @{} -Sender @{}
}
catch {
    $threwEmpty = $true
}
Assert-That 'g: empty hashtables do not throw' (-not $threwEmpty -and $null -ne $vEmpty)
if ($null -ne $vEmpty) {
    Assert-That 'g: empty hashtables produce 11 checks' (@($vEmpty.checks).Count -eq 11)
}

$threwGarbage = $false
$vGarbage = $null
try {
    $badHwObj = [pscustomobject]@{ nics = 'garbage'; power = 123; windows = $true; processes = 'none' }
    $badSenderObj = [pscustomobject]@{ ffmpeg = 'bad'; stream = 456; system = 'invalid' }
    $vGarbage = Get-SRObserverVerdict -Config $null -Hardware $badHwObj -Sender $badSenderObj
}
catch {
    $threwGarbage = $true
}
Assert-That 'g: garbage properties do not throw' (-not $threwGarbage -and $null -ne $vGarbage)
if ($null -ne $vGarbage) {
    Assert-That 'g: garbage properties produce 11 checks' (@($vGarbage.checks).Count -eq 11)
}

# No arguments
$threwNoArgs = $false
$vNoArgs = $null
try {
    $vNoArgs = Get-SRObserverVerdict
}
catch {
    $threwNoArgs = $true
}
Assert-That 'g: no arguments at all does not throw' (-not $threwNoArgs -and $null -ne $vNoArgs)

# =============================================================================================
Write-Host ''
Write-Host '=====================================================' -ForegroundColor Cyan
Write-Host ('Summary: {0} passed, {1} failed' -f $script:nPass, $script:nFail) -ForegroundColor $(if ($script:nFail -eq 0) { 'Green' } else { 'Red' })
Write-Host '=====================================================' -ForegroundColor Cyan

if ($script:nFail -eq 0) {
    exit 0
}
else {
    exit 1
}
