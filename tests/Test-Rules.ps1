# ShowReady - tests\Test-Rules.ps1
# Plain PowerShell assertions (no Pester) for lib\Rules.ps1 (Get-SRVerdict).
# Run:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Test-Rules.ps1
# Exit code 0 = all assertions passed, 1 = at least one failed. Pure ASCII, works on Windows PowerShell 5.1 and pwsh.

$ErrorActionPreference = 'Continue'
$testsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$kit = Split-Path -Parent $testsDir
$fx = Join-Path $testsDir 'fixtures'
$script:nPass = 0
$script:nFail = 0

. (Join-Path $kit 'lib\Rules.ps1')

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

function Run-Verdict {
    param($Config, $Hardware, $Network, $LoadTest, $Lan = $null)
    return (Get-SRVerdict -Config $Config -Hardware $Hardware -Network $Network -LoadTest $LoadTest -Lan $Lan -Now $fixedNow)
}

# Small hashtable-based network (also proves hashtables are accepted, not only PSCustomObject).
function New-MiniNet {
    param([double]$P95, [bool]$Udp = $true, [double]$LossPct = 0, [int]$Lossy = 0, [double]$Upload = 300)
    $udpList = @()
    if ($Udp) {
        $lost = [math]::Round(10000 * $LossPct / 100)
        $udpList = @(@{ host = 'iperf.example'; port = 5200; packets = 10000; lost = $lost; loss_pct = $LossPct; error = $null; lossy_intervals = $Lossy; worst_interval_loss_pct = 0; intervals = @() })
    }
    else {
        $udpList = @(@{ host = 'iperf.example'; port = 5200; packets = 0; lost = 0; loss_pct = $null; error = 'iperf3: the server is busy'; intervals = @() })
    }
    return @{
        targets = @(
            @{ name = 'FR one'; host = 'fr1.example'; group = 'france'; icmp = @{ sent = 30; received = 30; loss_pct = 0; p50_ms = ($P95 - 5); p95_ms = $P95; p99_ms = ($P95 + 3); samples_ms = @() }; tcp = @{ port = 443; attempts = 8; ok = 8; p50_ms = ($P95 - 4); p95_ms = ($P95 + 1) } }
        )
        udp = $udpList
        upload = @{ method = 'cloudflare'; mbps = $Upload; streams = 4; error = $null }
    }
}

$validStatus = @('PASS', 'WARN', 'FAIL', 'INFO', 'SKIP')
$validSections = @('france', 'uplink', 'ingest', 'lan', 'hardware', 'load', 'software')
$contractIds = @(
    'fr_reach', 'fr_rtt', 'fr_rtt_spread', 'fr_icmp_loss', 'fr_udp_loss', 'fr_udp_bursts',
    'uplink_capacity', 'uplink_wifi', 'ingest_youtube', 'ingest_twitch',
    'lan_wired', 'lan_headroom', 'lan_virtual_adapters', 'lan_profile', 'lan_eee',
    'lan_sources_found', 'lan_partner_throughput', 'lan_hosts',
    'hw_cpu_threads', 'hw_ram', 'hw_gpu', 'hw_nvenc_sessions', 'hw_power', 'hw_gpu_driver_age', 'hw_disk', 'hw_pending_reboot',
    'load_encoder', 'load_realtime', 'load_cpu', 'load_gpu_encode', 'load_throttle',
    'sw_mixer', 'sw_ndi', 'sw_background')

Write-Host ''
Write-Host 'ShowReady Rules tests' -ForegroundColor Cyan
Write-Host ('  PowerShell ' + $PSVersionTable.PSVersion.ToString()) -ForegroundColor DarkGray

# =============================================================================================
Write-Host ''
Write-Host '(a) strong show PC' -ForegroundColor Cyan
$v = $null
$threw = $false
try { $v = Run-Verdict (Get-Cfg) (Get-Fx 'strong_hardware.json') (Get-Fx 'strong_network.json') (Get-Fx 'strong_loadtest.json') -Lan (Get-Fx 'strong_lan.json') } catch { $threw = $true; Write-Host ('        exception: ' + $_.Exception.Message) -ForegroundColor Red }
Assert-That 'a: Get-SRVerdict does not throw' (-not $threw -and $null -ne $v)
if ($null -ne $v) {
    $fails = @($v.checks | Where-Object { $_.status -eq 'FAIL' })
    Assert-That 'a: overall is GO or CAUTION' (($v.overall -eq 'GO') -or ($v.overall -eq 'CAUTION')) ('overall = ' + $v.overall)
    Assert-That 'a: no FAIL check' ($fails.Count -eq 0) ('failing: ' + (($fails | ForEach-Object { $_.id }) -join ', '))
    $lat = Get-Set $v 'srt_latency'
    Assert-That 'a: srt_latency value is "1,100 ms"' (($null -ne $lat) -and ($lat.value -eq '1,100 ms')) ('value = ' + $lat.value)
    Assert-That 'a: SRT calc 4 x 273 -> 1092 -> 1100 (table minimum 850)' (($v.calc.srt.rtt_p95_ms -eq 273) -and ($v.calc.srt.mult -eq 4) -and ($v.calc.srt.latency_raw_ms -eq 1092) -and ($v.calc.srt.latency_ms -eq 1100) -and ($v.calc.srt.latency_table_ms -eq 850) -and ($v.calc.srt.mult_table -eq 3)) ($v.calc.srt | ConvertTo-Json -Compress)
    Assert-That 'a: srt_latency why mentions table minimum 850 and recommendation 1,100' (($lat.why -match '850') -and ($lat.why -match '1,100')) $lat.why
    $ovh = Get-Set $v 'srt_overhead'
    Assert-That 'a: srt_overhead is "25 %"' (($null -ne $ovh) -and ($ovh.value -eq '25 %')) ('value = ' + $ovh.value)
    Assert-That 'a: srt_bitrate is "10 Mbps video CBR, keyframe 2 s"' ((Get-Set $v 'srt_bitrate').value -eq '10 Mbps video CBR, keyframe 2 s')
    Assert-That 'a: fr_udp_loss PASS' ((Get-Chk $v 'fr_udp_loss').status -eq 'PASS')
    Assert-That 'a: uplink_capacity PASS' ((Get-Chk $v 'uplink_capacity').status -eq 'PASS') (Get-Chk $v 'uplink_capacity').value
    Assert-That 'a: uplink_capacity limit is ">= 2 x 36.0 Mbps"' ((Get-Chk $v 'uplink_capacity').limit -eq '>= 2 x 36.0 Mbps') ('limit = ' + (Get-Chk $v 'uplink_capacity').limit)
    Assert-That 'a: lan_headroom PASS and input_protocol OMT/NDI full' (((Get-Chk $v 'lan_headroom').status -eq 'PASS') -and ((Get-Set $v 'input_protocol').value -eq 'OMT (Medium) or full NDI'))
    Assert-That 'a: hw_nvenc_sessions PASS (8 sessions)' (((Get-Chk $v 'hw_nvenc_sessions').status -eq 'PASS') -and ((Get-Chk $v 'hw_nvenc_sessions').value -match '^8 sessions'))
    Assert-That 'a: hw_ram PASS for 63.7 GB, load_realtime PASS, load_encoder PASS' (((Get-Chk $v 'hw_ram').status -eq 'PASS') -and ((Get-Chk $v 'load_realtime').status -eq 'PASS') -and ((Get-Chk $v 'load_encoder').status -eq 'PASS'))
    Assert-That 'a: fr_rtt is INFO "273 ms"' (((Get-Chk $v 'fr_rtt').status -eq 'INFO') -and ((Get-Chk $v 'fr_rtt').value -eq '273 ms'))
    Assert-That 'a: fr_rtt detail tells how to get the exact path (-SrtHost)' ((Get-Chk $v 'fr_rtt').detail -match '-SrtHost')
    $missing = @($contractIds | Where-Object { $null -eq (Get-Chk $v $_) })
    Assert-That 'a: every contract check id is present' ($missing.Count -eq 0) ('missing: ' + ($missing -join ', '))
    $badStatus = @($v.checks | Where-Object { $validStatus -notcontains $_.status })
    $badSection = @($v.checks | Where-Object { $validSections -notcontains $_.section })
    Assert-That 'a: all statuses and sections are valid' (($badStatus.Count -eq 0) -and ($badSection.Count -eq 0))
    $idxs = @($v.checks | ForEach-Object { $validSections.IndexOf($_.section) })
    $sortedIdx = @($idxs | Sort-Object)
    Assert-That 'a: checks are in section order' (($idxs -join ',') -eq ($sortedIdx -join ','))
    $needSet = @('srt_latency', 'srt_overhead', 'srt_bitrate', 'srt_mode', 'ingest_servers', 'input_protocol', 'power_plan', 'encoder')
    $missingSet = @($needSet | Where-Object { $null -eq (Get-Set $v $_) })
    Assert-That 'a: all settings are produced' ($missingSet.Count -eq 0) ('missing: ' + ($missingSet -join ', '))
    Assert-That 'a: 5 manual checks' (@($v.manual_checks).Count -eq 5)
    Assert-That 'a: headline is not empty' (([string]$v.headline).Length -gt 0)
    $jsonOk = $false
    try { $j = ConvertTo-Json -InputObject $v -Depth 12; $back = $j | ConvertFrom-Json; $jsonOk = (@($back.checks).Count -eq @($v.checks).Count) } catch { $jsonOk = $false }
    Assert-That 'a: verdict serialises to JSON (Depth 12) and round-trips' $jsonOk
    $marginBad = @($v.checks | Where-Object { $null -ne $_.margin -and (($_.margin -isnot [double]) -or [double]::IsNaN($_.margin) -or [double]::IsInfinity($_.margin)) })
    Assert-That 'a: margins are finite numbers or null' ($marginBad.Count -eq 0)
    Show $v
}

# =============================================================================================
Write-Host ''
Write-Host '(b) weak dev laptop' -ForegroundColor Cyan
$v = $null
$threw = $false
try { $v = Run-Verdict (Get-Cfg) (Get-Fx 'weak_hardware.json') (Get-Fx 'weak_network.json') (Get-Fx 'weak_loadtest.json') } catch { $threw = $true; Write-Host ('        exception: ' + $_.Exception.Message) -ForegroundColor Red }
Assert-That 'b: Get-SRVerdict does not throw' (-not $threw -and $null -ne $v)
if ($null -ne $v) {
    Assert-That 'b: overall is NO-GO' ($v.overall -eq 'NO-GO') ('overall = ' + $v.overall)
    Assert-That 'b: lan_wired FAIL' ((Get-Chk $v 'lan_wired').status -eq 'FAIL')
    Assert-That 'b: uplink_wifi FAIL' ((Get-Chk $v 'uplink_wifi').status -eq 'FAIL')
    Assert-That 'b: hw_ram FAIL (13.9 GB)' ((Get-Chk $v 'hw_ram').status -eq 'FAIL')
    Assert-That 'b: hw_gpu WARN (integrated only, OBS only)' ((Get-Chk $v 'hw_gpu').status -eq 'WARN') ('status = ' + (Get-Chk $v 'hw_gpu').status)
    Assert-That 'b: hw_nvenc_sessions INFO (not NVIDIA)' ((Get-Chk $v 'hw_nvenc_sessions').status -eq 'INFO')
    Assert-That 'b: hw_power WARN (Balanced)' ((Get-Chk $v 'hw_power').status -eq 'WARN')
    Assert-That 'b: lan_virtual_adapters WARN (Hyper-V)' ((Get-Chk $v 'lan_virtual_adapters').status -eq 'WARN')
    Assert-That 'b: hw_cpu_threads mentions low-power laptop CPU' ((Get-Chk $v 'hw_cpu_threads').detail -match 'low-power laptop CPU')
    Assert-That 'b: load_encoder FAIL (libx264 only)' ((Get-Chk $v 'load_encoder').status -eq 'FAIL')
    Assert-That 'b: load_realtime FAIL and names the slow streams' (((Get-Chk $v 'load_realtime').status -eq 'FAIL') -and ((Get-Chk $v 'load_realtime').detail -match 'out-youtube'))
    Assert-That 'b: input_protocol says fix the network first' ((Get-Set $v 'input_protocol').value -eq 'fix the network first')
    $firstFail = @($v.checks | Where-Object { $_.status -eq 'FAIL' })[0].id
    Assert-That 'b: weakest = first FAIL in section order' ($v.weakest -eq $firstFail) ('weakest = ' + $v.weakest + ', first FAIL = ' + $firstFail)
    Assert-That 'b: every FAIL/WARN has a fix text' (@($v.checks | Where-Object { ($_.status -eq 'FAIL' -or $_.status -eq 'WARN') -and ([string]$_.fix) -eq '' }).Count -eq 0) ((@($v.checks | Where-Object { ($_.status -eq 'FAIL' -or $_.status -eq 'WARN') -and ([string]$_.fix) -eq '' } | ForEach-Object { $_.id }) -join ', '))
    Assert-That 'b: srt_latency is set (raised: lossy bursts + long haul)' ($null -ne (Get-Set $v 'srt_latency'))
    Show $v
}

# =============================================================================================
Write-Host ''
Write-Host '(c) lossy path (4 % UDP loss, lossy intervals)' -ForegroundColor Cyan
$v = $null
$threw = $false
try { $v = Run-Verdict (Get-Cfg) (Get-Fx 'strong_hardware.json') (Get-Fx 'lossy_network.json') (Get-Fx 'strong_loadtest.json') } catch { $threw = $true; Write-Host ('        exception: ' + $_.Exception.Message) -ForegroundColor Red }
Assert-That 'c: Get-SRVerdict does not throw' (-not $threw -and $null -ne $v)
if ($null -ne $v) {
    Assert-That 'c: multiplier is 6' ($v.calc.srt.mult -eq 6) ('mult = ' + $v.calc.srt.mult)
    Assert-That 'c: overhead >= 17' ($v.calc.srt.overhead_pct -ge 17) ('overhead = ' + $v.calc.srt.overhead_pct)
    Assert-That 'c: srt_overhead setting is "17 %"' ((Get-Set $v 'srt_overhead').value -eq '17 %') ('value = ' + (Get-Set $v 'srt_overhead').value)
    Assert-That 'c: srt_latency is "1,650 ms" (6 x 273 = 1638 -> 1650)' ((Get-Set $v 'srt_latency').value -eq '1,650 ms') ('value = ' + (Get-Set $v 'srt_latency').value)
    Assert-That 'c: fr_udp_loss WARN (4 % is above 1 % but not above 7 %)' ((Get-Chk $v 'fr_udp_loss').status -eq 'WARN') ('status = ' + (Get-Chk $v 'fr_udp_loss').status)
    Assert-That 'c: fr_udp_bursts WARN' ((Get-Chk $v 'fr_udp_bursts').status -eq 'WARN')
    Assert-That 'c: overall CAUTION' ($v.overall -eq 'CAUTION') ('overall = ' + $v.overall)
    Assert-That 'c: uplink need grows with the 17 % overhead' ($v.calc.need_mbps -lt 36.028 -and $v.calc.need_mbps -gt 35)
}

# =============================================================================================
Write-Host ''
Write-Host '(d) all collectors skipped ($null)' -ForegroundColor Cyan
$v = $null
$threw = $false
try { $v = Run-Verdict (Get-Cfg) $null $null $null } catch { $threw = $true; Write-Host ('        exception: ' + $_.Exception.Message) -ForegroundColor Red }
Assert-That 'd: no exception' (-not $threw -and $null -ne $v)
if ($null -ne $v) {
    $notSkip = @($v.checks | Where-Object { $_.status -ne 'SKIP' })
    Assert-That ('d: all ' + $contractIds.Count + ' checks are present and SKIP') ((@($v.checks).Count -eq $contractIds.Count) -and ($notSkip.Count -eq 0)) ('not SKIP: ' + (($notSkip | ForEach-Object { $_.id + '=' + $_.status }) -join ', '))
    Assert-That 'd: overall is not GO (nothing was tested)' ($v.overall -ne 'GO') ('overall = ' + $v.overall)
    Assert-That 'd: headline says nothing was tested' ($v.headline -match 'Nothing was tested') $v.headline
    Assert-That 'd: manual checks still present' (@($v.manual_checks).Count -eq 5)
    Assert-That 'd: no SRT settings without data' (($null -eq (Get-Set $v 'srt_latency')) -and ($null -ne (Get-Set $v 'power_plan')))
}
$threw = $false
$v2 = $null
try { $v2 = Get-SRVerdict -Config $null -Hardware $null -Network $null -LoadTest $null -Lan $null } catch { $threw = $true }
Assert-That 'd: no exception even with a $null config' (-not $threw -and $null -ne $v2)
$threw = $false
try { $v2 = Get-SRVerdict } catch { $threw = $true }
Assert-That 'd: no exception with no arguments at all' (-not $threw -and $null -ne $v2)
$threw = $false
try { $v2 = Run-Verdict (Get-Cfg) @{} @{} @{} @{} } catch { $threw = $true }
Assert-That 'd: no exception with empty collector objects' (-not $threw -and $null -ne $v2)
$threw = $false
try { $v2 = Run-Verdict (Get-Cfg) ([pscustomobject]@{ nics = 'garbage'; gpus = 5; cpu = 'x' }) ([pscustomobject]@{ targets = 7; udp = 'x'; upload = 3 }) ([pscustomobject]@{ streams = 'x'; system = 'y' }) ([pscustomobject]@{ adapter = 'x'; mdns = 'y'; sources = 'z'; sweep = 'w' }) } catch { $threw = $true }
Assert-That 'd: no exception with malformed collector objects' (-not $threw -and $null -ne $v2)

# =============================================================================================
Write-Host ''
Write-Host '(e: LAN step)' -ForegroundColor Cyan

# ---------------------------------------------------------------------------------------------
# lan_sources_found cases 1-7
# ---------------------------------------------------------------------------------------------

# Case 1: Lan null -> SKIP, detail "The local network step was not run."; add "local network" to not_tested
$v = Run-Verdict (Get-Cfg) $null $null $null $null
$chk = Get-Chk $v 'lan_sources_found'
Assert-That 'e: lan_sources_found case 1 (Lan null) status is SKIP' ($chk.status -eq 'SKIP')
Assert-That 'e: lan_sources_found case 1 detail is exact' ($chk.detail -eq 'The local network step was not run.')
Assert-That 'e: lan_sources_found case 1 adds local network to not_tested' ($v.not_tested -contains 'local network')

$cfgReq = Get-Cfg
$cfgReq.lan.require_sources = $true

# Case 2 default (require_sources false): SKIP without "NDI/OMT discovery" in not_tested
$vDef2 = Run-Verdict (Get-Cfg) $null $null $null (Get-Fx 'noquery_lan.json')
$chkDef2 = Get-Chk $vDef2 'lan_sources_found'
Assert-That 'e: lan_sources_found case 2 (query_ok false, default) status is SKIP' ($chkDef2.status -eq 'SKIP')
Assert-That 'e: lan_sources_found case 2 default does NOT add NDI/OMT discovery to not_tested' ($vDef2.not_tested -notcontains 'NDI/OMT discovery')

# Case 2 strict (require_sources true): mdns.query_ok != true -> SKIP, detail "Could not query the network for NDI/OMT sources: <error>."; add "NDI/OMT discovery" to not_tested
$v = Run-Verdict $cfgReq $null $null $null (Get-Fx 'noquery_lan.json')
$chk = Get-Chk $v 'lan_sources_found'
Assert-That 'e: lan_sources_found case 2 (query_ok false, strict) status is SKIP' ($chk.status -eq 'SKIP')
Assert-That 'e: lan_sources_found case 2 detail has method error' ($chk.detail -match 'Could not query the network for NDI/OMT sources: UDP socket send failed: network unreachable\.')
Assert-That 'e: lan_sources_found case 2 strict adds NDI/OMT discovery to not_tested' ($v.not_tested -contains 'NDI/OMT discovery')

# Case 3: counted >= expected -> PASS, value "<n> <P> sources", limit ">= <expected> <P> sources", margin n/expected, detail "Found: <list>." + EXTRAS
$v = Run-Verdict (Get-Cfg) $null $null $null (Get-Fx 'strong_lan.json')
$chk = Get-Chk $v 'lan_sources_found'
Assert-That 'e: lan_sources_found case 3 (counted >= expected) status is PASS' ($chk.status -eq 'PASS')
Assert-That 'e: lan_sources_found case 3 value is "2 OMT sources"' ($chk.value -ceq '2 OMT sources')
Assert-That 'e: lan_sources_found case 3 limit is ">= 2 OMT sources"' ($chk.limit -ceq '>= 2 OMT sources')
Assert-That 'e: lan_sources_found case 3 margin is 1' ($chk.margin -eq 1.0)
Assert-That 'e: lan_sources_found case 3 detail lists sources and local source' (($chk.detail -match 'Found: STUDIO-A \(Main Feed\) \(192\.168\.0\.21:6400\), STUDIO-B \(Side Feed\) \(192\.168\.0\.22:6400\)\.') -and ($chk.detail -match 'On this PC \(not counted\): LOCAL-PC \(Screen\)\.'))
Assert-That 'e: lan_sources_found case 3 fix is empty' ($chk.fix -eq '')

# Case 4 strict: 1 <= counted < expected -> WARN, value "<n> <P> source(s)", same limit, margin n/expected
$v = Run-Verdict $cfgReq $null $null $null (Get-Fx 'one_omt_lan.json')
$chk = Get-Chk $v 'lan_sources_found'
Assert-That 'e: lan_sources_found case 4 (1 <= counted < expected) status is WARN' ($chk.status -eq 'WARN')
Assert-That 'e: lan_sources_found case 4 value is "1 OMT source(s)"' ($chk.value -eq '1 OMT source(s)')
Assert-That 'e: lan_sources_found case 4 limit is ">= 2 OMT sources"' ($chk.limit -ceq '>= 2 OMT sources')
Assert-That 'e: lan_sources_found case 4 margin is 0.5' ($chk.margin -eq 0.5)
Assert-That 'e: lan_sources_found case 4 detail mentions found only and needs 2 feeds' (($chk.detail -match 'Found only: STUDIO-A \(Main Feed\) \(192\.168\.0\.21:6400\)\.') -and ($chk.detail -match 'The show needs 2 incoming OMT feeds\.'))
Assert-That 'e: lan_sources_found case 4 fix names subnet (192.168.0.0/24)' ($chk.fix -match '192\.168\.0\.0/24')

# Case 4 default (require_sources false): INFO, margin null, fix ""
$vDef4 = Run-Verdict (Get-Cfg) $null $null $null (Get-Fx 'one_omt_lan.json')
$chkDef4 = Get-Chk $vDef4 'lan_sources_found'
Assert-That 'e: lan_sources_found case 4 default status is INFO' ($chkDef4.status -eq 'INFO')
Assert-That 'e: lan_sources_found case 4 default margin is null' ($null -eq $chkDef4.margin)
Assert-That 'e: lan_sources_found case 4 default fix is empty' ($chkDef4.fix -ceq '')
Assert-That 'e: lan_sources_found case 4 default value is "1 OMT source(s)"' ($chkDef4.value -ceq '1 OMT source(s)')
Assert-That 'e: lan_sources_found case 4 default detail mentions does not count note' ($chkDef4.detail -cmatch 'This check does not count yet \(lan\.require_sources is false in config\.json\)\.')

# Case 5 strict: counted = 0 and m non-local Q sources > 0 -> WARN, value "0 <P>, <m> <Q>", same limit, margin 0
$v = Run-Verdict $cfgReq $null $null $null (Get-Fx 'ndi_only_lan.json')
$chk = Get-Chk $v 'lan_sources_found'
Assert-That 'e: lan_sources_found case 5 (counted=0, m Q sources>0) status is WARN' ($chk.status -eq 'WARN')
Assert-That 'e: lan_sources_found case 5 value is "0 OMT, 2 NDI"' ($chk.value -ceq '0 OMT, 2 NDI')
Assert-That 'e: lan_sources_found case 5 limit is ">= 2 OMT sources"' ($chk.limit -ceq '>= 2 OMT sources')
Assert-That 'e: lan_sources_found case 5 margin is 0' ($chk.margin -eq 0.0)
Assert-That 'e: lan_sources_found case 5 detail names Q sources and config expects OMT' (($chk.detail -match 'No OMT sources answered, but 2 NDI source\(s\) did: CAM-1 \(Camera 1\) \(192\.168\.0\.31:5961\), CAM-2 \(Camera 2\) \(192\.168\.0\.32:5961\)\.') -and ($chk.detail -match 'config\.json expects OMT\.'))
Assert-That 'e: lan_sources_found case 5 fix suggests switching or config update' ($chk.fix -eq 'Switch the senders to OMT, or set show.inputs.protocol to "NDI" in config.json if the show runs on NDI.')

# Case 5 default (require_sources false): INFO, margin null, fix ""
$vDef5 = Run-Verdict (Get-Cfg) $null $null $null (Get-Fx 'ndi_only_lan.json')
$chkDef5 = Get-Chk $vDef5 'lan_sources_found'
Assert-That 'e: lan_sources_found case 5 default status is INFO' ($chkDef5.status -eq 'INFO')
Assert-That 'e: lan_sources_found case 5 default margin is null' ($null -eq $chkDef5.margin)
Assert-That 'e: lan_sources_found case 5 default fix is empty' ($chkDef5.fix -ceq '')
Assert-That 'e: lan_sources_found case 5 default value is "0 OMT, 2 NDI"' ($chkDef5.value -ceq '0 OMT, 2 NDI')
Assert-That 'e: lan_sources_found case 5 default detail mentions does not count note' ($chkDef5.detail -cmatch 'This check does not count yet \(lan\.require_sources is false in config\.json\)\.')

# Case 6 strict: counted = 0 and discovery_servers.<p> not empty -> WARN, value "0 <P> sources (mDNS)", margin 0
$v = Run-Verdict $cfgReq $null $null $null (Get-Fx 'dserver_lan.json')
$chk = Get-Chk $v 'lan_sources_found'
Assert-That 'e: lan_sources_found case 6 (discovery server) status is WARN' ($chk.status -eq 'WARN')
Assert-That 'e: lan_sources_found case 6 value is "0 OMT sources (mDNS)"' ($chk.value -ceq '0 OMT sources (mDNS)')
Assert-That 'e: lan_sources_found case 6 limit is ">= 2 OMT sources"' ($chk.limit -ceq '>= 2 OMT sources')
Assert-That 'e: lan_sources_found case 6 margin is 0' ($chk.margin -eq 0.0)
Assert-That 'e: lan_sources_found case 6 detail names discovery server URL' ($chk.detail -cmatch 'OMT Discovery Server \(omt://10\.0\.0\.5:6399\)')
Assert-That 'e: lan_sources_found case 6 fix mentions vMix/OBS and checking discovery server' ($chk.fix -eq 'Confirm both feeds in vMix/OBS (they use the Discovery Server) and check that the Discovery Server is running and reachable.')

# Case 6 default (require_sources false): INFO, margin null, fix ""
$vDef6 = Run-Verdict (Get-Cfg) $null $null $null (Get-Fx 'dserver_lan.json')
$chkDef6 = Get-Chk $vDef6 'lan_sources_found'
Assert-That 'e: lan_sources_found case 6 default status is INFO' ($chkDef6.status -eq 'INFO')
Assert-That 'e: lan_sources_found case 6 default margin is null' ($null -eq $chkDef6.margin)
Assert-That 'e: lan_sources_found case 6 default fix is empty' ($chkDef6.fix -ceq '')
Assert-That 'e: lan_sources_found case 6 default value is "0 OMT sources (mDNS)"' ($chkDef6.value -ceq '0 OMT sources (mDNS)')
Assert-That 'e: lan_sources_found case 6 default detail mentions does not count note' ($chkDef6.detail -cmatch 'This check does not count yet \(lan\.require_sources is false in config\.json\)\.')

# Case 7 strict: otherwise -> FAIL, value "0 <P> sources", same limit, margin 0
$v = Run-Verdict $cfgReq $null $null $null (Get-Fx 'empty_lan.json')
$chk = Get-Chk $v 'lan_sources_found'
Assert-That 'e: lan_sources_found case 7 (otherwise) status is FAIL' ($chk.status -eq 'FAIL')
Assert-That 'e: lan_sources_found case 7 value is "0 OMT sources"' ($chk.value -ceq '0 OMT sources')
Assert-That 'e: lan_sources_found case 7 limit is ">= 2 OMT sources"' ($chk.limit -ceq '>= 2 OMT sources')
Assert-That 'e: lan_sources_found case 7 margin is 0' ($chk.margin -eq 0.0)
Assert-That 'e: lan_sources_found case 7 detail mentions adapter name, query and no device answered' (($chk.detail -match 'No OMT source answered an mDNS query \(_omt\._tcp\.local\) on Wi-Fi within 3 s\.') -and ($chk.detail -match 'No device answered mDNS at all'))
Assert-That 'e: lan_sources_found case 7 fix gives corrective guidance' ($chk.fix -match 'Start OMT output on both source PCs')

# Case 7 with k other devices answering mDNS (strict)
$lanK = Get-Fx 'empty_lan.json'
$lanK.mdns.responders = @('10.0.0.99', '10.0.0.100')
$v = Run-Verdict $cfgReq $null $null $null $lanK
$chk = Get-Chk $v 'lan_sources_found'
Assert-That 'e: lan_sources_found case 7 with responders says k other devices answered' ($chk.detail -match '2 other device\(s\) answered mDNS, so discovery itself works\.')

# Case 7 default (require_sources false): INFO, margin null, fix "", exact first sentence
$vDef7 = Run-Verdict (Get-Cfg) $null $null $null (Get-Fx 'empty_lan.json')
$chkDef7 = Get-Chk $vDef7 'lan_sources_found'
Assert-That 'e: lan_sources_found case 7 default status is INFO' ($chkDef7.status -eq 'INFO')
Assert-That 'e: lan_sources_found case 7 default margin is null' ($null -eq $chkDef7.margin)
Assert-That 'e: lan_sources_found case 7 default fix is empty' ($chkDef7.fix -ceq '')
Assert-That 'e: lan_sources_found case 7 default value is "0 OMT sources"' ($chkDef7.value -ceq '0 OMT sources')
Assert-That 'e: lan_sources_found case 7 default exact first sentence' ($chkDef7.detail -cmatch '^No OMT senders yet, which is expected until NDI/OMT is installed on the source PCs\.')
Assert-That 'e: lan_sources_found case 7 default detail mentions once senders are installed' ($chkDef7.detail -cmatch 'Once the senders are installed, run this again; set lan\.require_sources to true in config\.json to make this check count\.')

# A run whose only non-pass is lan_sources_found can be GO
$lanGo = Get-Fx 'strong_lan.json'
$lanGo.sources = @()
$vGo = Run-Verdict (Get-Cfg) (Get-Fx 'strong_hardware.json') (Get-Fx 'strong_network.json') (Get-Fx 'strong_loadtest.json') -Lan $lanGo
$srcChkGo = Get-Chk $vGo 'lan_sources_found'
Assert-That 'e: lan_sources_found default gives INFO when no sources' ($srcChkGo.status -eq 'INFO')
Assert-That 'e: run whose only non-pass is lan_sources_found can be GO' ($vGo.overall -eq 'GO')

# ---------------------------------------------------------------------------------------------
# lan_partner_throughput cases
# ---------------------------------------------------------------------------------------------

# Case 1: Lan null -> SKIP
$v = Run-Verdict (Get-Cfg) $null $null $null $null
$chk = Get-Chk $v 'lan_partner_throughput'
Assert-That 'e: lan_partner_throughput case 1 (Lan null) status is SKIP' ($chk.status -eq 'SKIP')
Assert-That 'e: lan_partner_throughput case 1 detail is exact' ($chk.detail -eq 'The local network step was not run.')

# Case 2: No partners -> SKIP (NOT added to not_tested)
$v = Run-Verdict (Get-Cfg) $null $null $null (Get-Fx 'empty_lan.json')
$chk = Get-Chk $v 'lan_partner_throughput'
Assert-That 'e: lan_partner_throughput case 2 (no partners) status is SKIP' ($chk.status -eq 'SKIP')
Assert-That 'e: lan_partner_throughput case 2 detail explains optional test' ($chk.detail -match 'Optional test, not run\.')
Assert-That 'e: lan_partner_throughput case 2 does NOT add partner test to not_tested' ($v.not_tested -notcontains 'lan_partner_throughput' -and $v.not_tested -notcontains 'partner')

# Case 3: All partners unmeasured -> WARN, value "not measured"
$lanUnmeasured = Get-Fx 'strong_lan.json'
$lanUnmeasured.partners = @(
    [pscustomobject]@{ host = '192.168.0.21'; ip = '192.168.0.21'; error = 'connection timed out'; tcp = $null; udp = $null }
)
$v = Run-Verdict (Get-Cfg) $null $null $null $lanUnmeasured
$chk = Get-Chk $v 'lan_partner_throughput'
Assert-That 'e: lan_partner_throughput case 3 (all unmeasured) status is WARN' ($chk.status -eq 'WARN')
Assert-That 'e: lan_partner_throughput case 3 value is "not measured"' ($chk.value -eq 'not measured')
Assert-That 'e: lan_partner_throughput case 3 margin is null' ($null -eq $chk.margin)
Assert-That 'e: lan_partner_throughput case 3 detail names host and error' ($chk.detail -eq 'Could not test 192.168.0.21: connection timed out.')
Assert-That 'e: lan_partner_throughput case 3 fix names host' ($chk.fix -match '192\.168\.0\.21')

# Case 4a: PASS (strong_lan.json: tcp 941, loss 0.0) -> margin = ratio / 1.5 = 4.705 / 1.5 = 3.14
$v = Run-Verdict (Get-Cfg) $null $null $null (Get-Fx 'strong_lan.json')
$chk = Get-Chk $v 'lan_partner_throughput'
Assert-That 'e: lan_partner_throughput case 4a (strong) status is PASS' ($chk.status -eq 'PASS')
Assert-That 'e: lan_partner_throughput case 4a value is "941 Mbps TCP, 0.00 % UDP loss"' ($chk.value -eq '941 Mbps TCP, 0.00 % UDP loss')
Assert-That 'e: lan_partner_throughput case 4a limit is ">= 300 Mbps, < 0.1 % UDP loss"' ($chk.limit -eq '>= 300 Mbps, < 0.1 % UDP loss')
Assert-That 'e: lan_partner_throughput case 4a margin is 3.14 (ratio / 1.5)' ($chk.margin -eq 3.14)
Assert-That 'e: lan_partner_throughput case 4a detail contains per-feed and partner measurements' (($chk.detail -match 'Per feed 200 Mbps \(OMT\), tested at 400 Mbps for 10 s, source PC to this PC\.') -and ($chk.detail -match '192\.168\.0\.21: TCP 941 Mbps, 0 retransmits; UDP 400 Mbps received, 0\.00 % loss, jitter 0\.02 ms\.'))
Assert-That 'e: lan_partner_throughput case 4a fix is empty for PASS' ($chk.fix -eq '')
# Case 4a': the cygwin iperf3 build reports no retransmits and can report no jitter -> those parts are left out, not "0".
$lanNoRt = Get-Fx 'strong_lan.json'
$lanNoRt.partners[0].tcp.retransmits = $null
$lanNoRt.partners[0].udp.jitter_ms = $null
$v = Run-Verdict (Get-Cfg) $null $null $null $lanNoRt
$chk = Get-Chk $v 'lan_partner_throughput'
Assert-That 'e: lan_partner_throughput null retransmits/jitter are omitted from the detail' (($chk.detail -cmatch '192\.168\.0\.21: TCP 941 Mbps; UDP 400 Mbps received, 0\.00 % loss\.') -and ($chk.detail -notmatch 'retransmits|jitter')) $chk.detail

# Case 4b: tcp 280 + loss 0.5 -> WARN (ratio 1.4 < 1.5, >= 1.0; loss 0.5 < 1.0)
$lanP1 = Get-Fx 'strong_lan.json'
$lanP1.partners[0].tcp.mbps = 280
$lanP1.partners[0].udp.loss_pct = 0.5
$lanP1.partners[0].udp.mbps = 280
$v = Run-Verdict (Get-Cfg) $null $null $null $lanP1
$chk = Get-Chk $v 'lan_partner_throughput'
Assert-That 'e: lan_partner_throughput tcp 280 + loss 0.5 is WARN' ($chk.status -eq 'WARN')
Assert-That 'e: lan_partner_throughput tcp 280 value is "280 Mbps TCP, 0.50 % UDP loss"' ($chk.value -eq '280 Mbps TCP, 0.50 % UDP loss')
Assert-That 'e: lan_partner_throughput tcp 280 margin is 0.93' ($chk.margin -eq 0.93)
Assert-That 'e: lan_partner_throughput WARN has fix naming host' ($chk.fix -match '192\.168\.0\.21')

# Case 4c: tcp 150 -> FAIL (ratio 0.75 < 1.0)
$lanP2 = Get-Fx 'strong_lan.json'
$lanP2.partners[0].tcp.mbps = 150
$lanP2.partners[0].udp.loss_pct = 0.0
$lanP2.partners[0].udp.mbps = 150
$v = Run-Verdict (Get-Cfg) $null $null $null $lanP2
$chk = Get-Chk $v 'lan_partner_throughput'
Assert-That 'e: lan_partner_throughput tcp 150 is FAIL' ($chk.status -eq 'FAIL')
Assert-That 'e: lan_partner_throughput tcp 150 margin is 0.5' ($chk.margin -eq 0.5)
Assert-That 'e: lan_partner_throughput FAIL has fix naming host' ($chk.fix -match '192\.168\.0\.21')

# Case 4d: tcp 941 + loss 0.5 -> WARN (ratio >= 1.5, but loss >= 0.1 and < 1.0)
$lanP3 = Get-Fx 'strong_lan.json'
$lanP3.partners[0].tcp.mbps = 941
$lanP3.partners[0].udp.loss_pct = 0.5
$v = Run-Verdict (Get-Cfg) $null $null $null $lanP3
$chk = Get-Chk $v 'lan_partner_throughput'
Assert-That 'e: lan_partner_throughput tcp 941 + loss 0.5 is WARN' ($chk.status -eq 'WARN')

# Case 4e: one ok + one error -> at least WARN
$lanP4 = Get-Fx 'strong_lan.json'
$lanP4.partners = @(
    $lanP4.partners[0],
    [pscustomobject]@{ host = '192.168.0.22'; ip = '192.168.0.22'; error = 'connection refused'; tcp = $null; udp = $null }
)
$v = Run-Verdict (Get-Cfg) $null $null $null $lanP4
$chk = Get-Chk $v 'lan_partner_throughput'
Assert-That 'e: lan_partner_throughput one ok + one error is at least WARN' ($chk.status -eq 'WARN')
Assert-That 'e: lan_partner_throughput detail includes both partner result and error' (($chk.detail -match '192\.168\.0\.21: TCP 941 Mbps') -and ($chk.detail -match 'Could not test 192\.168\.0\.22: connection refused\.'))

# Case 4f: loopback partner -> detail mentions loopback
$lanPLoop = Get-Fx 'strong_lan.json'
$lanPLoop.partners[0].loopback = $true
$v = Run-Verdict (Get-Cfg) $null $null $null $lanPLoop
$chk = Get-Chk $v 'lan_partner_throughput'
Assert-That 'e: lan_partner_throughput loopback mentions loopback in detail' ($chk.detail -match '\(loopback: measures this PC only, not the network\)')
$lanPLoop.partners[0].tcp.mbps = 280
$v = Run-Verdict (Get-Cfg) $null $null $null $lanPLoop
$chk = Get-Chk $v 'lan_partner_throughput'
Assert-That 'e: lan_partner_throughput weak loopback partner gets the loopback fix' (($chk.status -eq 'WARN') -and ($chk.fix -cmatch '^That was a loopback test') -and ($chk.fix -notmatch 'cable')) $chk.fix

# ---------------------------------------------------------------------------------------------
# lan_hosts cases
# ---------------------------------------------------------------------------------------------

# Case 1: Lan null -> SKIP
$v = Run-Verdict (Get-Cfg) $null $null $null $null
$chk = Get-Chk $v 'lan_hosts'
Assert-That 'e: lan_hosts case 1 (Lan null) status is SKIP' ($chk.status -eq 'SKIP')
Assert-That 'e: lan_hosts case 1 detail is exact' ($chk.detail -eq 'The local network step was not run.')

# Case 2: sweep missing or sweep.skipped_reason set -> SKIP
$v = Run-Verdict (Get-Cfg) $null $null $null (Get-Fx 'noquery_lan.json')
$chk = Get-Chk $v 'lan_hosts'
Assert-That 'e: lan_hosts case 2 (skipped_reason set) status is SKIP' ($chk.status -eq 'SKIP')
Assert-That 'e: lan_hosts case 2 detail has skipped_reason' ($chk.detail -eq 'Not scanned: Adapter is not connected.')

# Case 3: INFO with sweep parts (strong_lan.json)
$v = Run-Verdict (Get-Cfg) $null $null $null (Get-Fx 'strong_lan.json')
$chk = Get-Chk $v 'lan_hosts'
Assert-That 'e: lan_hosts case 3 status is INFO' ($chk.status -eq 'INFO')
Assert-That 'e: lan_hosts case 3 value is "12 devices on 192.168.0.0/24"' ($chk.value -eq '12 devices on 192.168.0.0/24')
Assert-That 'e: lan_hosts detail has Gateway' ($chk.detail -match 'Gateway: 192\.168\.0\.1 \(Cisco Systems\)\.')
Assert-That 'e: lan_hosts detail has Network gear' ($chk.detail -match 'Network gear: Cisco Systems \(192\.168\.0\.2\)\.')
Assert-That 'e: lan_hosts detail has PCs (this PC not counted)' ($chk.detail -match 'PCs: 6 \(Dell Inc\.\)\.') $chk.detail
Assert-That 'e: lan_hosts detail has Broadcast gear' ($chk.detail -match 'Broadcast gear: BirdDog Australia \(192\.168\.0\.20\)\.')
Assert-That 'e: lan_hosts detail has Source PCs' ($chk.detail -match 'Source PCs: 192\.168\.0\.21 \(1 source\(s\)\), 192\.168\.0\.22 \(1 source\(s\)\), 192\.168\.0\.50 \(1 source\(s\)\)\.')
Assert-That 'e: lan_hosts detail has Unknown vendor with randomised MAC' ($chk.detail -match 'Unknown vendor: 2 \(1 with a private/randomised MAC\)\.')
Assert-That 'e: lan_hosts detail has Managed switches note' ($chk.detail -match 'Managed switches only appear if they have a management IP on this subnet\.')

# Non-wired adapter in empty_lan.json (Wi-Fi)
$v = Run-Verdict (Get-Cfg) $null $null $null (Get-Fx 'empty_lan.json')
$chk = Get-Chk $v 'lan_hosts'
Assert-That 'e: lan_hosts non-wired note present for Wi-Fi' ($chk.detail -match 'Scanned the wifi adapter Wi-Fi because no wired adapter is up; on show day run this on the production network\.')

# ---------------------------------------------------------------------------------------------
# Ordering: the three new ids come right after lan_eee
# ---------------------------------------------------------------------------------------------
$v = Run-Verdict (Get-Cfg) $null $null $null (Get-Fx 'strong_lan.json')
$ids = @($v.checks | ForEach-Object { $_.id })
$idxEee = $ids.IndexOf('lan_eee')
$idxSrc = $ids.IndexOf('lan_sources_found')
$idxPt  = $ids.IndexOf('lan_partner_throughput')
$idxHst = $ids.IndexOf('lan_hosts')
$idxHw  = $ids.IndexOf('hw_cpu_threads')
Assert-That 'e: ordering: lan_sources_found right after lan_eee' ($idxSrc -eq ($idxEee + 1))
Assert-That 'e: ordering: lan_partner_throughput right after lan_sources_found' ($idxPt -eq ($idxEee + 2))
Assert-That 'e: ordering: lan_hosts right after lan_partner_throughput' ($idxHst -eq ($idxEee + 3))
Assert-That 'e: ordering: hw_cpu_threads right after lan_hosts' ($idxHw -eq ($idxEee + 4))

# ---------------------------------------------------------------------------------------------
# Lan null with everything else strong -> overall not GO and not_tested contains "local network"
# ---------------------------------------------------------------------------------------------
$v = Run-Verdict (Get-Cfg) (Get-Fx 'strong_hardware.json') (Get-Fx 'strong_network.json') (Get-Fx 'strong_loadtest.json') $null
Assert-That 'e: Lan null with strong PC is not GO' ($v.overall -ne 'GO')
Assert-That 'e: Lan null with strong PC is CAUTION (partial)' (($v.overall -eq 'CAUTION') -and ($v.partial -eq $true))
Assert-That 'e: Lan null adds "local network" to not_tested' ($v.not_tested -contains 'local network')

# ---------------------------------------------------------------------------------------------
# Hashtable-shaped lan objects accepted
# ---------------------------------------------------------------------------------------------
$lanHash = @{
    adapter = @{ name = 'Ethernet'; kind = 'wired'; ipv4 = '192.168.0.50'; prefix_length = 24; gateway = '192.168.0.1'; local_ips = @('192.168.0.50') }
    mdns = @{ query_ok = $true; listen_ms = 3000; methods = @(@{ name = 'unicast'; ok = $true; answers = 2; error = $null }); responders = @('192.168.0.21') }
    sources = @(
        @{ protocol = 'OMT'; name = 'STUDIO-A (Main Feed)'; machine = 'STUDIO-A'; source = 'Main Feed'; port = 6400; ip = '192.168.0.21'; local = $false }
        @{ protocol = 'OMT'; name = 'STUDIO-B (Side Feed)'; machine = 'STUDIO-B'; source = 'Side Feed'; port = 6400; ip = '192.168.0.22'; local = $false }
    )
    discovery_servers = @{ ndi = @(); omt = @() }
    sweep = @{ cidr = '192.168.0.0/24'; scanned = 254; alive = 2; seconds = 1.0; skipped_reason = $null }
    hosts = @(
        @{ ip = '192.168.0.1'; mac = '00-11-22-33-44-01'; vendor = 'Cisco Systems'; category = 'network'; is_gateway = $true; is_self = $false; sources = @() }
        @{ ip = '192.168.0.21'; mac = '00-14-22-01-02-05'; vendor = 'Dell Inc.'; category = 'pc'; is_gateway = $false; is_self = $false; sources = @('STUDIO-A (Main Feed)') }
    )
    partners = @(
        @{ host = '192.168.0.21'; ip = '192.168.0.21'; tcp = @{ mbps = 900; retransmits = 0 }; udp = @{ mbps = 400; loss_pct = 0.0; jitter_ms = 0.01 }; error = $null }
    )
    test = @{ protocol = 'OMT'; per_feed_mbps = 200; target_mbps = 400; seconds = 10 }
}
$vHash = $null
$threwHash = $false
try { $vHash = Run-Verdict (Get-Cfg) $null $null $null $lanHash } catch { $threwHash = $true }
Assert-That 'e: hashtable-shaped lan object does not throw' (-not $threwHash -and $null -ne $vHash)
Assert-That 'e: hashtable-shaped lan object yields PASS for sources' ((Get-Chk $vHash 'lan_sources_found').status -eq 'PASS')

# ---------------------------------------------------------------------------------------------
# Malformed lan object (strings where objects are expected) does not throw
# ---------------------------------------------------------------------------------------------
$badLan = [pscustomobject]@{
    adapter = 'not-an-object'
    mdns = 'invalid'
    sources = 'not-an-array'
    discovery_servers = 1234
    sweep = 'bad-sweep'
    hosts = 42
    partners = 'no-partners'
    test = $true
}
$threwBad = $false
$vBad = $null
try { $vBad = Run-Verdict (Get-Cfg) $null $null $null $badLan } catch { $threwBad = $true }
Assert-That 'e: malformed lan object does not throw' (-not $threwBad -and $null -ne $vBad)
Assert-That 'e: malformed lan object produces 34 checks' (@($vBad.checks).Count -eq $contractIds.Count)

# =============================================================================================
Write-Host ''
Write-Host '(e) SRT latency maths (hashtable inputs)' -ForegroundColor Cyan
$cfg = Get-Cfg

$v = Run-Verdict $cfg $null (New-MiniNet -P95 40) $null
Assert-That 'e: p95 40 ms, no loss -> table 3 x, no raise: 120 -> 150 ms, overhead 34 %' (($v.calc.srt.mult -eq 3) -and ((Get-Set $v 'srt_latency').value -eq '150 ms') -and ((Get-Set $v 'srt_overhead').value -eq '34 %')) ((Get-Set $v 'srt_latency').value + ' / ' + (Get-Set $v 'srt_overhead').value + ' / mult ' + $v.calc.srt.mult)
$v = Run-Verdict $cfg $null (New-MiniNet -P95 5) $null
Assert-That 'e: p95 5 ms is floored to 20 ms: 3 x 20 = 60 -> 100 ms' (((Get-Set $v 'srt_latency').value -eq '100 ms') -and ($v.calc.srt.rtt_calc_ms -eq 20)) ((Get-Set $v 'srt_latency').value)
$v = Run-Verdict $cfg $null (New-MiniNet -P95 160) $null
Assert-That 'e: RTT > 150 ms raises the multiplier to 4 even with clean UDP: 640 -> 650 ms' (($v.calc.srt.mult -eq 4) -and ((Get-Set $v 'srt_latency').value -eq '650 ms') -and ($v.calc.srt.latency_table_ms -eq 500)) ((Get-Set $v 'srt_latency').value + ' table ' + $v.calc.srt.latency_table_ms)
$v = Run-Verdict $cfg $null (New-MiniNet -P95 40 -Udp $false) $null
Assert-That 'e: UDP unmeasured raises 3 x to 4 x: 160 -> 200 ms, overhead 25 %' (($v.calc.srt.mult -eq 4) -and ((Get-Set $v 'srt_latency').value -eq '200 ms') -and ((Get-Set $v 'srt_overhead').value -eq '25 %')) ((Get-Set $v 'srt_latency').value)
Assert-That 'e: UDP unmeasured -> fr_udp_loss SKIP with the "ping only" note' (((Get-Chk $v 'fr_udp_loss').status -eq 'SKIP') -and ((Get-Chk $v 'fr_udp_loss').detail -match 'UDP path not measured - ping only'))
Assert-That 'e: UDP unmeasured -> overall is never GO' ($v.overall -ne 'GO') ('overall = ' + $v.overall)
$v = Run-Verdict $cfg $null (New-MiniNet -P95 40 -LossPct 2) $null
Assert-That 'e: 2 % loss -> table row 4 x / 4 %: 160 -> 200 ms, overhead 25 %' (($v.calc.srt.mult_table -eq 4) -and ((Get-Set $v 'srt_latency').value -eq '200 ms') -and ($v.calc.srt.overhead_pct -eq 25)) ((Get-Set $v 'srt_latency').value)
$v = Run-Verdict $cfg $null (New-MiniNet -P95 40 -LossPct 15) $null
Assert-That 'e: 15 % loss -> table row 10 x / 38 %: 400 ms, overhead 38 %' (($v.calc.srt.mult -eq 10) -and ((Get-Set $v 'srt_latency').value -eq '400 ms') -and ($v.calc.srt.overhead_pct -eq 38) -and ((Get-Chk $v 'fr_udp_loss').status -eq 'FAIL')) ((Get-Set $v 'srt_latency').value)
$v = Run-Verdict $cfg $null (New-MiniNet -P95 40 -LossPct 30) $null
Assert-That 'e: 30 % loss (above the whole table) uses the last row' (($v.calc.srt.mult -eq 10) -and ($v.calc.srt.overhead_pct -eq 38))
$v = Run-Verdict $cfg $null (New-MiniNet -P95 40 -LossPct 0 -Lossy 2) $null
Assert-That 'e: lossy intervals with 0 % average loss raise 3 x to 4 x' (($v.calc.srt.mult -eq 4) -and ((Get-Chk $v 'fr_udp_bursts').status -eq 'WARN'))
$v = Run-Verdict $cfg $null (New-MiniNet -P95 3000) $null
Assert-That 'e: latency is capped at srt_latency_max_ms (8000)' ((Get-Set $v 'srt_latency').value -eq '8,000 ms') ((Get-Set $v 'srt_latency').value)
$v = Run-Verdict $cfg $null (New-MiniNet -P95 40 -Upload 40) $null
Assert-That 'e: 40 Mbps upload vs ~36 Mbps need -> uplink_capacity FAIL' ((Get-Chk $v 'uplink_capacity').status -eq 'FAIL') ((Get-Chk $v 'uplink_capacity').value)
$v = Run-Verdict $cfg $null (New-MiniNet -P95 40 -Upload 60) $null
Assert-That 'e: 60 Mbps upload -> ratio 1.7 -> uplink_capacity WARN' ((Get-Chk $v 'uplink_capacity').status -eq 'WARN') ((Get-Chk $v 'uplink_capacity').value)

# SRT destination host: use that target alone for RTT
$cfg2 = Get-Cfg
$cfg2.show.srt_destination_host = '198.51.100.7'
$v = Run-Verdict $cfg2 $null (Get-Fx 'dest_network.json') $null
Assert-That 'e: -SrtHost target measured -> RTT from that target alone (214 ms)' (((Get-Chk $v 'fr_rtt').value -eq '214 ms') -and ($v.calc.srt.rtt_p95_ms -eq 214) -and ((Get-Set $v 'srt_latency').value -eq '900 ms')) ((Get-Chk $v 'fr_rtt').value + ' / ' + (Get-Set $v 'srt_latency').value)
Assert-That 'e: -SrtHost detail names the SRT destination' ((Get-Chk $v 'fr_rtt').detail -match 'SRT destination')
$cfg3 = Get-Cfg
$cfg3.show.srt_destination_host = '203.0.113.99'
$v = Run-Verdict $cfg3 $null (Get-Fx 'strong_network.json') $null
Assert-That 'e: -SrtHost set but not measured -> falls back to all France targets (273 ms)' ((Get-Chk $v 'fr_rtt').value -eq '273 ms')

# France unreachable
$netDown = @{ targets = @(@{ name = 'FR one'; host = 'fr1.example'; group = 'france'; icmp = @{ sent = 30; received = 0; blocked = $true }; tcp = @{ port = 443; attempts = 8; ok = 0 } }); udp = @(); upload = @{ mbps = 300 } }
$v = Run-Verdict $cfg $null $netDown $null
Assert-That 'e: no France target answering -> fr_reach FAIL, overall NO-GO' (((Get-Chk $v 'fr_reach').status -eq 'FAIL') -and ($v.overall -eq 'NO-GO'))
Assert-That 'e: no RTT -> fr_rtt SKIP and no srt_latency setting' (((Get-Chk $v 'fr_rtt').status -eq 'SKIP') -and ($null -eq (Get-Set $v 'srt_latency')))

# =============================================================================================
Write-Host ''
Write-Host '(f) partial runs and edge cases' -ForegroundColor Cyan
$v = Run-Verdict (Get-Cfg) (Get-Fx 'strong_hardware.json') $null $null
Assert-That 'f: hardware-only run on a good PC is CAUTION (partial), not GO' (($v.overall -eq 'CAUTION') -and ($v.partial -eq $true)) ('overall = ' + $v.overall)
Assert-That 'f: partial headline names what was not tested' (($v.headline -match 'network') -and ($v.headline -match 'load test')) $v.headline
Assert-That 'f: hardware checks still PASS' (((Get-Chk $v 'hw_ram').status -eq 'PASS') -and ((Get-Chk $v 'fr_reach').status -eq 'SKIP'))
Assert-That 'f: hardware-only still yields an encoder setting from the NVIDIA GPU' ((Get-Set $v 'encoder').value -match 'NVENC')

$hwVirt = Get-Fx 'strong_hardware.json'
$hwVirt.nics = @(
    [pscustomobject]@{ name = 'Ethernet'; status = 'Up'; link_mbps = 700; kind = 'wired'; default_route = $false; network_category = 'Public'; eee = 'on' },
    [pscustomobject]@{ name = 'vEthernet (External)'; status = 'Up'; link_mbps = 1000; kind = 'virtual'; default_route = $true; network_category = 'Private'; eee = 'unknown' }
)
$v = Run-Verdict (Get-Cfg) $hwVirt $null $null
Assert-That 'f: wired up but default route on a virtual adapter -> uplink_wifi WARN' ((Get-Chk $v 'uplink_wifi').status -eq 'WARN') ('status = ' + (Get-Chk $v 'uplink_wifi').status)
Assert-That 'f: Public wired profile -> lan_profile WARN' ((Get-Chk $v 'lan_profile').status -eq 'WARN')
Assert-That 'f: EEE on -> lan_eee WARN' ((Get-Chk $v 'lan_eee').status -eq 'WARN')
Assert-That 'f: 700 Mbps link vs 400 Mbps intake (1.75 x) -> lan_headroom WARN and input_protocol NDI HX3 or OMT Low' (((Get-Chk $v 'lan_headroom').status -eq 'WARN') -and ((Get-Set $v 'input_protocol').value -eq 'NDI HX3 or OMT Low')) ('status = ' + (Get-Chk $v 'lan_headroom').status)

$hwOld = Get-Fx 'strong_hardware.json'
$hwOld.gpus[0].nvidia_driver = 540.10
$hwOld.gpus[0].driver_date = '2024-01-05'
$hwOld.power.on_battery = $true
$hwOld.windows.pending_reboot = $true
$hwOld.disk.free_gb = 12
$hwOld.processes.running = @('vMix64', 'OneDrive', 'chrome')
$v = Run-Verdict (Get-Cfg) $hwOld $null $null
Assert-That 'f: driver 540.10 -> 5 sessions PASS' (((Get-Chk $v 'hw_nvenc_sessions').status -eq 'PASS') -and ((Get-Chk $v 'hw_nvenc_sessions').value -match '^5 sessions'))
$hwOld.gpus[0].nvidia_driver = 500.00
$v = Run-Verdict (Get-Cfg) $hwOld $null $null
Assert-That 'f: driver 500.00 -> 3-session WARN' ((Get-Chk $v 'hw_nvenc_sessions').status -eq 'WARN')
Assert-That 'f: old GPU driver -> hw_gpu_driver_age WARN' ((Get-Chk $v 'hw_gpu_driver_age').status -eq 'WARN') ((Get-Chk $v 'hw_gpu_driver_age').value)
Assert-That 'f: on battery -> hw_power FAIL' ((Get-Chk $v 'hw_power').status -eq 'FAIL')
Assert-That 'f: pending reboot -> hw_pending_reboot WARN' ((Get-Chk $v 'hw_pending_reboot').status -eq 'WARN')
Assert-That 'f: 12 GB free -> hw_disk WARN' ((Get-Chk $v 'hw_disk').status -eq 'WARN')
Assert-That 'f: OneDrive + chrome -> sw_background WARN naming them' (((Get-Chk $v 'sw_background').status -eq 'WARN') -and ((Get-Chk $v 'sw_background').fix -match 'OneDrive') -and ((Get-Chk $v 'sw_background').fix -match 'chrome') -and ((Get-Chk $v 'sw_background').fix -notmatch 'vMix'))

$hwNoMixer = Get-Fx 'weak_hardware.json'
$hwNoMixer.software.obs = $null
$v = Run-Verdict (Get-Cfg) $hwNoMixer $null $null
Assert-That 'f: integrated GPU and no mixer detected -> hw_gpu FAIL' ((Get-Chk $v 'hw_gpu').status -eq 'FAIL')
Assert-That 'f: no mixer -> sw_mixer WARN' ((Get-Chk $v 'sw_mixer').status -eq 'WARN')
$hwVmix = Get-Fx 'weak_hardware.json'
$hwVmix.software.vmix = '28.0.0.1'
$v = Run-Verdict (Get-Cfg) $hwVmix $null $null
Assert-That 'f: integrated GPU with vMix installed -> hw_gpu FAIL' ((Get-Chk $v 'hw_gpu').status -eq 'FAIL')

$cfgNdi = Get-Cfg
$cfgNdi.show.inputs.protocol = 'NDI'
$v = Run-Verdict $cfgNdi (Get-Fx 'weak_hardware.json') $null $null
Assert-That 'f: NDI show with OBS lacking DistroAV and no NDI runtime -> sw_ndi WARN' ((Get-Chk $v 'sw_ndi').status -eq 'WARN')
$v = Run-Verdict (Get-Cfg) (Get-Fx 'weak_hardware.json') $null $null
Assert-That 'f: OMT show -> sw_ndi is INFO' ((Get-Chk $v 'sw_ndi').status -eq 'INFO')

$ldHot = Get-Fx 'strong_loadtest.json'
$ldHot.system.cpu_p95 = 70
$ldHot.system.gpu_enc_p95 = 95
$ldHot.system.perf_min = 70
$v = Run-Verdict (Get-Cfg) $null $null $ldHot
Assert-That 'f: cpu p95 70 -> load_cpu WARN, gpu enc 95 -> FAIL, perf drop 30 % -> load_throttle WARN' (((Get-Chk $v 'load_cpu').status -eq 'WARN') -and ((Get-Chk $v 'load_gpu_encode').status -eq 'FAIL') -and ((Get-Chk $v 'load_throttle').status -eq 'WARN'))
$ldNoFf = Get-Fx 'strong_loadtest.json'
$ldNoFf.ffmpeg.found = $false
$v = Run-Verdict (Get-Cfg) $null $null $ldNoFf
Assert-That 'f: ffmpeg missing -> all load checks SKIP' (@($v.checks | Where-Object { $_.section -eq 'load' -and $_.status -ne 'SKIP' }).Count -eq 0)

# =============================================================================================
Write-Host ''
Write-Host '(g) real fixtures from ShowReady\fixtures (dev laptop)' -ForegroundColor Cyan
$realDir = Join-Path $kit 'fixtures'
$rh = $null; $rn = $null; $rl = $null; $rlan = $null
$haveAny = $false
foreach ($pair in @(@('hardware.json', 'h'), @('network.json', 'n'), @('loadtest.json', 'l'), @('lan.json', 'lan'))) {
    $p = Join-Path $realDir $pair[0]
    if (Test-Path $p) {
        $haveAny = $true
        try {
            $obj = Read-Json $p
            if ($pair[1] -eq 'h') { $rh = $obj }
            if ($pair[1] -eq 'n') { $rn = $obj }
            if ($pair[1] -eq 'l') { $rl = $obj }
            if ($pair[1] -eq 'lan') { $rlan = $obj }
            Write-Host ('  loaded ' + $pair[0]) -ForegroundColor DarkGray
        }
        catch { Write-Host ('  could not parse ' + $pair[0] + ': ' + $_.Exception.Message) -ForegroundColor Yellow }
    }
}
if (-not $haveAny) {
    Write-Host '  no real fixtures yet (hardware.json / network.json / loadtest.json) - skipped' -ForegroundColor Yellow
}
else {
    $threw = $false
    $v = $null
    try { $v = Get-SRVerdict -Config (Get-Cfg) -Hardware $rh -Network $rn -LoadTest $rl -Lan $rlan } catch { $threw = $true; Write-Host ('        exception: ' + $_.Exception.Message) -ForegroundColor Red }
    Assert-That 'g: Get-SRVerdict does not throw on real fixtures' (-not $threw -and $null -ne $v)
    if ($null -ne $v) {
        Write-Host ('  overall: ' + $v.overall) -ForegroundColor Cyan
        Write-Host ('  headline: ' + $v.headline) -ForegroundColor Cyan
        foreach ($c in $v.checks) {
            $col = 'Gray'
            if ($c.status -eq 'PASS') { $col = 'Green' }
            if ($c.status -eq 'WARN') { $col = 'Yellow' }
            if ($c.status -eq 'FAIL') { $col = 'Red' }
            Write-Host ('    {0,-5} {1,-22} {2}   [{3}]' -f $c.status, $c.id, $c.value, $c.limit) -ForegroundColor $col
        }
        foreach ($s in $v.settings) { Write-Host ('    setting {0,-15} {1}' -f $s.id, $s.value) -ForegroundColor DarkGray }
        if ($v.errors.Count -gt 0) { Write-Host ('  rule errors: ' + ($v.errors -join ' | ')) -ForegroundColor Yellow }
        if ($null -ne $rh) {
            Assert-That 'g: the dev laptop comes out NO-GO' ($v.overall -eq 'NO-GO') ('overall = ' + $v.overall)
        }
        if ($null -ne $rlan) {
            Assert-That 'g: real lan.json (Public Wi-Fi, no mDNS answers) -> lan_sources_found INFO' ((Get-Chk $v 'lan_sources_found').status -eq 'INFO')
            Assert-That 'g: real lan.json loopback partner -> loopback fix, not a cable fix' ((Get-Chk $v 'lan_partner_throughput').fix -notmatch 'cable') (Get-Chk $v 'lan_partner_throughput').fix
            Assert-That 'g: real lan.json -> lan_hosts INFO' ((Get-Chk $v 'lan_hosts').status -eq 'INFO')
        }
        $jsonOk = $false
        try { $null = ConvertTo-Json -InputObject $v -Depth 12; $jsonOk = $true } catch { $jsonOk = $false }
        Assert-That 'g: verdict on real fixtures serialises to JSON' $jsonOk
    }
}

# =============================================================================================
Write-Host ''
Write-Host '(h: encoder fallback and combined test)' -ForegroundColor Cyan

# ---------------------------------------------------------------------------------------------
# 1. NVIDIA old driver (nvold_hardware.json + nvold_loadtest.json)
# ---------------------------------------------------------------------------------------------
$vNvOld = Run-Verdict (Get-Cfg) (Get-Fx 'nvold_hardware.json') (Get-Fx 'strong_network.json') (Get-Fx 'nvold_loadtest.json') -Lan (Get-Fx 'strong_lan.json')
$chkEnc = Get-Chk $vNvOld 'load_encoder'
Assert-That 'h: NVIDIA old driver -> load_encoder WARN' ($chkEnc.status -eq 'WARN')
Assert-That 'h: NVIDIA old driver -> exact value string' ($chkEnc.value -ceq 'NVIDIA driver 560.94 is older than 570 needed by this test') ($chkEnc.value)
Assert-That 'h: NVIDIA old driver -> detail contains both nvenc lines' (($chkEnc.detail -cmatch '\[h264_nvenc\] Driver does not support the required nvenc API version\. Required: 13\.0 Found: 12\.2') -and ($chkEnc.detail -cmatch '\[h264_nvenc\] The minimum required Nvidia driver for nvenc is 570\.0 or newer')) ($chkEnc.detail)
Assert-That 'h: NVIDIA old driver -> exact fix' ($chkEnc.fix -ceq 'vMix/OBS can usually still use NVENC on this driver. To run this test, update to the current NVIDIA Studio driver, or check NVENC in vMix/OBS by hand.') ($chkEnc.fix)

$expectedFbDetail = 'Not representative: the test fell back to CPU encoding, but vMix/OBS would use the GPU.'
$chkRt = Get-Chk $vNvOld 'load_realtime'
$chkCpu = Get-Chk $vNvOld 'load_cpu'
$chkGpu = Get-Chk $vNvOld 'load_gpu_encode'
$chkThr = Get-Chk $vNvOld 'load_throttle'
Assert-That 'h: fellBack -> load_realtime SKIP with exact detail' (($chkRt.status -eq 'SKIP') -and ($chkRt.detail -ceq $expectedFbDetail)) ($chkRt.status + ': ' + $chkRt.detail)
Assert-That 'h: fellBack -> load_cpu SKIP with exact detail' (($chkCpu.status -eq 'SKIP') -and ($chkCpu.detail -ceq $expectedFbDetail)) ($chkCpu.status + ': ' + $chkCpu.detail)
Assert-That 'h: fellBack -> load_gpu_encode SKIP with exact detail' (($chkGpu.status -eq 'SKIP') -and ($chkGpu.detail -ceq $expectedFbDetail)) ($chkGpu.status + ': ' + $chkGpu.detail)
Assert-That 'h: fellBack -> load_throttle SKIP with exact detail' (($chkThr.status -eq 'SKIP') -and ($chkThr.detail -ceq $expectedFbDetail)) ($chkThr.status + ': ' + $chkThr.detail)
Assert-That 'h: not_tested contains "load test (fell back to CPU encoding)"' ($vNvOld.not_tested -contains 'load test (fell back to CPU encoding)')

Assert-That 'h: with everything else strong overall is CAUTION (not NO-GO)' ($vNvOld.overall -eq 'CAUTION') ('overall = ' + $vNvOld.overall)

$setEnc = Get-Set $vNvOld 'encoder'
Assert-That 'h: encoder setting is NVENC text' ($setEnc.value -ceq 'NVENC H.264 (h264_nvenc), preset P4, CBR, keyframe 2 s - same for all three outputs') ($setEnc.value)
Assert-That 'h: encoder setting why mentions load test could not confirm' ($setEnc.why -ceq 'Based on the NVIDIA GPU; the load test could not confirm it.') ($setEnc.why)

# ---------------------------------------------------------------------------------------------
# 2. AMD failure (inline AMD hardware + amdfail_loadtest.json)
# ---------------------------------------------------------------------------------------------
$amdHw = Get-Fx 'strong_hardware.json'
$amdHw.gpus = @(
    [pscustomobject]@{
        name = 'AMD Radeon RX 7900 XTX'
        vendor = 'AMD'
        integrated = $false
        driver_version = '31.0.24033.1003'
        driver_date = '2024-08-20'
        vram_gb = 24
    }
)
$vAmd = Run-Verdict (Get-Cfg) $amdHw (Get-Fx 'strong_network.json') (Get-Fx 'amdfail_loadtest.json') -Lan (Get-Fx 'strong_lan.json')
$chkAmd = Get-Chk $vAmd 'load_encoder'
Assert-That 'h: AMD failure -> load_encoder WARN (case c)' ($chkAmd.status -eq 'WARN')
Assert-That 'h: AMD failure -> exact value string' ($chkAmd.value -ceq 'AMD GPU encoder failed in this test') ($chkAmd.value)
Assert-That 'h: AMD failure -> detail shows real AMF line' ($chkAmd.detail -cmatch '\[h264_amf\] AMF failed to initialise context') ($chkAmd.detail)
Assert-That 'h: AMD failure -> exact fix' ($chkAmd.fix -ceq 'Update or reinstall the AMD GPU driver and run again. Meanwhile check in vMix/OBS that the GPU encoder (NVENC/AMF) works.') ($chkAmd.fix)
Assert-That 'h: AMD failure -> load_realtime SKIP due to fallback' ((Get-Chk $vAmd 'load_realtime').status -eq 'SKIP')

# ---------------------------------------------------------------------------------------------
# 3. Integrated GPU only + libx264 -> still FAIL (case d), load_realtime NOT skipped
# ---------------------------------------------------------------------------------------------
$vInteg = Run-Verdict (Get-Cfg) (Get-Fx 'weak_hardware.json') (Get-Fx 'strong_network.json') (Get-Fx 'nvold_loadtest.json') -Lan (Get-Fx 'strong_lan.json')
$chkInteg = Get-Chk $vInteg 'load_encoder'
Assert-That 'h: integrated GPU only + libx264 -> case d FAIL' ($chkInteg.status -eq 'FAIL')
Assert-That 'h: integrated GPU only + libx264 -> value is "software only (libx264)"' ($chkInteg.value -ceq 'software only (libx264)') ($chkInteg.value)
Assert-That 'h: integrated GPU only + libx264 -> load_realtime is NOT skipped' ((Get-Chk $vInteg 'load_realtime').status -ne 'SKIP') ((Get-Chk $vInteg 'load_realtime').status)
Assert-That 'h: integrated GPU only + libx264 -> not_tested does not contain CPU fallback' ($vInteg.not_tested -notcontains 'load test (fell back to CPU encoding)')

# ---------------------------------------------------------------------------------------------
# 4. QSV chosen -> PASS (case a)
# ---------------------------------------------------------------------------------------------
$ltQsv = Get-Fx 'nvold_loadtest.json'
$ltQsv.encoders.chosen = 'h264_qsv'
$vQsv = Run-Verdict (Get-Cfg) (Get-Fx 'nvold_hardware.json') (Get-Fx 'strong_network.json') $ltQsv -Lan (Get-Fx 'strong_lan.json')
$chkQsv = Get-Chk $vQsv 'load_encoder'
Assert-That 'h: QSV chosen -> case a PASS' ($chkQsv.status -eq 'PASS')
Assert-That 'h: QSV chosen -> value is "h264_qsv"' ($chkQsv.value -ceq 'h264_qsv') ($chkQsv.value)
Assert-That 'h: QSV chosen with NVIDIA GPU present -> detail notes NVENC failed' ($chkQsv.detail -cmatch 'An NVIDIA GPU is present but NVENC failed') ($chkQsv.detail)

# ---------------------------------------------------------------------------------------------
# 5. Tested entry without error_lines but with error still works
# ---------------------------------------------------------------------------------------------
$ltNoLines = Get-Fx 'amdfail_loadtest.json'
foreach ($te in $ltNoLines.encoders.tested) {
    if ($te.name -eq 'h264_amf') {
        $te.error = '[h264_amf] Generic failure code -10'
        $te.error_lines = $null
    }
}
$vNoLines = Run-Verdict (Get-Cfg) $amdHw (Get-Fx 'strong_network.json') $ltNoLines -Lan (Get-Fx 'strong_lan.json')
$chkNoLines = Get-Chk $vNoLines 'load_encoder'
Assert-That 'h: tested entry without error_lines but with error -> WARN' ($chkNoLines.status -eq 'WARN')
Assert-That 'h: tested entry without error_lines -> detail contains error property text' ($chkNoLines.detail -cmatch '\[h264_amf\] Generic failure code -10') ($chkNoLines.detail)

# ---------------------------------------------------------------------------------------------
# 6. driver_required null + API-version line -> "too old for this test's NVENC" value
# ---------------------------------------------------------------------------------------------
$ltNullReq = Get-Fx 'nvold_loadtest.json'
foreach ($te in $ltNullReq.encoders.tested) {
    if ($te.name -eq 'h264_nvenc') {
        $te.driver_required = $null
    }
}
$vNullReq = Run-Verdict (Get-Cfg) (Get-Fx 'nvold_hardware.json') (Get-Fx 'strong_network.json') $ltNullReq -Lan (Get-Fx 'strong_lan.json')
$chkNullReq = Get-Chk $vNullReq 'load_encoder'
Assert-That 'h: driver_required null + API-version line -> exact too old value' ($chkNullReq.value -ceq 'NVIDIA driver 560.94 is too old for this test''s NVENC') ($chkNullReq.value)

# ---------------------------------------------------------------------------------------------
# 7. lan_partner_throughput with combined_lan.json (WARN, bottleneck fix, "Both at once")
# ---------------------------------------------------------------------------------------------
$vComb = Run-Verdict (Get-Cfg) $null $null $null (Get-Fx 'combined_lan.json')
$chkComb = Get-Chk $vComb 'lan_partner_throughput'
Assert-That 'h: combined_lan.json -> lan_partner_throughput WARN' ($chkComb.status -eq 'WARN')
Assert-That 'h: combined_lan.json -> exact value string' ($chkComb.value -ceq '480 Mbps TCP together, 0.80 % UDP loss') ($chkComb.value)
Assert-That 'h: combined_lan.json -> exact bottleneck fix' ($chkComb.fix -ceq 'Each source PC passes on its own but not together, so the link into this PC (or the switch uplink) is the bottleneck. Use a 2.5 GbE link to this PC, or lighter feeds (NDI HX3 / OMT Low).') ($chkComb.fix)
Assert-That 'h: combined_lan.json -> detail contains "Both at once (2 source PCs)"' ($chkComb.detail -cmatch 'Both at once \(2 source PCs\)') ($chkComb.detail)
Assert-That 'h: combined_lan.json -> margin is 0.8 (480 / 600)' ($chkComb.margin -eq 0.8)

# ---------------------------------------------------------------------------------------------
# 8. Combined object with tcp.mbps null -> at least WARN with "Could not test both at once"
# ---------------------------------------------------------------------------------------------
$lanCombNull = Get-Fx 'combined_lan.json'
$lanCombNull.combined.tcp.mbps = $null
$lanCombNull.combined.error = 'connection timed out'
$vCombNull = Run-Verdict (Get-Cfg) $null $null $null $lanCombNull
$chkCombNull = Get-Chk $vCombNull 'lan_partner_throughput'
Assert-That 'h: combined tcp.mbps null -> at least WARN' (($chkCombNull.status -eq 'WARN') -or ($chkCombNull.status -eq 'FAIL')) ($chkCombNull.status)
Assert-That 'h: combined tcp.mbps null -> detail contains "Could not test both at once"' ($chkCombNull.detail -cmatch 'Could not test both at once: connection timed out\.') ($chkCombNull.detail)

# ---------------------------------------------------------------------------------------------
# 9. Combined missing -> unchanged (PASS, no "Both at once", partner value and empty fix)
# ---------------------------------------------------------------------------------------------
$lanCombMiss = Get-Fx 'combined_lan.json'
$lanCombMiss.combined = $null
$vCombMiss = Run-Verdict (Get-Cfg) $null $null $null $lanCombMiss
$chkCombMiss = Get-Chk $vCombMiss 'lan_partner_throughput'
Assert-That 'h: combined missing -> status PASS' ($chkCombMiss.status -eq 'PASS')
Assert-That 'h: combined missing -> detail does NOT contain "Both at once"' ($chkCombMiss.detail -cnotmatch 'Both at once') ($chkCombMiss.detail)
Assert-That 'h: combined missing -> fix is empty' ($chkCombMiss.fix -ceq '') ($chkCombMiss.fix)
Assert-That 'h: combined missing -> partner value preserved' ($chkCombMiss.value -ceq '935 Mbps TCP, 0.00 % UDP loss') ($chkCombMiss.value)

# =============================================================================================
Write-Host ''
if ($script:nFail -eq 0) {
    Write-Host ('ALL ' + $script:nPass + ' ASSERTIONS PASSED') -ForegroundColor Green
    exit 0
}
Write-Host ([string]$script:nFail + ' FAILED, ' + $script:nPass + ' passed') -ForegroundColor Red
exit 1
