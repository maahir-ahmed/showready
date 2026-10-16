# ShowReady - tests\Test-PrepSystem.ps1
# Plain PowerShell assertions (no Pester) for lib\Prep.System.ps1
# Non-elevated, read-only tests.
# Run:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Test-PrepSystem.ps1
#       pwsh -NoProfile -File tests\Test-PrepSystem.ps1
# Exit code 0 = all assertions passed, 1 = at least one failed. Pure ASCII, works on Windows PowerShell 5.1 and pwsh.

$ErrorActionPreference = 'Continue'
$testsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$kitRoot = Split-Path -Parent $testsDir
$libPath = Join-Path $kitRoot 'lib\Prep.System.ps1'
$fixturesDir = Join-Path $kitRoot 'fixtures'

$script:nPass = 0
$script:nFail = 0

function Assert-That {
    param(
        [string]$Name,
        $Condition,
        [string]$Detail = ''
    )
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

Write-Host ''
Write-Host 'ShowReady Prep System tests' -ForegroundColor Cyan
Write-Host ('  PowerShell ' + $PSVersionTable.PSVersion.ToString()) -ForegroundColor DarkGray

# =============================================================================================
# 1. Dot-sourcing and pure ASCII check
# =============================================================================================
Write-Host '1: Dot-sourcing and code checks' -ForegroundColor Cyan
$dotOut = @(. $libPath)
Assert-That '1.1: Dot-sourcing Prep.System.ps1 emits no stdout output' ($dotOut.Count -eq 0) ('output count: ' + $dotOut.Count)
Assert-That '1.2: Get-SRPrepSystemPlan is defined' ($null -ne (Get-Command Get-SRPrepSystemPlan -CommandType Function -ErrorAction SilentlyContinue))
Assert-That '1.3: Invoke-SRPrepSystemApply is defined' ($null -ne (Get-Command Invoke-SRPrepSystemApply -CommandType Function -ErrorAction SilentlyContinue))
Assert-That '1.4: Undo-SRPrepSystem is defined' ($null -ne (Get-Command Undo-SRPrepSystem -CommandType Function -ErrorAction SilentlyContinue))
Assert-That '1.5: Test-SRPrepPerUserMismatch is defined' ($null -ne (Get-Command Test-SRPrepPerUserMismatch -CommandType Function -ErrorAction SilentlyContinue))

$src = [System.IO.File]::ReadAllText($libPath)
Assert-That '1.6: Prep.System.ps1 is pure ASCII' (-not [regex]::IsMatch($src, '[^\x00-\x7F]'))

# =============================================================================================
# 2. Helper unit tests: NVIDIA version converter, pause time, mismatch
# =============================================================================================
Write-Host '2: Helper unit tests' -ForegroundColor Cyan

# NVIDIA version tests from task specification:
# '32.0.15.7270' -> '572.70', '31.0.15.5244' -> '552.44', '32.0.16.1062' -> '610.62'
$nv1 = Convert-SRNvidiaDriverVersion '32.0.15.7270'
Assert-That '2.1: Convert-SRNvidiaDriverVersion 32.0.15.7270 -> 572.70' ($nv1 -eq '572.70') ("Got: $nv1")

$nv2 = Convert-SRNvidiaDriverVersion '31.0.15.5244'
Assert-That '2.2: Convert-SRNvidiaDriverVersion 31.0.15.5244 -> 552.44' ($nv2 -eq '552.44') ("Got: $nv2")

$nv3 = Convert-SRNvidiaDriverVersion '32.0.16.1062'
Assert-That '2.3: Convert-SRNvidiaDriverVersion 32.0.16.1062 -> 610.62' ($nv3 -eq '610.62') ("Got: $nv3")

$nvEmpty = Convert-SRNvidiaDriverVersion ''
Assert-That '2.4: Convert-SRNvidiaDriverVersion empty returns null' ($null -eq $nvEmpty)

# Pause-time formatting test
$testDt = [DateTime]::SpecifyKind([DateTime]'2026-10-16 14:00:00', [DateTimeKind]::Utc)
$pauseStr = Format-SRPauseTime $testDt
Assert-That '2.5: Format-SRPauseTime outputs exact yyyy-MM-ddTHH:mm:ssZ' ($pauseStr -eq '2026-10-16T14:00:00Z') ("Got: $pauseStr")

$parsedBack = [DateTime]::ParseExact($pauseStr, 'yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal)
Assert-That '2.6: Pause-time round-trip parses successfully' ($parsedBack.ToUniversalTime() -eq $testDt)

# Mismatch helper returns a bool
$mismatchVal = Test-SRPrepPerUserMismatch
Assert-That '2.7: Test-SRPrepPerUserMismatch returns a boolean' ($mismatchVal -is [bool]) ("Got type: $($mismatchVal.GetType().FullName)")

# =============================================================================================
# 3. Plan with $null settings
# =============================================================================================
Write-Host '3: Get-SRPrepSystemPlan with $null settings' -ForegroundColor Cyan

$planLog = [System.Collections.Generic.List[string]]::new()
$logSb = { param($msg) $planLog.Add($msg) }

$planNull = Get-SRPrepSystemPlan -Settings $null -Role 'prod' -Log $logSb
Assert-That '3.1: Plan with $null settings returns an array' ($planNull -is [System.Array])
Assert-That '3.2: Plan contains items' ($planNull.Count -gt 0) ("Count: $($planNull.Count)")

$validSections = @('language', 'drivers', 'disk', 'updates', 'reboot', 'power', 'startup', 'background', 'network', 'capture', 'notifications')
$validStatuses = @('OK', 'CHANGE', 'MANUAL', 'INFO', 'ERROR')
$validRisks    = @('low', 'medium')

$schemaOk = $true
$statusOk = $true
$sectionOk = $true
$riskOk = $true
$typesOk = $true
$changeHasCmds = $true

$ids = [System.Collections.Generic.List[string]]::new()

foreach ($item in $planNull) {
    $ids.Add($item.id)

    # Check 13 schema fields
    $fields = @('id', 'section', 'title', 'status', 'current', 'target', 'detail', 'risk', 'needs_reboot', 'needs_admin', 'default_apply', 'commands', 'undo')
    foreach ($f in $fields) {
        if ($null -eq $item.PSObject.Properties[$f]) {
            $schemaOk = $false
        }
    }

    if ($validStatuses -notcontains $item.status) { $statusOk = $false }
    if ($validSections -notcontains $item.section) { $sectionOk = $false }
    if ($validRisks -notcontains $item.risk) { $riskOk = $false }
    if ($item.needs_reboot -isnot [bool] -or $item.needs_admin -isnot [bool] -or $item.default_apply -isnot [bool]) {
        $typesOk = $false
    }
    if ($item.status -eq 'CHANGE' -and (@($item.commands).Count -eq 0)) {
        $changeHasCmds = $false
    }
}

Assert-That '3.3: Every item has all 13 schema fields' $schemaOk
Assert-That '3.4: Every item has valid section' $sectionOk
Assert-That '3.5: Every item has valid plan status' $statusOk
Assert-That '3.6: Every item has valid risk' $riskOk
Assert-That '3.7: Boolean fields are true booleans' $typesOk
Assert-That '3.8: No item has status CHANGE without commands' $changeHasCmds

# Unique IDs
$uniqueIds = @($ids | Select-Object -Unique)
Assert-That '3.9: Item IDs are unique' ($ids.Count -eq $uniqueIds.Count) ("Total: $($ids.Count), Unique: $($uniqueIds.Count)")

# Expected core items presence
$itemIdsStr = $ids -join ', '
Assert-That '3.10: sys_admin item exists' ($ids -contains 'sys_admin') ("IDs: $itemIdsStr")
Assert-That '3.11: sys_language item exists' ($ids -contains 'sys_language')
Assert-That '3.12: sys_disk item exists' ($ids -contains 'sys_disk')
Assert-That '3.13: sys_reboot item exists' ($ids -contains 'sys_reboot')
Assert-That '3.14: sys_wu_pause item exists' ($ids -contains 'sys_wu_pause')

# =============================================================================================
# 4. Plan with custom settings object
# =============================================================================================
Write-Host '4: Get-SRPrepSystemPlan with custom settings object' -ForegroundColor Cyan

$customSettings = [pscustomobject]@{
    language = [pscustomobject]@{
        ui         = 'en-US'
        keep_input = @('ko-KR', 'ja-JP')
    }
    disk     = [pscustomobject]@{
        warn_gb = 100
        fail_gb = 50
    }
    updates  = [pscustomobject]@{
        pause_days = 14
    }
    drivers  = [pscustomobject]@{
        nvidia_min  = '572.00'
        max_age_days = 180
    }
}

$planCustom = Get-SRPrepSystemPlan -Settings $customSettings -Role 'prod'
Assert-That '4.1: Custom plan returns an array' ($planCustom -is [System.Array])
Assert-That '4.2: Custom plan items count > 0' ($planCustom.Count -gt 0)

$customDisk = $planCustom | Where-Object { $_.id -eq 'sys_disk' }
Assert-That '4.3: Custom plan disk target reflects warn_gb threshold (100 GB)' ($customDisk.target -match '100') ("Target: $($customDisk.target)")

$customPause = $planCustom | Where-Object { $_.id -eq 'sys_wu_pause' }
Assert-That '4.4: Custom plan updates pause target reflects pause_days (14 days)' ($customPause.target -match '14') ("Target: $($customPause.target)")

$customSchemaOk = $true
$customIds = [System.Collections.Generic.List[string]]::new()
foreach ($ci in $planCustom) {
    $customIds.Add($ci.id)
    if ($validStatuses -notcontains $ci.status -or $validSections -notcontains $ci.section) {
        $customSchemaOk = $false
    }
    if ($ci.status -eq 'CHANGE' -and (@($ci.commands).Count -eq 0)) {
        $customSchemaOk = $false
    }
}
$customUniqueIds = @($customIds | Select-Object -Unique)
Assert-That '4.5: Custom plan items have valid schema and unique IDs' ($customSchemaOk -and ($customIds.Count -eq $customUniqueIds.Count))

# =============================================================================================
# 5. Invoke-SRPrepSystemApply -DryRun safety tests
# =============================================================================================
Write-Host '5: Invoke-SRPrepSystemApply -DryRun safety verification' -ForegroundColor Cyan

# Read initial system state before DryRun
$initialLangOverride = try { (Get-WinUILanguageOverride) } catch { '' }
$uxPath = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
$initialPauseExpiry = try { (Get-ItemProperty -Path $uxPath -ErrorAction SilentlyContinue).PauseUpdatesExpiryTime } catch { '' }
$initialPauseStart = try { (Get-ItemProperty -Path $uxPath -ErrorAction SilentlyContinue).PauseUpdatesStartTime } catch { '' }

# Select plan's CHANGE items, or create synthetic CHANGE item if none
$changeItems = @($planNull | Where-Object { $_.status -eq 'CHANGE' })
if ($changeItems.Count -eq 0) {
    $changeItems = @(
        (New-SRPrepItem -Id 'sys_wu_pause' -Section 'updates' -Title 'Pause Windows Update' `
            -Status 'CHANGE' -Current 'Not paused' -Target 'Pause for 7 days' `
            -Detail 'Dry run test change' -Commands @("Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' -Name 'PauseUpdatesStartTime' -Value '2026-10-16T14:00:00Z'") `
            -Undo $null)
    )
}

$dryLog = [System.Collections.Generic.List[string]]::new()
$dryLogSb = { param($msg) $dryLog.Add($msg) }
$tempBackupDir = Join-Path $env:TEMP ("sr-prep-test-backup-" + [Guid]::NewGuid().ToString('N'))

$applied = Invoke-SRPrepSystemApply `
    -Items $changeItems `
    -Settings $null `
    -BackupDir $tempBackupDir `
    -DryRun `
    -Log $dryLogSb

Assert-That '5.1: Apply -DryRun returns results' ($applied.Count -gt 0) ("Applied count: $($applied.Count)")

$allSkipped = $true
$allDryDetail = $true
foreach ($ap in $applied) {
    if ($ap.status -ne 'SKIPPED') { $allSkipped = $false }
    if ($ap.detail -ne 'dry run') { $allDryDetail = $false }
}
Assert-That '5.2: Apply -DryRun sets all item statuses to SKIPPED' $allSkipped
Assert-That '5.3: Apply -DryRun sets detail to "dry run"' $allDryDetail

# Assert all logged command messages have DRYRUN: prefix
$allDryrunPrefix = $true
$hasDryrunLogs = ($dryLog.Count -gt 0)
foreach ($msg in $dryLog) {
    if (-not $msg.StartsWith('DRYRUN: ')) {
        $allDryrunPrefix = $false
    }
}
Assert-That '5.4: Apply -DryRun emits DRYRUN: prefixed log lines' ($hasDryrunLogs -and $allDryrunPrefix) ("Log count: $($dryLog.Count)")

# Assert system state is UNCHANGED before vs after
$afterLangOverride = try { (Get-WinUILanguageOverride) } catch { '' }
$afterPauseExpiry = try { (Get-ItemProperty -Path $uxPath -ErrorAction SilentlyContinue).PauseUpdatesExpiryTime } catch { '' }
$afterPauseStart = try { (Get-ItemProperty -Path $uxPath -ErrorAction SilentlyContinue).PauseUpdatesStartTime } catch { '' }

Assert-That '5.5: UI Language override unchanged after DryRun' ($initialLangOverride -eq $afterLangOverride)
Assert-That '5.6: WU PauseUpdatesExpiryTime unchanged after DryRun' ($initialPauseExpiry -eq $afterPauseExpiry)
Assert-That '5.7: WU PauseUpdatesStartTime unchanged after DryRun' ($initialPauseStart -eq $afterPauseStart)

# Clean up temp backup dir if created
if (Test-Path $tempBackupDir) {
    Remove-Item -Path $tempBackupDir -Recurse -Force -ErrorAction SilentlyContinue
}

# =============================================================================================
# 6. Undo-SRPrepSystem -DryRun safety tests
# =============================================================================================
Write-Host '6: Undo-SRPrepSystem -DryRun safety verification' -ForegroundColor Cyan

$tempUndoDir = Join-Path $env:TEMP ("sr-prep-test-undo-" + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $tempUndoDir -Force -ErrorAction SilentlyContinue

$fakeUndoList = @(
    [pscustomobject]@{
        id        = 'sys_wu_pause'
        section   = 'updates'
        undo      = [pscustomobject]@{
            PauseUpdatesStartTime        = 'absent'
            PauseUpdatesExpiryTime       = 'absent'
            PauseFeatureUpdatesStartTime = 'absent'
            PauseFeatureUpdatesEndTime   = 'absent'
            PauseQualityUpdatesStartTime = 'absent'
            PauseQualityUpdatesEndTime   = 'absent'
        }
        timestamp = [DateTime]::UtcNow.ToString('o')
    },
    [pscustomobject]@{
        id        = 'sys_language'
        section   = 'language'
        undo      = [pscustomobject]@{
            win_ui_language_override      = 'en-US'
            user_language_list_tags       = @('en-US', 'ko-KR')
            system_preferred_ui_language  = 'en-US'
        }
        timestamp = [DateTime]::UtcNow.ToString('o')
    }
)
$fakeUndoJson = ConvertTo-Json -InputObject $fakeUndoList -Depth 10
Set-Content -Path (Join-Path $tempUndoDir 'system-undo.json') -Value $fakeUndoJson -Encoding ASCII -Force

$undoLog = [System.Collections.Generic.List[string]]::new()
$undoLogSb = { param($msg) $undoLog.Add($msg) }

$undone = Undo-SRPrepSystem -BackupDir $tempUndoDir -DryRun -Log $undoLogSb
Assert-That '6.1: Undo-SRPrepSystem -DryRun returns undone items' ($undone.Count -eq 2) ("Count: $($undone.Count)")

$undoAllSkipped = $true
$undoAllDryrunLogs = ($undoLog.Count -gt 0)
foreach ($uItem in $undone) {
    if ($uItem.status -ne 'SKIPPED') { $undoAllSkipped = $false }
}
foreach ($uMsg in $undoLog) {
    if (-not $uMsg.StartsWith('DRYRUN: ')) { $undoAllDryrunLogs = $false }
}
Assert-That '6.2: Undo-SRPrepSystem -DryRun sets status to SKIPPED' $undoAllSkipped
Assert-That '6.3: Undo-SRPrepSystem -DryRun logs only DRYRUN: lines' $undoAllDryrunLogs
# Verify reverse order: sys_language restored first, then sys_wu_pause
Assert-That '6.4: Undo restores items in reverse order of undo file' ($undone[0].id -eq 'sys_language' -and $undone[1].id -eq 'sys_wu_pause')

Remove-Item -Path $tempUndoDir -Recurse -Force -ErrorAction SilentlyContinue

# =============================================================================================
# 7. Fixture generation: Save plan to fixtures\prep-system-plan.json
# =============================================================================================
Write-Host '7: Fixture generation' -ForegroundColor Cyan

if (-not (Test-Path $fixturesDir)) {
    $null = New-Item -ItemType Directory -Path $fixturesDir -Force -ErrorAction SilentlyContinue
}
$fixtureFile = Join-Path $fixturesDir 'prep-system-plan.json'
$planJson = ConvertTo-Json -InputObject @($planNull) -Depth 6
Set-Content -Path $fixtureFile -Value $planJson -Encoding ASCII -Force

Assert-That '7.1: Fixture file fixtures\prep-system-plan.json created' (Test-Path $fixtureFile)
$fixtureContent = Get-Content -Path $fixtureFile -Raw -Encoding ASCII
Assert-That '7.2: Fixture is non-empty valid JSON' ($fixtureContent.Length -gt 50 -and (-not [string]::IsNullOrEmpty((ConvertFrom-Json $fixtureContent))))

# =============================================================================================
# Test Summary
# =============================================================================================
Write-Host ''
Write-Host "Prep System Test Results: $($script:nPass) passed, $($script:nFail) failed" -ForegroundColor $(if ($script:nFail -eq 0) { 'Green' } else { 'Red' })

if ($script:nFail -eq 0) {
    Write-Host 'ALL PREP SYSTEM TESTS PASSED' -ForegroundColor Green
    exit 0
} else {
    Write-Host 'SOME PREP SYSTEM TESTS FAILED' -ForegroundColor Red
    exit 1
}
