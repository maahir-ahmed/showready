# ShowReady — build contract (read fully before writing code)

A portable Windows kit a crew member double-clicks on a live-production PC at **Gen.G Academy, Seoul**
to decide whether that PC and its internet line can run the show, and which settings to use.

**Show:** 2 incoming 1080p60 feeds over the LAN (OMT or NDI) into vMix or OBS → mix → 3 encoded
1080p60 outputs: 1× SRT to a partner in **France** (~210–290 ms RTT from Seoul), 1× YouTube, 1× Twitch.

**Three PCs, one kit.** The "prod" PC runs vMix/OBS and the outputs (Run-ShowReady.cmd). The two "observer"
(source) PCs run the game/observer client and will send the two feeds; they may not have NDI/OMT installed yet.
They run Run-Observer.cmd (`ShowReady.ps1 -Role observer`): hardware + network-adapter checks, a one-feed
sender encode test, then an iperf3 server that waits for the prod PC's LAN test.

## Folder layout

```
ShowReady\
  Run-ShowReady.cmd          double-click launcher (quick mode); Run-ShowReady-Full.cmd for full mode
  Run-Observer.cmd           run on each OBSERVER (source) PC: ShowReady.ps1 -Role observer
  ShowReady.ps1              orchestrator
  config.json                show profile, endpoints, thresholds (already written — read it)
  lib\Hardware.ps1           Get-SRHardware
  lib\Network.ps1            Invoke-SRNetwork
  lib\LoadTest.ps1           Invoke-SRLoadTest, Invoke-SRSenderTest, SRLT_ProbeErrorLines
  lib\Lan.ps1                Invoke-SRLan (NDI/OMT discovery, LAN device sweep, iperf3 to source PCs)
  lib\Rules.ps1              Get-SRVerdict
  lib\ObserverRules.ps1      Get-SRObserverVerdict (needs Rules.ps1 dot-sourced first)
  Run-LanPartner.cmd         run on a SOURCE PC: bin\iperf3.exe -s -p 5201 only (Run-Observer.cmd also does this)
  report-template.html       renders results; contains the literal token /*__SHOWREADY_DATA__*/null
  bin\ffmpeg.exe  bin\iperf3.exe  bin\cygwin1.dll   (already present)
  fixtures\*.json            real outputs captured on the dev laptop
  tests\Test-Rules.ps1       plain-PowerShell assertions for Rules.ps1 (no Pester)
  tests\Test-Lan.ps1         plain-PowerShell assertions for Lan.ps1's offline parts (DNS parser, OUI lookup, iperf JSON,
                             both-at-once sums); -Live adds two loopback iperf3 servers for the combined test
  tests\Test-ObserverRules.ps1  assertions for ObserverRules.ps1
  tests\Test-Encoder.ps1     assertions for SRLT_ProbeErrorLines (encoder probe stderr → error_lines, driver_required),
                             progress parsing and Invoke-SRSenderTest; -Live adds a 15 s real sender test
  results\<yyyyMMdd-HHmmss>\results.json + report.html   (created at runtime)
```

## Hard constraints (all files)

1. **Windows PowerShell 5.1.** The target PC has no PowerShell 7. Verify every file with
   `powershell.exe -NoProfile -ExecutionPolicy Bypass -File ...` — never only with `pwsh`.
   Banned: ternary `?:`, `??`, `?.`, `ForEach-Object -Parallel`, `ConvertFrom-Json -AsHashtable`,
   `Test-Connection -TargetName`, `Get-Error`, `&&`/`||` chains, `using namespace` after code,
   `[ordered]` is fine. JSON: `ConvertTo-Json -Depth 12`.
2. **Locale-independent.** The PC may run **Korean** Windows. Do NOT use `Get-Counter` (counter names are
   translated); use CIM perf classes (`Win32_PerfFormattedData_Counters_ProcessorInformation`,
   `Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine`, `Win32_PerfFormattedData_PerfOS_Memory`).
   Identify power plans by GUID, not name. Parse `tracert`/`powercfg` output with regexes on numbers,
   IPs and GUIDs only — never English words.
3. **No admin, no installs, no system changes.** Read-only inspection. If something needs admin, record
   `"unknown"` and move on.
4. **Never throw to the caller.** Wrap each probe in try/catch; append a short message to the object's
   `errors` array; leave the field `$null`. Every external process gets a timeout and is killed after it.
5. **External binaries** (`$BinDir\iperf3.exe`, `$BinDir\ffmpeg.exe`) are launched with
   `-WorkingDirectory $env:TEMP` (cygwin iperf3 dislikes long cwd paths) and absolute paths for files.
6. Optional `-Log` scriptblock parameter: call `& $Log "message"` for progress lines (if not null).
7. Each lib file only defines its function(s); no top-level side effects when dot-sourced.

## Function signatures and outputs

All outputs are `[pscustomobject]` (nested objects/arrays allowed) that serialise with `ConvertTo-Json -Depth 12`.
Numbers are numbers (not strings). Milliseconds as `_ms`, percentages as `_pct` (0–100).

### `Get-SRHardware [-Log <scriptblock>]`  (lib\Hardware.ps1)
```
os:        { caption, version, build }
computer:  { name, manufacturer, model, is_laptop (bool; chassis type or battery present) }
cpu:       { name, cores, threads, max_mhz }
ram_gb:    number (1 decimal)
gpus:      [ { name, vendor: "NVIDIA"|"AMD"|"Intel"|"Other", integrated (bool),
               driver_version, nvidia_driver (e.g. 560.94 as number, from last 5 digits of driver_version; null if not NVIDIA),
               driver_date "yyyy-MM-dd", vram_gb (from registry HardwareInformation.qwMemorySize when available) } ]
nics:      [ { name, description, status, link_mbps (number|null), kind: "wired"|"wifi"|"virtual"|"other",
               default_route (bool), ipv4: [..], network_category: "Public"|"Private"|"DomainAuthenticated"|null,
               eee: "on"|"off"|"unknown" } ]
           kind=virtual when not HardwareInterface or description matches Hyper-V|Virtual|vEthernet|VPN|TAP|
           WireGuard|Tailscale|ZeroTier|VMware|VirtualBox|Loopback|WAN Miniport|Bluetooth.
power:     { plan_guid, plan: "balanced"|"high_performance"|"ultimate"|"power_saver"|"custom", on_battery (bool|null), battery_pct }
           GUIDs: 381b4222-f694-41f0-9685-ff5bb260df2e balanced, 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c high_performance,
                  e9a42b02-d5df-448d-aa00-03f14749eb61 ultimate, a1841308-3541-4fab-bc81-f71556f20b4a power_saver.
disk:      { system_drive, free_gb, total_gb }
software:  { vmix, obs, ndi_runtime, ndi_tools, distroav, omt }   (version string or null; from Uninstall registry keys
           HKLM + WOW6432Node + HKCU; also check OBS plugin folders for distroav)
windows:   { hags: "on"|"off"|"unknown" (HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers HwSchMode 2=on),
             game_mode: "on"|"off"|"unknown" (HKCU\Software\Microsoft\GameBar AutoGameModeEnabled),
             pending_reboot (bool), firewall_profiles: [ { name, enabled } ] }
processes: { running: [names from watchlist found running] }
           watchlist: vMix64, vMix, obs64, OneDrive, Teams, ms-teams, Discord, Steam, chrome, msedge,
                      EpicGamesLauncher, Dropbox, GoogleDriveFS, NDI*, OMT*
errors:    [ strings ]
```

### `Invoke-SRNetwork -Config <obj> -BinDir <path> [-Mode quick|full] [-Log]`  (lib\Network.ps1)
```
public:   { ip, city, country, org }  (GET config.network.public_ip_lookup, 8 s timeout; null on failure)
targets:  [ { name, host, group, service, ip,
              icmp: { sent, received, loss_pct, min_ms, p50_ms, p95_ms, p99_ms, max_ms, jitter_ms, samples_ms: [...] },
              tcp:  { port, attempts, ok, p50_ms, p95_ms, samples_ms: [...] } } ]
          ICMP: System.Net.NetworkInformation.Ping; ping all targets concurrently each round (SendPingAsync +
          [Threading.Tasks.Task]::WaitAll), rounds = config.network.ping_count[mode], interval ping_interval_ms,
          timeout 2000 ms. jitter_ms = mean |rtt[i]-rtt[i-1]| over successful replies.
          If received = 0, set icmp.blocked = true (host ignores ping; NOT treated as loss).
          TCP: TcpClient.BeginConnect with 3000 ms timeout, Stopwatch timing, tcp_samples attempts.
traces:   [ { host, hops: [ { hop, ip (null for *), rtt_ms: [n|null, n|null, n|null] } ] } ]
          tracert -d -w 800 -h 30 <host> for each host in config.network.trace_hosts[mode]; regex-parse.
udp:      [ { host, port, target_mbps, seconds, packet_bytes, packets, lost, loss_pct, jitter_ms,
              intervals: [ { t, packets, lost } ], worst_interval_loss_pct, lossy_intervals, error } ]
          For each target with iperf_ports: iperf3 -c host -p P -u -b <mbps>M -l 1316 -t <udp_seconds[mode]>
          --get-server-output -J; try ports from the range in order until one works (servers allow one
          client at a time; "busy" / connect errors → next port, max 12 tries, 1 s pause).
          target_mbps = srt video_kbps * 1.25 / 1000 (from config.show.outputs id "srt").
          Use RECEIVER numbers: server_output_json.end (sum) for packets/lost/jitter, and
          server_output_json.intervals[].sum for per-interval packets/lost_packets. If server output is
          missing, fall back to end.sum and leave intervals empty.
          lossy_intervals = count of intervals with lost/packets*100 > thresholds.srt_burst_interval_loss_pct.
upload:   { method: "cloudflare", mbps, streams, bytes, seconds, error }
          Create one temp file of random bytes (mb_per_stream MB). Start `streams` concurrent
          `curl.exe -s -o NUL -X POST --data-binary @file <url> -w "%{size_upload} %{time_total}"`
          processes; mbps = total bytes*8 / max wall time / 1e6. Delete the temp file. (Measures local
          uplink capacity to a nearby Cloudflare PoP — the shared budget for SRT+YouTube+Twitch.)
errors:   [ strings ]
```

### `Invoke-SRLoadTest -Config <obj> -BinDir <path> [-Seconds <int>] [-Log]`  (lib\LoadTest.ps1)
Simulates the show's processing: 2 incoming intra-codec 1080p60 feeds decoded + 3 simultaneous 1080p60
H.264 encodes at the configured bitrates, all real-time paced, while sampling CPU/GPU.
```
ffmpeg:   { found, path, version }
encoders: { available: [...], tested: [ { name, ok, error, error_lines: [..], driver_required } ], chosen }
          Test in order h264_nvenc, h264_amf, h264_qsv, libx264 with a 1 s 1080p60 lavfi encode (20 s timeout);
          chosen = first ok. Presets: nvenc "-preset p4 -tune ll", amf "-quality speed", qsv "-preset veryfast",
          libx264 "-preset veryfast".
          error_lines = SRLT_ProbeErrorLines(stderr): up to 3 meaningful stderr lines, trimmed, in order, no
          duplicates, with the context pointer removed ("[h264_nvenc @ 0000021c8f2e1a40] X" → "[h264_nvenc] X").
          Preference: (1) lines from the encoder's own context ("[h264_nvenc @", "[h264_amf @", "[AMF @",
          "[h264_qsv @", "[hevc_… @") and lines matching
          "nvenc API version|minimum required Nvidia driver|runtime version|Cannot load|failed to open" (case-
          insensitive); (2) only if none, other lines matching "cannot|could not|error|failed|invalid" except
          "Error while opening encoder"; (3) only if still none, the "Error while opening encoder…" line.
          error = error_lines[0] (else "Exit code N" / "Timeout after 20s"). driver_required = number from
          "minimum required Nvidia driver for nvenc is (\S+)" (e.g. 570.0), else null.
          ffmpeg is BtbN n8.1 (built against nv-codec-headers sdk/13.0: NVENC needs NVIDIA driver 570.0+).
          BtbN's FFmpeg 9.x builds use NVENC API 13.1, which needs driver 610.00+ and gave a false NO-GO on
          NVIDIA PCs with older (but vMix/OBS-capable) drivers.
source:   { codec: "speedhq", pix_fmt: "yuv422p", width: 1920, height: 1080, fps: 60, seconds: 4, file_mb }
          Generate once in $env:TEMP: ffmpeg -f lavfi -i "testsrc2=s=1920x1080:r=60,noise=alls=12:allf=t"
          -t 4 -c:v speedhq -pix_fmt yuv422p <tmp>.mkv   (temporal noise ≈ high-motion esports content).
seconds:  run length
streams:  [ { role: "in-1"|"in-2"|"out-srt"|"out-youtube"|"out-twitch", kind: "decode"|"encode", codec,
              target_kbps, speed_min, speed_p50, fps_p50, ok, error } ]
          All 5 run concurrently: ffmpeg -hide_banner -nostats -re -stream_loop -1 -i src.mkv -t <Seconds>
          then decode: "-f null -"   encode: "-c:v <chosen> <preset> -b:v Kk -maxrate Kk -bufsize 2Kk -g 120 -f null -"
          each with "-progress <tmpfile>". Parse progress blocks (speed=1.00x, fps=); ignore the first 5 s;
          ok = speed_min >= thresholds.load_speed_min and exit code 0.
system:   { cpu_p50, cpu_p95, cpu_max, perf_start, perf_min, perf_p50, gpu_enc_p95, gpu_dec_p95, gpu_3d_p95,
            mem_used_pct_max, samples: [ { t, cpu, perf, gpu_enc, gpu_dec, gpu_3d, mem } ] }
          Sample once per second via CIM: cpu = ProcessorInformation(_Total).PercentProcessorUtility
          (fall back to PercentProcessorTime), perf = PercentProcessorPerformance, GPU = sum of
          UtilizationPercentage over GPUEngine instances whose Name contains engtype_VideoEncode /
          engtype_VideoDecode / engtype_3D (cap 100), mem = PerfOS_Memory PercentCommittedBytesInUse.
note:     "SpeedHQ is the codec inside full-bandwidth NDI; OMT's VMX is the same class but not identical.
           vMix/OBS compositing load is NOT included — treat results as a lower bound."
errors:   [ strings ]
```
Clean up temp files and kill all child ffmpeg processes on exit, including on Ctrl+C (try/finally).

### `Invoke-SRSenderTest -Config <obj> -BinDir <path> [-Seconds <int>] [-Log]`  (lib\LoadTest.ps1)
Observer PCs only. One 1080p60 SpeedHQ encode, the job an NDI sender does, run while the game/observer client is
running (the operator is told to start it first). Needs no NDI/OMT install.
```
ffmpeg:    { found, path, version }
codec:     "speedhq"   pix_fmt: "yuv422p"   width: 1920   height: 1080   fps: 60
seconds:   paced run length (config.observer.sender_seconds[mode]: quick 45, full 120)
source:    same 4 s noise clip as the load test (generated once in $env:TEMP, deleted afterwards)
max_speed: speed of a 10 s UNPACED encode of the clip (no -re), e.g. 1.99 = could encode 1.99 x real time; null on error
stream:    { speed_min, speed_p50, fps_p50, ok, error }
           ffmpeg -hide_banner -nostats -re -stream_loop -1 -i src.mkv -t <seconds> -c:v speedhq -pix_fmt yuv422p
           -f null - -progress <tmp>; same progress parsing as the load test (ignore the first 5 s);
           ok = exit code 0 and speed_min >= thresholds.load_speed_min.
system:    { cpu_p50, cpu_p95, cpu_max, perf_start, perf_min, perf_p50, gpu_3d_p95, mem_used_pct_max,
             samples: [ { t, cpu, perf, gpu_3d, mem } ] }   sampled once per second during the paced run (same CIM classes)
note:      "SpeedHQ is the codec full NDI uses. OMT's VMX codec has no ffmpeg encoder, so SpeedHQ stands in for both.
            ffmpeg's SpeedHQ encoder is less optimised than the NDI SDK's, so this errs on the safe side."
errors:    [ strings ]
```
ffmpeg's SpeedHQ encoder has no threading (`ffmpeg -h encoder=speedhq`: "Threading capabilities: none"), so this
measures one core. On the dev laptop (i5-1340P) n8.1 encodes the clip at 1.99 x unpaced on mains power, but only
1.08 x unpaced and 0.77 x paced on battery with the Balanced plan. CIM sampling costs about 1 s per sample here
(three WMI perf queries of ~300 ms each), so a 45 s run collects roughly 30-45 samples (31 on battery).

### `Invoke-SRLan -Config <obj> -BinDir <path> [-Mode quick|full] [-Log]`  (lib\Lan.ps1)
Are the incoming NDI/OMT feeds visible, and can the local network carry them? Reads `config.lan` (see config.json).

DNS-SD service types (RFC 6763):
- NDI `_ndi._tcp.local` (senders on TCP 5960+, NDI Discovery Server TCP 5959).
- OMT `_omt._tcp.local`. Source: libomtnet `PROTOCOL.md` ("Open Media Transport uses the service type _omt._tcp";
  instance names "HOSTNAME (Source Name)._omt._tcp.local") and `src/win32/OMTDiscoveryWin32.cs`
  (`new MDNSClient("_omt._tcp.local")`), https://github.com/openmediatransport/libomtnet. Senders listen on
  TCP 6400–6600 (`OMTConstants.cs`); OMT Discovery Server TCP 6399.

```
adapter:  { name, description, kind: "wired"|"wifi"|"other", chosen_because: "wired"|"default_route",
            ipv4, prefix_length, gateway, link_mbps, local_ips: [every IPv4 of this PC] }   or null if none usable
          Usable = Up, not virtual (same virtual regex as Hardware.ps1), has an IPv4 that is not 169.254.x.
          Wired first (highest link speed), else the default-route adapter. Never a virtual adapter.
mdns:     { query_ok (bool: at least one method ran without error), listen_ms,
            methods: [ { name: "unicast"|"windows", ok (bool), answers (int), error } ],
            responders: [ ip ... ]              every IP that answered any query
            service_types_seen: [ "_googlecast._tcp", ... ] }   from _services._dns-sd._udp.local
          unicast: one raw DNS query (PTR _ndi._tcp.local, _omt._tcp.local, _services._dns-sd._udp.local, QU bit set)
            sent from an ephemeral UDP socket bound to adapter.ipv4 to 224.0.0.251:5353 (multicast interface =
            adapter, TTL 255), re-sent every 1000 ms for listen_ms. A query from a port other than 5353 is answered
            by unicast to that port (RFC 6762 §6.7). Parse answer, authority and additional sections with name
            compression; follow PTR → SRV/TXT → A. If an instance arrives without SRV/A, send one SRV+A follow-up.
          windows: DnsServiceBrowse (dnsapi.dll, Windows 10 1809+) through Add-Type C#, same types, same window.
            Windows' own mDNS service does the listening, so this needs no listening socket of ours.
          NEVER bind UDP 5353 or any fixed listening port: a Windows Firewall prompt may appear, and a non-admin
          "Cancel" creates block rules (a system change).
sources:  [ { protocol: "NDI"|"OMT", name ("MACHINE (Source Name)"), machine, source, host (SRV target), port, ip,
              local (bool: ip in adapter.local_ips or machine = this computer's name), found_by: ["unicast"|"windows"] } ]
          De-duplicated on protocol + name, sorted by protocol then name.
discovery_servers: { ndi: [ "host[:port]" ], omt: [ "omt://host:port" ], ndi_config_path, omt_settings_path }
          NDI: ndi.networks.discovery (comma-separated) in ndi-config.v1.json, first found of %NDI_CONFIG_DIR%,
          %APPDATA%\NDI, %ProgramData%\NDI. OMT: <DiscoveryServer> in settings.xml from %OMT_STORAGE_PATH% or
          C:\ProgramData\OMT. Missing file → empty list, not an error.
sweep:    { cidr, scanned (int), alive (int), seconds, skipped_reason (string|null) }
          Skipped (reason set) when there is no adapter, config.lan.sweep is false, or adapter.kind is "other".
hosts:    [ { ip, mac ("aa-bb-cc-dd-ee-ff"|null), vendor (string|null),
              category: "network"|"pc"|"broadcast"|"mobile"|"other"|null, randomized_mac (bool),
              ping_ms (number|null), is_self, is_gateway, sources: [ source names on that ip ] } ]
          ICMP sweep of the adapter's subnet, capped at /24 (prefix < 24 → the /24 that contains adapter.ipv4):
          Ping.SendPingAsync in batches of 64, timeout config.lan.sweep_timeout_ms. Then Get-NetNeighbor
          -AddressFamily IPv4 -InterfaceIndex <adapter> (keep Reachable/Stale/Delay/Probe; drop Permanent,
          224–239.x, broadcast, all-zero and all-ff MACs). A host is alive if it answered ping OR is in the
          neighbour table. Proxy ARP: when 8 or more neighbour-table addresses share one MAC, the ones that did not
          answer ping (other than the gateway) are dropped and lan.errors gets one note naming the MAC and counts
          (a venue Wi-Fi seen on 2026-10-16 listed all 253 addresses under the access point's MAC).
          Vendor from an embedded OUI table (134 entries, each checked against the IEEE registry
          via macvendors.com on 2026-10-16: switch/router makers, PC/NIC makers, broadcast gear such as Blackmagic,
          AJA, Ross, Evertz, Audinate, Shure, Yamaha, Panasonic, Sony; NewTek/BirdDog/PTZOptics left out because
          their OUIs could not be confirmed). randomized_mac = locally administered bit set. Sorted by IP.
          The list includes this PC (is_self); sweep.alive counts the other hosts.
partners: [ { host, ip, port, origin: "config"|"cli"|"auto", loopback (bool), direction: "to_this_pc",
              tcp: { mbps, retransmits, seconds, error },
              udp: { target_mbps, mbps, packets, lost, loss_pct, jitter_ms, seconds, error },
              error } ]
          Hosts = config.lan.partner_hosts (origin config) + config.lan.cli_hosts (set by -LanHosts, origin cli)
          + if config.lan.auto_partners: every non-local source IP that accepts TCP on lan.partner_port within
          500 ms (origin auto). De-duplicated by IP. For each, two iperf3 runs from $BinDir\iperf3.exe:
            TCP: -c <ip> -p <port> -R -t <test_seconds> -b <target>M -J --connect-timeout 3000
            UDP: the same plus -u -l 1400   (the default datagram follows the path MTU: 64 KB on loopback, which
                 fragments and showed 11 % loss where 1400-byte datagrams showed 0.04 %)
          -R makes the source PC send to this PC, the direction the feeds travel. Read the receiver-side numbers
          (with -R the client is the receiver; checked against iperf3 3.22): TCP mbps from end.sum_received,
          retransmits from end.sum_sent (null if absent; the cygwin build reports none); UDP packets/lost/loss_pct/
          jitter_ms from end.sum and mbps from end.sum_received. Each run is killed
          after test_seconds + 15 s. "server is busy" → wait 2 s and retry once.
combined: { hosts: [ip ..], seconds, tcp: { mbps, per_host: [ { ip, mbps } ], error },
            udp: { target_mbps, mbps, packets, lost, loss_pct, jitter_ms, error }, error }   or null
          "Both at once": the prod NIC receives the sum of both feeds. Runs when config.lan.combined_test is not false
          and at least 2 partners were measured (tcp.mbps not null); hosts = those partners. TCP: all iperf3 -R
          clients started together (same arguments as the single test), wait for all; mbps = sum of their
          receiver mbps. Then UDP the same way. target_mbps = sum of the per-host targets; packets/lost summed,
          loss_pct = lost/packets × 100 (2 decimals), jitter_ms = the highest. error = set when any client failed
          (the numbers then cover the clients that worked; tcp.error / udp.error carry the first failure).
test:     { protocol: "NDI"|"OMT", per_feed_mbps, target_mbps (per_feed × lan.test_multiplier), seconds }
          per_feed_mbps uses the same lookup as lan_headroom (mbps_per_feed[protocol], NDI* → NDI).
errors:   [ strings ]
```

### `Get-SRVerdict -Config <obj> -Hardware <obj> -Network <obj> -LoadTest <obj> [-Lan <obj>]`  (lib\Rules.ps1)
Any of Hardware/Network/LoadTest/Lan may be `$null` (skipped) → their checks become SKIP.
```
overall:  "GO" | "CAUTION" | "NO-GO"      (any FAIL → NO-GO; else any WARN → CAUTION; else GO)
headline: one plain sentence naming the weakest link
weakest:  id of the first FAIL (else first WARN) by section order france, uplink, ingest, lan, hardware, load, software
checks:   [ { id, section, title, status: "PASS"|"WARN"|"FAIL"|"INFO"|"SKIP", value, limit, margin, detail, fix } ]
          value/limit are display strings ("273 ms", "≥ 2.0×"); margin = number where > 1 is good (or null)
settings: [ { id, label, value, why } ]
manual_checks: [ { id, text } ]
```
See RULES section below for every check.

### `Get-SRObserverVerdict -Config <obj> -Hardware <obj> -Sender <obj> [-Now <datetime>]`  (lib\ObserverRules.ps1)
Same output shape as Get-SRVerdict plus `role: "observer"`. Hardware or Sender may be `$null`. See OBSERVER RULES.

### Orchestrator `ShowReady.ps1 [-Mode quick|full] [-Skip network,hardware,lan,load] [-NoOpen] [-SrtHost <host>] [-LanHosts <ip>[,<ip>…]]`
Dot-sources lib\*.ps1, reads config.json (`-SrtHost` overrides show.srt_destination_host and is added as a
france target named "SRT destination"; `-LanHosts` (split on , ; space) is stored as config.lan.cli_hosts),
runs Hardware → Network → LAN → LoadTest (network before LAN so 400 Mbps of LAN iperf traffic can't skew the
France numbers; LAN before load so the load test can't skew the LAN numbers), each step timed and wrapped in
try/catch, prints coloured progress ([n/5]), then Get-SRVerdict with -Lan. `-Skip` accepts lan (also `local`,
`localnetwork`). After the LAN step one summary line, e.g.
`        2 OMT + 0 NDI source(s) | 14 device(s) on 192.168.0.0/24 | 192.168.0.21: 941 Mbps TCP, 0.00 % UDP loss`.
Writes results\<stamp>\results.json (tool_version 1.2.0):
`{ schema: "showready/1", meta: { tool_version, role: "prod", mode, started, finished, computer, duration_s, lan_hosts: [string] }, profile: config.show,
   hardware, network, lan, loadtest, verdict }`
and report.html = report-template.html with `/*__SHOWREADY_DATA__*/null` replaced by the JSON (escape `</` as `<\/`).
Console ends with the overall verdict, the settings sheet and the report path; opens the report unless -NoOpen.
`Run-ShowReady.cmd`: `@echo off` + `powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ShowReady.ps1" %*` + `pause`.

**Observer role** `ShowReady.ps1 -Role observer [-Mode quick|full] [-Skip hardware,sender] [-NoOpen] [-NoPrompt]
[-ServerMinutes <n>]` (`Run-Observer.cmd` = the Run-ShowReady.cmd line with `-Role observer`). -Role also accepts
`source`/`obs`; anything else is "prod". Steps [n/3]: Hardware → (prompt: "Start the game / observer client now,
as on show day, then press Enter"; skipped with -NoPrompt) → Sender test (Invoke-SRSenderTest) → Verdict
(Get-SRObserverVerdict). results.json:
`{ schema: "showready/1", meta: { tool_version, role: "observer", mode, started, finished, computer, duration_s,
   observer_ip (wired IPv4 the prod PC should use, else the default-route IPv4, else null), observer_ip_kind
   ("wired"|"wifi"|"other"|null) }, profile: config.show, hardware, sender, verdict }`, same report.html step.
Then the server phase (skipped when -ServerMinutes 0): print a firewall warning (allow iperf3 on Private
networks; Cancel blocks the test), start `$BinDir\iperf3.exe -s -p <config.observer.port> --forceflush` hidden
(working directory $env:TEMP, stdout to a temp file), print the observer IP in large block digits plus
"Now run the prod PC test: Run-ShowReady.cmd -LanHosts <ip>,<other observer's ip>", echo each "Accepted
connection from <ip>" as "Prod PC <ip> connected - testing", and wait until a key is pressed or ServerMinutes
(config.observer.server_minutes, default 30) pass; then stop iperf3. Never throws; if iperf3 cannot start, say so.

## RULES (Get-SRVerdict)

Let T = config.thresholds. "France targets" = network.targets where group = "france".
If show.srt_destination_host is set and measured, use THAT target alone for RTT/loss; else use all France targets.

**france**
- `fr_reach` — at least one France target answered ICMP or TCP. FAIL if none.
- `fr_rtt` — RTT_p95 = p95 of the chosen target (or the median of France targets' p95, using ICMP p95 where
  available else TCP p95). INFO; value "273 ms"; detail lists min/max across France networks and says
  "the SRT latency below is computed from this; re-run with -SrtHost <partner IP> for the exact path".
- `fr_rtt_spread` — p99 − p50 of the chosen ICMP samples (max over France targets). PASS < T.rtt_spread_ms.warn,
  WARN < fail, else FAIL.
- `fr_icmp_loss` — loss over France targets with icmp.blocked != true (pooled). PASS < warn, WARN < fail, else FAIL.
  Blocked hosts listed in detail as "ignores ping (not a fault)".
- `fr_udp_loss` — pooled UDP loss % at SRT bitrate (receiver side). PASS ≤ T.udp_loss_pct.warn, WARN ≤ fail,
  FAIL above. SKIP + WARN-level note if no UDP test succeeded ("UDP path not measured — ping only").
- `fr_udp_bursts` — total lossy_intervals. PASS if 0, WARN if ≥ 1 (detail: worst_interval_loss_pct).

**SRT settings** (always produced when fr_rtt has a value)
- rtt_calc = max(RTT_p95, 20). loss = pooled UDP loss % if measured, else pooled ICMP loss %, else 1.
- row = first table row with loss ≤ max_loss_pct (last row if above all). mult_table = row.multiplier.
- mult = mult_table, raised to T.srt_min_multiplier_when_unmeasured_or_bursty when UDP was not measured OR
  any lossy interval was seen. Also always raise to at least 4 when rtt_calc > 150 (long-haul path; ICMP/UDP
  probes are too short to see rare bursts).
- latency_table_ms = round_up(mult_table × rtt_calc, 50); latency_ms = round_up(mult × rtt_calc, 50), capped at max.
- overhead_pct = max(row.overhead_pct, ceil(100 / mult)).
- settings: `srt_latency` value "1,100 ms" why "≈4 × p95 RTT 273 ms (table minimum 850 ms for <1% loss). SRT
  needs several round trips to resend lost packets; the 120–125 ms encoder default will drop video on this path.";
  `srt_overhead` "25 %"; `srt_bitrate` "10 Mbps video CBR, keyframe 2 s"; `srt_mode` "caller, packet size 1316,
  same latency on both ends (receiver latency wins if higher)".

**uplink**
- need_mbps = Σ outputs (video_kbps + audio_kbps)/1000, with the SRT output × (1 + overhead_pct/100).
- `uplink_capacity` — ratio = upload.mbps / need_mbps. PASS ≥ T.uplink_ratio.pass, WARN ≥ warn, FAIL below.
  value "312 Mbps", limit "≥ 2.0 × 35.6 Mbps". SKIP if upload not measured.
- `uplink_wifi` — default-route NIC kind: wired PASS, wifi FAIL ("stream over wired Ethernet").

**ingest**
- `ingest_youtube` / `ingest_twitch` — best TCP p95 among targets with that service. PASS if ok>0 and p95 ≤
  T.ingest_tcp_p95_ms.warn, WARN if slower, FAIL if unreachable. Twitch detail always adds: "Reachability only —
  Twitch closed its Korean business in Feb 2024; do a 30-second test stream with the real key from this venue."
- setting `ingest_servers`: "YouTube: rtmp://a.rtmp.youtube.com/live2 (auto-nearest) · Twitch: <best Twitch host>".

**lan** (2 incoming feeds)
- intake_mbps = inputs.count × mbps_per_feed[inputs.protocol].
- `lan_wired` — at least one non-virtual wired NIC with status Up: PASS; none → FAIL ("Wi-Fi cannot carry
  2× 1080p60 OMT/NDI reliably").
- `lan_headroom` — best wired link_mbps / intake_mbps (if the same NIC is the default route, add need_mbps).
  PASS ≥ T.lan_ratio.pass, WARN ≥ warn, FAIL below / no wired.
- `lan_virtual_adapters` — any virtual NIC Up → WARN ("NDI/OMT discovery may bind to <names>; disable them for the show
  or pin the adapter in NDI Access Manager / vMix"); none → PASS.
- `lan_profile` — a wired Up NIC with network_category Public → WARN ("set to Private so Windows Firewall allows
  NDI/OMT discovery"); else PASS.
- `lan_eee` — Energy-Efficient Ethernet "on" on a wired Up NIC → WARN (causes micro-drops); off PASS; unknown INFO.
- setting `input_protocol`: if lan_headroom PASS "OMT (Medium) or full NDI"; WARN → "NDI HX3 or OMT Low";
  FAIL → "fix the network first".

**lan — LAN step** (from `-Lan`; the three ids go into SRV_Meta right after `lan_eee`, section `lan`).
The strings below are the exact user-facing copy (pure ASCII: "x", ">=", "-"). `<…>` = substituted value.
P = "OMT" if inputs.protocol starts with OMT, else "NDI"; Q = the other one; p = lower-case P.
expected = inputs.count. per_feed = the lan_headroom lookup. List items are "<name> (<ip>:<port>)", joined with
SRV_JoinNames (max 6). "Counted" sources = protocol P and local != true.

- `lan_sources_found` — title "Incoming feeds found on the network". First matching case wins:
  1. Lan null → SKIP, detail "The local network step was not run."; add "local network" to not_tested.
  2. mdns.query_ok != true → SKIP, detail "Could not query the network for NDI/OMT sources: <first method error,
     else first lan error>."; add "NDI/OMT discovery" to not_tested.
  3. counted >= expected → PASS, value "<n> <P> sources", limit ">= <expected> <P> sources", margin n/expected,
     detail "Found: <list>." + EXTRAS.
  4. 1 <= counted < expected → WARN, value "<n> <P> source(s)", same limit, margin n/expected,
     detail "Found only: <list>. The show needs <expected> incoming <P> feeds." + EXTRAS,
     fix "Start the missing sender(s) on the source PCs and make sure they are on the same switch and subnet as
     this PC (<sweep.cidr, else adapter.ipv4/prefix_length>). A source on another subnet or VLAN is not found by
     mDNS; add it by IP in vMix/OBS."
  5. counted = 0 and m non-local Q sources > 0 → WARN, value "0 <P>, <m> <Q>", same limit, margin 0,
     detail "No <P> sources answered, but <m> <Q> source(s) did: <Q list>. config.json expects <P>.",
     fix "Switch the senders to <P>, or set show.inputs.protocol to \"<Q>\" in config.json if the show runs on <Q>."
  6. counted = 0 and discovery_servers.<p> is not empty → WARN, value "0 <P> sources (mDNS)", same limit, margin 0,
     detail "No <P> sources answered mDNS. This PC is set to use a <P> Discovery Server (<servers joined ", ">);
     senders registered there do not answer mDNS.",
     fix "Confirm both feeds in vMix/OBS (they use the Discovery Server) and check that the Discovery Server is
     running and reachable."
  7. otherwise → FAIL, value "0 <P> sources", same limit, margin 0,
     detail "No <P> source answered an mDNS query (_<p>._tcp.local) on <adapter.name> within <listen_ms/1000> s."
     + (" <k> other device(s) answered mDNS, so discovery itself works." when k = responders not in
     adapter.local_ips > 0, else " No device answered mDNS at all: the switch or Wi-Fi may block multicast, or
     Windows Firewall blocks it on a Public network."),
     fix "Start <P> output on both source PCs, connect them to the same switch and subnet as this PC, and set every
     PC's network profile to Private. Sources registered only with an NDI Discovery Server (TCP 5959) or OMT
     Discovery Server (TCP 6399) do not show up here."
  EXTRAS = (" Also on the network: <m> <Q> source(s)." if m > 0) + (" On this PC (not counted): <names>." if any
  local sources of either protocol).
  **Not required yet** (config.lan.require_sources is not true; the default is false because the observer PCs
  have no NDI/OMT installed yet): this check never WARNs or FAILs and never blocks GO.
  - case 2: still SKIP with the same detail, but "NDI/OMT discovery" is NOT added to not_tested.
  - cases 4, 5, 6: status INFO, margin null, fix "", same value; detail = the case's detail + EXTRAS +
    " This check does not count yet (lan.require_sources is false in config.json)."
  - case 7: status INFO, value "0 <P> sources", same limit, margin null, fix "", detail
    "No <P> senders yet, which is expected until NDI/OMT is installed on the source PCs." + the same responder
    sentence as case 7 (" <k> other device(s) answered mDNS, so discovery itself works." or " No device answered
    mDNS at all: ...") + " Once the senders are installed, run this again; set lan.require_sources to true in
    config.json to make this check count."
  - case 3 stays PASS. With require_sources true, cases 2–7 behave exactly as listed above.

- `lan_partner_throughput` — title "Network throughput from source PCs". need = per_feed × T.lan_partner_ratio.pass.
  Per partner: tcp = tcp.mbps, loss = udp.loss_pct, ratio = tcp / per_feed. A partner is "unmeasured" if
  partner.error is set or tcp is null. Measured partner grade: PASS if ratio >= T.lan_partner_ratio.pass and
  loss is not null and loss < T.lan_partner_udp_loss_pct.pass; else WARN if ratio >= T.lan_partner_ratio.warn and
  (loss is null or loss < T.lan_partner_udp_loss_pct.warn); else FAIL.
  1. Lan null → SKIP, detail "The local network step was not run."
  2. no partners → SKIP (NOT added to not_tested: the test is optional), detail "Optional test, not run. To measure
     the source PCs: run Run-Observer.cmd on each, then run here: Run-ShowReady.cmd -LanHosts <IP 1>,<IP 2>."
  3. all partners unmeasured → WARN, value "not measured", limit LIMIT, margin null,
     detail "Could not test <host>: <error>." per partner (joined with " "),
     fix "Make sure Run-Observer.cmd (or Run-LanPartner.cmd) is still waiting on <hosts joined ", "> and that Windows Firewall on that PC
     allowed iperf3 on Private networks, then run again."
  4. else status = worst measured grade (FAIL > WARN > PASS); if any partner is unmeasured, at least WARN.
     value from the worst measured partner: "<tcp, SRV_Mbps> Mbps TCP, <loss, 2 decimals> % UDP loss"
     (or "<tcp> Mbps TCP, UDP not measured"), limit LIMIT, margin = min over measured of SRV_Margin(ratio, pass),
     detail "Per feed <per_feed> Mbps (<P>), tested at <test.target_mbps> Mbps for <test.seconds> s, source PC to
     this PC." then per partner " <host>: TCP <tcp> Mbps, <retransmits> retransmits; UDP <udp.mbps> Mbps received,
     <loss> % loss, jitter <jitter_ms, 2 decimals> ms." (", <retransmits> retransmits" and ", jitter .. ms" are left
     out when null; the cygwin iperf3 build reports no retransmits) (+ " (loopback: measures this PC only, not the network)"
     when loopback; unmeasured partners as " Could not test <host>: <error>."),
     fix for WARN/FAIL "Check the cable, switch port and link speed between this PC and <worst host>; avoid
     chained or unmanaged desktop switches; turn off Energy-Efficient Ethernet on both PCs. If it stays low, use
     NDI HX3 / OMT Low for that feed." When the worst partner is loopback the fix is instead "That was a loopback test (this
     PC to itself): it measures this PC, not the network. Run Run-Observer.cmd on each source PC, then run here:
     Run-ShowReady.cmd -LanHosts <IP 1>,<IP 2>."
  LIMIT = ">= <need, SRV_Mbps> Mbps, < <T.lan_partner_udp_loss_pct.pass> % UDP loss".
  **Both at once** (C = lan.combined; ignored when missing or null). n = count of C.hosts; cper = n × per_feed;
  cratio = C.tcp.mbps / cper; closs = C.udp.loss_pct. C is "measured" when C.tcp.mbps is not null; its grade uses
  the partner formula with cratio and closs. C is "unmeasured" when it is not null and C.tcp.mbps is null.
  - status = worst of the measured partner grades and C's grade; an unmeasured C (like an unmeasured partner)
    makes it at least WARN. Case 3 ("all unmeasured") only applies when no partner was measured.
  - margin = min of the partner margins and SRV_Margin(cratio, pass).
  - detail: after the per-partner parts append " Both at once (<n> source PCs): TCP <C.tcp.mbps, SRV_Mbps> Mbps,
    UDP <C.udp.mbps, SRV_Mbps> Mbps received, <closs, 2 decimals> % loss; needs >= <cper × pass, SRV_Mbps> Mbps
    together." (", UDP not measured" instead of the UDP part when closs is null); unmeasured C:
    " Could not test both at once: <C.error, else C.tcp.error>."
  - value and fix: when C's grade is strictly worse than every measured partner's grade, value = "<C.tcp.mbps,
    SRV_Mbps> Mbps TCP together, <closs, 2 decimals> % UDP loss" (or ", UDP not measured") and fix = "Each source
    PC passes on its own but not together, so the link into this PC (or the switch uplink) is the bottleneck. Use
    a 2.5 GbE link to this PC, or lighter feeds (NDI HX3 / OMT Low)."; otherwise value/fix as in case 4.

- `lan_hosts` — title "Devices on the local network". Never affects the verdict.
  1. Lan null → SKIP, detail "The local network step was not run."
  2. sweep missing or sweep.skipped_reason set → SKIP, detail "Not scanned: <skipped_reason>."
  3. else INFO, value "<sweep.alive> devices on <sweep.cidr>", limit "", margin null, detail = these parts, each
     only when non-empty, joined with " ":
     "Gateway: <ip> (<vendor or "unknown vendor">)."
     "Network gear: <vendor (ip) list>."              category network, excluding the gateway
     "PCs: <count> (<distinct vendors joined ", ">)."   category pc, not counting is_self
     "Broadcast gear: <vendor (ip) list>."            category broadcast
     "Source PCs: <ip (n source(s)) list>."           hosts with sources
     "Unknown vendor: <n> (<r> with a private/randomised MAC)."   vendor null, not counting is_self
     "Scanned the <adapter.kind> adapter <adapter.name> because no wired adapter is up; on show day run this on
     the production network."                       when adapter.kind != "wired"
     "Managed switches only appear if they have a management IP on this subnet."   always last

**hardware**
- `hw_cpu_threads` — threads ≥ T.threads.pass PASS, ≥ warn WARN, else FAIL. detail names the CPU; if name matches
  `\d{4,5}(U|P|Y)\b` or "Celeron|Pentium|Atom" add "low-power laptop CPU".
- `hw_ram` — ≥ pass PASS, ≥ warn WARN, else FAIL.
- `hw_gpu` — any non-integrated NVIDIA → PASS; non-integrated AMD → PASS; integrated only → WARN for OBS, but
  value says "no dedicated GPU — vMix at 1080p60 with 3 encodes is not supported on integrated graphics"
  → FAIL if software.vmix is set or vMix not detected and OBS not detected; WARN if only OBS detected.
- `hw_nvenc_sessions` — NVIDIA only: nvidia_driver ≥ 551.76 PASS (8 sessions); ≥ 531.41 PASS (5); else WARN
  ("3-session limit: exactly enough for 3 outputs, no recording"). Non-NVIDIA → INFO.
- `hw_power` — on_battery true → FAIL; plan high_performance/ultimate PASS; balanced WARN; power_saver FAIL.
- `hw_gpu_driver_age` — newest dedicated GPU driver older than T days → WARN; else PASS.
- `hw_disk` — system free < T.disk_free_gb.warn → WARN.
- `hw_pending_reboot` — true → WARN ("reboot before the show, not during it").
- setting `power_plan`: "High performance (or Ultimate), on mains power, sleep off".

**load** (SKIP all if LoadTest null or ffmpeg missing)
Definitions: dedicated = hardware GPUs where SRV_IsDedicated; nvGpus / amdGpus = dedicated with vendor NVIDIA / AMD.
For a tested encoder E: lines(E) = E.error_lines, or @(E.error) when error_lines is missing or empty.
nvT = the tested entry named h264_nvenc. nvDriverIssue = nvT exists, nvT.ok != true, and (nvT.driver_required is
not null or any line of nvT matches "(?i)nvenc API version|minimum required Nvidia driver").
installed = highest SRV_NvDriver over nvGpus (null if none). fellBack = (chosen matches x264 or chosen is empty)
and (nvGpus + amdGpus) is not empty. FAILED = "<name> (<first line>)" for each tested encoder with ok != true,
joined with ", " (just "<name>" when it has no line).
- `load_encoder` — first matching case:
  a. chosen matches nvenc|amf|qsv → PASS, value chosen, limit "hardware encoder", detail "The test encoded with
     <chosen>." + (" Encoders that did not work: <FAILED>." when any) + (" An NVIDIA GPU is present but NVENC
     failed: <first line of nvT>." when nvGpus not empty and chosen is not nvenc).
  b. nvGpus not empty and nvDriverIssue → WARN, value "NVIDIA driver <installed, SRV_F 2> is older than
     <driver_required, SRV_T> needed by this test" ("unknown" for a null installed; when driver_required is null:
     "NVIDIA driver <installed> is too old for this test's NVENC"), limit "hardware encoder", margin null,
     detail "h264_nvenc failed: <lines(nvT) joined " / ">. The test fell back to <chosen, else "no encoder">, so
     the load figures are not representative.", fix "vMix/OBS can usually still use NVENC on this driver. To run
     this test, update to the current NVIDIA Studio driver, or check NVENC in vMix/OBS by hand."
  c. nvGpus or amdGpus not empty (any other hardware-encoder failure on a dedicated-GPU PC) → WARN, value
     "<NVIDIA|AMD> GPU encoder failed in this test" (NVIDIA when nvGpus not empty), limit "hardware encoder",
     margin null, detail "<h264_nvenc|h264_amf> failed: <its lines joined " / ", else "no error text">. The test fell
     back to <chosen, else "no encoder">, so the load figures are not representative.", fix "Update or reinstall the
     <vendor> GPU driver and run again. Meanwhile check in vMix/OBS that the GPU encoder (NVENC/AMF) works."
  d. chosen matches x264 → FAIL, value "software only (libx264)", limit "hardware encoder", margin 0, detail
     "3 software 1080p60 encodes on the CPU will not hold." + (" Encoders that did not work: <FAILED>." when any),
     fix "Use a PC with an NVIDIA (NVENC) or AMD (AMF) GPU, or install the GPU driver."
  e. otherwise → FAIL, value "no working H.264 encoder", margin 0, detail "No H.264 encoder passed the 1-second
     test." + (" Encoders that did not work: <FAILED>." when any), fix "Install or repair the GPU driver, then run
     ShowReady again."
- When fellBack: `load_realtime`, `load_cpu`, `load_gpu_encode`, `load_throttle` are all SKIP with detail
  "Not representative: the test fell back to CPU encoding, but vMix/OBS would use the GPU." and
  "load test (fell back to CPU encoding)" is added to not_tested, so the kit's own limitation can make the result
  CAUTION at worst, never NO-GO. Without fellBack they behave as below.
- `load_realtime` — all 5 streams ok → PASS; any decode/encode below speed threshold → FAIL (name them).
- `load_cpu` — cpu_p95 < warn PASS, < fail WARN, else FAIL; detail "vMix/OBS compositing not included".
- `load_gpu_encode` — gpu_enc_p95 thresholds as above (INFO if null).
- `load_throttle` — (perf_start − perf_min)/perf_start × 100 > T.load_perf_drop_pct.warn → WARN.
- setting `encoder`: e.g. "NVENC H.264 (h264_nvenc), preset P4, CBR, keyframe 2 s — same for all three outputs".
  When fellBack, use the GPU-vendor text (as when the load test did not run) with why "Based on the <vendor> GPU;
  the load test could not confirm it."

**software**
- `sw_mixer` — vMix or OBS detected → PASS (value lists versions); neither → WARN.
- `sw_ndi` — inputs.protocol starts with NDI and OBS without distroav / no NDI runtime → WARN; else INFO.
- `sw_background` — any watchlist process other than vMix/OBS/NDI/OMT running → WARN ("close: …").

**manual_checks** (always):
1. "Confirm the French partner's receive latency matches the SRT latency above (the higher of the two ends wins)."
2. "Twitch from Korea: do a 30-second test stream with the real stream key from this venue before show day."
3. "Re-run ShowReady at the same time of day as the show (evening congestion differs from daytime)."
4. "Run a 30-minute rehearsal with the real vMix/OBS scene and both real feeds; watch vMix/OBS dropped frames."
5. "When the partner sends their SRT IP, run: Run-ShowReady.cmd -SrtHost <their IP>."

## OBSERVER RULES (Get-SRObserverVerdict, lib\ObserverRules.ps1)
An observer (source) PC sends one 1080p60 feed while running the game/observer client. No France, uplink,
ingest, LAN-step or load checks. Pure ASCII copy as below; the file defines only functions (prefix SRO_ for
helpers) and assumes lib\Rules.ps1 is already dot-sourced (it calls Get-SRVerdict and the SRV_* helpers).

1. base = Get-SRVerdict -Config $Config -Hardware $Hardware -Network $null -LoadTest $null -Lan $null -Now $Now.
2. Keep these checks from base.checks, unchanged except where noted: `lan_wired`, `lan_virtual_adapters`,
   `lan_profile`, `lan_eee`, `hw_power`, `hw_pending_reboot`, `sw_background`.
   - `sw_background`: recomputed from Hardware.processes.running exactly as Rules.ps1 does, but Steam and
     EpicGamesLauncher are also left out (the game may need its launcher); PASS detail "No known background apps
     (OneDrive, Teams, Discord, browsers) are running. Game launchers are expected on an observer PC."; no process
     list → base check unchanged.
   - `lan_wired` FAIL: detail "No wired network adapter is connected. Wi-Fi cannot carry a 1080p60 OMT/NDI feed
     reliably." + the base detail's " Adapters up: ..." sentence when present; fix "Connect this PC to the
     production switch with an Ethernet cable (1 GbE or faster)."
3. Add (section in brackets):
   - `obs_link` [lan] "Wired link speed": best link_mbps over wired NICs with status Up.
     PASS when >= T.observer_link_mbps.pass (1000): value "<n> Mbps", limit ">= 1000 Mbps", margin n/1000,
     detail "<nic name> links at <n> Mbps.";
     FAIL below: value "<n> Mbps", same limit, margin n/1000, detail "<nic name> links at only <n> Mbps.",
     fix "Use a Cat5e/Cat6 cable and a gigabit switch port; a link below 1 Gbps usually means a bad cable or an
     old switch.";
     no wired NIC up → SKIP "No wired adapter is up."; link speed unknown → INFO value "unknown";
     Hardware null → SKIP "Hardware scan was not run.".
   - `sender_realtime` [sender] "Sender encode in real time": S = Sender.
     S null → SKIP "The sender test was not run." (+ not_tested "sender test");
     S.ffmpeg.found false → SKIP "ffmpeg was not found in the bin folder, so the sender test could not run."
     (+ not_tested "sender test (ffmpeg missing)");
     S.stream.speed_min null → SKIP "The sender test returned no speed: <S.stream.error, else first S.errors>."
     (+ not_tested "sender test");
     speed_min >= T.load_speed_min → PASS, value "<speed_min, 2 decimals> x", limit ">= <T.load_speed_min, 2
     decimals> x", margin SRV_Margin(speed_min, T.load_speed_min), detail "One 1080p60 SpeedHQ encode kept up
     with real time (slowest <speed_min> x)." + (" Unpaced it ran at <max_speed, 2 decimals> x real time." when
     max_speed is not null);
     else WARN (not FAIL: ffmpeg's SpeedHQ encoder is single-threaded, `ffmpeg -h encoder=speedhq` says
     "Threading capabilities: none", while the NDI/OMT sender spreads its encode over several cores, so falling
     behind here does not prove the real sender will), same value/limit/margin, detail "One 1080p60 SpeedHQ encode
     fell behind real time (slowest <speed_min> x)." + the same max_speed sentence + " ffmpeg's SpeedHQ encoder
     uses one CPU core; the NDI/OMT sender spreads the work over several, so the real sender may still keep up.",
     fix "Close other programs and lower the game's graphics load, then re-run. If it still falls behind, check
     the real NDI/OMT sender on this PC for dropped frames before show day." A starved CPU still gives NO-GO
     through `sender_cpu`.
   - `sender_cpu` [sender] "CPU load during sender test": S.system.cpu_p95 graded with SRV_GradeLow and
     T.sender_cpu_p95 (warn 70, fail 90): value "<p95, 0 decimals> %", limit "< <warn> %", margin
     SRV_Margin(warn, p95), detail "CPU p95 while the game/observer client and one 1080p60 SpeedHQ encode ran
     together." + (" Peak <cpu_max> %." when not null), fix for WARN/FAIL "Little CPU headroom left for the
     sender: close background programs, cap the game's frame rate, or use a stronger CPU.";
     null p95 → SKIP "CPU load was not sampled."; S null → SKIP "The sender test was not run.".
   - `sender_throttle` [sender] "CPU clock throttling": same formula, thresholds and copy as `load_throttle`
     (perf_start/perf_min from S.system); S null → SKIP "The sender test was not run.".
4. Order of checks: lan_wired, obs_link, lan_virtual_adapters, lan_profile, lan_eee, hw_power,
   hw_pending_reboot, sw_background, sender_realtime, sender_cpu, sender_throttle.
5. not_tested: "hardware scan" when Hardware is null, plus the sender entries above. overall / weakest /
   headline / partial: exactly Get-SRVerdict's assemble rules over these checks (FAIL → NO-GO, else WARN →
   CAUTION, else GO; never GO with not_tested; "Nothing was tested - run ShowReady without -Skip so there is
   something to judge." when Hardware and Sender are both null).
6. settings: only base's `power_plan` setting (when present).
7. manual_checks:
   1. id mc_obs_wait "Leave Run-Observer.cmd waiting until the prod PC has finished its LAN test (Run-ShowReady.cmd -LanHosts <this PC's IP>,<other observer's IP>)."
   2. id mc_obs_sender "Before show day, install the NDI/OMT sender (or turn on NDI/OMT output in the observer client) and check that the feed arrives in vMix/OBS on the prod PC."
   3. id mc_obs_rehearsal "Run a 30-minute rehearsal with the game/observer client and the real NDI/OMT output; watch for dropped frames on the prod PC."
8. Output: { role: "observer", overall, headline, weakest, partial, not_tested, checks, settings, manual_checks,
   calc: {}, errors } — errors = base.errors + this function's own. Never throws (wrap each check in try/catch
   like Rules.ps1).
Thresholds (config.json): sender_cpu_p95 { warn: 70, fail: 90 }, observer_link_mbps { pass: 1000 }.

## Fixtures
Each collector author runs their function on the dev laptop and saves the real output to
`fixtures\<hardware|network|lan|loadtest>.json` (ConvertTo-Json -Depth 12). Rules and the report are built
against these fixtures. The dev laptop is a known-bad machine (Wi-Fi only, integrated GPU, 14 GB RAM):
its expected overall verdict is NO-GO. Its fixtures\lan.json comes from a run with a loopback partner
(`bin\iperf3.exe -s -B 127.0.0.1 -p 5201` on the same laptop, bound to loopback so Windows Firewall does not
prompt, then `-LanHosts 127.0.0.1`); it is on a Public Wi-Fi where no device
answers mDNS, so it has no sources. tests\fixtures\*_lan.json are synthetic cases for the rules.
tests\fixtures\sender_{ok,slow,nodata}.json and observer_hw_wired.json are synthetic cases for the observer
rules; nvold_{hardware,loadtest}.json (NVIDIA driver 560.94 with the real ffmpeg "driver too old" lines),
amdfail_loadtest.json and combined_lan.json cover the encoder fallback and the both-at-once test.
