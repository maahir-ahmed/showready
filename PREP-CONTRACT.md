# ShowReady Prep + Upload: build contract

Two additions to the ShowReady kit (see CONTRACT.md for the existing diagnosis kit):

1. **Prep**: a separate script, run *as administrator* on each show PC before testing. It
   updates drivers, switches the Windows display language to English, disables startup apps,
   closes background apps, warns about low disk space, sets the power plan and applies the
   other fixes the diagnosis flags.
2. **Upload**: every script (diagnosis, observer, LAN partner, prep) uploads its results
   folder to a public GitHub repo so they can be analysed remotely.

## Hard constraints (all files)

- Windows PowerShell 5.1 compatible: no ternary, no `??`, no `-Parallel`, no `ForEach-Object -Parallel`, no
  PS7-only cmdlets or parameters. `[math]::Max/Min` with mixed types: cast both to `[double]`.
- Pure ASCII source files (no smart quotes or dashes).
- Locale-independent: PCs may run Korean Windows. Never parse localized command output except
  GUIDs, numbers and IPs via regex. Prefer CIM, registry and cmdlets with object output. Power
  plans are identified by GUID.
- Never throw to the caller. Every item is wrapped in try/catch; a failure becomes an item with
  status `ERROR` or `FAILED` and a readable `detail`.
- Launch external binaries with `-WorkingDirectory $env:TEMP`.
- Logging goes through a `-Log` scriptblock parameter: `& $Log "message"` (may be `$null`; guard it).
- **Testing rule for whoever builds this: never run any Apply/Undo function, and never run any
  command that changes system state (Set-*, Disable-*, Enable-*, Stop-Process, powercfg /set*,
  /change, /duplicatescheme, Install-Language, reg add, Restart-Computer, Windows Update
  install/download) on the build machine.** Test plan (read-only) functions and use `-DryRun`,
  which prints the exact command each action would run without running it.

## Folder layout (new files only)

```
ShowReady\
  Run-Prep.cmd            launcher: elevates (UAC) and runs Prep.ps1 %*
  Undo-Prep.cmd           launcher: elevates and runs Prep.ps1 -Undo latest
  Upload-Results.cmd      uploads every results folder not yet uploaded
  Setup-Upload.cmd        asks for the upload token once and writes upload.json
  Prep.ps1                prep orchestrator
  prep-config.json        prep settings (thresholds, keep/close lists)
  lib\Prep.System.ps1     language, drivers, disk, Windows Update pause, pending reboot
  lib\Prep.Tune.ps1       power, startup apps, background apps, network adapter, capture, notifications
  lib\Upload.ps1          GitHub upload
```

Results of a prep run: `results\<yyyyMMdd-HHmmss>-prep\prep.json`, `prep.log`, `backup\*.json`
(undo data). Same `results\` folder as the diagnosis runs.

## Prep item schema

Every plan/apply function returns an array of items (PSCustomObject):

| field | type | meaning |
|---|---|---|
| id | string | e.g. `sys_edition`, `sys_language`, `tune_startup:Steam` (sub-items use `id:name`) |
| section | string | `language`, `drivers`, `disk`, `updates`, `reboot`, `power`, `startup`, `background`, `network`, `capture`, `notifications` |
| title | string | short, plain English, for the operator |
| status | string | plan: `OK` (nothing to do), `CHANGE` (will change if applied), `MANUAL` (operator must act; see detail), `INFO`, `ERROR`; after apply: `DONE`, `FAILED`, `SKIPPED` |
| current | string | what it is now |
| target | string | what it will be |
| detail | string | one or two plain sentences; for MANUAL, exactly what to do |
| risk | string | `low` or `medium` (medium = asks separately, default No) |
| needs_reboot | bool | |
| needs_admin | bool | |
| default_apply | bool | true if applied by "apply recommended" |
| commands | string[] | human-readable exact commands the apply step will run (shown by `-DryRun`) |
| undo | object or $null | data needed to restore (written to the backup file on apply) |

### Windows edition switch (`sys_edition`)

- Planned only on Windows Home Single Language (`EditionID = CoreSingleLanguage`), in section `language` before `sys_language`.
- Target: `Windows Home (NOT activated) - allows English` (or Pro) via Microsoft public generic key.
- Risk: `medium`, `default_apply = $false` (`-Yes` never applies it), `needs_reboot = $true`, `needs_admin = $true`.
- **HOME confirmation**: requires typing `HOME` (or `PRO` for Pro target) to confirm; Enter skips.
- **Run-last rule**: `changepk.exe` may restart the PC; `sys_edition` is removed from phase 1 and runs last after all other changes, report writing, results upload, and summary, in place of the normal restart prompt.
- **No undo**: cannot be undone automatically; returning to activated Windows requires buying a licence or reinstalling factory Windows. `Undo-SRPrepSystem` outputs a `MANUAL` item.


## Function signatures

```powershell
# lib\Prep.System.ps1
Get-SRPrepSystemPlan   -Settings <obj> -Role <prod|observer> -Log <sb>        # read-only, works without admin
Invoke-SRPrepSystemApply -Items <obj[]> -Settings <obj> -BackupDir <path> -DryRun:<bool> -Log <sb>
Invoke-SRPrepEditionSwitch -Item <obj> -BackupDir <path> -DryRun:<bool> -Log <sb>
Undo-SRPrepSystem      -BackupDir <path> -DryRun:<bool> -Log <sb>

# lib\Prep.Tune.ps1
Get-SRPrepTunePlan     -Settings <obj> -Role <prod|observer> -Log <sb>        # read-only, works without admin
Invoke-SRPrepTuneApply -Items <obj[]> -Settings <obj> -BackupDir <path> -DryRun:<bool> -Log <sb>
Undo-SRPrepTune        -BackupDir <path> -DryRun:<bool> -Log <sb>

# lib\Upload.ps1
Send-SRResults -RunDir <path> -Kind <showready|observer|lanpartner|prep> -Root <kit root> -Log <sb>
    # returns [pscustomobject]@{ ok; url; files; error }   never throws
Send-SRPendingResults -Root <kit root> -Log <sb>   # uploads every results\* folder without .uploaded
```

Apply functions apply only items whose `status` is `CHANGE`, as passed in (the orchestrator
filters by the operator's choices). Each applied item returns with status `DONE` or `FAILED`.
Before changing anything, apply writes the item's undo data to `BackupDir\system-undo.json` or
`BackupDir\tune-undo.json` (append/merge; write before the change so a crash still leaves undo data).

`$Settings` is `prep-config.json` parsed with ConvertFrom-Json.

## Orchestrator (Prep.ps1)

```
Prep.ps1 [-Role prod|observer] [-Yes] [-PlanOnly] [-DryRun] [-Only <sections>] [-Skip <sections>] [-Undo <latest|folder>] [-NoUpload]
```
- `-Only/-Skip` may arrive as one comma-joined string (cmd `%*` passes `a,b` as one string): split on commas.
- If not elevated: relaunch itself elevated with `Start-Process powershell -Verb RunAs` and the same
  arguments, then exit. If elevation is refused, continue in plan-only mode and say so.
- If `-Role` is missing, ask: "Is this the PROD PC (vMix/OBS) or an OBSERVER PC? [P/O]".
- Build both plans, print them grouped by section (status colour, title, current -> target).
- Unless `-Yes` or `-PlanOnly`: ask per section "Apply the N recommended changes in <section>? [Y/n]".
  Items with risk `medium` are asked one by one with default No. MANUAL items are listed at the end
  as a checklist.
- Order of apply: language, drivers (both slow; say so), then the tune sections, then
  `updates` (Windows Update pause) last, so driver updates happen first. `sys_edition` is
  excluded from phase 1 and runs last after all other items, upload, and summary.
- Write `results\<stamp>-prep\prep.json` (meta + all items before/after), `prep.log`, `backup\`.
- Upload the folder with `Send-SRResults -Kind prep` unless `-NoUpload` (if lib\Upload.ps1 exists).
- End with a summary: changed / failed / manual counts, "Reboot needed" if any item needs it.
  If `sys_edition` was selected, run `Invoke-SRPrepEditionSwitch` here (after upload; do not upload again).
  Then ask "Restart now? [y/N]". Never restart without a yes.
- `-Undo latest` restores from the newest `results\*-prep\backup` (both Undo functions). If the backup
  contains `sys_edition`, a MANUAL item is added since the edition switch cannot be undone automatically.

## Elevation and the per-user gotcha

- `Prep.ps1 -NoElevate` skips the self-elevation (for tests and for plan-only runs).
- When a standard user elevates with a *different* administrator's password, HKCU and per-user
  settings (display language, HKCU Run keys, notifications, Game DVR) belong to the admin account,
  not the person signed in. Detect it by comparing the elevated identity
  (`[Security.Principal.WindowsIdentity]::GetCurrent().Name`) with the console user
  (`(Get-CimInstance Win32_ComputerSystem).UserName`). If they differ, per-user items become
  `MANUAL` ("sign in to Windows as an administrator account and run Prep again"); machine-wide items
  still apply.

## prep-config.json (keys; each lib has the same values built in as defaults)

```json
{
  "language":      { "ui": "en-US", "keep_input": ["ko-KR"] },
  "disk":          { "warn_gb": 50, "fail_gb": 20 },
  "updates":       { "pause_days": 7 },
  "power":         { "prefer": "ultimate" },
  "drivers":       { "nvidia_min": "570.00", "max_age_days": 365 },
  "startup":       { "keep_patterns": "<regex>", "disable_patterns": "<regex>" },
  "background":    { "close_patterns": "<regex>", "close_prod_only_patterns": "<regex>",
                     "ask_patterns": "<regex>", "never_close_patterns": "<regex>" },
  "network":       { "offer_disable_wifi_when_wired": true, "offer_disable_virtual_adapters": true },
  "notifications": { "disable_toasts": true }
}
```
All patterns are case-insensitive .NET regexes, matched against the entry name, command line and
process name. The default values are listed in the Tune build prompt and copied verbatim here by the
orchestrator build.

## Upload (lib\Upload.ps1)

- Reads `upload.json` in the kit root: `{ "repo": "owner/name", "branch": "main", "token": "...", "enabled": true, "api": "https://api.github.com" }`
  (`api` is optional, default `https://api.github.com`; tests point it at a local mock server).
  If missing or disabled, return `ok=$false, error='upload not set up'` quietly (one log line:
  "Not uploaded: run Setup-Upload.cmd once on this PC").
- The token only ever lives in `upload.json` on the PCs. It is never committed, never inside a
  public download, never printed or logged. `upload.json` is excluded from the public kit.
- GitHub REST, "create or update file contents": `PUT https://api.github.com/repos/{repo}/contents/{path}`
  with body `{ message, content (base64), branch }`, headers `Authorization: Bearer <token>`,
  `Accept: application/vnd.github+json`, `X-GitHub-Api-Version: 2022-11-28`, `User-Agent: ShowReady`.
  Force TLS 1.2 on PS 5.1. Use `Invoke-WebRequest -UseBasicParsing` or `Invoke-RestMethod`.
- Remote path: `runs/<run folder name>_<COMPUTERNAME>_<kind>/<relative file path>`. Upload every file in
  the run folder except `backup\` (prep undo data stays local) and files over 25 MB.
- Retry each file up to 4 times with backoff (1, 2, 4, 8 s) on 409/422/5xx/network errors: three PCs may
  upload at the same moment.
- On success write `<RunDir>\.uploaded` (the remote URL) and return the folder URL
  `https://github.com/{repo}/tree/{branch}/runs/<folder>`.
- Never print or log the token. Never throw.
- `Setup-Upload.cmd`: prompts for the token with hidden input (`Read-Host -AsSecureString`), checks it with
  `GET /repos/{repo}` and a test `PUT` of `runs/_setup/<COMPUTERNAME>.txt`, writes `upload.json`, and prints
  "Upload ready". The default repo is `thomasyuxizeng/showready-results`.
