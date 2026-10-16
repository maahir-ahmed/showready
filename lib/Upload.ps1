<#
.SYNOPSIS
    ShowReady Results Uploader (lib\Upload.ps1)
.DESCRIPTION
    Uploads ShowReady results (diagnosis, observer, LAN partner, prep) to a GitHub repository.
    Complies with ShowReady PREP-CONTRACT.md and works under Windows PowerShell 5.1 and pwsh.
#>

function Get-SRHttpStatusCode {
    param($ErrorRecord)
    if (-not $ErrorRecord) { return $null }

    $resp = $null
    if ($ErrorRecord.Exception -and $ErrorRecord.Exception.PSObject.Properties['Response']) {
        $resp = $ErrorRecord.Exception.Response
    } elseif ($ErrorRecord.PSObject.Properties['Response']) {
        $resp = $ErrorRecord.Response
    }

    if ($resp -and $resp.PSObject.Properties['StatusCode']) {
        try {
            return [int]$resp.StatusCode
        } catch { }
    }

    if ($ErrorRecord.Exception -and $ErrorRecord.Exception.PSObject.Properties['StatusCode']) {
        try {
            return [int]$ErrorRecord.Exception.StatusCode
        } catch { }
    }

    if ($ErrorRecord.Exception -and $ErrorRecord.Exception.InnerException) {
        $inner = $ErrorRecord.Exception.InnerException
        if ($inner.PSObject.Properties['Response']) {
            try {
                return [int]$inner.Response.StatusCode
            } catch { }
        }
        if ($inner.PSObject.Properties['StatusCode']) {
            try {
                return [int]$inner.StatusCode
            } catch { }
        }
    }

    return $null
}

function Scrub-SRToken {
    param(
        [string]$Text,
        [string]$Token
    )
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    if (-not [string]::IsNullOrEmpty($Token)) {
        return $Text.Replace($Token, '***')
    }
    return $Text
}

function Send-SRResults {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunDir,

        [Parameter(Mandatory = $true)]
        [string]$Kind,

        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $false)]
        [scriptblock]$Log
    )

    $uploadedFiles = @()
    $token = $null

    try {
        # Helper logging function with token scrubbing
        $writeLog = {
            param([string]$Message)
            if ($Log) {
                if (-not [string]::IsNullOrEmpty($token)) {
                    $Message = $Message.Replace($token, '***')
                }
                & $Log $Message
            }
        }

        # 1. Read <Root>\upload.json
        $uploadJsonPath = Join-Path $Root 'upload.json'
        if (-not (Test-Path -LiteralPath $uploadJsonPath)) {
            & $writeLog 'Not uploaded: run Setup-Upload.cmd once on this PC'
            return [pscustomobject]@{
                ok    = $false
                url   = $null
                files = @()
                error = 'upload not set up'
            }
        }

        $config = $null
        try {
            $rawJson = [System.IO.File]::ReadAllText($uploadJsonPath, [System.Text.Encoding]::UTF8)
            $config = $rawJson | ConvertFrom-Json
        } catch {
            & $writeLog 'Not uploaded: run Setup-Upload.cmd once on this PC'
            return [pscustomobject]@{
                ok    = $false
                url   = $null
                files = @()
                error = 'upload not set up'
            }
        }

        if (-not $config -or
            -not ($config.PSObject.Properties['enabled']) -or
            $config.enabled -ne $true -or
            [string]::IsNullOrWhiteSpace($config.token) -or
            [string]::IsNullOrWhiteSpace($config.repo)) {
            & $writeLog 'Not uploaded: run Setup-Upload.cmd once on this PC'
            return [pscustomobject]@{
                ok    = $false
                url   = $null
                files = @()
                error = 'upload not set up'
            }
        }

        $token = [string]$config.token
        $repo = [string]$config.repo
        $branch = if ($config.PSObject.Properties['branch'] -and -not [string]::IsNullOrWhiteSpace($config.branch)) { [string]$config.branch } else { 'main' }
        $api = if ($config.PSObject.Properties['api'] -and -not [string]::IsNullOrWhiteSpace($config.api)) { [string]$config.api } else { 'https://api.github.com' }
        $api = $api.TrimEnd('/')

        # 2. Force TLS 1.2
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        } catch { }

        # 3. Check RunDir
        if (-not (Test-Path -LiteralPath $RunDir)) {
            $err = "Run directory not found: $RunDir"
            & $writeLog $err
            return [pscustomobject]@{
                ok    = $false
                url   = $null
                files = @()
                error = $err
            }
        }

        $cleanRunDir = $RunDir.TrimEnd('\', '/')
        $runDirItem = Get-Item -LiteralPath $cleanRunDir
        $leaf = $runDirItem.Name
        $compName = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { 'UNKNOWN-PC' }

        # Remote folder: 'runs/' + <RunDir leaf name> + '_' + $env:COMPUTERNAME + '_' + <Kind>
        # Sanitize to [A-Za-z0-9._-] (replace others with '-')
        $rawFolderName = "$($leaf)_$($compName)_$($Kind)"
        $sanitizedFolder = $rawFolderName -replace '[^A-Za-z0-9._-]', '-'
        $remoteFolder = "runs/$sanitizedFolder"

        # 4. Enumerate files:
        # Every file under RunDir recursively, except anything under a 'backup' subfolder,
        # the '.uploaded' marker, and files larger than 25 MB (log skipped ones).
        # Relative paths use '/'.
        $basePath = $runDirItem.FullName.TrimEnd('\', '/')
        $allFileItems = @(Get-ChildItem -LiteralPath $cleanRunDir -File -Recurse -Force)
        $filesToUpload = [System.Collections.Generic.List[object]]::new()
        $maxBytes = 25 * 1024 * 1024

        foreach ($f in $allFileItems) {
            $rel = $f.FullName.Substring($basePath.Length).TrimStart('\', '/') -replace '\\', '/'

            if ($rel -eq '.uploaded') {
                continue
            }

            $segments = $rel.Split('/')
            if ($segments.Length -gt 1) {
                $parentDirs = $segments[0..($segments.Length - 2)]
                if ($parentDirs -contains 'backup') {
                    continue
                }
            }

            if ($f.Length -gt $maxBytes) {
                $mb = [math]::Round([double]$f.Length / (1024.0 * 1024.0), 2)
                & $writeLog "Skipping large file ($rel): $mb MB exceeds 25 MB limit"
                continue
            }

            $filesToUpload.Add([pscustomobject]@{
                Item    = $f
                RelPath = $rel
            })
        }

        # 5. Upload files
        $headers = @{
            'Authorization'        = "Bearer $token"
            'Accept'               = 'application/vnd.github+json'
            'X-GitHub-Api-Version' = '2022-11-28'
            'User-Agent'           = 'ShowReady'
        }

        $waits = @(1, 2, 4, 8)

        foreach ($entry in $filesToUpload) {
            $relPath = $entry.RelPath
            $fileItem = $entry.Item
            $remotePath = "$remoteFolder/$relPath"

            $escapedSegments = @($remotePath.Split('/') | ForEach-Object { [Uri]::EscapeDataString($_) })
            $escapedPath = $escapedSegments -join '/'

            $getContentUrl = "$api/repos/$repo/contents/$escapedPath`?ref=$branch"
            $putContentUrl = "$api/repos/$repo/contents/$escapedPath"

            # Initial GET to check for existing sha
            $existingSha = $null
            try {
                $getResp = Invoke-WebRequest -UseBasicParsing -Method Get -Uri $getContentUrl -Headers $headers -ErrorAction Stop
                $getContent = $getResp.Content | ConvertFrom-Json
                if ($getContent -and $getContent.sha) {
                    $existingSha = [string]$getContent.sha
                }
            } catch {
                $getStat = Get-SRHttpStatusCode $_
                if ($getStat -eq 401 -or $getStat -eq 403) {
                    $authErr = 'upload key rejected or expired: run Setup-Upload.cmd with a new key'
                    & $writeLog $authErr
                    return [pscustomobject]@{
                        ok    = $false
                        url   = $null
                        files = $uploadedFiles
                        error = $authErr
                    }
                }
                # 404 indicates a new file; any other error can proceed to PUT attempt
                $existingSha = $null
            }

            # Read file raw bytes and base64 encode
            $fileBytes = [System.IO.File]::ReadAllBytes($fileItem.FullName)
            $base64Content = [System.Convert]::ToBase64String($fileBytes)
            $commitMsg = "ShowReady $Kind $compName $leaf"

            $fileUploaded = $false
            $lastException = $null
            $lastStatusCode = $null
            $terminalError = $null

            for ($attempt = 0; $attempt -le 4; $attempt++) {
                if ($attempt -gt 0) {
                    $waitSec = $waits[$attempt - 1]
                    & $writeLog "Retrying PUT for $relPath in $waitSec s (attempt $($attempt + 1) of 5)..."
                    Start-Sleep -Seconds $waitSec

                    # If previous attempt failed with 422 (sha mismatch), re-fetch sha first
                    if ($lastStatusCode -eq 422) {
                        try {
                            $reGetResp = Invoke-WebRequest -UseBasicParsing -Method Get -Uri $getContentUrl -Headers $headers -ErrorAction Stop
                            $reContent = $reGetResp.Content | ConvertFrom-Json
                            if ($reContent -and $reContent.sha) {
                                $existingSha = [string]$reContent.sha
                            } else {
                                $existingSha = $null
                            }
                        } catch {
                            $reStat = Get-SRHttpStatusCode $_
                            if ($reStat -eq 401 -or $reStat -eq 403) {
                                $terminalError = 'upload key rejected or expired: run Setup-Upload.cmd with a new key'
                                break
                            }
                            if ($reStat -eq 404) {
                                $existingSha = $null
                            }
                        }
                    }
                }

                $putPayload = [ordered]@{
                    message = $commitMsg
                    content = $base64Content
                    branch  = $branch
                }
                if ($existingSha) {
                    $putPayload['sha'] = $existingSha
                }

                $jsonBody = ConvertTo-Json $putPayload -Compress
                $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonBody)

                try {
                    $null = Invoke-WebRequest -UseBasicParsing -Method Put -Uri $putContentUrl -Headers $headers -Body $bodyBytes -ContentType 'application/json' -ErrorAction Stop
                    $fileUploaded = $true
                    break
                } catch {
                    $statusCode = Get-SRHttpStatusCode $_
                    $lastStatusCode = $statusCode
                    $lastException = $_

                    # Immediate fatal codes
                    if ($statusCode -eq 401 -or $statusCode -eq 403) {
                        $terminalError = 'upload key rejected or expired: run Setup-Upload.cmd with a new key'
                        break
                    }
                    if ($statusCode -eq 404) {
                        $terminalError = 'repo not found'
                        break
                    }

                    # Retryable: 409, 422, 429, 5xx, or network exception ($null)
                    $isRetryable = ($statusCode -eq 409) -or
                                   ($statusCode -eq 422) -or
                                   ($statusCode -eq 429) -or
                                   ($statusCode -ge 500 -and $statusCode -le 599) -or
                                   ($null -eq $statusCode)

                    if (-not $isRetryable) {
                        $errMsg = if ($statusCode) { "HTTP $statusCode" } else { Scrub-SRToken "$($_.Exception.Message)" $token }
                        $terminalError = "Upload failed for $relPath`: $errMsg"
                        break
                    }

                    if ($attempt -eq 4) {
                        $errMsg = if ($statusCode) { "HTTP $statusCode" } else { Scrub-SRToken "$($_.Exception.Message)" $token }
                        $terminalError = "Upload failed for $relPath after 5 attempts: $errMsg"
                    }
                }
            }

            if ($terminalError) {
                & $writeLog $terminalError
                return [pscustomobject]@{
                    ok    = $false
                    url   = $null
                    files = $uploadedFiles
                    error = $terminalError
                }
            }

            if (-not $fileUploaded) {
                $err = "Failed to upload $relPath"
                & $writeLog $err
                return [pscustomobject]@{
                    ok    = $false
                    url   = $null
                    files = $uploadedFiles
                    error = $err
                }
            }

            $uploadedFiles += $relPath
        }

        # 6. On success: write <RunDir>\.uploaded containing folder URL
        # URL format: 'https://github.com/<repo>/tree/<branch>/<remote folder>'
        $folderUrl = "https://github.com/$repo/tree/$branch/$remoteFolder"
        try {
            $markerPath = Join-Path $cleanRunDir '.uploaded'
            [System.IO.File]::WriteAllText($markerPath, $folderUrl, [System.Text.UTF8Encoding]::new($false))
        } catch {
            & $writeLog "Warning: Could not write .uploaded marker: $($_.Exception.Message)"
        }

        & $writeLog "Uploaded to $folderUrl ($($uploadedFiles.Count) file(s))"
        return [pscustomobject]@{
            ok    = $true
            url   = $folderUrl
            files = $uploadedFiles
            error = $null
        }
    } catch {
        $msg = Scrub-SRToken "Unexpected error during upload: $($_.Exception.Message)" $token
        if ($Log) {
            & $Log $msg
        }
        return [pscustomobject]@{
            ok    = $false
            url   = $null
            files = $uploadedFiles
            error = $msg
        }
    }
}

function Send-SRPendingResults {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $false)]
        [scriptblock]$Log
    )

    $allResults = @()
    try {
        $resultsDir = Join-Path $Root 'results'
        if (-not (Test-Path -LiteralPath $resultsDir)) {
            return @()
        }

        $dirs = @(Get-ChildItem -LiteralPath $resultsDir -Directory | Sort-Object Name)
        foreach ($d in $dirs) {
            $marker = Join-Path $d.FullName '.uploaded'
            if (Test-Path -LiteralPath $marker) {
                continue
            }

            $folderName = $d.Name
            $kind = 'showready'
            if ($folderName -match '-(prep|prep-undo)$') {
                $kind = 'prep'
            } else {
                $resFile = Join-Path $d.FullName 'results.json'
                $isObserver = $false
                if (Test-Path -LiteralPath $resFile) {
                    try {
                        $jsonRaw = [System.IO.File]::ReadAllText($resFile, [System.Text.Encoding]::UTF8)
                        $parsed = $jsonRaw | ConvertFrom-Json
                        if ($parsed -and $parsed.meta -and $parsed.meta.role -eq 'observer') {
                            $isObserver = $true
                        }
                    } catch { }
                }

                if ($isObserver) {
                    $kind = 'observer'
                } elseif ($folderName.ToLower().Contains('lanpartner')) {
                    $kind = 'lanpartner'
                } else {
                    $kind = 'showready'
                }
            }

            $res = Send-SRResults -RunDir $d.FullName -Kind $kind -Root $Root -Log $Log
            $allResults += $res
        }
    } catch {
        if ($Log) {
            & $Log "Error scanning pending results: $($_.Exception.Message)"
        }
    }
    return $allResults
}
