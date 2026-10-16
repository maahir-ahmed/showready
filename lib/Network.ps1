# ShowReady - Network Collector
# Compatible with Windows PowerShell 5.1 and PowerShell 7+
# Locale-independent (numbers, IPs, CIM classes only; no translated strings)

function Get-SRPercentile {
    param(
        [double[]]$SortedList,
        [double]$Percentile
    )
    if ($null -eq $SortedList -or $SortedList.Count -eq 0) {
        return $null
    }
    if ($SortedList.Count -eq 1) {
        return [math]::Round($SortedList[0], 1)
    }
    $n = $SortedList.Count
    $idx = [int][math]::Ceiling(($Percentile / 100.0) * $n) - 1
    if ($idx -lt 0) { $idx = 0 }
    if ($idx -ge $n) { $idx = $n - 1 }
    return [math]::Round($SortedList[$idx], 1)
}

function Invoke-SRNetwork {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Config,

        [Parameter(Mandatory = $true)]
        [string]$BinDir,

        [ValidateSet('quick', 'full')]
        [string]$Mode = 'quick',

        [scriptblock]$Log = $null
    )

    $errors = New-Object System.Collections.Generic.List[string]

    # Helper for logging progress
    $logger = {
        param([string]$Message)
        if ($null -ne $Log) {
            try {
                & $Log $Message
            } catch {
                # Ignore logging errors
            }
        }
    }

    # ---------------------------------------------------------
    # 1. Public IP Lookup
    # ---------------------------------------------------------
    & $logger "Resolving public IP information..."
    $publicResult = $null
    try {
        $lookupUrl = "https://ipinfo.io/json"
        if ($Config.network -and $Config.network.public_ip_lookup) {
            $lookupUrl = $Config.network.public_ip_lookup
        }

        $req = [System.Net.HttpWebRequest]::Create($lookupUrl)
        $req.Timeout = 8000
        $req.ReadWriteTimeout = 8000
        $req.UserAgent = "curl/8.4.0"
        $resp = $req.GetResponse()
        $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $content = $sr.ReadToEnd()
        $sr.Close()
        $resp.Close()

        $ipJson = $content | ConvertFrom-Json
        $publicResult = [pscustomobject]@{
            ip      = if ($ipJson.ip) { [string]$ipJson.ip } else { $null }
            city    = if ($ipJson.city) { [string]$ipJson.city } else { $null }
            country = if ($ipJson.country) { [string]$ipJson.country } else { $null }
            org     = if ($ipJson.org) { [string]$ipJson.org } else { $null }
        }
    } catch {
        $errors.Add("Public IP lookup failed: $($_.Exception.Message)")
        $publicResult = $null
    }

    # ---------------------------------------------------------
    # 2. Targets: ICMP and TCP Probing
    # ---------------------------------------------------------
    $targetsConfig = @()
    if ($Config.network -and $Config.network.targets) {
        $targetsConfig = $Config.network.targets
    }

    # Resolve IPv4 for all targets
    $resolvedTargets = @()
    foreach ($t in $targetsConfig) {
        $ipStr = $null
        try {
            $addresses = [System.Net.Dns]::GetHostAddresses($t.host)
            foreach ($a in $addresses) {
                if ($a.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
                    $ipStr = $a.ToString()
                    break
                }
            }
        } catch {
            # DNS resolution error; host may still be pingable or resolved by ping
        }

        $svc = $null
        if ($t.PSObject.Properties['service'] -and $null -ne $t.service) {
            $svc = [string]$t.service
        }

        $tcpPort = 80
        if ($t.PSObject.Properties['tcp_port'] -and $null -ne $t.tcp_port) {
            $tcpPort = [int]$t.tcp_port
        }

        $iperfPorts = $null
        if ($t.PSObject.Properties['iperf_ports'] -and $null -ne $t.iperf_ports) {
            $iperfPorts = $t.iperf_ports
        }

        $resolvedTargets += [pscustomobject]@{
            Config     = $t
            Name       = [string]$t.name
            Host       = [string]$t.host
            Group      = [string]$t.group
            Service    = $svc
            Ip         = $ipStr
            TcpPort    = $tcpPort
            IperfPorts = $iperfPorts
        }
    }

    # 2A. ICMP Probes (concurrent per round)
    $pingRounds = 30
    if ($Config.network -and $Config.network.ping_count -and $Config.network.ping_count.$Mode) {
        $pingRounds = [int]$Config.network.ping_count.$Mode
    }

    $pingIntervalMs = 250
    if ($Config.network -and $Config.network.ping_interval_ms) {
        $pingIntervalMs = [int]$Config.network.ping_interval_ms
    }

    & $logger "Starting ICMP ping probes ($pingRounds rounds, $($resolvedTargets.Count) targets)..."

    # Create Ping instance per target
    $pingInstances = @()
    $icmpSamplesPerTarget = @()
    foreach ($rt in $resolvedTargets) {
        $pingInstances += (New-Object System.Net.NetworkInformation.Ping)
        $icmpSamplesPerTarget += ,(New-Object System.Collections.Generic.List[double])
    }

    try {
        for ($round = 1; $round -le $pingRounds; $round++) {
            $roundSw = [System.Diagnostics.Stopwatch]::StartNew()
            $tasks = @()

            for ($i = 0; $i -lt $resolvedTargets.Count; $i++) {
                $targetHost = $resolvedTargets[$i].Host
                $pinger = $pingInstances[$i]
                try {
                    $task = $pinger.SendPingAsync($targetHost, 2000)
                    $tasks += $task
                } catch {
                    $tasks += $null
                }
            }

            # Wait for all tasks in this round
            $activeTasks = @()
            foreach ($tsk in $tasks) {
                if ($null -ne $tsk) {
                    $activeTasks += $tsk
                }
            }

            if ($activeTasks.Count -gt 0) {
                try {
                    [System.Threading.Tasks.Task]::WaitAll($activeTasks)
                } catch {
                    # Aggregated exceptions caught, individual task status inspected below
                }
            }

            # Collect results for this round
            for ($i = 0; $i -lt $resolvedTargets.Count; $i++) {
                $task = $tasks[$i]
                if ($null -ne $task -and $task.Status -eq 'RanToCompletion' -and $null -ne $task.Result) {
                    if ($task.Result.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                        $icmpSamplesPerTarget[$i].Add([double]$task.Result.RoundtripTime)
                        # If IP was not resolved earlier, fill it from ping reply
                        if ([string]::IsNullOrEmpty($resolvedTargets[$i].Ip) -and $null -ne $task.Result.Address) {
                            $resolvedTargets[$i].Ip = $task.Result.Address.ToString()
                        }
                    }
                }
            }

            $roundSw.Stop()
            $remainingSleep = $pingIntervalMs - [int]$roundSw.ElapsedMilliseconds
            if ($remainingSleep -gt 0) {
                Start-Sleep -Milliseconds $remainingSleep
            }
        }
    } catch {
        $errors.Add("ICMP probing encountered an error: $($_.Exception.Message)")
    } finally {
        foreach ($p in $pingInstances) {
            try { $p.Dispose() } catch { }
        }
    }

    # 2B. TCP Probes
    $tcpSamplesCount = 8
    if ($Config.network -and $Config.network.tcp_samples) {
        $tcpSamplesCount = [int]$Config.network.tcp_samples
    }

    & $logger "Starting TCP connection probes ($tcpSamplesCount samples, $($resolvedTargets.Count) targets)..."

    $tcpSamplesPerTarget = @()
    $tcpOkPerTarget = @()
    for ($i = 0; $i -lt $resolvedTargets.Count; $i++) {
        $tcpSamplesPerTarget += ,(New-Object System.Collections.Generic.List[double])
        $tcpOkPerTarget += 0
    }

    for ($i = 0; $i -lt $resolvedTargets.Count; $i++) {
        $rt = $resolvedTargets[$i]
        $targetHost = $rt.Host
        $targetPort = $rt.TcpPort

        for ($s = 1; $s -le $tcpSamplesCount; $s++) {
            $client = New-Object System.Net.Sockets.TcpClient
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                $iar = $client.BeginConnect($targetHost, $targetPort, $null, $null)
                $signaled = $iar.AsyncWaitHandle.WaitOne(3000, $false)
                $sw.Stop()
                if ($signaled) {
                    $client.EndConnect($iar)
                    $elapsedMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1)
                    $tcpSamplesPerTarget[$i].Add($elapsedMs)
                    $tcpOkPerTarget[$i]++
                }
            } catch {
                $sw.Stop()
            } finally {
                try { $client.Close() } catch { }
            }
        }
    }

    # Build targets array
    $targetsResult = @()
    for ($i = 0; $i -lt $resolvedTargets.Count; $i++) {
        $rt = $resolvedTargets[$i]
        $samplesIcmp = $icmpSamplesPerTarget[$i]
        $sentIcmp = $pingRounds
        $receivedIcmp = $samplesIcmp.Count

        if ($receivedIcmp -gt 0) {
            $blockedIcmp = $false
            $lossPctIcmp = [math]::Round((($sentIcmp - $receivedIcmp) / [double]$sentIcmp) * 100.0, 2)
            $sortedIcmp = $samplesIcmp | Sort-Object
            $minMsIcmp = [math]::Round($sortedIcmp[0], 1)
            $maxMsIcmp = [math]::Round($sortedIcmp[-1], 1)
            $p50MsIcmp = Get-SRPercentile -SortedList $sortedIcmp -Percentile 50
            $p95MsIcmp = Get-SRPercentile -SortedList $sortedIcmp -Percentile 95
            $p99MsIcmp = Get-SRPercentile -SortedList $sortedIcmp -Percentile 99

            $jitterMsIcmp = 0.0
            if ($receivedIcmp -gt 1) {
                $diffSum = 0.0
                for ($j = 1; $j -lt $samplesIcmp.Count; $j++) {
                    $diffSum += [math]::Abs($samplesIcmp[$j] - $samplesIcmp[$j-1])
                }
                $jitterMsIcmp = [math]::Round($diffSum / [double]($samplesIcmp.Count - 1), 2)
            }
            $samplesIcmpArray = $samplesIcmp.ToArray()
        } else {
            $blockedIcmp = $true
            $lossPctIcmp = 0.0
            $minMsIcmp = $null
            $maxMsIcmp = $null
            $p50MsIcmp = $null
            $p95MsIcmp = $null
            $p99MsIcmp = $null
            $jitterMsIcmp = $null
            $samplesIcmpArray = @()
        }

        $icmpObj = [pscustomobject]@{
            sent       = $sentIcmp
            received   = $receivedIcmp
            loss_pct   = $lossPctIcmp
            min_ms     = $minMsIcmp
            p50_ms     = $p50MsIcmp
            p95_ms     = $p95MsIcmp
            p99_ms     = $p99MsIcmp
            max_ms     = $maxMsIcmp
            jitter_ms  = $jitterMsIcmp
            samples_ms = $samplesIcmpArray
            blocked    = $blockedIcmp
        }

        $samplesTcp = $tcpSamplesPerTarget[$i]
        $okTcp = $tcpOkPerTarget[$i]
        if ($okTcp -gt 0) {
            $sortedTcp = $samplesTcp | Sort-Object
            $p50MsTcp = Get-SRPercentile -SortedList $sortedTcp -Percentile 50
            $p95MsTcp = Get-SRPercentile -SortedList $sortedTcp -Percentile 95
            $samplesTcpArray = $samplesTcp.ToArray()
        } else {
            $p50MsTcp = $null
            $p95MsTcp = $null
            $samplesTcpArray = @()
        }

        $tcpObj = [pscustomobject]@{
            port       = $rt.TcpPort
            attempts   = $tcpSamplesCount
            ok         = $okTcp
            p50_ms     = $p50MsTcp
            p95_ms     = $p95MsTcp
            samples_ms = $samplesTcpArray
        }

        $targetsResult += [pscustomobject]@{
            name    = $rt.Name
            host    = $rt.Host
            group   = $rt.Group
            service = $rt.Service
            ip      = $rt.Ip
            icmp    = $icmpObj
            tcp     = $tcpObj
        }
    }

    # ---------------------------------------------------------
    # 3. Traces (tracert)
    # ---------------------------------------------------------
    $traceHosts = @()
    if ($Config.network -and $Config.network.trace_hosts -and $Config.network.trace_hosts.$Mode) {
        $traceHosts = $Config.network.trace_hosts.$Mode
    }

    $tracesResult = @()
    foreach ($th in $traceHosts) {
        & $logger "Running traceroute to $th..."
        $hops = @()
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "tracert.exe"
        $psi.Arguments = "-d -w 800 -h 30 `"$th`""
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi

        try {
            $proc.Start() | Out-Null
            $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
            $stderrTask = $proc.StandardError.ReadToEndAsync()

            # Max wait 75 seconds for tracert
            if ($proc.WaitForExit(75000)) {
                $rawOutput = $stdoutTask.Result
                $lines = $rawOutput -split "`r?`n"

                foreach ($line in $lines) {
                    if ($line -match '^\s*(\d+)\s+(.+)$') {
                        $hopNum = [int]$matches[1]
                        $rest = $matches[2]

                        $hopIp = $null
                        if ($rest -match '\b(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\b') {
                            $hopIp = [string]$matches[1]
                        }

                        $rtts = @()
                        $rttMatches = [regex]::Matches($rest, '(?:<\s*(\d+)\s*ms|(\d+)\s*ms|(\*))')
                        for ($idx = 0; $idx -lt 3; $idx++) {
                            if ($idx -lt $rttMatches.Count) {
                                $m = $rttMatches[$idx]
                                if ($m.Groups[1].Success) {
                                    $rtts += [int]$m.Groups[1].Value
                                } elseif ($m.Groups[2].Success) {
                                    $rtts += [int]$m.Groups[2].Value
                                } else {
                                    $rtts += $null
                                }
                            } else {
                                $rtts += $null
                            }
                        }

                        $hops += [pscustomobject]@{
                            hop    = $hopNum
                            ip     = $hopIp
                            rtt_ms = $rtts
                        }
                    }
                }
            } else {
                try { $proc.Kill() } catch { }
                $errors.Add("Traceroute to $th timed out after 75 seconds")
            }
        } catch {
            $errors.Add("Traceroute to $th failed: $($_.Exception.Message)")
        } finally {
            try { $proc.Dispose() } catch { }
        }

        $tracesResult += [pscustomobject]@{
            host = [string]$th
            hops = $hops
        }
    }

    # ---------------------------------------------------------
    # 4. UDP Probing (iperf3)
    # ---------------------------------------------------------
    $iperfExe = Join-Path $BinDir "iperf3.exe"
    if (-not (Test-Path $iperfExe)) {
        $iperfExe = "iperf3.exe"
    }

    $udpSeconds = 20
    if ($Config.network -and $Config.network.udp_seconds -and $Config.network.udp_seconds.$Mode) {
        $udpSeconds = [int]$Config.network.udp_seconds.$Mode
    }

    $packetBytes = 1316
    if ($Config.network -and $Config.network.udp_packet_bytes) {
        $packetBytes = [int]$Config.network.udp_packet_bytes
    }

    $targetMbps = 12.5
    if ($Config.show -and $Config.show.outputs) {
        foreach ($outp in $Config.show.outputs) {
            if ($outp.id -eq 'srt' -and $outp.video_kbps) {
                $targetMbps = [double]($outp.video_kbps * 1.25 / 1000.0)
                break
            }
        }
    }

    $burstThresholdPct = 5.0
    if ($Config.thresholds -and $Config.thresholds.srt_burst_interval_loss_pct) {
        $burstThresholdPct = [double]$Config.thresholds.srt_burst_interval_loss_pct
    }

    $udpTargets = @()
    foreach ($rt in $resolvedTargets) {
        if ($null -ne $rt.IperfPorts -and $rt.IperfPorts.Count -ge 2) {
            $udpTargets += $rt
        }
    }

    & $logger "Starting UDP iperf3 testing for $($udpTargets.Count) targets ($udpSeconds s per target, $targetMbps Mbps)..."

    $udpResult = @()
    foreach ($ut in $udpTargets) {
        $minPort = [int]$ut.IperfPorts[0]
        $maxPort = [int]$ut.IperfPorts[1]
        $portCandidates = $minPort..$maxPort
        $maxTries = [math]::Min(12, $portCandidates.Count)

        $success = $false
        $lastError = $null
        $chosenPort = $null
        $udpObj = $null

        for ($tIdx = 0; $tIdx -lt $maxTries; $tIdx++) {
            $port = $portCandidates[$tIdx]
            & $logger "UDP $($ut.Host): testing port $port (attempt $($tIdx + 1)/$maxTries)..."

            $timeoutMs = ($udpSeconds + 12) * 1000
            $iperfArgs = "-c `"$($ut.Host)`" -p $port -u -b $($targetMbps)M -l $packetBytes -t $udpSeconds --get-server-output -J"

            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $iperfExe
            $psi.Arguments = $iperfArgs
            $psi.WorkingDirectory = $env:TEMP
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.CreateNoWindow = $true

            $proc = New-Object System.Diagnostics.Process
            $proc.StartInfo = $psi

            $stdout = ""
            $stderr = ""
            try {
                $proc.Start() | Out-Null
                $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
                $stderrTask = $proc.StandardError.ReadToEndAsync()

                if ($proc.WaitForExit($timeoutMs)) {
                    $stdout = $stdoutTask.Result
                    $stderr = $stderrTask.Result
                } else {
                    try { $proc.Kill() } catch { }
                    $lastError = "iperf3 timed out on port $port"
                    Start-Sleep -Seconds 1
                    continue
                }
            } catch {
                $lastError = $_.Exception.Message
                Start-Sleep -Seconds 1
                continue
            } finally {
                try { $proc.Dispose() } catch { }
            }

            if ([string]::IsNullOrEmpty($stdout)) {
                $lastError = if ($stderr) { $stderr.Trim() } else { "No output from iperf3 on port $port" }
                Start-Sleep -Seconds 1
                continue
            }

            $json = $null
            try {
                $json = $stdout | ConvertFrom-Json
            } catch {
                $lastError = "Failed to parse iperf3 JSON on port $($port): $($_.Exception.Message)"
                Start-Sleep -Seconds 1
                continue
            }

            if ($null -ne $json -and $json.error) {
                $lastError = [string]$json.error
                Start-Sleep -Seconds 1
                continue
            }

            # Check if we have valid end data
            $recvEnd = $null
            $recvIntervals = $null

            if ($null -ne $json.server_output_json -and $null -ne $json.server_output_json.end -and $null -ne $json.server_output_json.end.sum) {
                $recvEnd = $json.server_output_json.end.sum
                if ($null -ne $json.server_output_json.intervals) {
                    $recvIntervals = $json.server_output_json.intervals
                }
            } elseif ($null -ne $json.end) {
                if ($null -ne $json.end.sum_received) {
                    $recvEnd = $json.end.sum_received
                } elseif ($null -ne $json.end.sum) {
                    $recvEnd = $json.end.sum
                }
                # Server output missing, intervals empty per contract
                $recvIntervals = $null
            }

            if ($null -ne $recvEnd) {
                # Success on this port!
                $chosenPort = $port
                $success = $true

                $uPackets = 0
                if ($recvEnd.packets) { $uPackets = [int]$recvEnd.packets }

                $uLost = 0
                if ($recvEnd.lost_packets) { $uLost = [int]$recvEnd.lost_packets }

                $uJitter = 0.0
                if ($recvEnd.jitter_ms) { $uJitter = [math]::Round([double]$recvEnd.jitter_ms, 2) }

                $uLossPct = 0.0
                if ($uPackets -gt 0) {
                    $uLossPct = [math]::Round(($uLost / [double]$uPackets) * 100.0, 2)
                }

                $intervalsList = @()
                $worstIntervalLoss = 0.0
                $lossyIntervalsCount = 0

                if ($null -ne $recvIntervals) {
                    foreach ($iv in $recvIntervals) {
                        if ($null -ne $iv.sum) {
                            $ivSum = $iv.sum
                            $tSec = 0.0
                            if ($ivSum.end) { $tSec = [math]::Round([double]$ivSum.end, 1) }

                            $ivPackets = 0
                            if ($ivSum.packets) { $ivPackets = [int]$ivSum.packets }

                            $ivLost = 0
                            if ($ivSum.lost_packets) { $ivLost = [int]$ivSum.lost_packets }

                            $intervalsList += [pscustomobject]@{
                                t       = $tSec
                                packets = $ivPackets
                                lost    = $ivLost
                            }

                            $ivLossPct = 0.0
                            if ($ivPackets -gt 0) {
                                $ivLossPct = ($ivLost / [double]$ivPackets) * 100.0
                            }

                            if ($ivLossPct -gt $worstIntervalLoss) {
                                $worstIntervalLoss = $ivLossPct
                            }

                            if ($ivLossPct -gt $burstThresholdPct) {
                                $lossyIntervalsCount++
                            }
                        }
                    }
                }

                $udpObj = [pscustomobject]@{
                    host                    = $ut.Host
                    port                    = $chosenPort
                    target_mbps             = $targetMbps
                    seconds                 = $udpSeconds
                    packet_bytes            = $packetBytes
                    packets                 = $uPackets
                    lost                    = $uLost
                    loss_pct                = $uLossPct
                    jitter_ms               = $uJitter
                    intervals               = $intervalsList
                    worst_interval_loss_pct = [math]::Round($worstIntervalLoss, 2)
                    lossy_intervals         = $lossyIntervalsCount
                    error                   = $null
                }
                break
            } else {
                $lastError = "Missing receiver and end summary in iperf3 JSON on port $port"
                Start-Sleep -Seconds 1
            }
        }

        if ($success -and $null -ne $udpObj) {
            $udpResult += $udpObj
        } else {
            $errMsg = if ($lastError) { $lastError } else { "Failed to connect to iperf3 server on any tested port" }
            $errors.Add("UDP test to $($ut.Host) failed: $errMsg")
            $udpResult += [pscustomobject]@{
                host                    = $ut.Host
                port                    = $null
                target_mbps             = $targetMbps
                seconds                 = $udpSeconds
                packet_bytes            = $packetBytes
                packets                 = 0
                lost                    = 0
                loss_pct                = 0.0
                jitter_ms               = $null
                intervals               = @()
                worst_interval_loss_pct = 0.0
                lossy_intervals         = 0
                error                   = $errMsg
            }
        }
    }

    # ---------------------------------------------------------
    # 5. Upload Test (Cloudflare via curl.exe)
    # ---------------------------------------------------------
    & $logger "Starting uplink capacity test (Cloudflare)..."
    $uploadUrl = "https://speed.cloudflare.com/__up"
    $mbPerStream = 20
    $streamsCount = 4

    if ($Config.network -and $Config.network.upload_test) {
        $upCfg = $Config.network.upload_test
        if ($upCfg.url) { $uploadUrl = [string]$upCfg.url }
        if ($upCfg.mb_per_stream) { $mbPerStream = [int]$upCfg.mb_per_stream }
        if ($upCfg.streams) { $streamsCount = [int]$upCfg.streams }
    }

    $curlPath = "C:\Windows\System32\curl.exe"
    if (-not (Test-Path $curlPath)) {
        $curlPath = "curl.exe"
    }

    $tmpUploadFile = Join-Path $env:TEMP ("sr_upload_" + [guid]::NewGuid().ToString('N') + ".bin")
    $uploadResult = $null

    try {
        # Generate temp file with random bytes
        $bufSize = 1024 * 1024
        $buffer = New-Object byte[] $bufSize
        (New-Object System.Random).NextBytes($buffer)

        $fs = [System.IO.File]::OpenWrite($tmpUploadFile)
        for ($b = 0; $b -lt $mbPerStream; $b++) {
            $fs.Write($buffer, 0, $bufSize)
        }
        $fs.Close()

        $uploadProcs = @()
        $swUpload = [System.Diagnostics.Stopwatch]::StartNew()

        for ($s = 0; $s -lt $streamsCount; $s++) {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $curlPath
            $psi.Arguments = "-s -o NUL -X POST --data-binary `"@$tmpUploadFile`" `"$uploadUrl`" -w `"%{size_upload} %{time_total}`""
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.CreateNoWindow = $true

            $p = New-Object System.Diagnostics.Process
            $p.StartInfo = $psi
            $p.Start() | Out-Null
            $uploadProcs += $p
        }

        $totalUploadBytes = [long]0
        $maxCurlSeconds = [double]0.0

        foreach ($p in $uploadProcs) {
            $outStrTask = $p.StandardOutput.ReadToEndAsync()
            $errStrTask = $p.StandardError.ReadToEndAsync()

            # 60 seconds timeout per stream
            if ($p.WaitForExit(60000)) {
                $outStr = $outStrTask.Result
                if ($outStr -match '(\d+(?:\.\d+)?)\s+(\d+(?:\.\d+)?)') {
                    $bytesVal = [long][double]$matches[1]
                    $timeVal = [double]$matches[2]
                    $totalUploadBytes += $bytesVal
                    if ($timeVal -gt $maxCurlSeconds) {
                        $maxCurlSeconds = $timeVal
                    }
                }
            } else {
                try { $p.Kill() } catch { }
            }
            try { $p.Dispose() } catch { }
        }
        $swUpload.Stop()

        $wallSeconds = $swUpload.Elapsed.TotalSeconds
        $effectiveSeconds = if ($wallSeconds -gt 0) { $wallSeconds } else { $maxCurlSeconds }

        $mbpsUpload = 0.0
        if ($effectiveSeconds -gt 0 -and $totalUploadBytes -gt 0) {
            $mbpsUpload = [math]::Round(($totalUploadBytes * 8.0) / ($effectiveSeconds * 1e6), 2)
        }

        $uploadResult = [pscustomobject]@{
            method  = "cloudflare"
            mbps    = $mbpsUpload
            streams = $streamsCount
            bytes   = $totalUploadBytes
            seconds = [math]::Round($effectiveSeconds, 2)
            error   = $null
        }
    } catch {
        $errMsg = "Upload test failed: $($_.Exception.Message)"
        $errors.Add($errMsg)
        $uploadResult = [pscustomobject]@{
            method  = "cloudflare"
            mbps    = 0.0
            streams = $streamsCount
            bytes   = [long]0
            seconds = 0.0
            error   = $errMsg
        }
    } finally {
        if (Test-Path $tmpUploadFile) {
            try { Remove-Item $tmpUploadFile -Force } catch { }
        }
    }

    # ---------------------------------------------------------
    # Final Result Object
    # ---------------------------------------------------------
    return [pscustomobject]@{
        public  = $publicResult
        targets = $targetsResult
        traces  = $tracesResult
        udp     = $udpResult
        upload  = $uploadResult
        errors  = $errors.ToArray()
    }
}
