# ShowReady - tests\Test-PrepTune.ps1
# Plain PowerShell assertions for lib\Prep.Tune.ps1 (Get-SRPrepTunePlan, Invoke-SRPrepTuneApply, Undo-SRPrepTune).
# Non-elevated, read-only testing. Never mutates system state.
# Run:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Test-PrepTune.ps1
#       pwsh -NoProfile -File tests\Test-PrepTune.ps1
# Pure ASCII source, works on Windows PowerShell 5.1 and pwsh 7.

$ErrorActionPreference = 'Continue'
$testsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$kit = Split-Path -Parent $testsDir
$fixturesDir = Join-Path $kit 'fixtures'

$script:nPass = 0
$script:nFail = 0

function Assert-That {
    param([string]$Name, $Condition, [string]$Detail = '')
    if ($Condition -eq $true) {
        $script:nPass++
        Write-Host ('  PASS  ' + $Name) -ForegroundColor Green
    } else {
        $script:nFail++
        $d = ''
        if ($Detail -ne '') { $d = '  -> ' + $Detail }
        Write-Host ('  FAIL  ' + $Name + $d) -ForegroundColor Red
    }
}

# 1. Dot-source the lib
$libPath = Join-Path $kit 'lib\Prep.Tune.ps1'
Assert-That 'Prep.Tune.ps1 exists' (Test-Path -Path $libPath)
. $libPath

Write-Host "--- TEST GROUP 1: StartupApproved byte decoding and encoding ---" -ForegroundColor Cyan

# Decoding unit tests
$decNull = Get-SRStartupApprovedState $null
Assert-That 'Decode $null is enabled' ($decNull -eq 'enabled')

$decEmpty = Get-SRStartupApprovedState (@())
Assert-That 'Decode empty byte array is enabled' ($decEmpty -eq 'enabled')

$bytes02 = [byte[]]@(0x02, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8)
$dec02 = Get-SRStartupApprovedState $bytes02
Assert-That 'Decode 0x02 is enabled' ($dec02 -eq 'enabled')

$bytes06 = [byte[]]@(0x06, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8)
$dec06 = Get-SRStartupApprovedState $bytes06
Assert-That 'Decode 0x06 is enabled' ($dec06 -eq 'enabled')

$bytes03 = [byte[]]@(0x03, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8)
$dec03 = Get-SRStartupApprovedState $bytes03
Assert-That 'Decode 0x03 is disabled' ($dec03 -eq 'disabled')

$bytes07 = [byte[]]@(0x07, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8)
$dec07 = Get-SRStartupApprovedState $bytes07
Assert-That 'Decode 0x07 is disabled' ($dec07 -eq 'disabled')

# Encoding unit tests
$encoded = New-SRStartupApprovedDisabledBytes
Assert-That 'Encoded disabled bytes length is 12' ($encoded.Length -eq 12)
Assert-That 'Encoded disabled byte 0 is 0x03' ($encoded[0] -eq 3)
Assert-That 'Encoded disabled byte 1 is 0x00' ($encoded[1] -eq 0)
Assert-That 'Encoded disabled byte 2 is 0x00' ($encoded[2] -eq 0)
Assert-That 'Encoded disabled byte 3 is 0x00' ($encoded[3] -eq 0)

$ftPart = [BitConverter]::ToInt64($encoded, 4)
Assert-That 'Encoded filetime is non-zero' ($ftPart -gt 0)

$decBack = Get-SRStartupApprovedState $encoded
Assert-That 'Encoded bytes decode to disabled' ($decBack -eq 'disabled')


Write-Host "--- TEST GROUP 2: powercfg hex parser on fixed samples ---" -ForegroundColor Cyan

$enSamplePath = Join-Path $fixturesDir 'powercfg-sample-en.txt'
Assert-That 'English powercfg fixture exists' (Test-Path -Path $enSamplePath)
$enText = [System.IO.File]::ReadAllText($enSamplePath, [System.Text.Encoding]::UTF8)
$enVals = Get-SRHexAcDcValues $enText
Assert-That 'English sample returns non-null' ($null -ne $enVals)
Assert-That 'English sample AC value is 5' ($enVals.ac_val -eq 5)
Assert-That 'English sample DC value is 5' ($enVals.dc_val -eq 5)

$koSamplePath = Join-Path $fixturesDir 'powercfg-sample-ko.txt'
Assert-That 'Korean powercfg fixture exists' (Test-Path -Path $koSamplePath)
$koText = [System.IO.File]::ReadAllText($koSamplePath, [System.Text.Encoding]::UTF8)
$koVals = Get-SRHexAcDcValues $koText
Assert-That 'Korean sample returns non-null' ($null -ne $koVals)
Assert-That 'Korean sample AC value is 100' ($koVals.ac_val -eq 100)
Assert-That 'Korean sample DC value is 5' ($koVals.dc_val -eq 5)


Write-Host "--- TEST GROUP 3: Get-SRPrepTunePlan for prod and observer ($null settings) ---" -ForegroundColor Cyan

$prodPlan = Get-SRPrepTunePlan -Role 'prod' -Settings $null
Assert-That 'Prod plan returns items' ($prodPlan -and $prodPlan.Count -gt 0)

$observerPlan = Get-SRPrepTunePlan -Role 'observer' -Settings $null
Assert-That 'Observer plan returns items' ($observerPlan -and $observerPlan.Count -gt 0)

$validStatuses = @('OK', 'CHANGE', 'MANUAL', 'INFO', 'ERROR')
$validSections = @('power', 'startup', 'background', 'network', 'capture', 'notifications')

function Validate-PlanItems {
    param([array]$Plan, [string]$PlanName)

    $idSet = [System.Collections.Generic.HashSet[string]]::new()
    $allHaveRequiredFields = $true
    $allStatusesValid = $true
    $allSectionsValid = $true
    $allChangeHaveCommands = $true
    $allRisksValid = $true
    $allBoolsValid = $true

    foreach ($item in $Plan) {
        # Check required fields
        if (-not ($item.PSObject.Properties['id'] -and
                  $item.PSObject.Properties['section'] -and
                  $item.PSObject.Properties['title'] -and
                  $item.PSObject.Properties['status'] -and
                  $item.PSObject.Properties['current'] -and
                  $item.PSObject.Properties['target'] -and
                  $item.PSObject.Properties['detail'] -and
                  $item.PSObject.Properties['risk'] -and
                  $item.PSObject.Properties['needs_reboot'] -and
                  $item.PSObject.Properties['needs_admin'] -and
                  $item.PSObject.Properties['default_apply'] -and
                  $item.PSObject.Properties['commands'] -and
                  $item.PSObject.Properties['undo'])) {
            $allHaveRequiredFields = $false
        }

        # Status
        if ($item.status -notin $validStatuses) {
            $allStatusesValid = $false
        }

        # Section
        if ($item.section -notin $validSections) {
            $allSectionsValid = $false
        }

        # Risk
        if ($item.risk -notin @('low', 'medium')) {
            $allRisksValid = $false
        }

        # Bools
        if ($item.needs_reboot -isnot [bool] -or $item.needs_admin -isnot [bool] -or $item.default_apply -isnot [bool]) {
            $allBoolsValid = $false
        }

        # CHANGE items must have commands
        if ($item.status -eq 'CHANGE') {
            if ($null -eq $item.commands -or $item.commands.Count -eq 0) {
                $allChangeHaveCommands = $false
            }
        }

        # Track IDs
        [void]$idSet.Add($item.id)
    }

    Assert-That "$PlanName : all items have required contract fields" $allHaveRequiredFields
    Assert-That "$PlanName : all statuses valid" $allStatusesValid
    Assert-That "$PlanName : all sections valid" $allSectionsValid
    Assert-That "$PlanName : all risks valid ('low' or 'medium')" $allRisksValid
    Assert-That "$PlanName : boolean fields are valid bools" $allBoolsValid
    Assert-That "$PlanName : all CHANGE items have commands" $allChangeHaveCommands
    Assert-That "$PlanName : item IDs are unique" ($idSet.Count -eq $Plan.Count) ("Found $($idSet.Count) unique IDs across $($Plan.Count) items")
}

Validate-PlanItems -Plan $prodPlan -PlanName "Prod Plan"
Validate-PlanItems -Plan $observerPlan -PlanName "Observer Plan"

# Assert observer plan never contains close_prod_only_patterns or never_close_patterns
$closeProdOnlyRegex = '^(steam|steamwebhelper|EpicGamesLauncher|EpicWebHelper|Battle\.net|RiotClientServices|RiotClientUx|RiotClientUxRender|LeagueClient|LeagueClientUx|Origin|EADesktop|upc|GalaxyClient)$'
$neverCloseRegex = '^(System|Idle|smss|csrss|wininit|winlogon|services|lsass|svchost|explorer|dwm|fontdrvhost|sihost|ctfmon|RuntimeBroker|SearchHost|StartMenuExperienceHost|ShellExperienceHost|TextInputHost|SecurityHealth.*|MsMpEng|NisSrv|powershell|pwsh|cmd|conhost|WindowsTerminal|OpenConsole|ffmpeg|iperf3|vMix.*|obs64|obs32|NDI.*|OMT.*|AnyDesk|TeamViewer.*|parsecd|rustdesk|vgtray|vgc|FACEIT.*|EasyAntiCheat.*|BEService.*|League of Legends|VALORANT.*|cs2|dota2)$'

$obsBgItems = @($observerPlan | Where-Object { $_.section -eq 'background' })
$obsHasProdOnly = $false
$obsHasNeverClose = $false
foreach ($bg in $obsBgItems) {
    $procName = $bg.id.Substring(16)
    if ($procName -match $closeProdOnlyRegex) { $obsHasProdOnly = $true }
    if ($procName -match $neverCloseRegex) { $obsHasNeverClose = $true }
}
Assert-That 'Observer plan never contains close_prod_only items' (-not $obsHasProdOnly)
Assert-That 'Observer plan never contains never_close items' (-not $obsHasNeverClose)


Write-Host "--- TEST GROUP 4: Get-SRPrepTunePlan with settings object ---" -ForegroundColor Cyan

$customSettings = [pscustomobject]@{
    startup       = [pscustomobject]@{
        keep_patterns    = '.*'
        disable_patterns = '.*'
    }
    notifications = [pscustomobject]@{
        disable_toasts = $false
    }
    network       = [pscustomobject]@{
        offer_disable_wifi_when_wired    = $false
        offer_disable_virtual_adapters = $false
    }
    power         = [pscustomobject]@{
        prefer = 'ultimate'
    }
}

$planWithSettings = Get-SRPrepTunePlan -Role 'prod' -Settings $customSettings
Assert-That 'Plan with custom settings returned items' ($planWithSettings -and $planWithSettings.Count -gt 0)

$notifItem = $planWithSettings | Where-Object { $_.id -eq 'tune_notifications' }
Assert-That 'disable_toasts=false turns tune_notifications into INFO' ($notifItem -and $notifItem.status -eq 'INFO')


Write-Host "--- TEST GROUP 5: Invoke-SRPrepTuneApply -DryRun safety and SKIPPED status ---" -ForegroundColor Cyan

# Gather current state before dry-run
$actBefore = Invoke-SRPowercfg '/getactivescheme'
$guidBefore = $null
if ($actBefore.StdOut -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
    $guidBefore = $matches[1].ToLower()
}

$runPropBefore = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' -ErrorAction SilentlyContinue

$changeItems = @($prodPlan | Where-Object { $_.status -eq 'CHANGE' })
Assert-That 'Plan has CHANGE items to test DryRun' ($changeItems.Count -gt 0)

$dryRunLogs = [System.Collections.Generic.List[string]]::new()
$logBlock = { param($msg) $dryRunLogs.Add($msg) }

$testBackupDir = Join-Path $env:TEMP "sr-tune-test-backup-$(Get-Random)"
if (-not (Test-Path -Path $testBackupDir)) {
    [void](New-Item -ItemType Directory -Path $testBackupDir -Force)
}

$appliedItems = Invoke-SRPrepTuneApply -Items $changeItems -DryRun -BackupDir $testBackupDir -Log $logBlock

Assert-That 'Apply DryRun returned same count of items' ($appliedItems.Count -eq $changeItems.Count)

$allSkipped = $true
$allDetailDryRun = $true
foreach ($ai in $appliedItems) {
    if ($ai.status -ne 'SKIPPED') { $allSkipped = $false }
    if ($ai.detail -ne 'dry run') { $allDetailDryRun = $false }
}
Assert-That 'All Apply DryRun items have status SKIPPED' $allSkipped
Assert-That 'All Apply DryRun items have detail dry run' $allDetailDryRun

$allLogsDryRun = $true
foreach ($l in $dryRunLogs) {
    if (-not $l.StartsWith('DRYRUN: ')) { $allLogsDryRun = $false }
}
Assert-That 'All logged lines start with DRYRUN: ' ($allLogsDryRun -and $dryRunLogs.Count -gt 0)

# Verify system state is unchanged
$actAfter = Invoke-SRPowercfg '/getactivescheme'
$guidAfter = $null
if ($actAfter.StdOut -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
    $guidAfter = $matches[1].ToLower()
}
Assert-That 'Active power scheme GUID is unchanged after DryRun' ($guidBefore -eq $guidAfter)

$runPropAfter = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' -ErrorAction SilentlyContinue
$startupApprovedUnchanged = $true
if ($runPropBefore -and $runPropAfter) {
    foreach ($p in $runPropBefore.Property) {
        $b1 = $runPropBefore.GetValue($p)
        $b2 = $runPropAfter.GetValue($p)
        if ($b1 -is [byte[]] -and $b2 -is [byte[]]) {
            if ([BitConverter]::ToString($b1) -ne [BitConverter]::ToString($b2)) {
                $startupApprovedUnchanged = $false
            }
        }
    }
}
Assert-That 'StartupApproved registry entries are unchanged after DryRun' $startupApprovedUnchanged


Write-Host "--- TEST GROUP 6: Undo-SRPrepTune -DryRun ---" -ForegroundColor Cyan

# Create mock tune-undo.json in test backup dir
$mockUndo = @(
    [pscustomobject]@{
        id      = 'tune_power'
        section = 'power'
        title   = 'Power scheme and AC settings'
        undo    = [pscustomobject]@{
            previous_active_guid = '381b4222-f694-41f0-9685-ff5bb260df2e'
            created_guid         = '11111111-2222-3333-4444-555555555555'
            previous_ac_values   = [pscustomobject]@{
                standby_timeout   = 1800
                hibernate_timeout = 3600
                monitor_timeout   = 900
                disk_timeout      = 1200
                usb_suspend       = 1
                pcie_link_state   = 0
                min_proc_state    = 5
            }
        }
    },
    [pscustomobject]@{
        id      = 'tune_startup:MockApp'
        section = 'startup'
        title   = 'Startup app: MockApp'
        undo    = [pscustomobject]@{
            type         = 'startup_approved'
            approved_key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
            name         = 'MockApp'
            previous_val = 'AgAAAAAAAAAAAAAA'
        }
    }
)

$undoJsonPath = Join-Path $testBackupDir 'tune-undo.json'
Set-Content -Path $undoJsonPath -Value ($mockUndo | ConvertTo-Json -Depth 10) -Force

$undoDryLogs = [System.Collections.Generic.List[string]]::new()
$undoLogBlock = { param($msg) $undoDryLogs.Add($msg) }

$undoneItems = Undo-SRPrepTune -BackupDir $testBackupDir -DryRun -Log $undoLogBlock
Assert-That 'Undo DryRun returned 2 items' ($undoneItems.Count -eq 2)

$undoAllSkipped = $true
foreach ($ui in $undoneItems) {
    if ($ui.status -ne 'SKIPPED') { $undoAllSkipped = $false }
}
Assert-That 'All Undo DryRun items have status SKIPPED' $undoAllSkipped

$allUndoLogsDry = $true
foreach ($ul in $undoDryLogs) {
    if (-not $ul.StartsWith('DRYRUN: ')) { $allUndoLogsDry = $false }
}
Assert-That 'All Undo DryRun logs start with DRYRUN: ' ($allUndoLogsDry -and $undoDryLogs.Count -gt 0)

# Clean up test temp backup dir
Remove-Item -Path $testBackupDir -Recurse -Force -ErrorAction SilentlyContinue


Write-Host "--- TEST GROUP 7: Save real plans to fixtures ---" -ForegroundColor Cyan

$fixtureProdPath = Join-Path $fixturesDir 'prep-tune-plan-prod.json'
$fixtureObsPath = Join-Path $fixturesDir 'prep-tune-plan-observer.json'

$prodJson = $prodPlan | ConvertTo-Json -Depth 10
Set-Content -Path $fixtureProdPath -Value $prodJson -Force
Assert-That 'prep-tune-plan-prod.json created' (Test-Path -Path $fixtureProdPath)

$obsJson = $observerPlan | ConvertTo-Json -Depth 10
Set-Content -Path $fixtureObsPath -Value $obsJson -Force
Assert-That 'prep-tune-plan-observer.json created' (Test-Path -Path $fixtureObsPath)

# Validate fixture JSON readable
$testReadProd = [System.IO.File]::ReadAllText($fixtureProdPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
Assert-That 'prep-tune-plan-prod.json valid JSON' ($testReadProd.Count -eq $prodPlan.Count)

$testReadObs = [System.IO.File]::ReadAllText($fixtureObsPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
Assert-That 'prep-tune-plan-observer.json valid JSON' ($testReadObs.Count -eq $observerPlan.Count)


Write-Host ""
Write-Host "Test Results: $script:nPass passed, $script:nFail failed." -ForegroundColor $(if ($script:nFail -eq 0) { 'Green' } else { 'Red' })

if ($script:nFail -eq 0) {
    Write-Host 'ALL PREP TUNE TESTS PASSED' -ForegroundColor Green
    exit 0
} else {
    Write-Host 'SOME PREP TUNE TESTS FAILED' -ForegroundColor Red
    exit 1
}
