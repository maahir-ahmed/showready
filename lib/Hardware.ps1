<#
.SYNOPSIS
    ShowReady Hardware Collector (lib\Hardware.ps1)
.DESCRIPTION
    Collects hardware, OS, network adapters, GPU, power, storage, software,
    Windows configurations, and running watchlist processes for ShowReady.
    Complies with ShowReady CONTRACT.md and works under Windows PowerShell 5.1 and pwsh 7.
#>

function Get-SRHardware {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [scriptblock]$Log
    )

    $errors = [System.Collections.Generic.List[string]]::new()

    # 1. Operating System
    if ($Log) { & $Log "Inspecting Operating System..." }
    $osObj = $null
    try {
        $osCim = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $osObj = [pscustomobject]@{
            caption = [string]$osCim.Caption
            version = [string]$osCim.Version
            build   = [string]$osCim.BuildNumber
        }
    } catch {
        $errors.Add("Failed to query Win32_OperatingSystem: $($_.Exception.Message)")
    }

    # 2. Computer & Laptop detection
    if ($Log) { & $Log "Inspecting Computer System..." }
    $computerObj = $null
    try {
        $csCim = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop

        $isLaptop = $false
        # Check chassis type
        try {
            $enclosures = @(Get-CimInstance Win32_SystemEnclosure -ErrorAction SilentlyContinue)
            foreach ($enc in $enclosures) {
                if ($enc.ChassisTypes) {
                    foreach ($ct in $enc.ChassisTypes) {
                        # Chassis types: 8 (Portable), 9 (Laptop), 10 (Notebook), 11 (Hand Held),
                        # 12 (Docking Station), 14 (Sub Notebook), 30 (Tablet), 31 (Convertible), 32 (Detachable)
                        if ($ct -in @(8, 9, 10, 11, 12, 14, 30, 31, 32)) {
                            $isLaptop = $true
                            break
                        }
                    }
                }
            }
        } catch { }

        # Check battery presence
        try {
            $batteries = @(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
            if ($batteries -and $batteries.Count -gt 0) {
                $isLaptop = $true
            }
        } catch { }

        $computerObj = [pscustomobject]@{
            name         = [string]$csCim.Name
            manufacturer = [string]$csCim.Manufacturer
            model        = [string]$csCim.Model
            is_laptop    = [bool]$isLaptop
        }
    } catch {
        $errors.Add("Failed to query Win32_ComputerSystem: $($_.Exception.Message)")
    }

    # 3. CPU
    if ($Log) { & $Log "Inspecting Processor..." }
    $cpuObj = $null
    try {
        $procs = @(Get-CimInstance Win32_Processor -ErrorAction Stop)
        if ($procs.Count -gt 0) {
            $cpuName = [string]$procs[0].Name
            $cores = 0
            $threads = 0
            $maxMhz = 0
            foreach ($p in $procs) {
                $cores += [int]$p.NumberOfCores
                $threads += [int]$p.NumberOfLogicalProcessors
                if ($p.MaxClockSpeed -gt $maxMhz) {
                    $maxMhz = [int]$p.MaxClockSpeed
                }
            }
            $cpuObj = [pscustomobject]@{
                name    = $cpuName.Trim()
                cores   = [int]$cores
                threads = [int]$threads
                max_mhz = [int]$maxMhz
            }
        }
    } catch {
        $errors.Add("Failed to query Win32_Processor: $($_.Exception.Message)")
    }

    # 4. RAM
    if ($Log) { & $Log "Inspecting Physical Memory..." }
    $ramGb = $null
    try {
        $csMem = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        if ($csMem.TotalPhysicalMemory -ne $null -and $csMem.TotalPhysicalMemory -gt 0) {
            $ramGb = [double][Math]::Round([double]$csMem.TotalPhysicalMemory / 1GB, 1)
        } else {
            # Fallback to Win32_PhysicalMemory sum
            $physMems = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue)
            $totalCap = 0.0
            foreach ($m in $physMems) {
                $totalCap += [double]$m.Capacity
            }
            if ($totalCap -gt 0) {
                $ramGb = [double][Math]::Round($totalCap / 1GB, 1)
            }
        }
    } catch {
        $errors.Add("Failed to inspect RAM: $($_.Exception.Message)")
    }

    # 5. GPUs
    if ($Log) { & $Log "Inspecting GPUs..." }
    $gpus = @()
    try {
        $vcs = @(Get-CimInstance Win32_VideoController -ErrorAction Stop)
        foreach ($vc in $vcs) {
            $name = if ($vc.Name) { [string]$vc.Name } else { "" }
            $compat = if ($vc.AdapterCompatibility) { [string]$vc.AdapterCompatibility } else { "" }

            # Vendor detection (use word boundaries to avoid false positives like Corporation matching ATI)
            $vendor = "Other"
            if ($name -match '\bNVIDIA\b' -or $compat -match '\bNVIDIA\b') {
                $vendor = "NVIDIA"
            } elseif ($name -match '\b(AMD|Radeon|ATI)\b' -or $compat -match '\b(AMD|Radeon|ATI)\b|Advanced\s+Micro\s+Devices') {
                $vendor = "AMD"
            } elseif ($name -match '\bIntel\b' -or $compat -match '\bIntel\b') {
                $vendor = "Intel"
            }

            # Integrated detection
            $integrated = $false
            if ($vendor -eq "Intel") {
                # Intel Arc discrete cards (e.g. Arc A770, Arc A380, Arc Pro, Iris Xe MAX)
                if ($name -match 'Arc\s+[AB]\d|Iris\s+Xe\s+MAX' -and $name -notmatch 'Arc\(TM\)\s+Graphics') {
                    $integrated = $false
                } else {
                    $integrated = $true
                }
            } elseif ($vendor -eq "AMD") {
                if ($name -match 'Radeon\(TM\)\s+Graphics|Radeon\s+Graphics\b|Vega\s+\d|APU\b') {
                    $integrated = $true
                } else {
                    $integrated = $false
                }
            } elseif ($vendor -eq "NVIDIA") {
                $integrated = $false
            } else {
                $integrated = $false
            }

            # Driver version string
            $driverVer = if ($vc.DriverVersion) { [string]$vc.DriverVersion } else { $null }

            # nvidia_driver: e.g. 560.94 as number, from last 5 digits of driver_version; null if not NVIDIA
            $nvidiaDriver = $null
            if ($vendor -eq "NVIDIA" -and $driverVer) {
                $cleanDigits = ($driverVer -replace '[^0-9]', '')
                if ($cleanDigits.Length -ge 5) {
                    $last5 = $cleanDigits.Substring($cleanDigits.Length - 5)
                    $major = $last5.Substring(0, 3)
                    $minor = $last5.Substring(3, 2)
                    $nvidiaDriver = [double]"$major.$minor"
                }
            }

            # driver_date "yyyy-MM-dd"
            $driverDate = $null
            if ($vc.DriverDate) {
                if ($vc.DriverDate -is [System.DateTime]) {
                    $driverDate = $vc.DriverDate.ToString('yyyy-MM-dd')
                } else {
                    try {
                        $parsedDate = [DateTime]::Parse($vc.DriverDate)
                        $driverDate = $parsedDate.ToString('yyyy-MM-dd')
                    } catch {
                        $driverDate = [string]$vc.DriverDate
                    }
                }
            }

            # vram_gb: from registry HardwareInformation.qwMemorySize when available
            $vramGb = $null
            try {
                $baseKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
                for ($i = 0; $i -le 16; $i++) {
                    $subKeyName = ('{0:D4}' -f $i)
                    $subKeyPath = "$baseKey\$subKeyName"
                    if (Test-Path -LiteralPath $subKeyPath) {
                        $prop = Get-ItemProperty -LiteralPath $subKeyPath -ErrorAction SilentlyContinue
                        if ($prop) {
                            $matchFound = $false
                            if ($prop.DriverDesc -and $prop.DriverDesc -eq $name) {
                                $matchFound = $true
                            } elseif ($prop.DriverVersion -and $prop.DriverVersion -eq $driverVer) {
                                $matchFound = $true
                            } elseif ($prop.MatchingDeviceId -and $vc.PNPDeviceID -and $vc.PNPDeviceID.ToLower().Contains($prop.MatchingDeviceId.ToLower())) {
                                $matchFound = $true
                            }

                            if ($matchFound) {
                                $qw = $prop.'HardwareInformation.qwMemorySize'
                                if ($qw -ne $null) {
                                    $rawBytes = $null
                                    if ($qw -is [byte[]]) {
                                        $rawBytes = [BitConverter]::ToInt64($qw, 0)
                                    } elseif ($qw -is [int64] -or $qw -is [int32] -or $qw -is [double]) {
                                        $rawBytes = [int64]$qw
                                    }
                                    if ($rawBytes -and $rawBytes -gt 0) {
                                        $vramGb = [double][Math]::Round($rawBytes / 1GB, 1)
                                        break
                                    }
                                }
                            }
                        }
                    }
                }
            } catch { }

            $gpus += [pscustomobject]@{
                name           = $name
                vendor         = $vendor
                integrated     = [bool]$integrated
                driver_version = $driverVer
                nvidia_driver  = $nvidiaDriver
                driver_date    = $driverDate
                vram_gb        = $vramGb
            }
        }
    } catch {
        $errors.Add("Failed to inspect GPUs: $($_.Exception.Message)")
    }

    # 6. Network Adapters
    if ($Log) { & $Log "Inspecting Network Adapters..." }
    $nics = @()
    try {
        # Determine default route interface index
        $defaultRouteIfIndex = $null
        try {
            $routes = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -AddressFamily IPv4 -ErrorAction SilentlyContinue)
            if ($routes.Count -gt 0) {
                $bestRoute = $routes | Sort-Object RouteMetric, Metric | Select-Object -First 1
                $defaultRouteIfIndex = $bestRoute.InterfaceIndex
            }
        } catch { }

        $adapters = @(Get-NetAdapter -ErrorAction Stop)
        foreach ($adapter in $adapters) {
            $name = [string]$adapter.Name
            $desc = [string]$adapter.InterfaceDescription
            $status = [string]$adapter.Status

            # Virtual check:
            # kind=virtual when not HardwareInterface or description matches Hyper-V|Virtual|vEthernet|VPN|TAP|
            # WireGuard|Tailscale|ZeroTier|VMware|VirtualBox|Loopback|WAN Miniport|Bluetooth.
            $isVirtual = $false
            if (-not $adapter.HardwareInterface -or $adapter.Virtual) {
                $isVirtual = $true
            } elseif ($desc -match 'Hyper-V|Virtual|vEthernet|VPN|TAP|WireGuard|Tailscale|ZeroTier|VMware|VirtualBox|Loopback|WAN Miniport|Bluetooth' -or $name -match 'Hyper-V|Virtual|vEthernet|VPN|TAP|WireGuard|Tailscale|ZeroTier|VMware|VirtualBox|Loopback|WAN Miniport|Bluetooth') {
                $isVirtual = $true
            }

            $kind = "other"
            if ($isVirtual) {
                $kind = "virtual"
            } elseif ($adapter.PhysicalMediaType -match '802\.11' -or $adapter.MediaType -match '802\.11' -or $desc -match 'Wi-?Fi|Wireless|802\.11') {
                $kind = "wifi"
            } elseif ($adapter.PhysicalMediaType -match '802\.3|Ethernet' -or $adapter.MediaType -match '802\.3' -or $desc -match 'Ethernet|Gigabit|GbE|LAN|Realtek|Intel\(R\) Ethernet') {
                $kind = "wired"
            } else {
                $kind = "other"
            }

            # link_mbps (number|null)
            $linkMbps = $null
            if ($status -eq "Up" -and $adapter.Speed -ne $null -and $adapter.Speed -gt 0) {
                $linkMbps = [int64][Math]::Round([double]$adapter.Speed / 1000000)
            }

            # default_route (bool)
            $isDefault = ($defaultRouteIfIndex -ne $null -and $adapter.InterfaceIndex -eq $defaultRouteIfIndex)

            # ipv4 [..]
            $ipv4List = @()
            try {
                $ips = Get-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
                if ($ips) {
                    foreach ($ip in $ips) {
                        if ($ip.IPAddress) {
                            $ipv4List += [string]$ip.IPAddress
                        }
                    }
                }
            } catch { }

            # network_category: "Public"|"Private"|"DomainAuthenticated"|null
            $netCategory = $null
            try {
                $connProfile = Get-NetConnectionProfile -InterfaceIndex $adapter.InterfaceIndex -ErrorAction SilentlyContinue
                if (-not $connProfile) {
                    $connProfile = Get-NetConnectionProfile -InterfaceAlias $adapter.Name -ErrorAction SilentlyContinue
                }
                if ($connProfile -ne $null -and $connProfile.NetworkCategory -ne $null) {
                    $netCategory = [string]$connProfile.NetworkCategory
                }
            } catch { }

            # eee: "on"|"off"|"unknown"
            $eee = "unknown"
            if ($kind -eq "wired") {
                try {
                    $advProps = Get-NetAdapterAdvancedProperty -Name $adapter.Name -ErrorAction SilentlyContinue |
                        Where-Object { $_.RegistryKeyword -match 'EEE|Energy|Green' -or $_.DisplayName -match 'EEE|Energy|Green' }
                    if ($advProps) {
                        foreach ($p in $advProps) {
                            $val = [string]$p.RegistryValue
                            $disp = [string]$p.DisplayValue
                            if ($val -eq '1' -or $disp -match '(?i)Enabled|On') {
                                $eee = "on"
                                break
                            } elseif ($val -eq '0' -or $disp -match '(?i)Disabled|Off') {
                                $eee = "off"
                            }
                        }
                    }
                } catch { }
            }

            $nics += [pscustomobject]@{
                name             = $name
                description      = $desc
                status           = $status
                link_mbps        = $linkMbps
                kind             = $kind
                default_route    = [bool]$isDefault
                ipv4             = @($ipv4List)
                network_category = $netCategory
                eee              = $eee
            }
        }
    } catch {
        $errors.Add("Failed to inspect network adapters: $($_.Exception.Message)")
    }

    # 7. Power
    if ($Log) { & $Log "Inspecting Power..." }
    $powerObj = $null
    try {
        $planGuid = $null
        try {
            $rawScheme = Get-ItemPropertyValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes' -Name 'ActivePowerScheme' -ErrorAction Stop
            if ($rawScheme -match '([a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12})') {
                $planGuid = $matches[1].ToLower()
            }
        } catch { }

        if (-not $planGuid) {
            try {
                $pinfo = New-Object System.Diagnostics.ProcessStartInfo
                $pinfo.FileName = "powercfg.exe"
                $pinfo.Arguments = "/getactivescheme"
                $pinfo.RedirectStandardOutput = $true
                $pinfo.RedirectStandardError = $true
                $pinfo.UseShellExecute = $false
                $pinfo.CreateNoWindow = $true
                $proc = [System.Diagnostics.Process]::Start($pinfo)
                if ($proc.WaitForExit(3000)) {
                    $cfgOut = $proc.StandardOutput.ReadToEnd()
                    if ($cfgOut -match '([a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12})') {
                        $planGuid = $matches[1].ToLower()
                    }
                } else {
                    $proc.Kill()
                }
            } catch { }
        }

        # Plan mapping:
        # 381b4222-f694-41f0-9685-ff5bb260df2e balanced
        # 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c high_performance
        # e9a42b02-d5df-448d-aa00-03f14749eb61 ultimate
        # a1841308-3541-4fab-bc81-f71556f20b4a power_saver
        $plan = "custom"
        if ($planGuid -eq "381b4222-f694-41f0-9685-ff5bb260df2e") {
            $plan = "balanced"
        } elseif ($planGuid -eq "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c") {
            $plan = "high_performance"
        } elseif ($planGuid -eq "e9a42b02-d5df-448d-aa00-03f14749eb61") {
            $plan = "ultimate"
        } elseif ($planGuid -eq "a1841308-3541-4fab-bc81-f71556f20b4a") {
            $plan = "power_saver"
        }

        $onBattery = $null
        $batteryPct = $null
        $bats = @(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
        if ($bats.Count -gt 0) {
            if ($bats[0].EstimatedChargeRemaining -ne $null) {
                $batteryPct = [int]$bats[0].EstimatedChargeRemaining
            }
        }

        try {
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
            $ps = [System.Windows.Forms.SystemInformation]::PowerStatus
            if ($ps) {
                if ($ps.PowerLineStatus -eq [System.Windows.Forms.PowerLineStatus]::Offline) {
                    $onBattery = $true
                } elseif ($ps.PowerLineStatus -eq [System.Windows.Forms.PowerLineStatus]::Online) {
                    $onBattery = $false
                }
                if ($batteryPct -eq $null -and $ps.BatteryLifePercent -ge 0 -and $ps.BatteryLifePercent -le 1) {
                    $batteryPct = [int][Math]::Round($ps.BatteryLifePercent * 100)
                }
            }
        } catch { }

        if ($onBattery -eq $null) {
            if ($bats.Count -gt 0) {
                if ($bats[0].BatteryStatus -eq 1) {
                    $onBattery = $true
                } elseif ($bats[0].BatteryStatus -ge 2) {
                    $onBattery = $false
                }
            } else {
                # Desktop PC without battery is running on mains power
                $onBattery = $false
            }
        }

        $powerObj = [pscustomobject]@{
            plan_guid   = $planGuid
            plan        = $plan
            on_battery  = $onBattery
            battery_pct = $batteryPct
        }
    } catch {
        $errors.Add("Failed to inspect power: $($_.Exception.Message)")
    }

    # 8. Disk
    if ($Log) { & $Log "Inspecting Disk..." }
    $diskObj = $null
    try {
        $sysDrive = if ($env:SystemDrive) { $env:SystemDrive } else { "C:" }
        $diskCim = Get-CimInstance Win32_LogicalDisk -ErrorAction Stop | Where-Object { $_.DeviceID -eq $sysDrive }
        if ($diskCim) {
            $diskObj = [pscustomobject]@{
                system_drive = [string]$sysDrive
                free_gb      = [double][Math]::Round([double]$diskCim.FreeSpace / 1GB, 1)
                total_gb     = [double][Math]::Round([double]$diskCim.Size / 1GB, 1)
            }
        }
    } catch {
        $errors.Add("Failed to inspect disk: $($_.Exception.Message)")
    }

    # 9. Software
    if ($Log) { & $Log "Inspecting Installed Software..." }
    $softwareObj = $null
    try {
        $regPaths = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        )
        $installed = @(Get-ItemProperty -Path $regPaths -ErrorAction SilentlyContinue)

        $vmixVer = $null
        $obsVer = $null
        $obsInstallLoc = $null
        $ndiRuntimeVer = $null
        $ndiToolsVer = $null
        $distroavVer = $null
        $omtVer = $null

        foreach ($app in $installed) {
            $dn = if ($app.DisplayName) { [string]$app.DisplayName } else { "" }
            $dv = if ($app.DisplayVersion) { [string]$app.DisplayVersion } else { $null }

            # vMix
            if (-not $vmixVer -and $dn -match '(?i)\bvmix\b') {
                $vmixVer = $dv
            }

            # OBS Studio
            if (-not $obsVer -and $dn -match '(?i)^obs\s+studio\b') {
                $obsVer = $dv
                if ($app.InstallLocation) {
                    $obsInstallLoc = [string]$app.InstallLocation
                }
            }

            # NDI Runtime: NDI Runtime / Core / Redistributable
            if (-not $ndiRuntimeVer -and ($dn -match '(?i)\bndi\b.*(runtime|core|redistributable)' -or $dn -match '(?i)newtek.*ndi.*runtime')) {
                $ndiRuntimeVer = $dv
            }

            # NDI Tools
            if (-not $ndiToolsVer -and ($dn -match '(?i)\bndi\b.*tools' -or $dn -match '(?i)newtek.*ndi.*tools')) {
                $ndiToolsVer = $dv
            }

            # DistroAV (obs-ndi) from uninstall registry
            if (-not $distroavVer -and $dn -match '(?i)\b(distroav|obs-ndi)\b') {
                $distroavVer = $dv
            }

            # OMT
            if (-not $omtVer -and $dn -match '(?i)\bomt\b|open\s*media\s*transport') {
                $omtVer = $dv
            }
        }

        # If distroav not found in registry, check OBS plugin folders
        if (-not $distroavVer) {
            $pluginDlls = @(
                'C:\Program Files\obs-studio\obs-plugins\64bit\distroav.dll',
                'C:\Program Files\obs-studio\obs-plugins\64bit\obs-ndi.dll',
                'C:\ProgramData\obs-studio\plugins\distroav\bin\64bit\distroav.dll',
                'C:\ProgramData\obs-studio\plugins\obs-ndi\bin\64bit\obs-ndi.dll',
                (Join-Path $env:APPDATA 'obs-studio\plugins\distroav\bin\64bit\distroav.dll'),
                (Join-Path $env:APPDATA 'obs-studio\plugins\obs-ndi\bin\64bit\obs-ndi.dll')
            )
            if ($obsInstallLoc) {
                $pluginDlls += (Join-Path $obsInstallLoc 'obs-plugins\64bit\distroav.dll')
                $pluginDlls += (Join-Path $obsInstallLoc 'obs-plugins\64bit\obs-ndi.dll')
            }

            foreach ($dll in $pluginDlls) {
                if (Test-Path -LiteralPath $dll) {
                    try {
                        $vi = (Get-Item -LiteralPath $dll).VersionInfo
                        if ($vi.ProductVersion) {
                            $distroavVer = [string]$vi.ProductVersion
                            break
                        } elseif ($vi.FileVersion) {
                            $distroavVer = [string]$vi.FileVersion
                            break
                        }
                    } catch { }
                }
            }
        }

        $softwareObj = [pscustomobject]@{
            vmix        = $vmixVer
            obs         = $obsVer
            ndi_runtime = $ndiRuntimeVer
            ndi_tools   = $ndiToolsVer
            distroav    = $distroavVer
            omt         = $omtVer
        }
    } catch {
        $errors.Add("Failed to inspect installed software: $($_.Exception.Message)")
    }

    # 10. Windows
    if ($Log) { & $Log "Inspecting Windows Settings..." }
    $windowsObj = $null
    try {
        # HAGS: HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers HwSchMode 2=on
        $hags = "unknown"
        try {
            $hwSch = Get-ItemPropertyValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name 'HwSchMode' -ErrorAction SilentlyContinue
            if ($hwSch -eq 2) {
                $hags = "on"
            } elseif ($hwSch -eq 1) {
                $hags = "off"
            } elseif ($hwSch -ne $null) {
                $hags = "unknown"
            }
        } catch {
            $hags = "unknown"
        }

        # Game Mode: HKCU\Software\Microsoft\GameBar AutoGameModeEnabled
        $gameMode = "unknown"
        try {
            $gm = Get-ItemPropertyValue -Path 'HKCU:\Software\Microsoft\GameBar' -Name 'AutoGameModeEnabled' -ErrorAction SilentlyContinue
            if ($gm -eq 1) {
                $gameMode = "on"
            } elseif ($gm -eq 0) {
                $gameMode = "off"
            }
        } catch {
            $gameMode = "unknown"
        }

        # Pending reboot: (bool)
        $pendingReboot = $false
        try {
            $cbs = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
            $wu = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
            $sm = $false
            $smProp = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue
            if ($smProp -and $smProp.PendingFileRenameOperations) {
                $sm = $true
            }
            if ($cbs -or $wu -or $sm) {
                $pendingReboot = $true
            }
        } catch { }

        # Firewall profiles: [ { name, enabled } ]
        $firewallProfiles = @()
        try {
            $fw = Get-NetFirewallProfile -ErrorAction Stop
            foreach ($p in $fw) {
                $isEnabled = ($p.Enabled.ToString() -eq 'True' -or $p.Enabled -eq 1 -or $p.Enabled -eq $true)
                $firewallProfiles += [pscustomobject]@{
                    name    = [string]$p.Name
                    enabled = [bool]$isEnabled
                }
            }
        } catch {
            $profilesMap = @(
                @{ Name = 'Domain'; Path = 'HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\DomainProfile' },
                @{ Name = 'Private'; Path = 'HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\StandardProfile' },
                @{ Name = 'Public'; Path = 'HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\PublicProfile' }
            )
            foreach ($m in $profilesMap) {
                $en = $true
                try {
                    $val = Get-ItemPropertyValue -Path $m.Path -Name 'EnableFirewall' -ErrorAction SilentlyContinue
                    if ($val -eq 0) { $en = $false }
                } catch { }
                $firewallProfiles += [pscustomobject]@{
                    name    = [string]$m.Name
                    enabled = [bool]$en
                }
            }
        }

        $windowsObj = [pscustomobject]@{
            hags              = $hags
            game_mode         = $gameMode
            pending_reboot    = [bool]$pendingReboot
            firewall_profiles = @($firewallProfiles)
        }
    } catch {
        $errors.Add("Failed to inspect Windows settings: $($_.Exception.Message)")
    }

    # 11. Processes
    if ($Log) { & $Log "Inspecting Running Processes..." }
    $processesObj = [pscustomobject]@{ running = @() }
    try {
        $allProcs = @(Get-Process -ErrorAction SilentlyContinue)
        $procNames = $allProcs | Select-Object -ExpandProperty ProcessName -Unique
        # Watchlist: vMix64, vMix, obs64, OneDrive, Teams, ms-teams, Discord, Steam, chrome, msedge,
        #            EpicGamesLauncher, Dropbox, GoogleDriveFS, NDI*, OMT*
        $runningList = @()
        $pattern = '^(vMix64|vMix|obs64|OneDrive|Teams|ms-teams|Discord|Steam|chrome|msedge|EpicGamesLauncher|Dropbox|GoogleDriveFS|NDI.*|OMT.*)$'
        foreach ($pName in $procNames) {
            if ($pName -match $pattern) {
                $runningList += [string]$pName
            }
        }
        $processesObj = [pscustomobject]@{
            running = @($runningList | Sort-Object -Unique)
        }
    } catch {
        $errors.Add("Failed to inspect running processes: $($_.Exception.Message)")
    }

    if ($Log) { & $Log "Hardware probe complete." }

    return [pscustomobject]@{
        os        = $osObj
        computer  = $computerObj
        cpu       = $cpuObj
        ram_gb    = $ramGb
        gpus      = @($gpus)
        nics      = @($nics)
        power     = $powerObj
        disk      = $diskObj
        software  = $softwareObj
        windows   = $windowsObj
        processes = $processesObj
        errors    = @($errors)
    }
}
