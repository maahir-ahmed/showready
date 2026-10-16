<#
.SYNOPSIS
    ShowReady Prep - Tune Module (lib\Prep.Tune.ps1)
.DESCRIPTION
    Tuning optimizations for esports broadcast PCs:
    power schemes, startup apps, background processes, network adapters,
    capture/GameDVR settings, and toast notifications.
    Complies with ShowReady CONTRACT.md and PREP-CONTRACT.md.
    Supports Windows PowerShell 5.1 and pwsh 7.
#>

# Built-in default patterns (verbatim from specification)
$script:DefaultKeepPatterns = 'SecurityHealth|Windows ?Defender|MsMpEng|AhnLab V3|V3 ?Lite|V3UI|V3L|ESET|egui|Kaspersky|avp\.exe|Norton|McAfee|Bitdefender|Avast|AVG|Malwarebytes|RtkAud|Realtek|RTHDVCPL|Waves|MaxxAudio|Nahimic|Dolby|Sonic ?Studio|NVIDIA|NvContainer|AMD|Radeon|IGCC|igfx|Intel\(R\) Graphics|Synaptics|ELAN|Logitech|LGHUB|Razer|SteelSeries|Corsair|iCUE|Wooting|Bluetooth|ctfmon|IME|NDI|\bOMT\b|vMix|obs64|OBS Studio|Elgato|Stream ?Deck|Blackmagic|Desktop Video|Magewell|AJA|AnyDesk|TeamViewer|Parsec|RustDesk|Splashtop|Chrome Remote|vgtray|Vanguard|FACEIT|EasyAntiCheat|BattlEye|BEService'
$script:DefaultDisablePatterns = '.*'
$script:DefaultClosePatterns = '^(chrome|msedge|firefox|whale|opera|brave|OneDrive|Teams|ms-teams|Spotify|Dropbox|GoogleDriveFS|iCloudDrive|iCloudServices|CCXProcess|Creative Cloud|AdobeIPCBroker|Acrobat|AcroCEF|KakaoTalk|LINE|Skype|Zoom|Everything|GoogleUpdate|MicrosoftEdgeUpdate|AdobeARM|jusched|nProtect.*|npkcmsvc|TouchEn.*|Veraport.*|IPinside.*|Delfino.*|Wizvera.*|CrossEX.*|INISAFE.*|MagicLine.*|KeySharp.*|AnySign.*|ASTx.*)$'
$script:DefaultCloseProdOnlyPatterns = '^(steam|steamwebhelper|EpicGamesLauncher|EpicWebHelper|Battle\.net|RiotClientServices|RiotClientUx|RiotClientUxRender|LeagueClient|LeagueClientUx|Origin|EADesktop|upc|GalaxyClient)$'
$script:DefaultAskPatterns = '^(Discord|Slack|WhatsApp|Telegram|KakaoTalk)$'
$script:DefaultNeverClosePatterns = '^(System|Idle|smss|csrss|wininit|winlogon|services|lsass|svchost|explorer|dwm|fontdrvhost|sihost|ctfmon|RuntimeBroker|SearchHost|StartMenuExperienceHost|ShellExperienceHost|TextInputHost|SecurityHealth.*|MsMpEng|NisSrv|powershell|pwsh|cmd|conhost|WindowsTerminal|OpenConsole|ffmpeg|iperf3|vMix.*|obs64|obs32|NDI.*|OMT.*|AnyDesk|TeamViewer.*|parsecd|rustdesk|vgtray|vgc|FACEIT.*|EasyAntiCheat.*|BEService.*|League of Legends|VALORANT.*|cs2|dota2)$'
$script:DefaultOfferDisableWifi = $true
$script:DefaultOfferDisableVirtual = $true
$script:DefaultDisableToasts = $true
$script:DefaultPowerPrefer = 'ultimate'

$script:HighPerfGuid = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
$script:UltimateGuid = 'e9a42b02-d5df-448d-aa00-03f14749eb61'

function Test-SRLocalPerUserMismatch {
    if (Get-Command -Name 'Test-SRPrepPerUserMismatch' -ErrorAction SilentlyContinue) {
        return (Test-SRPrepPerUserMismatch)
    }
    try {
        $current = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
        $console = $null
        if ($cs -and $cs.UserName) { $console = $cs.UserName }
        if ($console -and $current -and ($console.Trim() -ne $current.Trim())) {
            return $true
        }
    } catch { }
    return $false
}

function Get-SRSettingValue {
    param($Obj, [string]$Path, $DefaultValue)
    if ($null -eq $Obj) { return $DefaultValue }
    $parts = $Path.Split('.')
    $curr = $Obj
    foreach ($p in $parts) {
        if ($null -eq $curr) { return $DefaultValue }
        if ($curr -is [System.Collections.IDictionary]) {
            if ($curr.Contains($p)) { $curr = $curr[$p] } else { return $DefaultValue }
        } elseif ($curr.PSObject -and $curr.PSObject.Properties[$p]) {
            $curr = $curr.$p
        } else {
            return $DefaultValue
        }
    }
    if ($null -eq $curr) { return $DefaultValue }
    return $curr
}

function Get-SRHexAcDcValues {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $null }
    $regexMatches = [regex]::Matches($Text, '0x[0-9a-fA-F]{8}')
    if ($regexMatches.Count -lt 2) { return $null }
    $acHex = $regexMatches[$regexMatches.Count - 2].Value
    $dcHex = $regexMatches[$regexMatches.Count - 1].Value
    return [pscustomobject]@{
        ac_hex = $acHex
        dc_hex = $dcHex
        ac_val = [Convert]::ToInt32($acHex, 16)
        dc_val = [Convert]::ToInt32($dcHex, 16)
    }
}

function Get-SRStartupApprovedState {
    param([byte[]]$Bytes)
    if ($null -eq $Bytes -or $Bytes.Length -eq 0) {
        return 'enabled'
    }
    $b0 = [int]$Bytes[0]
    if ($b0 -eq 0x02 -or $b0 -eq 0x06) {
        return 'enabled'
    }
    if ($b0 -eq 0x03 -or $b0 -eq 0x07) {
        return 'disabled'
    }
    if (($b0 -band 1) -eq 1) {
        return 'disabled'
    }
    return 'enabled'
}

function New-SRStartupApprovedDisabledBytes {
    $nowUtc = [DateTime]::UtcNow.ToFileTimeUtc()
    $ftBytes = [BitConverter]::GetBytes($nowUtc)
    $res = New-Object byte[] 12
    $res[0] = [byte]0x03
    $res[1] = [byte]0x00
    $res[2] = [byte]0x00
    $res[3] = [byte]0x00
    [Array]::Copy($ftBytes, 0, $res, 4, 8)
    return $res
}

function Invoke-SRPowercfg {
    param([string]$Arguments)
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'powercfg.exe'
        $psi.Arguments = $Arguments
        $psi.WorkingDirectory = $env:TEMP
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        return [pscustomobject]@{
            ExitCode = $proc.ExitCode
            StdOut   = $stdout
            StdErr   = $stderr
        }
    } catch {
        return [pscustomobject]@{
            ExitCode = -1
            StdOut   = ''
            StdErr   = $_.Exception.Message
        }
    }
}

function Get-SRRegistryDwordValue {
    param([string]$Path, [string]$Name)
    try {
        if (Test-Path -Path $Path) {
            $p = Get-ItemProperty -Path $Path -ErrorAction SilentlyContinue
            if ($p -and $p.PSObject.Properties[$Name]) {
                return $p.$Name
            }
        }
    } catch { }
    return $null
}

function New-SRPrepItem {
    param(
        [string]$Id,
        [string]$Section,
        [string]$Title,
        [string]$Status,
        [string]$Current,
        [string]$Target,
        [string]$Detail,
        [string]$Risk = 'low',
        [bool]$NeedsReboot = $false,
        [bool]$NeedsAdmin = $false,
        [bool]$DefaultApply = $true,
        [string[]]$Commands = @(),
        $Undo = $null
    )
    if ($null -eq $Commands) { $Commands = @() }
    return [pscustomobject]@{
        id             = $Id
        section        = $Section
        title          = $Title
        status         = $Status
        current        = $Current
        target         = $Target
        detail         = $Detail
        risk           = $Risk
        needs_reboot   = $NeedsReboot
        needs_admin    = $NeedsAdmin
        default_apply  = $DefaultApply
        commands       = $Commands
        undo           = $Undo
    }
}

function Get-SRPrepTunePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        $Settings,

        [Parameter(Mandatory = $false)]
        [ValidateSet('prod', 'observer')]
        [string]$Role = 'prod',

        [Parameter(Mandatory = $false)]
        [scriptblock]$Log
    )

    $items = [System.Collections.Generic.List[object]]::new()
    $seenIds = [System.Collections.Generic.HashSet[string]]::new()

    $keepPatterns = Get-SRSettingValue $Settings 'startup.keep_patterns' $script:DefaultKeepPatterns
    $disablePatterns = Get-SRSettingValue $Settings 'startup.disable_patterns' $script:DefaultDisablePatterns
    $closePatterns = Get-SRSettingValue $Settings 'background.close_patterns' $script:DefaultClosePatterns
    $closeProdOnlyPatterns = Get-SRSettingValue $Settings 'background.close_prod_only_patterns' $script:DefaultCloseProdOnlyPatterns
    $askPatterns = Get-SRSettingValue $Settings 'background.ask_patterns' $script:DefaultAskPatterns
    $neverClosePatterns = Get-SRSettingValue $Settings 'background.never_close_patterns' $script:DefaultNeverClosePatterns
    $offerDisableWifi = [bool](Get-SRSettingValue $Settings 'network.offer_disable_wifi_when_wired' $script:DefaultOfferDisableWifi)
    $offerDisableVirtual = [bool](Get-SRSettingValue $Settings 'network.offer_disable_virtual_adapters' $script:DefaultOfferDisableVirtual)
    $disableToasts = [bool](Get-SRSettingValue $Settings 'notifications.disable_toasts' $script:DefaultDisableToasts)
    $powerPrefer = Get-SRSettingValue $Settings 'power.prefer' $script:DefaultPowerPrefer

    $isPerUserMismatch = Test-SRLocalPerUserMismatch

    # ---------------------------------------------------------
    # 1. Power (section power)
    # ---------------------------------------------------------
    if ($Log) { & $Log "Inspecting power configuration..." }
    try {
        # Check laptop battery
        try {
            $bats = @(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
            if ($bats.Count -gt 0) {
                $onBattery = $false
                foreach ($b in $bats) {
                    if ($null -ne $b.BatteryStatus -and $b.BatteryStatus -ne 2) {
                        $onBattery = $true
                        break
                    }
                }
                if ($onBattery) {
                    $items.Add((New-SRPrepItem -Id 'tune_power:battery' -Section 'power' -Title 'Mains power' -Status 'MANUAL' -Current 'battery' -Target 'mains' -Detail 'Plug in mains power' -Risk 'low' -NeedsReboot $false -NeedsAdmin $false -DefaultApply $false -Commands @() -Undo $null))
                    [void]$seenIds.Add('tune_power:battery')
                }
            }
        } catch { }

        $actRes = Invoke-SRPowercfg '/getactivescheme'
        $activeGuid = $null
        if ($actRes.StdOut -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
            $activeGuid = $matches[1].ToLower()
        }

        if (-not $activeGuid) {
            $items.Add((New-SRPrepItem -Id 'tune_power' -Section 'power' -Title 'Power scheme' -Status 'ERROR' -Current 'unknown' -Target 'ultimate' -Detail 'Could not determine active power scheme GUID.' -Risk 'low' -NeedsReboot $false -NeedsAdmin $true -DefaultApply $true -Commands @() -Undo $null))
            [void]$seenIds.Add('tune_power')
        } else {
            $standbyRes = Invoke-SRPowercfg "/query $activeGuid SUB_SLEEP STANDBYIDLE"
            $standbyVal = Get-SRHexAcDcValues $standbyRes.StdOut

            $hibernateRes = Invoke-SRPowercfg "/query $activeGuid SUB_SLEEP HIBERNATEIDLE"
            $hibernateVal = Get-SRHexAcDcValues $hibernateRes.StdOut

            $monitorRes = Invoke-SRPowercfg "/query $activeGuid SUB_VIDEO VIDEOIDLE"
            $monitorVal = Get-SRHexAcDcValues $monitorRes.StdOut

            $diskRes = Invoke-SRPowercfg "/query $activeGuid SUB_DISK DISKIDLE"
            $diskVal = Get-SRHexAcDcValues $diskRes.StdOut

            $usbRes = Invoke-SRPowercfg "/query $activeGuid 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226"
            $usbVal = Get-SRHexAcDcValues $usbRes.StdOut

            $pcieRes = Invoke-SRPowercfg "/query $activeGuid 501a4d13-42af-4429-9fd1-a8ae23f6a9fd ee12f906-d277-404b-b6da-e5fa1a576df5"
            $pcieVal = Get-SRHexAcDcValues $pcieRes.StdOut

            $minProcRes = Invoke-SRPowercfg "/query $activeGuid 54533251-82be-4824-96c1-47b60b740d00 893dee8e-2bef-41e0-89c6-b55d0929964c"
            $minProcVal = Get-SRHexAcDcValues $minProcRes.StdOut

            $isAlreadyGood = ($activeGuid -eq $script:HighPerfGuid -or $activeGuid -eq $script:UltimateGuid -or ($minProcVal -and $minProcVal.ac_val -eq 100))

            $curStandby = if ($standbyVal) { $standbyVal.ac_val } else { $null }
            $curHibernate = if ($hibernateVal) { $hibernateVal.ac_val } else { $null }
            $curMonitor = if ($monitorVal) { $monitorVal.ac_val } else { $null }
            $curDisk = if ($diskVal) { $diskVal.ac_val } else { $null }
            $curUsb = if ($usbVal) { $usbVal.ac_val } else { $null }
            $curPcie = if ($pcieVal) { $pcieVal.ac_val } else { $null }
            $curMinProc = if ($minProcVal) { $minProcVal.ac_val } else { $null }

            $needsStandby = ($null -eq $curStandby -or $curStandby -ne 0)
            $needsHibernate = ($null -eq $curHibernate -or $curHibernate -ne 0)
            $needsMonitor = ($null -eq $curMonitor -or $curMonitor -ne 0)
            $needsDisk = ($null -eq $curDisk -or $curDisk -ne 0)
            $needsUsb = ($null -eq $curUsb -or $curUsb -ne 0)
            $needsPcie = ($pcieVal -and $curPcie -ne 0)
            $needsMinProc = ($null -eq $curMinProc -or $curMinProc -ne 100)

            $allAcOptimal = (-not ($needsStandby -or $needsHibernate -or $needsMonitor -or $needsDisk -or $needsUsb -or $needsPcie -or $needsMinProc))

            $undoObj = [pscustomobject]@{
                previous_active_guid = $activeGuid
                created_guid         = $null
                previous_ac_values   = [pscustomobject]@{
                    standby_timeout   = $curStandby
                    hibernate_timeout = $curHibernate
                    monitor_timeout   = $curMonitor
                    disk_timeout      = $curDisk
                    usb_suspend       = $curUsb
                    pcie_link_state   = $curPcie
                    min_proc_state    = $curMinProc
                }
            }

            [void]$seenIds.Add('tune_power')
            if ($isAlreadyGood) {
                if ($allAcOptimal) {
                    $items.Add((New-SRPrepItem -Id 'tune_power' -Section 'power' -Title 'Power scheme and AC settings' -Status 'OK' -Current "$activeGuid (optimized)" -Target "$activeGuid" -Detail 'Active scheme is High performance/Ultimate and all AC power settings are optimized.' -Risk 'low' -NeedsReboot $false -NeedsAdmin $true -DefaultApply $true -Commands @() -Undo $null))
                } else {
                    $powerCmds = [System.Collections.Generic.List[string]]::new()
                    $powerCmds.Add('powercfg /change standby-timeout-ac 0')
                    $powerCmds.Add('powercfg /change hibernate-timeout-ac 0')
                    $powerCmds.Add('powercfg /change monitor-timeout-ac 0')
                    $powerCmds.Add('powercfg /change disk-timeout-ac 0')
                    $powerCmds.Add("powercfg /setacvalueindex $activeGuid 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0")
                    if ($pcieVal) {
                        $powerCmds.Add("powercfg /setacvalueindex $activeGuid 501a4d13-42af-4429-9fd1-a8ae23f6a9fd ee12f906-d277-404b-b6da-e5fa1a576df5 0")
                    }
                    $powerCmds.Add("powercfg /setacvalueindex $activeGuid 54533251-82be-4824-96c1-47b60b740d00 893dee8e-2bef-41e0-89c6-b55d0929964c 100")
                    $powerCmds.Add("powercfg /setactive $activeGuid")

                    $items.Add((New-SRPrepItem -Id 'tune_power' -Section 'power' -Title 'Power scheme and AC settings' -Status 'CHANGE' -Current "$activeGuid (AC settings need optimization)" -Target "$activeGuid (AC settings optimized)" -Detail 'Optimize AC power settings (disable sleep, hibernate, monitor turnoff, disk turnoff, USB suspend, set 100% min CPU).' -Risk 'low' -NeedsReboot $false -NeedsAdmin $true -DefaultApply $true -Commands ($powerCmds.ToArray()) -Undo $undoObj))
                }
            } else {
                $powerCmds = [System.Collections.Generic.List[string]]::new()
                $powerCmds.Add('powercfg /duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61')
                $powerCmds.Add('powercfg /setactive <scheme>')
                $powerCmds.Add('powercfg /change standby-timeout-ac 0')
                $powerCmds.Add('powercfg /change hibernate-timeout-ac 0')
                $powerCmds.Add('powercfg /change monitor-timeout-ac 0')
                $powerCmds.Add('powercfg /change disk-timeout-ac 0')
                $powerCmds.Add('powercfg /setacvalueindex <scheme> 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0')
                $powerCmds.Add('powercfg /setacvalueindex <scheme> 501a4d13-42af-4429-9fd1-a8ae23f6a9fd ee12f906-d277-404b-b6da-e5fa1a576df5 0')
                $powerCmds.Add('powercfg /setacvalueindex <scheme> 54533251-82be-4824-96c1-47b60b740d00 893dee8e-2bef-41e0-89c6-b55d0929964c 100')
                $powerCmds.Add('powercfg /setactive <scheme>')

                $items.Add((New-SRPrepItem -Id 'tune_power' -Section 'power' -Title 'Power scheme and AC settings' -Status 'CHANGE' -Current "$activeGuid" -Target 'ultimate (or high performance) with optimized AC settings' -Detail 'Switch to Ultimate/High performance power plan and optimize AC timeouts, USB suspend, and processor state.' -Risk 'low' -NeedsReboot $false -NeedsAdmin $true -DefaultApply $true -Commands ($powerCmds.ToArray()) -Undo $undoObj))
            }
        }
    } catch {
        $items.Add((New-SRPrepItem -Id 'tune_power' -Section 'power' -Title 'Power scheme and AC settings' -Status 'ERROR' -Current 'unknown' -Target 'ultimate' -Detail "Error inspecting power configuration: $($_.Exception.Message)" -Risk 'low' -NeedsReboot $false -NeedsAdmin $true -DefaultApply $true -Commands @() -Undo $null))
        [void]$seenIds.Add('tune_power')
    }

    # ---------------------------------------------------------
    # 2. Startup Apps (section startup)
    # ---------------------------------------------------------
    if ($Log) { & $Log "Inspecting startup apps..." }
    try {
        $startupSources = @(
            [pscustomobject]@{ Type = 'HKCU_Run'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; Approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'; IsHklm = $false },
            [pscustomobject]@{ Type = 'HKLM_Run'; Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'; Approved = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'; IsHklm = $true },
            [pscustomobject]@{ Type = 'HKLM_Run32'; Path = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Approved = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32'; IsHklm = $true }
        )

        foreach ($src in $startupSources) {
            if (Test-Path -Path $src.Path) {
                $regKey = Get-Item -Path $src.Path -ErrorAction SilentlyContinue
                if ($regKey) {
                    $approvedItem = $null
                    if (Test-Path -Path $src.Approved) {
                        $approvedItem = Get-Item -Path $src.Approved -ErrorAction SilentlyContinue
                    }
                    foreach ($valName in $regKey.Property) {
                        $cmd = [string]$regKey.GetValue($valName)
                        $apprBytes = $null
                        if ($approvedItem) {
                            $apprBytes = $approvedItem.GetValue($valName)
                        }
                        $curState = Get-SRStartupApprovedState $apprBytes
                        $itemId = "tune_startup:$valName"
                        if ($seenIds.Contains($itemId)) {
                            $itemId = "tune_startup:${valName}_$($src.Type)"
                        }
                        [void]$seenIds.Add($itemId)

                        $isKept = ($valName -match $keepPatterns -or $cmd -match $keepPatterns)
                        if ($isKept) {
                            $items.Add((New-SRPrepItem -Id $itemId -Section 'startup' -Title "Startup app: $valName" -Status 'OK' -Current $curState -Target $curState -Detail 'kept: needed for drivers/security/broadcast/remote access' -Risk 'low' -NeedsReboot $false -NeedsAdmin $src.IsHklm -DefaultApply $true -Commands @() -Undo $null))
                        } elseif ($curState -eq 'disabled') {
                            $items.Add((New-SRPrepItem -Id $itemId -Section 'startup' -Title "Startup app: $valName" -Status 'OK' -Current 'disabled' -Target 'disabled' -Detail 'already disabled' -Risk 'low' -NeedsReboot $false -NeedsAdmin $src.IsHklm -DefaultApply $true -Commands @() -Undo $null))
                        } else {
                            if ((-not $src.IsHklm) -and $isPerUserMismatch) {
                                $items.Add((New-SRPrepItem -Id $itemId -Section 'startup' -Title "Startup app: $valName" -Status 'MANUAL' -Current 'enabled' -Target 'disabled' -Detail 'Sign in to Windows as an administrator account and run Prep again.' -Risk 'low' -NeedsReboot $false -NeedsAdmin $src.IsHklm -DefaultApply $true -Commands @() -Undo $null))
                            } else {
                                $undoB64 = if ($apprBytes) { [Convert]::ToBase64String($apprBytes) } else { 'absent' }
                                $undoObj = [pscustomobject]@{
                                    type         = 'startup_approved'
                                    approved_key = $src.Approved
                                    name         = $valName
                                    previous_val = $undoB64
                                }
                                $cmdStr = "Set-ItemProperty -Path '$($src.Approved)' -Name '$valName' -Value ([byte[]](@([byte]0x03,0,0,0) + [BitConverter]::GetBytes([DateTime]::UtcNow.ToFileTimeUtc()))) -Type Binary"
                                $items.Add((New-SRPrepItem -Id $itemId -Section 'startup' -Title "Startup app: $valName" -Status 'CHANGE' -Current 'enabled' -Target 'disabled' -Detail 'Third-party app configured to launch at Windows startup; disable to free resources.' -Risk 'low' -NeedsReboot $false -NeedsAdmin $src.IsHklm -DefaultApply $true -Commands @($cmdStr) -Undo $undoObj))
                            }
                        }
                    }
                }
            }
        }

        # User and Common Startup folders
        $userStartupDir = [Environment]::GetFolderPath('Startup')
        $commonStartupDir = [Environment]::GetFolderPath('CommonStartup')
        $folderSources = @(
            [pscustomobject]@{ Type = 'User_Folder'; Path = $userStartupDir; Approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'; IsHklm = $false },
            [pscustomobject]@{ Type = 'Common_Folder'; Path = $commonStartupDir; Approved = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'; IsHklm = $true }
        )

        foreach ($fsrc in $folderSources) {
            if ($fsrc.Path -and (Test-Path -Path $fsrc.Path)) {
                $files = @(Get-ChildItem -Path $fsrc.Path -File -ErrorAction SilentlyContinue)
                $approvedItem = $null
                if (Test-Path -Path $fsrc.Approved) {
                    $approvedItem = Get-Item -Path $fsrc.Approved -ErrorAction SilentlyContinue
                }
                foreach ($file in $files) {
                    $valName = $file.Name
                    $cmd = $file.FullName
                    $apprBytes = $null
                    if ($approvedItem) {
                        $apprBytes = $approvedItem.GetValue($valName)
                    }
                    $curState = Get-SRStartupApprovedState $apprBytes
                    $itemId = "tune_startup:$valName"
                    if ($seenIds.Contains($itemId)) {
                        $itemId = "tune_startup:${valName}_$($fsrc.Type)"
                    }
                    [void]$seenIds.Add($itemId)

                    $isKept = ($valName -match $keepPatterns -or $cmd -match $keepPatterns)
                    if ($isKept) {
                        $items.Add((New-SRPrepItem -Id $itemId -Section 'startup' -Title "Startup item: $valName" -Status 'OK' -Current $curState -Target $curState -Detail 'kept: needed for drivers/security/broadcast/remote access' -Risk 'low' -NeedsReboot $false -NeedsAdmin $fsrc.IsHklm -DefaultApply $true -Commands @() -Undo $null))
                    } elseif ($curState -eq 'disabled') {
                        $items.Add((New-SRPrepItem -Id $itemId -Section 'startup' -Title "Startup item: $valName" -Status 'OK' -Current 'disabled' -Target 'disabled' -Detail 'already disabled' -Risk 'low' -NeedsReboot $false -NeedsAdmin $fsrc.IsHklm -DefaultApply $true -Commands @() -Undo $null))
                    } else {
                        if ((-not $fsrc.IsHklm) -and $isPerUserMismatch) {
                            $items.Add((New-SRPrepItem -Id $itemId -Section 'startup' -Title "Startup item: $valName" -Status 'MANUAL' -Current 'enabled' -Target 'disabled' -Detail 'Sign in to Windows as an administrator account and run Prep again.' -Risk 'low' -NeedsReboot $false -NeedsAdmin $fsrc.IsHklm -DefaultApply $true -Commands @() -Undo $null))
                        } else {
                            $undoB64 = if ($apprBytes) { [Convert]::ToBase64String($apprBytes) } else { 'absent' }
                            $undoObj = [pscustomobject]@{
                                type         = 'startup_approved'
                                approved_key = $fsrc.Approved
                                name         = $valName
                                previous_val = $undoB64
                            }
                            $cmdStr = "Set-ItemProperty -Path '$($fsrc.Approved)' -Name '$valName' -Value ([byte[]](@([byte]0x03,0,0,0) + [BitConverter]::GetBytes([DateTime]::UtcNow.ToFileTimeUtc()))) -Type Binary"
                            $items.Add((New-SRPrepItem -Id $itemId -Section 'startup' -Title "Startup item: $valName" -Status 'CHANGE' -Current 'enabled' -Target 'disabled' -Detail 'Startup folder entry launches at Windows startup; disable to free resources.' -Risk 'low' -NeedsReboot $false -NeedsAdmin $fsrc.IsHklm -DefaultApply $true -Commands @($cmdStr) -Undo $undoObj))
                        }
                    }
                }
            }
        }

        # Korean banking/security services
        $koreanServices = @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object {
            ($_.Name -and ($_.Name -match 'nProtect|npkcmsvc|TouchEn|Veraport|IPinside|Delfino|Wizvera|CrossEX|INISAFE|MagicLine|KeySharp|AnySign|ASTx|AhnLab Safe Transaction')) -or
            ($_.DisplayName -and ($_.DisplayName -match 'nProtect|npkcmsvc|TouchEn|Veraport|IPinside|Delfino|Wizvera|CrossEX|INISAFE|MagicLine|KeySharp|AnySign|ASTx|AhnLab Safe Transaction'))
        })
        foreach ($svc in $koreanServices) {
            if ($svc.StartMode -eq 'Auto') {
                $itemId = "tune_startup:svc:$($svc.Name)"
                if (-not $seenIds.Contains($itemId)) {
                    [void]$seenIds.Add($itemId)
                    $undoObj = [pscustomobject]@{
                        type                = 'service'
                        name                = $svc.Name
                        previous_start_mode = $svc.StartMode
                        was_running         = ($svc.State -eq 'Running')
                    }
                    $cmds = @(
                        "Set-Service -Name '$($svc.Name)' -StartupType Manual",
                        "Stop-Service -Name '$($svc.Name)' -Force"
                    )
                    $items.Add((New-SRPrepItem -Id $itemId -Section 'startup' -Title "Korean banking service: $($svc.Name)" -Status 'CHANGE' -Current "Auto ($($svc.State))" -Target 'Manual (Stopped)' -Detail 'Korean banking/security service set to start automatically; hooks keyboard/network. Set to Manual and stop.' -Risk 'low' -NeedsReboot $false -NeedsAdmin $true -DefaultApply $true -Commands $cmds -Undo $undoObj))
                }
            }
        }

        # Scheduled updater tasks
        $updaterTasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
            $_.TaskPath -notmatch '^\\Microsoft\\' -and
            $_.State -eq 'Ready' -and
            $_.TaskName -match 'GoogleUpdate|MicrosoftEdgeUpdate|Adobe Acrobat Update|OneDrive|Opera|Brave|Spotify|Dropbox|CCleaner|Avast|AVG' -and
            $_.TaskName -notmatch $keepPatterns
        })
        foreach ($task in $updaterTasks) {
            $itemId = "tune_startup:task:$($task.TaskPath)$($task.TaskName)"
            if (-not $seenIds.Contains($itemId)) {
                [void]$seenIds.Add($itemId)
                $undoObj = [pscustomobject]@{
                    type      = 'task'
                    task_path = $task.TaskPath
                    task_name = $task.TaskName
                }
                $cmdStr = "Disable-ScheduledTask -TaskPath '$($task.TaskPath)' -TaskName '$($task.TaskName)'"
                $items.Add((New-SRPrepItem -Id $itemId -Section 'startup' -Title "Scheduled updater task: $($task.TaskName)" -Status 'CHANGE' -Current 'Ready' -Target 'Disabled' -Detail 'Third-party scheduled task launches background updater. Disable task.' -Risk 'low' -NeedsReboot $false -NeedsAdmin $true -DefaultApply $true -Commands @($cmdStr) -Undo $undoObj))
            }
        }
    } catch {
        $items.Add((New-SRPrepItem -Id 'tune_startup:error' -Section 'startup' -Title 'Startup apps inspection' -Status 'ERROR' -Current 'unknown' -Target 'unknown' -Detail "Error inspecting startup apps: $($_.Exception.Message)" -Risk 'low' -NeedsReboot $false -NeedsAdmin $false -DefaultApply $false -Commands @() -Undo $null))
        [void]$seenIds.Add('tune_startup:error')
    }

    # ---------------------------------------------------------
    # 3. Background apps (section background)
    # ---------------------------------------------------------
    if ($Log) { & $Log "Inspecting background processes..." }
    try {
        $processes = @(Get-Process -ErrorAction SilentlyContinue)
        $grouped = $processes | Group-Object -Property ProcessName
        foreach ($grp in $grouped) {
            $pName = $grp.Name
            $pCount = $grp.Count
            if ($pName -match $neverClosePatterns) {
                continue
            }
            if ($pName -match $askPatterns) {
                $itemId = "tune_background:$pName"
                if (-not $seenIds.Contains($itemId)) {
                    [void]$seenIds.Add($itemId)
                    $suffix = if ($pCount -gt 1) { 's' } else { '' }
                    $items.Add((New-SRPrepItem -Id $itemId -Section 'background' -Title "Close background app: $pName ($pCount instance$suffix)" -Status 'CHANGE' -Current "$pCount running" -Target 'closed' -Detail 'Might be your crew comms; closed only if you say yes.' -Risk 'medium' -NeedsReboot $false -NeedsAdmin $false -DefaultApply $false -Commands @("Stop-Process -Name '$pName' -Force") -Undo $null))
                }
                continue
            }
            if ($Role -eq 'prod' -and ($pName -match $closeProdOnlyPatterns)) {
                $itemId = "tune_background:$pName"
                if (-not $seenIds.Contains($itemId)) {
                    [void]$seenIds.Add($itemId)
                    $suffix = if ($pCount -gt 1) { 's' } else { '' }
                    $items.Add((New-SRPrepItem -Id $itemId -Section 'background' -Title "Close background app: $pName ($pCount instance$suffix)" -Status 'CHANGE' -Current "$pCount running" -Target 'closed' -Detail 'Save any open work first: this closes the app.' -Risk 'low' -NeedsReboot $false -NeedsAdmin $false -DefaultApply $true -Commands @("Stop-Process -Name '$pName' -Force") -Undo $null))
                }
                continue
            }
            if ($Role -eq 'observer' -and ($pName -match $closeProdOnlyPatterns)) {
                continue
            }
            if ($pName -match $closePatterns) {
                $itemId = "tune_background:$pName"
                if (-not $seenIds.Contains($itemId)) {
                    [void]$seenIds.Add($itemId)
                    $suffix = if ($pCount -gt 1) { 's' } else { '' }
                    $detail = if ($pName -match '^(chrome|msedge|firefox|whale|opera|brave)$') {
                        'Save any open work first: this closes the app (open tabs will close).'
                    } else {
                        'Save any open work first: this closes the app.'
                    }
                    $items.Add((New-SRPrepItem -Id $itemId -Section 'background' -Title "Close background app: $pName ($pCount instance$suffix)" -Status 'CHANGE' -Current "$pCount running" -Target 'closed' -Detail $detail -Risk 'low' -NeedsReboot $false -NeedsAdmin $false -DefaultApply $true -Commands @("Stop-Process -Name '$pName' -Force") -Undo $null))
                }
                continue
            }
        }
    } catch {
        $items.Add((New-SRPrepItem -Id 'tune_background:error' -Section 'background' -Title 'Background processes' -Status 'ERROR' -Current 'unknown' -Target 'unknown' -Detail "Error inspecting background processes: $($_.Exception.Message)" -Risk 'low' -NeedsReboot $false -NeedsAdmin $false -DefaultApply $false -Commands @() -Undo $null))
        [void]$seenIds.Add('tune_background:error')
    }

    # ---------------------------------------------------------
    # 4. Network (section network)
    # ---------------------------------------------------------
    if ($Log) { & $Log "Inspecting network adapters..." }
    try {
        $allAdapters = @(Get-NetAdapter -ErrorAction SilentlyContinue)
        $physicalWired = @($allAdapters | Where-Object {
            $_.Physical -and
            ($_.PhysicalMediaType -eq '802.3' -or $_.NdisPhysicalMedium -eq 14) -and
            $_.Status -eq 'Up'
        })

        $eeeKeywords = @('*EEE','EEE','EEELinkAdvertisement','AdvancedEEE','EnableGreenEthernet','GreenEthernet','*GreenEthernet','PowerSavingMode','EnablePowerSaving','ULPMode','GigaLite','ReduceSpeedOnPowerDown','*SSIdleTimeout')

        foreach ($wa in $physicalWired) {
            # 4a. EEE
            try {
                $advProps = @(Get-NetAdapterAdvancedProperty -Name $wa.Name -AllProperties -ErrorAction SilentlyContinue)
                $eeePropsToChange = [System.Collections.Generic.List[object]]::new()
                $origValues = [pscustomobject]@{}
                foreach ($prop in $advProps) {
                    if ($prop.RegistryKeyword -and ($prop.RegistryKeyword -in $eeeKeywords)) {
                        $validVals = @($prop.ValidRegistryValues)
                        if ($validVals -contains '0' -and $prop.RegistryValue -ne '0') {
                            $eeePropsToChange.Add($prop)
                            Add-Member -InputObject $origValues -NotePropertyName $prop.RegistryKeyword -NotePropertyValue $prop.RegistryValue -Force
                        }
                    }
                }
                $eeeId = "tune_network:eee:$($wa.Name)"
                [void]$seenIds.Add($eeeId)
                if ($eeePropsToChange.Count -gt 0) {
                    $eeeCmds = [System.Collections.Generic.List[string]]::new()
                    foreach ($p in $eeePropsToChange) {
                        $eeeCmds.Add("Set-NetAdapterAdvancedProperty -Name '$($wa.Name)' -RegistryKeyword '$($p.RegistryKeyword)' -RegistryValue 0")
                    }
                    $undoObj = [pscustomobject]@{
                        type            = 'eee'
                        adapter         = $wa.Name
                        original_values = $origValues
                    }
                    $items.Add((New-SRPrepItem -Id $eeeId -Section 'network' -Title "Energy-Efficient Ethernet: $($wa.Name)" -Status 'CHANGE' -Current 'power saving enabled' -Target '0 (disabled)' -Detail 'Energy-Efficient Ethernet and link power saving off (link drops for a few seconds).' -Risk 'low' -NeedsReboot $false -NeedsAdmin $true -DefaultApply $true -Commands ($eeeCmds.ToArray()) -Undo $undoObj))
                } else {
                    $items.Add((New-SRPrepItem -Id $eeeId -Section 'network' -Title "Energy-Efficient Ethernet: $($wa.Name)" -Status 'OK' -Current 'disabled' -Target 'disabled' -Detail 'Energy-Efficient Ethernet and link power saving already disabled.' -Risk 'low' -NeedsReboot $false -NeedsAdmin $true -DefaultApply $true -Commands @() -Undo $null))
                }
            } catch {
                if ($Log) { & $Log "Error inspecting EEE on $($wa.Name): $($_.Exception.Message)" }
            }

            # 4b. Power Management
            try {
                $pm = Get-NetAdapterPowerManagement -Name $wa.Name -ErrorAction SilentlyContinue
                $pmId = "tune_network:pm:$($wa.Name)"
                [void]$seenIds.Add($pmId)
                if ($pm -and $pm.AllowComputerToTurnOffDevice -eq 'Enabled') {
                    $undoObj = [pscustomobject]@{
                        type                              = 'pm'
                        adapter                           = $wa.Name
                        allow_computer_to_turn_off_device = 'Enabled'
                    }
                    $items.Add((New-SRPrepItem -Id $pmId -Section 'network' -Title "Adapter power management: $($wa.Name)" -Status 'CHANGE' -Current 'Enabled' -Target 'Disabled' -Detail 'Prevent Windows from turning off the network adapter to save power.' -Risk 'low' -NeedsReboot $false -NeedsAdmin $true -DefaultApply $true -Commands @("Set-NetAdapterPowerManagement -Name '$($wa.Name)' -AllowComputerToTurnOffDevice Disabled") -Undo $undoObj))
                } else {
                    $curPm = if ($pm -and $pm.AllowComputerToTurnOffDevice) { [string]$pm.AllowComputerToTurnOffDevice } else { 'Unsupported' }
                    $items.Add((New-SRPrepItem -Id $pmId -Section 'network' -Title "Adapter power management: $($wa.Name)" -Status 'OK' -Current $curPm -Target $curPm -Detail "Adapter power management AllowComputerToTurnOffDevice is $curPm." -Risk 'low' -NeedsReboot $false -NeedsAdmin $true -DefaultApply $true -Commands @() -Undo $null))
                }
            } catch {
                if ($Log) { & $Log "Error inspecting PM on $($wa.Name): $($_.Exception.Message)" }
            }

            # 4c. Profile
            try {
                $prof = Get-NetConnectionProfile -InterfaceIndex $wa.InterfaceIndex -ErrorAction SilentlyContinue
                $profId = "tune_network:profile:$($wa.Name)"
                [void]$seenIds.Add($profId)
                if ($prof -and $prof.NetworkCategory -eq 'Public') {
                    $undoObj = [pscustomobject]@{
                        type             = 'profile'
                        interface_index  = $wa.InterfaceIndex
                        network_category = 'Public'
                    }
                    $items.Add((New-SRPrepItem -Id $profId -Section 'network' -Title "Network profile: $($wa.Name)" -Status 'CHANGE' -Current 'Public' -Target 'Private' -Detail 'Switch network profile from Public to Private so NDI/OMT discovery is not blocked.' -Risk 'low' -NeedsReboot $false -NeedsAdmin $true -DefaultApply $true -Commands @("Set-NetConnectionProfile -InterfaceIndex $($wa.InterfaceIndex) -NetworkCategory Private") -Undo $undoObj))
                } else {
                    $cat = if ($prof -and $prof.NetworkCategory) { [string]$prof.NetworkCategory } else { 'Private/Domain' }
                    $items.Add((New-SRPrepItem -Id $profId -Section 'network' -Title "Network profile: $($wa.Name)" -Status 'OK' -Current $cat -Target $cat -Detail "Network category is $cat." -Risk 'low' -NeedsReboot $false -NeedsAdmin $true -DefaultApply $true -Commands @() -Undo $null))
                }
            } catch {
                if ($Log) { & $Log "Error inspecting profile on $($wa.Name): $($_.Exception.Message)" }
            }
        }

        # 4d. Wi-Fi
        if ($offerDisableWifi) {
            $hasWiredIpv4 = $false
            foreach ($wa in $physicalWired) {
                $ips = @(Get-NetIPAddress -InterfaceIndex $wa.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notmatch '^169\.254\.' })
                if ($ips.Count -gt 0) {
                    $hasWiredIpv4 = $true
                    break
                }
            }
            if ($hasWiredIpv4) {
                $wifiAdapters = @($allAdapters | Where-Object {
                    ($_.PhysicalMediaType -match '802\.11' -or $_.NdisPhysicalMedium -eq 9) -and
                    $_.Status -eq 'Up'
                })
                foreach ($wifi in $wifiAdapters) {
                    $wifiId = "tune_network:wifi:$($wifi.Name)"
                    if (-not $seenIds.Contains($wifiId)) {
                        [void]$seenIds.Add($wifiId)
                        $undoObj = [pscustomobject]@{
                            type    = 'adapter_state'
                            adapter = $wifi.Name
                            action  = 'enable'
                        }
                        $items.Add((New-SRPrepItem -Id $wifiId -Section 'network' -Title "Disable Wi-Fi: $($wifi.Name)" -Status 'CHANGE' -Current 'Up' -Target 'Disabled' -Detail 'NDI/OMT may pick the Wi-Fi connection. Only say yes if the wired network also has internet (the prod PC needs it to stream).' -Risk 'medium' -NeedsReboot $false -NeedsAdmin $true -DefaultApply $false -Commands @("Disable-NetAdapter -Name '$($wifi.Name)' -Confirm:`$false") -Undo $undoObj))
                    }
                }
            }
        }

        # 4e. Virtual adapters
        if ($offerDisableVirtual) {
            $physicalNames = @($physicalWired | ForEach-Object { $_.Name })
            $virtualAdapters = @($allAdapters | Where-Object {
                $_.Status -eq 'Up' -and
                ($_.Name -notin $physicalNames) -and
                ((-not $_.Physical) -or ($_.InterfaceDescription -match 'Hyper-V|VirtualBox|VMware|TAP-Windows|Tailscale|ZeroTier|Hamachi|Radmin|WireGuard|NordLynx|Wintun|OpenVPN|Fortinet|Cisco AnyConnect|Npcap Loopback'))
            })
            foreach ($vadapt in $virtualAdapters) {
                if ($vadapt.PhysicalMediaType -match '802\.11' -or $vadapt.NdisPhysicalMedium -eq 9) {
                    continue
                }
                $vId = "tune_network:virtual:$($vadapt.Name)"
                if (-not $seenIds.Contains($vId)) {
                    [void]$seenIds.Add($vId)
                    if ($vadapt.InterfaceDescription -match 'Hyper-V Virtual Ethernet' -or $vadapt.Name -match '^vEthernet') {
                        $items.Add((New-SRPrepItem -Id $vId -Section 'network' -Title "Virtual adapter: $($vadapt.Name)" -Status 'MANUAL' -Current 'Up' -Target 'Configured' -Detail 'In NDI Access Manager (or vMix network settings) select the wired adapter only' -Risk 'low' -NeedsReboot $false -NeedsAdmin $false -DefaultApply $false -Commands @() -Undo $null))
                    } else {
                        $undoObj = [pscustomobject]@{
                            type    = 'adapter_state'
                            adapter = $vadapt.Name
                            action  = 'enable'
                        }
                        $items.Add((New-SRPrepItem -Id $vId -Section 'network' -Title "Disable virtual adapter: $($vadapt.Name)" -Status 'CHANGE' -Current 'Up' -Target 'Disabled' -Detail 'VPN/virtual adapters can capture NDI/OMT discovery. Say no if you need this VPN during the show.' -Risk 'medium' -NeedsReboot $false -NeedsAdmin $true -DefaultApply $false -Commands @("Disable-NetAdapter -Name '$($vadapt.Name)' -Confirm:`$false") -Undo $undoObj))
                    }
                }
            }
        }
    } catch {
        $items.Add((New-SRPrepItem -Id 'tune_network:error' -Section 'network' -Title 'Network adapter inspection' -Status 'ERROR' -Current 'unknown' -Target 'unknown' -Detail "Error inspecting network adapters: $($_.Exception.Message)" -Risk 'low' -NeedsReboot $false -NeedsAdmin $false -DefaultApply $false -Commands @() -Undo $null))
        [void]$seenIds.Add('tune_network:error')
    }

    # ---------------------------------------------------------
    # 5. Capture (section capture)
    # ---------------------------------------------------------
    if ($Log) { & $Log "Inspecting capture settings..." }
    try {
        $dvrVal = Get-SRRegistryDwordValue 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled'
        $capVal = Get-SRRegistryDwordValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled'

        $needsDvr = ($null -eq $dvrVal -or $dvrVal -ne 0)
        $needsCap = ($null -eq $capVal -or $capVal -ne 0)

        $dvrStr = if ($null -ne $dvrVal) { [string]$dvrVal } else { 'absent' }
        $capStr = if ($null -ne $capVal) { [string]$capVal } else { 'absent' }
        $curCapture = "GameDVR_Enabled=$dvrStr, AppCaptureEnabled=$capStr"

        [void]$seenIds.Add('tune_capture')
        if ($needsDvr -or $needsCap) {
            if ($isPerUserMismatch) {
                $items.Add((New-SRPrepItem -Id 'tune_capture' -Section 'capture' -Title 'Xbox Game Bar background recording' -Status 'MANUAL' -Current $curCapture -Target '0' -Detail 'Sign in to Windows as an administrator account and run Prep again.' -Risk 'low' -NeedsReboot $false -NeedsAdmin $false -DefaultApply $true -Commands @() -Undo $null))
            } else {
                $dvrUndo = 'absent'
                if ($null -ne $dvrVal) { $dvrUndo = [int]$dvrVal }
                $capUndo = 'absent'
                if ($null -ne $capVal) { $capUndo = [int]$capVal }
                $undoObj = [pscustomobject]@{
                    type                = 'capture'
                    game_dvr_enabled    = $dvrUndo
                    app_capture_enabled = $capUndo
                }
                $capCmds = @(
                    "if (-not (Test-Path 'HKCU:\System\GameConfigStore')) { [void](New-Item -Path 'HKCU:\System\GameConfigStore' -Force) }; Set-ItemProperty -Path 'HKCU:\System\GameConfigStore' -Name 'GameDVR_Enabled' -Value 0 -Type DWord",
                    "if (-not (Test-Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR')) { [void](New-Item -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' -Force) }; Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' -Name 'AppCaptureEnabled' -Value 0 -Type DWord"
                )
                $items.Add((New-SRPrepItem -Id 'tune_capture' -Section 'capture' -Title 'Xbox Game Bar background recording' -Status 'CHANGE' -Current $curCapture -Target '0' -Detail 'Xbox Game Bar background recording uses the GPU encoder; disable it.' -Risk 'low' -NeedsReboot $false -NeedsAdmin $false -DefaultApply $true -Commands $capCmds -Undo $undoObj))
            }
        } else {
            $items.Add((New-SRPrepItem -Id 'tune_capture' -Section 'capture' -Title 'Xbox Game Bar background recording' -Status 'OK' -Current '0' -Target '0' -Detail 'Xbox Game Bar background recording already disabled.' -Risk 'low' -NeedsReboot $false -NeedsAdmin $false -DefaultApply $true -Commands @() -Undo $null))
        }
    } catch {
        $items.Add((New-SRPrepItem -Id 'tune_capture' -Section 'capture' -Title 'Xbox Game Bar background recording' -Status 'ERROR' -Current 'unknown' -Target '0' -Detail "Error inspecting GameDVR settings: $($_.Exception.Message)" -Risk 'low' -NeedsReboot $false -NeedsAdmin $false -DefaultApply $true -Commands @() -Undo $null))
        [void]$seenIds.Add('tune_capture')
    }

    # ---------------------------------------------------------
    # 6. Notifications (section notifications)
    # ---------------------------------------------------------
    if ($Log) { & $Log "Inspecting notification settings..." }
    try {
        [void]$seenIds.Add('tune_notifications')
        if (-not $disableToasts) {
            $items.Add((New-SRPrepItem -Id 'tune_notifications' -Section 'notifications' -Title 'Toast notifications' -Status 'INFO' -Current 'configured' -Target 'configured' -Detail 'Toast notifications disabling disabled by config.' -Risk 'low' -NeedsReboot $false -NeedsAdmin $false -DefaultApply $false -Commands @() -Undo $null))
        } else {
            $toastVal = Get-SRRegistryDwordValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications' 'ToastEnabled'
            $nocVal = Get-SRRegistryDwordValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings' 'NOC_GLOBAL_SETTING_TOASTS_ENABLED'

            $needsToast = ($null -eq $toastVal -or $toastVal -ne 0)
            $needsNoc = ($null -eq $nocVal -or $nocVal -ne 0)

            $toastStr = if ($null -ne $toastVal) { [string]$toastVal } else { 'absent' }
            $nocStr = if ($null -ne $nocVal) { [string]$nocVal } else { 'absent' }
            $curNotif = "ToastEnabled=$toastStr, NOC_GLOBAL_SETTING_TOASTS_ENABLED=$nocStr"

            if ($needsToast -or $needsNoc) {
                if ($isPerUserMismatch) {
                    $items.Add((New-SRPrepItem -Id 'tune_notifications' -Section 'notifications' -Title 'Toast notifications' -Status 'MANUAL' -Current $curNotif -Target '0' -Detail 'Sign in to Windows as an administrator account and run Prep again.' -Risk 'low' -NeedsReboot $false -NeedsAdmin $false -DefaultApply $true -Commands @() -Undo $null))
                } else {
                $toastUndo = 'absent'
                if ($null -ne $toastVal) { $toastUndo = [int]$toastVal }
                $nocUndo = 'absent'
                if ($null -ne $nocVal) { $nocUndo = [int]$nocVal }
                $undoObj = [pscustomobject]@{
                    type                              = 'notifications'
                    toast_enabled                     = $toastUndo
                    noc_global_setting_toasts_enabled = $nocUndo
                }
                    $notifCmds = @(
                        "if (-not (Test-Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications')) { [void](New-Item -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications' -Force) }; Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications' -Name 'ToastEnabled' -Value 0 -Type DWord",
                        "if (-not (Test-Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings')) { [void](New-Item -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings' -Force) }; Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings' -Name 'NOC_GLOBAL_SETTING_TOASTS_ENABLED' -Value 0 -Type DWord"
                    )
                    $items.Add((New-SRPrepItem -Id 'tune_notifications' -Section 'notifications' -Title 'Toast notifications' -Status 'CHANGE' -Current $curNotif -Target '0' -Detail 'Disable toast notification popups so they do not appear during the broadcast.' -Risk 'low' -NeedsReboot $false -NeedsAdmin $false -DefaultApply $true -Commands $notifCmds -Undo $undoObj))
                }
            } else {
                $items.Add((New-SRPrepItem -Id 'tune_notifications' -Section 'notifications' -Title 'Toast notifications' -Status 'OK' -Current '0' -Target '0' -Detail 'Toast notifications already disabled.' -Risk 'low' -NeedsReboot $false -NeedsAdmin $false -DefaultApply $true -Commands @() -Undo $null))
            }
        }
    } catch {
        $items.Add((New-SRPrepItem -Id 'tune_notifications' -Section 'notifications' -Title 'Toast notifications' -Status 'ERROR' -Current 'unknown' -Target '0' -Detail "Error inspecting notification settings: $($_.Exception.Message)" -Risk 'low' -NeedsReboot $false -NeedsAdmin $false -DefaultApply $true -Commands @() -Undo $null))
        [void]$seenIds.Add('tune_notifications')
    }

    return ,$items.ToArray()
}

function Invoke-SRPrepTuneApply {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [array]$Items,

        [Parameter(Mandatory = $false)]
        $Settings,

        [Parameter(Mandatory = $false)]
        [string]$BackupDir,

        [Parameter(Mandatory = $false)]
        [switch]$DryRun,

        [Parameter(Mandatory = $false)]
        [scriptblock]$Log
    )

    $applied = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $Items -or $Items.Count -eq 0) {
        return @()
    }

    $changeItems = @($Items | Where-Object { $_.status -eq 'CHANGE' })
    if ($changeItems.Count -eq 0) {
        if ($Log) { & $Log "No items with status CHANGE to apply." }
        return @()
    }

    if ($DryRun) {
        foreach ($item in $changeItems) {
            if ($item.commands) {
                foreach ($cmd in $item.commands) {
                    $dryMsg = "DRYRUN: $cmd"
                    if ($Log) { & $Log $dryMsg } else { Write-Output $dryMsg }
                }
            }
            $clone = [pscustomobject]@{
                id            = $item.id
                section       = $item.section
                title         = $item.title
                status        = 'SKIPPED'
                current       = $item.current
                target        = $item.target
                detail        = 'dry run'
                risk          = $item.risk
                needs_reboot  = $item.needs_reboot
                needs_admin   = $item.needs_admin
                default_apply = $item.default_apply
                commands      = $item.commands
                undo          = $item.undo
            }
            $applied.Add($clone)
        }
        return ,$applied.ToArray()
    }

    # REAL APPLY (Safety guarded)
    if (-not [string]::IsNullOrEmpty($BackupDir)) {
        if (-not (Test-Path -Path $BackupDir)) {
            [void](New-Item -ItemType Directory -Path $BackupDir -Force)
        }
    }

    $undoPath = $null
    if (-not [string]::IsNullOrEmpty($BackupDir)) {
        $undoPath = Join-Path $BackupDir "tune-undo.json"
    }

    $undoEntries = [System.Collections.Generic.List[object]]::new()
    if ($undoPath -and (Test-Path -Path $undoPath)) {
        try {
            $rawJson = Get-Content -Path $undoPath -Raw -ErrorAction SilentlyContinue
            if ($rawJson) {
                $existing = ConvertFrom-Json $rawJson
                if ($existing) {
                    foreach ($e in $existing) { $undoEntries.Add($e) }
                }
            }
        } catch { }
    }

    foreach ($item in $changeItems) {
        $itemStatus = 'DONE'
        $itemDetail = 'Applied successfully'

        # 1. Merge undo into tune-undo.json BEFORE changing anything
        if ($undoPath -and ($null -ne $item.undo)) {
            try {
                $undoRecord = [pscustomobject]@{
                    id      = $item.id
                    section = $item.section
                    title   = $item.title
                    undo    = $item.undo
                }
                $undoEntries.Add($undoRecord)
                $jsonStr = $undoEntries | ConvertTo-Json -Depth 10
                Set-Content -Path $undoPath -Value $jsonStr -Force
            } catch {
                if ($Log) { & $Log "Warning: failed to record undo for $($item.id): $($_.Exception.Message)" }
            }
        }

        # 2. Perform change based on item
        try {
            if ($item.id -eq 'tune_power') {
                $actRes = Invoke-SRPowercfg '/getactivescheme'
                $curActive = $null
                if ($actRes.StdOut -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
                    $curActive = $matches[1].ToLower()
                }
                $targetScheme = $curActive

                $minProcRes = Invoke-SRPowercfg "/query $curActive 54533251-82be-4824-96c1-47b60b740d00 893dee8e-2bef-41e0-89c6-b55d0929964c"
                $minProcVals = Get-SRHexAcDcValues $minProcRes.StdOut
                $isGood = ($curActive -eq $script:HighPerfGuid -or $curActive -eq $script:UltimateGuid -or ($minProcVals -and $minProcVals.ac_val -eq 100))

                if (-not $isGood) {
                    $dupRes = Invoke-SRPowercfg "/duplicatescheme $script:UltimateGuid"
                    $newGuid = $null
                    if ($dupRes.ExitCode -eq 0 -and $dupRes.StdOut -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
                        $newGuid = $matches[1].ToLower()
                        $setRes = Invoke-SRPowercfg "/setactive $newGuid"
                        if ($setRes.ExitCode -eq 0) {
                            $targetScheme = $newGuid
                            if ($item.undo) { $item.undo.created_guid = $newGuid }
                        } else {
                            $newGuid = $null
                        }
                    }
                    if (-not $newGuid) {
                        $hpRes = Invoke-SRPowercfg "/setactive $script:HighPerfGuid"
                        if ($hpRes.ExitCode -eq 0) {
                            $targetScheme = $script:HighPerfGuid
                        } else {
                            $itemStatus = 'FAILED'
                            $itemDetail = 'This PC only allows the Balanced plan (Modern Standby). Plug in mains power and set Power mode to Best performance in Settings > System > Power.'
                        }
                    }
                }

                if ($itemStatus -ne 'FAILED') {
                    [void](Invoke-SRPowercfg '/change standby-timeout-ac 0')
                    [void](Invoke-SRPowercfg '/change hibernate-timeout-ac 0')
                    [void](Invoke-SRPowercfg '/change monitor-timeout-ac 0')
                    [void](Invoke-SRPowercfg '/change disk-timeout-ac 0')
                    [void](Invoke-SRPowercfg "/setacvalueindex $targetScheme 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0")
                    [void](Invoke-SRPowercfg "/setacvalueindex $targetScheme 501a4d13-42af-4429-9fd1-a8ae23f6a9fd ee12f906-d277-404b-b6da-e5fa1a576df5 0")
                    [void](Invoke-SRPowercfg "/setacvalueindex $targetScheme 54533251-82be-4824-96c1-47b60b740d00 893dee8e-2bef-41e0-89c6-b55d0929964c 100")
                    [void](Invoke-SRPowercfg "/setactive $targetScheme")
                }
            } elseif ($item.section -eq 'startup') {
                if ($item.undo -and $item.undo.type -eq 'startup_approved') {
                    $disBytes = New-SRStartupApprovedDisabledBytes
                    if (-not (Test-Path -Path $item.undo.approved_key)) {
                        [void](New-Item -Path $item.undo.approved_key -Force)
                    }
                    Set-ItemProperty -Path $item.undo.approved_key -Name $item.undo.name -Value $disBytes -Type Binary -ErrorAction Stop
                } elseif ($item.undo -and $item.undo.type -eq 'service') {
                    Set-Service -Name $item.undo.name -StartupType Manual -ErrorAction Stop
                    Stop-Service -Name $item.undo.name -Force -ErrorAction Stop
                } elseif ($item.undo -and $item.undo.type -eq 'task') {
                    Disable-ScheduledTask -TaskPath $item.undo.task_path -TaskName $item.undo.task_name -ErrorAction Stop | Out-Null
                }
            } elseif ($item.section -eq 'background') {
                $procName = $item.id.Substring(16)
                Stop-Process -Name $procName -Force -ErrorAction Stop
            } elseif ($item.section -eq 'network') {
                if ($item.undo -and $item.undo.type -eq 'eee') {
                    foreach ($prop in $item.undo.original_values.PSObject.Properties) {
                        Set-NetAdapterAdvancedProperty -Name $item.undo.adapter -RegistryKeyword $prop.Name -RegistryValue 0 -ErrorAction Stop
                    }
                } elseif ($item.undo -and $item.undo.type -eq 'pm') {
                    Set-NetAdapterPowerManagement -Name $item.undo.adapter -AllowComputerToTurnOffDevice Disabled -ErrorAction Stop
                } elseif ($item.undo -and $item.undo.type -eq 'profile') {
                    Set-NetConnectionProfile -InterfaceIndex $item.undo.interface_index -NetworkCategory Private -ErrorAction Stop
                } elseif ($item.undo -and $item.undo.type -eq 'adapter_state') {
                    Disable-NetAdapter -Name $item.undo.adapter -Confirm:$false -ErrorAction Stop
                }
            } elseif ($item.section -eq 'capture') {
                if (-not (Test-Path 'HKCU:\System\GameConfigStore')) {
                    [void](New-Item -Path 'HKCU:\System\GameConfigStore' -Force)
                }
                Set-ItemProperty -Path 'HKCU:\System\GameConfigStore' -Name 'GameDVR_Enabled' -Value 0 -Type DWord -ErrorAction Stop

                if (-not (Test-Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR')) {
                    [void](New-Item -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' -Force)
                }
                Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' -Name 'AppCaptureEnabled' -Value 0 -Type DWord -ErrorAction Stop
            } elseif ($item.section -eq 'notifications') {
                if (-not (Test-Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications')) {
                    [void](New-Item -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications' -Force)
                }
                Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications' -Name 'ToastEnabled' -Value 0 -Type DWord -ErrorAction Stop

                if (-not (Test-Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings')) {
                    [void](New-Item -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings' -Force)
                }
                Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings' -Name 'NOC_GLOBAL_SETTING_TOASTS_ENABLED' -Value 0 -Type DWord -ErrorAction Stop
            }
        } catch {
            $itemStatus = 'FAILED'
            $itemDetail = $_.Exception.Message
            if ($Log) { & $Log "Error applying $($item.id): $($_.Exception.Message)" }
        }

        $applied.Add([pscustomobject]@{
            id            = $item.id
            section       = $item.section
            title         = $item.title
            status        = $itemStatus
            current       = $item.current
            target        = $item.target
            detail        = $itemDetail
            risk          = $item.risk
            needs_reboot  = $item.needs_reboot
            needs_admin   = $item.needs_admin
            default_apply = $item.default_apply
            commands      = $item.commands
            undo          = $item.undo
        })
    }

    return ,$applied.ToArray()
}

function Undo-SRPrepTune {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$BackupDir,

        [Parameter(Mandatory = $false)]
        [switch]$DryRun,

        [Parameter(Mandatory = $false)]
        [scriptblock]$Log
    )

    $results = [System.Collections.Generic.List[object]]::new()
    if ([string]::IsNullOrEmpty($BackupDir)) {
        if ($Log) { & $Log "No BackupDir specified for Undo-SRPrepTune." }
        return @()
    }

    $undoPath = Join-Path $BackupDir "tune-undo.json"
    if (-not (Test-Path -Path $undoPath)) {
        if ($Log) { & $Log "No tune-undo.json found in $BackupDir." }
        return @()
    }

    $entries = @()
    try {
        $raw = Get-Content -Path $undoPath -Raw -ErrorAction SilentlyContinue
        if ($raw) {
            $parsed = ConvertFrom-Json $raw
            if ($parsed) { $entries = @($parsed) }
        }
    } catch {
        if ($Log) { & $Log "Error reading $($undoPath): $($_.Exception.Message)" }
        return @()
    }

    if ($entries.Count -eq 0) {
        return @()
    }

    # Reverse order restoration
    [array]::Reverse($entries)

    foreach ($entry in $entries) {
        $u = $entry.undo
        $id = [string]$entry.id
        $section = [string]$entry.section
        $title = [string]$entry.title

        $restoreCmds = [System.Collections.Generic.List[string]]::new()

        if ($id -eq 'tune_power') {
            if ($u.created_guid) {
                $restoreCmds.Add("powercfg /setactive $($u.previous_active_guid)")
                $restoreCmds.Add("powercfg /delete $($u.created_guid)")
            } else {
                $restoreCmds.Add("powercfg /setactive $($u.previous_active_guid)")
            }
            if ($u.previous_ac_values) {
                $pac = $u.previous_ac_values
                if ($null -ne $pac.standby_timeout) { $restoreCmds.Add("powercfg /change standby-timeout-ac $([int][math]::Ceiling([double]$pac.standby_timeout / 60))") }
                if ($null -ne $pac.hibernate_timeout) { $restoreCmds.Add("powercfg /change hibernate-timeout-ac $([int][math]::Ceiling([double]$pac.hibernate_timeout / 60))") }
                if ($null -ne $pac.monitor_timeout) { $restoreCmds.Add("powercfg /change monitor-timeout-ac $([int][math]::Ceiling([double]$pac.monitor_timeout / 60))") }
                if ($null -ne $pac.disk_timeout) { $restoreCmds.Add("powercfg /change disk-timeout-ac $([int][math]::Ceiling([double]$pac.disk_timeout / 60))") }
                if ($null -ne $pac.usb_suspend) { $restoreCmds.Add("powercfg /setacvalueindex $($u.previous_active_guid) 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 $($pac.usb_suspend)") }
                if ($null -ne $pac.pcie_link_state) { $restoreCmds.Add("powercfg /setacvalueindex $($u.previous_active_guid) 501a4d13-42af-4429-9fd1-a8ae23f6a9fd ee12f906-d277-404b-b6da-e5fa1a576df5 $($pac.pcie_link_state)") }
                if ($null -ne $pac.min_proc_state) { $restoreCmds.Add("powercfg /setacvalueindex $($u.previous_active_guid) 54533251-82be-4824-96c1-47b60b740d00 893dee8e-2bef-41e0-89c6-b55d0929964c $($pac.min_proc_state)") }
                $restoreCmds.Add("powercfg /setactive $($u.previous_active_guid)")
            }
        } elseif ($section -eq 'startup') {
            if ($u.type -eq 'startup_approved') {
                if ($u.previous_val -eq 'absent') {
                    $restoreCmds.Add("Remove-ItemProperty -Path '$($u.approved_key)' -Name '$($u.name)' -ErrorAction SilentlyContinue")
                } else {
                    $restoreCmds.Add("Set-ItemProperty -Path '$($u.approved_key)' -Name '$($u.name)' -Value ([Convert]::FromBase64String('$($u.previous_val)')) -Type Binary")
                }
            } elseif ($u.type -eq 'service') {
                $restoreCmds.Add("Set-Service -Name '$($u.name)' -StartupType $($u.previous_start_mode)")
                if ($u.was_running) {
                    $restoreCmds.Add("Start-Service -Name '$($u.name)'")
                }
            } elseif ($u.type -eq 'task') {
                $restoreCmds.Add("Enable-ScheduledTask -TaskPath '$($u.task_path)' -TaskName '$($u.task_name)'")
            }
        } elseif ($section -eq 'network') {
            if ($u.type -eq 'eee') {
                if ($u.original_values) {
                    foreach ($prop in $u.original_values.PSObject.Properties) {
                        $restoreCmds.Add("Set-NetAdapterAdvancedProperty -Name '$($u.adapter)' -RegistryKeyword '$($prop.Name)' -RegistryValue '$($prop.Value)'")
                    }
                }
            } elseif ($u.type -eq 'pm') {
                $restoreCmds.Add("Set-NetAdapterPowerManagement -Name '$($u.adapter)' -AllowComputerToTurnOffDevice $($u.allow_computer_to_turn_off_device)")
            } elseif ($u.type -eq 'profile') {
                $restoreCmds.Add("Set-NetConnectionProfile -InterfaceIndex $($u.interface_index) -NetworkCategory $($u.network_category)")
            } elseif ($u.type -eq 'adapter_state') {
                $restoreCmds.Add("Enable-NetAdapter -Name '$($u.adapter)' -Confirm:`$false")
            }
        } elseif ($section -eq 'capture') {
            if ($u.game_dvr_enabled -eq 'absent') {
                $restoreCmds.Add("Remove-ItemProperty -Path 'HKCU:\System\GameConfigStore' -Name 'GameDVR_Enabled' -ErrorAction SilentlyContinue")
            } else {
                $restoreCmds.Add("Set-ItemProperty -Path 'HKCU:\System\GameConfigStore' -Name 'GameDVR_Enabled' -Value $($u.game_dvr_enabled) -Type DWord")
            }
            if ($u.app_capture_enabled -eq 'absent') {
                $restoreCmds.Add("Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' -Name 'AppCaptureEnabled' -ErrorAction SilentlyContinue")
            } else {
                $restoreCmds.Add("Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' -Name 'AppCaptureEnabled' -Value $($u.app_capture_enabled) -Type DWord")
            }
        } elseif ($section -eq 'notifications') {
            if ($u.toast_enabled -eq 'absent') {
                $restoreCmds.Add("Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications' -Name 'ToastEnabled' -ErrorAction SilentlyContinue")
            } else {
                $restoreCmds.Add("Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications' -Name 'ToastEnabled' -Value $($u.toast_enabled) -Type DWord")
            }
            if ($u.noc_global_setting_toasts_enabled -eq 'absent') {
                $restoreCmds.Add("Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings' -Name 'NOC_GLOBAL_SETTING_TOASTS_ENABLED' -ErrorAction SilentlyContinue")
            } else {
                $restoreCmds.Add("Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings' -Name 'NOC_GLOBAL_SETTING_TOASTS_ENABLED' -Value $($u.noc_global_setting_toasts_enabled) -Type DWord")
            }
        }

        if ($DryRun) {
            foreach ($cmd in $restoreCmds) {
                $dryMsg = "DRYRUN: $cmd"
                if ($Log) { & $Log $dryMsg } else { Write-Output $dryMsg }
            }
            $results.Add([pscustomobject]@{
                id            = $id
                section       = $section
                title         = $title
                status        = 'SKIPPED'
                current       = 'restored'
                target        = 'restored'
                detail        = 'dry run'
                risk          = 'low'
                needs_reboot  = $false
                needs_admin   = $false
                default_apply = $false
                commands      = ($restoreCmds.ToArray())
                undo          = $null
            })
        } else {
            # Real execute
            $status = 'DONE'
            $detail = 'Restored successfully'
            try {
                if ($id -eq 'tune_power') {
                    if ($u.created_guid) {
                        [void](Invoke-SRPowercfg "/setactive $($u.previous_active_guid)")
                        [void](Invoke-SRPowercfg "/delete $($u.created_guid)")
                    } else {
                        [void](Invoke-SRPowercfg "/setactive $($u.previous_active_guid)")
                    }
                    if ($u.previous_ac_values) {
                        $pac = $u.previous_ac_values
                        if ($null -ne $pac.standby_timeout) { [void](Invoke-SRPowercfg "/change standby-timeout-ac $([int][math]::Ceiling([double]$pac.standby_timeout / 60))") }
                        if ($null -ne $pac.hibernate_timeout) { [void](Invoke-SRPowercfg "/change hibernate-timeout-ac $([int][math]::Ceiling([double]$pac.hibernate_timeout / 60))") }
                        if ($null -ne $pac.monitor_timeout) { [void](Invoke-SRPowercfg "/change monitor-timeout-ac $([int][math]::Ceiling([double]$pac.monitor_timeout / 60))") }
                        if ($null -ne $pac.disk_timeout) { [void](Invoke-SRPowercfg "/change disk-timeout-ac $([int][math]::Ceiling([double]$pac.disk_timeout / 60))") }
                        if ($null -ne $pac.usb_suspend) { [void](Invoke-SRPowercfg "/setacvalueindex $($u.previous_active_guid) 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 $($pac.usb_suspend)") }
                        if ($null -ne $pac.pcie_link_state) { [void](Invoke-SRPowercfg "/setacvalueindex $($u.previous_active_guid) 501a4d13-42af-4429-9fd1-a8ae23f6a9fd ee12f906-d277-404b-b6da-e5fa1a576df5 $($pac.pcie_link_state)") }
                        if ($null -ne $pac.min_proc_state) { [void](Invoke-SRPowercfg "/setacvalueindex $($u.previous_active_guid) 54533251-82be-4824-96c1-47b60b740d00 893dee8e-2bef-41e0-89c6-b55d0929964c $($pac.min_proc_state)") }
                        [void](Invoke-SRPowercfg "/setactive $($u.previous_active_guid)")
                    }
                } elseif ($section -eq 'startup') {
                    if ($u.type -eq 'startup_approved') {
                        if ($u.previous_val -eq 'absent') {
                            Remove-ItemProperty -Path $u.approved_key -Name $u.name -ErrorAction SilentlyContinue
                        } else {
                            $bytes = [Convert]::FromBase64String($u.previous_val)
                            Set-ItemProperty -Path $u.approved_key -Name $u.name -Value $bytes -Type Binary -ErrorAction Stop
                        }
                    } elseif ($u.type -eq 'service') {
                        Set-Service -Name $u.name -StartupType $u.previous_start_mode -ErrorAction Stop
                        if ($u.was_running) {
                            Start-Service -Name $u.name -ErrorAction Stop
                        }
                    } elseif ($u.type -eq 'task') {
                        Enable-ScheduledTask -TaskPath $u.task_path -TaskName $u.task_name -ErrorAction Stop | Out-Null
                    }
                } elseif ($section -eq 'network') {
                    if ($u.type -eq 'eee') {
                        if ($u.original_values) {
                            foreach ($prop in $u.original_values.PSObject.Properties) {
                                Set-NetAdapterAdvancedProperty -Name $u.adapter -RegistryKeyword $prop.Name -RegistryValue $prop.Value -ErrorAction Stop
                            }
                        }
                    } elseif ($u.type -eq 'pm') {
                        Set-NetAdapterPowerManagement -Name $u.adapter -AllowComputerToTurnOffDevice $u.allow_computer_to_turn_off_device -ErrorAction Stop
                    } elseif ($u.type -eq 'profile') {
                        Set-NetConnectionProfile -InterfaceIndex $u.interface_index -NetworkCategory $u.network_category -ErrorAction Stop
                    } elseif ($u.type -eq 'adapter_state') {
                        Enable-NetAdapter -Name $u.adapter -Confirm:$false -ErrorAction Stop
                    }
                } elseif ($section -eq 'capture') {
                    if ($u.game_dvr_enabled -eq 'absent') {
                        Remove-ItemProperty -Path 'HKCU:\System\GameConfigStore' -Name 'GameDVR_Enabled' -ErrorAction SilentlyContinue
                    } else {
                        Set-ItemProperty -Path 'HKCU:\System\GameConfigStore' -Name 'GameDVR_Enabled' -Value $u.game_dvr_enabled -Type DWord -ErrorAction Stop
                    }
                    if ($u.app_capture_enabled -eq 'absent') {
                        Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' -Name 'AppCaptureEnabled' -ErrorAction SilentlyContinue
                    } else {
                        Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' -Name 'AppCaptureEnabled' -Value $u.app_capture_enabled -Type DWord -ErrorAction Stop
                    }
                } elseif ($section -eq 'notifications') {
                    if ($u.toast_enabled -eq 'absent') {
                        Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications' -Name 'ToastEnabled' -ErrorAction SilentlyContinue
                    } else {
                        Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications' -Name 'ToastEnabled' -Value $u.toast_enabled -Type DWord -ErrorAction Stop
                    }
                    if ($u.noc_global_setting_toasts_enabled -eq 'absent') {
                        Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings' -Name 'NOC_GLOBAL_SETTING_TOASTS_ENABLED' -ErrorAction SilentlyContinue
                    } else {
                        Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings' -Name 'NOC_GLOBAL_SETTING_TOASTS_ENABLED' -Value $u.noc_global_setting_toasts_enabled -Type DWord -ErrorAction Stop
                    }
                }
            } catch {
                $status = 'FAILED'
                $detail = $_.Exception.Message
                if ($Log) { & $Log "Error undoing $($id): $($_.Exception.Message)" }
            }

            $results.Add([pscustomobject]@{
                id            = $id
                section       = $section
                title         = $title
                status        = $status
                current       = 'restored'
                target        = 'restored'
                detail        = $detail
                risk          = 'low'
                needs_reboot  = $false
                needs_admin   = $false
                default_apply = $false
                commands      = ($restoreCmds.ToArray())
                undo          = $null
            })
        }
    }

    return ,$results.ToArray()
}
