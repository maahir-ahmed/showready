# ShowReady - tests\Test-Upload.ps1
# Plain PowerShell assertions (no Pester) for GitHub upload functionality in lib\Upload.ps1,
# Setup-Upload.ps1, and Upload-Results.ps1 using a local mock HTTP server.
# Exit code 0 = all assertions passed, 1 = at least one failed. Pure ASCII, works on Windows PowerShell 5.1 and pwsh.

$ErrorActionPreference = 'Continue'
$testsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrEmpty($testsDir)) {
    $testsDir = $PSScriptRoot
}
$kit = Split-Path -Parent $testsDir
$uploadLibPath = Join-Path $kit 'lib\Upload.ps1'

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

Write-Host ''
Write-Host 'ShowReady upload tests' -ForegroundColor Cyan
Write-Host ('  PowerShell ' + $PSVersionTable.PSVersion.ToString()) -ForegroundColor DarkGray

# =============================================================================================
# 1. Source files check
# =============================================================================================
Write-Host '1: source files and dot-sourcing' -ForegroundColor Cyan
$dotOut = @(. $uploadLibPath)
Assert-That '1: dot-sourcing Upload.ps1 prints nothing' ($dotOut.Count -eq 0) ('output count ' + $dotOut.Count)
foreach ($fn in 'Send-SRResults', 'Send-SRPendingResults', 'Get-SRHttpStatusCode', 'Scrub-SRToken') {
    Assert-That ('1: ' + $fn + ' is defined') ($null -ne (Get-Command $fn -CommandType Function -ErrorAction SilentlyContinue))
}

$filesToCheck = @(
    'lib\Upload.ps1',
    'Setup-Upload.ps1',
    'Setup-Upload.cmd',
    'Upload-Results.ps1',
    'Upload-Results.cmd',
    'tests\Test-Upload.ps1'
)
foreach ($rel in $filesToCheck) {
    $full = Join-Path $kit $rel
    if (Test-Path -LiteralPath $full) {
        $srcText = [System.IO.File]::ReadAllText($full)
        Assert-That ("1: $rel is pure ASCII") (-not ($srcText -match '[^\x00-\x7F]'))
    }
}

# =============================================================================================
# 2. Start mock GitHub API with System.Net.HttpListener in background RUNSPACE
# =============================================================================================
Write-Host '2: start mock GitHub API listener' -ForegroundColor Cyan

$port = 0
for ($p = 18000; $p -le 18999; $p++) {
    try {
        $tcp = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $p)
        $tcp.Start()
        $tcp.Stop()
        $port = $p
        break
    } catch { }
}
Assert-That "2: found free port $port in range 18000-18999" ($port -ge 18000 -and $port -le 18999)

$shared = [hashtable]::Synchronized(@{
    Running           = $true
    Port              = $port
    Storage           = [hashtable]::Synchronized(@{})
    FailFirstPutPaths = [hashtable]::Synchronized(@{})
    FailedPathsCount  = [hashtable]::Synchronized(@{})
    Requests          = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
    Error             = $null
})

$runspace = [runspacefactory]::CreateRunspace()
$runspace.Open()
$runspace.SessionStateProxy.SetVariable('shared', $shared)
$ps = [powershell]::Create()
$ps.Runspace = $runspace
[void]$ps.AddScript({
    $listener = New-Object System.Net.HttpListener
    $prefix = "http://127.0.0.1:$($shared.Port)/"
    $listener.Prefixes.Add($prefix)
    $listener.Start()
    try {
        while ($shared.Running) {
            $async = $listener.BeginGetContext($null, $null)
            while (-not $async.AsyncWaitHandle.WaitOne(100)) {
                if (-not $shared.Running) { break }
            }
            if (-not $shared.Running) { break }
            $ctx = $listener.EndGetContext($async)
            $req = $ctx.Request
            $resp = $ctx.Response

            # Record every request: headers minus Authorization value presence
            $headersMinusAuth = [ordered]@{}
            foreach ($k in $req.Headers.AllKeys) {
                if ($k -ieq 'Authorization') {
                    $headersMinusAuth[$k] = '[PRESENT]'
                } else {
                    $headersMinusAuth[$k] = $req.Headers[$k]
                }
            }
            $shared.Requests.Add([pscustomobject]@{
                Method  = $req.HttpMethod
                Path    = $req.Url.AbsolutePath
                Query   = $req.Url.Query
                Headers = $headersMinusAuth
            })

            # Check for shutdown trigger
            if ($req.Url.AbsolutePath -eq '/shutdown') {
                $resp.StatusCode = 200
                $resp.Close()
                break
            }

            # Magic token 'bad' -> 401
            $auth = $req.Headers['Authorization']
            if ($auth -and $auth.Trim() -eq 'Bearer bad') {
                $resp.StatusCode = 401
                $resp.ContentType = 'application/json'
                $bytes = [System.Text.Encoding]::UTF8.GetBytes('{"message":"Bad credentials"}')
                $resp.OutputStream.Write($bytes, 0, $bytes.Length)
                $resp.Close()
                continue
            }

            # Route: GET /repos/o/r -> 200
            if ($req.HttpMethod -eq 'GET' -and $req.Url.AbsolutePath -eq '/repos/o/r') {
                $resp.StatusCode = 200
                $resp.ContentType = 'application/json'
                $bytes = [System.Text.Encoding]::UTF8.GetBytes('{"name":"r","full_name":"o/r"}')
                $resp.OutputStream.Write($bytes, 0, $bytes.Length)
                $resp.Close()
                continue
            }

            # Route: /repos/o/r/contents/<path>
            $contentsPrefix = '/repos/o/r/contents/'
            if ($req.Url.AbsolutePath.StartsWith($contentsPrefix)) {
                $itemPath = $req.Url.AbsolutePath.Substring($contentsPrefix.Length)
                $itemPath = [Uri]::UnescapeDataString($itemPath)

                if ($req.HttpMethod -eq 'GET') {
                    if ($shared.Storage.ContainsKey($itemPath)) {
                        $stored = $shared.Storage[$itemPath]
                        $resp.StatusCode = 200
                        $resp.ContentType = 'application/json'
                        $json = "{`"sha`":`"$($stored.sha)`"}"
                        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
                        $resp.OutputStream.Write($bytes, 0, $bytes.Length)
                    } else {
                        $resp.StatusCode = 404
                        $resp.ContentType = 'application/json'
                        $bytes = [System.Text.Encoding]::UTF8.GetBytes('{"message":"Not Found"}')
                        $resp.OutputStream.Write($bytes, 0, $bytes.Length)
                    }
                    $resp.Close()
                    continue
                }

                if ($req.HttpMethod -eq 'PUT') {
                    # Configurable fail first PUT with 409
                    if ($shared.FailFirstPutPaths.ContainsKey($itemPath)) {
                        $shared.FailFirstPutPaths.Remove($itemPath)
                        $currCount = 0
                        if ($shared.FailedPathsCount.ContainsKey($itemPath)) {
                            $currCount = [int]$shared.FailedPathsCount[$itemPath]
                        }
                        $shared.FailedPathsCount[$itemPath] = $currCount + 1
                        $resp.StatusCode = 409
                        $resp.ContentType = 'application/json'
                        $bytes = [System.Text.Encoding]::UTF8.GetBytes('{"message":"Conflict"}')
                        $resp.OutputStream.Write($bytes, 0, $bytes.Length)
                        $resp.Close()
                        continue
                    }

                    # Read body, decode base64, compute sha, store
                    $reader = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
                    $bodyText = $reader.ReadToEnd()
                    $bodyObj = $bodyText | ConvertFrom-Json
                    $rawB64 = [string]$bodyObj.content
                    $rawBytes = [System.Convert]::FromBase64String($rawB64)

                    $sha1 = [System.Security.Cryptography.SHA1]::Create()
                    $hashBytes = $sha1.ComputeHash($rawBytes)
                    $shaHex = ($hashBytes | ForEach-Object { $_.ToString('x2') }) -join ''

                    $shared.Storage[$itemPath] = [hashtable]::Synchronized(@{
                        bytes  = $rawBytes
                        sha    = $shaHex
                        base64 = $rawB64
                    })

                    $resp.StatusCode = 201
                    $resp.ContentType = 'application/json'
                    $respJson = "{`"content`":{`"sha`":`"$shaHex`"}}"
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes($respJson)
                    $resp.OutputStream.Write($bytes, 0, $bytes.Length)
                    $resp.Close()
                    continue
                }
            }

            # Default 404
            $resp.StatusCode = 404
            $resp.ContentType = 'application/json'
            $bytes = [System.Text.Encoding]::UTF8.GetBytes('{"message":"Not Found"}')
            $resp.OutputStream.Write($bytes, 0, $bytes.Length)
            $resp.Close()
        }
    } catch {
        $shared.Error = $_.Exception.ToString()
    } finally {
        try { $listener.Stop() } catch { }
        try { $listener.Close() } catch { }
    }
})
$asyncResult = $ps.BeginInvoke()
Start-Sleep -Milliseconds 400

# =============================================================================================
# 3. Create temp kit root
# =============================================================================================
Write-Host '3: create temp kit root and test fixture files' -ForegroundColor Cyan

$tempRoot = Join-Path $env:TEMP ('ShowReady-UploadTest-' + [guid]::NewGuid().ToString('N'))
$capturedLogs = [System.Collections.Generic.List[string]]::new()
$logCollector = {
    param([string]$m)
    $capturedLogs.Add($m)
}

try {
    $runDir1 = Join-Path $tempRoot 'results\20261016-120000'
    $runDirPrep = Join-Path $tempRoot 'results\20261016-130000-prep'
    $backupDir = Join-Path $runDir1 'backup'

    [void](New-Item -ItemType Directory -Path $backupDir -Force)
    [void](New-Item -ItemType Directory -Path $runDirPrep -Force)
    [void](New-Item -ItemType Directory -Path (Join-Path $tempRoot 'lib') -Force)

    Copy-Item -LiteralPath $uploadLibPath -Destination (Join-Path $tempRoot 'lib\Upload.ps1') -Force
    Copy-Item -LiteralPath (Join-Path $kit 'Setup-Upload.ps1') -Destination (Join-Path $tempRoot 'Setup-Upload.ps1') -Force

    $resultsJsonContent = '{"meta":{"role":"prod"},"status":"OK","test":"test-data"}'
    $reportHtmlContent = '<!DOCTYPE html><html><body><h1>ShowReady Report</h1></body></html>'
    $secretBackupContent = '{"secret":"keep-local-undo-data"}'
    $prepJsonContent = '{"meta":{"role":"prep"},"status":"OK"}'

    [System.IO.File]::WriteAllText((Join-Path $runDir1 'results.json'), $resultsJsonContent, [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText((Join-Path $runDir1 'report.html'), $reportHtmlContent, [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText((Join-Path $backupDir 'secret.json'), $secretBackupContent, [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText((Join-Path $runDirPrep 'prep.json'), $prepJsonContent, [System.Text.Encoding]::UTF8)

    # 26 MB dummy file
    $bigFilePath = Join-Path $runDir1 'bigfile.bin'
    $fs = [System.IO.File]::Create($bigFilePath)
    $fs.SetLength(26 * 1024 * 1024)
    $fs.Close()

    # =========================================================================================
    # Assertion A: missing upload.json -> ok false, 'upload not set up'
    # =========================================================================================
    Write-Host 'a: missing upload.json' -ForegroundColor Cyan
    $resMissing = Send-SRResults -RunDir $runDir1 -Kind 'showready' -Root $tempRoot -Log $logCollector
    Assert-That 'a: returns ok = $false' ($resMissing.ok -eq $false)
    Assert-That "a: error is 'upload not set up'" ($resMissing.error -eq 'upload not set up') $resMissing.error
    Assert-That "a: logged 'Not uploaded: run Setup-Upload.cmd once on this PC'" ($capturedLogs -contains 'Not uploaded: run Setup-Upload.cmd once on this PC')

    # =========================================================================================
    # Assertion B: normal upload stores results.json and report.html with byte-identical content
    # =========================================================================================
    Write-Host 'b: normal upload' -ForegroundColor Cyan
    $testToken = 'test-secret-token-12345'
    $uploadJsonPath = Join-Path $tempRoot 'upload.json'
    $uploadConfig = [ordered]@{
        repo    = 'o/r'
        branch  = 'main'
        token   = $testToken
        enabled = $true
        api     = "http://127.0.0.1:$port"
    }
    $cfgJson = ConvertTo-Json $uploadConfig -Depth 4
    [System.IO.File]::WriteAllText($uploadJsonPath, $cfgJson, [System.Text.UTF8Encoding]::new($false))

    $resNormal = Send-SRResults -RunDir $runDir1 -Kind 'showready' -Root $tempRoot -Log $logCollector
    Assert-That 'b: normal upload returns ok = $true' ($resNormal.ok -eq $true)
    Assert-That 'b: files list contains results.json' ($resNormal.files -contains 'results.json')
    Assert-That 'b: files list contains report.html' ($resNormal.files -contains 'report.html')

    $sanitizedComp = ($env:COMPUTERNAME -replace '[^A-Za-z0-9._-]', '-')
    $expectedFolder = "runs/20261016-120000_$($sanitizedComp)_showready"
    $storedResultsKey = "$expectedFolder/results.json"
    $storedReportKey = "$expectedFolder/report.html"

    Assert-That 'b: results.json stored in mock' ($shared.Storage.ContainsKey($storedResultsKey))
    Assert-That 'b: report.html stored in mock' ($shared.Storage.ContainsKey($storedReportKey))

    $localResultsBytes = [System.IO.File]::ReadAllBytes((Join-Path $runDir1 'results.json'))
    $storedResultsBytes = $shared.Storage[$storedResultsKey].bytes
    $resultsIdentical = ($localResultsBytes.Length -eq $storedResultsBytes.Length)
    if ($resultsIdentical) {
        for ($i = 0; $i -lt $localResultsBytes.Length; $i++) {
            if ($localResultsBytes[$i] -ne $storedResultsBytes[$i]) {
                $resultsIdentical = $false
                break
            }
        }
    }
    Assert-That 'b: results.json content is byte-identical after base64 round trip' ($resultsIdentical)

    $localReportBytes = [System.IO.File]::ReadAllBytes((Join-Path $runDir1 'report.html'))
    $storedReportBytes = $shared.Storage[$storedReportKey].bytes
    $reportIdentical = ($localReportBytes.Length -eq $storedReportBytes.Length)
    if ($reportIdentical) {
        for ($i = 0; $i -lt $localReportBytes.Length; $i++) {
            if ($localReportBytes[$i] -ne $storedReportBytes[$i]) {
                $reportIdentical = $false
                break
            }
        }
    }
    Assert-That 'b: report.html content is byte-identical after base64 round trip' ($reportIdentical)

    # =========================================================================================
    # Assertion C: backup\ and the 26 MB file are NOT uploaded
    # =========================================================================================
    Write-Host 'c: exclusions (backup subfolder and >25MB file)' -ForegroundColor Cyan
    $storedKeys = @($shared.Storage.Keys)
    $backupUploaded = $false
    $bigUploaded = $false
    foreach ($k in $storedKeys) {
        if ($k -match 'backup' -or $k -match 'secret\.json') { $backupUploaded = $true }
        if ($k -match 'bigfile\.bin') { $bigUploaded = $true }
    }
    Assert-That 'c: backup\ secret.json is NOT uploaded' (-not $backupUploaded)
    Assert-That 'c: 26 MB dummy file is NOT uploaded' (-not $bigUploaded)
    Assert-That 'c: skipped large file was logged' (@($capturedLogs -match 'exceeds 25 MB limit').Count -gt 0)

    # =========================================================================================
    # Assertion D: .uploaded marker written with the github.com URL
    # =========================================================================================
    Write-Host 'd: .uploaded marker' -ForegroundColor Cyan
    $markerPath = Join-Path $runDir1 '.uploaded'
    Assert-That 'd: .uploaded marker file exists' (Test-Path -LiteralPath $markerPath)
    $markerContent = [System.IO.File]::ReadAllText($markerPath).Trim()
    $expectedUrl = "https://github.com/o/r/tree/main/$expectedFolder"
    Assert-That 'd: .uploaded marker contains github.com URL' ($markerContent -eq $expectedUrl) ("found: $markerContent vs expected: $expectedUrl")
    Assert-That 'd: return object url matches marker' ($resNormal.url -eq $expectedUrl)

    # =========================================================================================
    # Assertion E: 409 on first PUT is retried and succeeds
    # =========================================================================================
    Write-Host 'e: 409 conflict retry' -ForegroundColor Cyan
    $runDir409 = Join-Path $tempRoot 'results\20261016-140000'
    [void](New-Item -ItemType Directory -Path $runDir409 -Force)
    [System.IO.File]::WriteAllText((Join-Path $runDir409 'results.json'), '{"test":"retry-409"}', [System.Text.Encoding]::UTF8)

    $folder409 = "runs/20261016-140000_$($sanitizedComp)_showready"
    $file409Path = "$folder409/results.json"
    $shared.FailFirstPutPaths[$file409Path] = $true

    $res409 = Send-SRResults -RunDir $runDir409 -Kind 'showready' -Root $tempRoot -Log $logCollector
    Assert-That 'e: 409 retry succeeds with ok = $true' ($res409.ok -eq $true)
    Assert-That 'e: 409 was encountered exactly once' ($shared.FailedPathsCount[$file409Path] -eq 1)
    Assert-That 'e: file was successfully stored on retry' ($shared.Storage.ContainsKey($file409Path))

    # =========================================================================================
    # Assertion F: token 'bad' -> ok false with rejected or expired message
    # =========================================================================================
    Write-Host 'f: bad token handling' -ForegroundColor Cyan
    $runDirBad = Join-Path $tempRoot 'results\20261016-150000'
    [void](New-Item -ItemType Directory -Path $runDirBad -Force)
    [System.IO.File]::WriteAllText((Join-Path $runDirBad 'results.json'), '{"test":"bad-token"}', [System.Text.Encoding]::UTF8)

    $badConfig = [ordered]@{
        repo    = 'o/r'
        branch  = 'main'
        token   = 'bad'
        enabled = $true
        api     = "http://127.0.0.1:$port"
    }
    [System.IO.File]::WriteAllText($uploadJsonPath, (ConvertTo-Json $badConfig), [System.Text.UTF8Encoding]::new($false))

    $resBad = Send-SRResults -RunDir $runDirBad -Kind 'showready' -Root $tempRoot -Log $logCollector
    Assert-That 'f: token bad returns ok = $false' ($resBad.ok -eq $false)
    $expectedBadMsg = 'upload key rejected or expired: run Setup-Upload.cmd with a new key'
    Assert-That 'f: error message is rejected or expired' ($resBad.error -eq $expectedBadMsg) $resBad.error
    Assert-That 'f: .uploaded marker NOT written on failure' (-not (Test-Path -LiteralPath (Join-Path $runDirBad '.uploaded')))

    # =========================================================================================
    # Assertion G: token string never appears in any captured log line or returned error
    # =========================================================================================
    Write-Host 'g: token scrubbing' -ForegroundColor Cyan
    $tokensToSearch = @('test-secret-token-12345', 'bad')
    $tokenLeakedInLogs = $false
    $tokenLeakedInErrors = $false

    foreach ($tok in $tokensToSearch) {
        foreach ($logLine in $capturedLogs) {
            if ($logLine -and $logLine.Contains($tok)) {
                $tokenLeakedInLogs = $true
            }
        }
        if ($resMissing.error -and $resMissing.error.Contains($tok)) { $tokenLeakedInErrors = $true }
        if ($resNormal.error -and $resNormal.error.Contains($tok)) { $tokenLeakedInErrors = $true }
        if ($res409.error -and $res409.error.Contains($tok)) { $tokenLeakedInErrors = $true }
        if ($resBad.error -and $resBad.error.Contains($tok)) { $tokenLeakedInErrors = $true }
    }
    Assert-That 'g: token never appears in any captured log line' (-not $tokenLeakedInLogs)
    Assert-That 'g: token never appears in any returned error' (-not $tokenLeakedInErrors)

    # Also verify mock request headers did not store token value
    $tokenInMockHeaders = $false
    foreach ($reqRecord in $shared.Requests) {
        foreach ($val in $reqRecord.Headers.Values) {
            if ($val -and ($val.Contains('test-secret-token-12345') -or $val.Contains('bad'))) {
                $tokenInMockHeaders = $true
            }
        }
    }
    Assert-That 'g: mock request headers list scrubbed Authorization value' (-not $tokenInMockHeaders)

    # =========================================================================================
    # Assertion H: Send-SRPendingResults skips folders with .uploaded and infers Kind 'prep'
    # =========================================================================================
    Write-Host 'h: Send-SRPendingResults' -ForegroundColor Cyan
    # Restore valid token in upload.json
    [System.IO.File]::WriteAllText($uploadJsonPath, (ConvertTo-Json $uploadConfig), [System.Text.UTF8Encoding]::new($false))
    # Clean up the bad folder so only runDirPrep is pending (runDir1 and runDir409 have .uploaded)
    if (Test-Path -LiteralPath $runDirBad) {
        Remove-Item -LiteralPath $runDirBad -Recurse -Force
    }

    $pendingResults = @(Send-SRPendingResults -Root $tempRoot -Log $logCollector)
    Assert-That 'h: only un-uploaded folders are processed (count = 1)' ($pendingResults.Count -eq 1) ("count was $($pendingResults.Count)")
    Assert-That 'h: pending prep folder returns ok = $true' ($pendingResults[0].ok -eq $true)
    Assert-That "h: prep folder URL contains '_prep'" ($pendingResults[0].url -match '_prep$') ($pendingResults[0].url)
    Assert-That 'h: prep folder now has .uploaded marker' (Test-Path -LiteralPath (Join-Path $runDirPrep '.uploaded'))

    # Running Send-SRPendingResults again finds 0 folders
    $pendingEmpty = @(Send-SRPendingResults -Root $tempRoot -Log $logCollector)
    Assert-That 'h: running again finds 0 pending folders' ($pendingEmpty.Count -eq 0)

    # =========================================================================================
    # Assertion I: Setup-Upload.ps1 writes upload.json with good token, and not with bad token
    # =========================================================================================
    Write-Host 'i: Setup-Upload.ps1 verification' -ForegroundColor Cyan
    # Remove upload.json before test
    if (Test-Path -LiteralPath $uploadJsonPath) {
        Remove-Item -LiteralPath $uploadJsonPath -Force
    }

    $setupScript = Join-Path $tempRoot 'Setup-Upload.ps1'

    # Run with -Token bad
    $psExe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
    $cmdBad = "-NoProfile -ExecutionPolicy Bypass -File `"$setupScript`" -Token bad -Api http://127.0.0.1:$port -Repo o/r -NonInteractive -Root `"$tempRoot`""
    $pBad = Start-Process $psExe -ArgumentList $cmdBad -Wait -PassThru -NoNewWindow
    Assert-That 'i: Setup-Upload with bad token exits with non-zero exit code' ($pBad.ExitCode -ne 0) ("exit code: $($pBad.ExitCode)")
    Assert-That 'i: upload.json NOT written on failure' (-not (Test-Path -LiteralPath $uploadJsonPath))

    # Run with -Token good
    $cmdGood = "-NoProfile -ExecutionPolicy Bypass -File `"$setupScript`" -Token good -Api http://127.0.0.1:$port -Repo o/r -NonInteractive -Root `"$tempRoot`""
    $pGood = Start-Process $psExe -ArgumentList $cmdGood -Wait -PassThru -NoNewWindow
    Assert-That 'i: Setup-Upload with good token exits with exit code 0' ($pGood.ExitCode -eq 0) ("exit code: $($pGood.ExitCode)")
    Assert-That 'i: upload.json written on success' (Test-Path -LiteralPath $uploadJsonPath)

    if (Test-Path -LiteralPath $uploadJsonPath) {
        $writtenCfg = [System.IO.File]::ReadAllText($uploadJsonPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        Assert-That "i: written token is 'good'" ($writtenCfg.token -eq 'good')
        Assert-That "i: written repo is 'o/r'" ($writtenCfg.repo -eq 'o/r')
        Assert-That 'i: written enabled is $true' ($writtenCfg.enabled -eq $true)
        Assert-That "i: written branch is 'main'" ($writtenCfg.branch -eq 'main')
    }

} finally {
    # Stop listener and runspace
    $shared.Running = $false
    try {
        $wc = New-Object System.Net.WebClient
        $null = $wc.DownloadString("http://127.0.0.1:$port/shutdown")
    } catch { }

    try {
        $null = $ps.EndInvoke($asyncResult)
    } catch { }
    $ps.Dispose()
    $runspace.Close()
    $runspace.Dispose()

    # Clean up temp folder
    if ($tempRoot -and (Test-Path -LiteralPath $tempRoot)) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}

Write-Host ''
if ($script:nFail -eq 0) {
    Write-Host 'ALL UPLOAD TESTS PASSED' -ForegroundColor Green
    exit 0
} else {
    Write-Host "TESTS FAILED: $($script:nFail) failure(s), $($script:nPass) passed" -ForegroundColor Red
    exit 1
}
