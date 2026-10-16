<#
.SYNOPSIS
    ShowReady - Setup GitHub Upload (Setup-Upload.ps1)
.DESCRIPTION
    Configures GitHub upload settings by validating the upload token against the target
    repository, writing upload.json in the kit root.
    Complies with ShowReady PREP-CONTRACT.md and works under Windows PowerShell 5.1 and pwsh.
#>

[CmdletBinding()]
param(
    [string]$Repo = 'thomasyuxizeng/showready-results',
    [string]$Branch = 'main',
    [string]$Token,
    [string]$Api = 'https://api.github.com',
    [switch]$NonInteractive,
    [string]$Root
)

$ErrorActionPreference = 'Stop'

# Determine Kit Root
if ([string]::IsNullOrEmpty($Root)) {
    $Root = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if ([string]::IsNullOrEmpty($Root)) {
    $Root = $PSScriptRoot
}
if ([string]::IsNullOrEmpty($Root)) {
    $Root = (Get-Location).Path
}

# 1. Explain in 3 short lines what it does
Write-Host "ShowReady GitHub Upload Setup" -ForegroundColor Cyan
Write-Host "Configures this PC to automatically upload test and prep results to GitHub."
Write-Host "Results from this PC will be uploaded to https://github.com/$Repo"

# 2. Prompt for token if not supplied
if ([string]::IsNullOrEmpty($Token)) {
    if ($NonInteractive) {
        Write-Host "Error: No upload token provided in non-interactive mode." -ForegroundColor Red
        exit 1
    }

    $secure = Read-Host "Paste the upload key, then press Enter" -AsSecureString
    if ($null -eq $secure) {
        Write-Host "Error: No key entered." -ForegroundColor Red
        exit 1
    }

    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        $Token = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

$Token = $Token.Trim()
if ([string]::IsNullOrEmpty($Token)) {
    Write-Host "Error: Upload key cannot be empty." -ForegroundColor Red
    exit 1
}

# 3. Force TLS 1.2
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

function Get-SetupStatusCode {
    param($ErrorRecord)
    if (-not $ErrorRecord) { return $null }

    $resp = $null
    if ($ErrorRecord.Exception -and $ErrorRecord.Exception.PSObject.Properties['Response']) {
        $resp = $ErrorRecord.Exception.Response
    } elseif ($ErrorRecord.PSObject.Properties['Response']) {
        $resp = $ErrorRecord.Response
    }

    if ($resp -and $resp.PSObject.Properties['StatusCode']) {
        try { return [int]$resp.StatusCode } catch { }
    }

    if ($ErrorRecord.Exception -and $ErrorRecord.Exception.PSObject.Properties['StatusCode']) {
        try { return [int]$ErrorRecord.Exception.StatusCode } catch { }
    }

    if ($ErrorRecord.Exception -and $ErrorRecord.Exception.InnerException) {
        $inner = $ErrorRecord.Exception.InnerException
        if ($inner.PSObject.Properties['Response']) {
            try { return [int]$inner.Response.StatusCode } catch { }
        }
        if ($inner.PSObject.Properties['StatusCode']) {
            try { return [int]$inner.StatusCode } catch { }
        }
    }
    return $null
}

$apiClean = $Api.TrimEnd('/')
$headers = @{
    'Authorization'        = "Bearer $Token"
    'Accept'               = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
    'User-Agent'           = 'ShowReady'
}

# 4. Check GET <api>/repos/<repo> (200 needed)
$repoUrl = "$apiClean/repos/$Repo"
try {
    $null = Invoke-WebRequest -UseBasicParsing -Method Get -Uri $repoUrl -Headers $headers -ErrorAction Stop
} catch {
    $stat = Get-SetupStatusCode $_
    if ($stat -eq 401 -or $stat -eq 403) {
        Write-Host "The key was rejected: check it has Contents read and write access to $Repo and has not expired" -ForegroundColor Red
    } elseif ($stat -eq 404) {
        Write-Host "Repository not found: $Repo" -ForegroundColor Red
    } else {
        $detail = if ($stat) { "HTTP $stat" } else { $_.Exception.Message }
        Write-Host "Failed to verify repository: $detail" -ForegroundColor Red
    }
    exit 1
}

# 5. Check test PUT of runs/_setup/<COMPUTERNAME>.txt
$compName = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { 'UNKNOWN' }
$setupFileRemotePath = "runs/_setup/$compName.txt"
$escapedSegments = @($setupFileRemotePath.Split('/') | ForEach-Object { [Uri]::EscapeDataString($_) })
$escapedPath = $escapedSegments -join '/'

$setupGetUrl = "$apiClean/repos/$Repo/contents/$escapedPath`?ref=$Branch"
$setupPutUrl = "$apiClean/repos/$Repo/contents/$escapedPath"
$setupSha = $null

try {
    $getResp = Invoke-WebRequest -UseBasicParsing -Method Get -Uri $setupGetUrl -Headers $headers -ErrorAction Stop
    $getObj = $getResp.Content | ConvertFrom-Json
    if ($getObj -and $getObj.sha) {
        $setupSha = [string]$getObj.sha
    }
} catch {
    $stat = Get-SetupStatusCode $_
    if ($stat -eq 401 -or $stat -eq 403) {
        Write-Host "The key was rejected: check it has Contents read and write access to $Repo and has not expired" -ForegroundColor Red
        exit 1
    }
    # 404 is expected if file does not exist yet
}

$isoTime = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
$setupContent = "setup ok $isoTime"
$setupBytes = [System.Text.Encoding]::UTF8.GetBytes($setupContent)
$setupB64 = [System.Convert]::ToBase64String($setupBytes)

$putObj = [ordered]@{
    message = "ShowReady setup test $compName"
    content = $setupB64
    branch  = $Branch
}
if ($setupSha) {
    $putObj['sha'] = $setupSha
}

$putJson = ConvertTo-Json $putObj -Compress
$putBodyBytes = [System.Text.Encoding]::UTF8.GetBytes($putJson)

try {
    $null = Invoke-WebRequest -UseBasicParsing -Method Put -Uri $setupPutUrl -Headers $headers -Body $putBodyBytes -ContentType 'application/json' -ErrorAction Stop
} catch {
    $stat = Get-SetupStatusCode $_
    if ($stat -eq 401 -or $stat -eq 403) {
        Write-Host "The key was rejected: check it has Contents read and write access to $Repo and has not expired" -ForegroundColor Red
    } else {
        $detail = if ($stat) { "HTTP $stat" } else { $_.Exception.Message }
        Write-Host "Failed to write setup test file: $detail" -ForegroundColor Red
    }
    exit 1
}

# 6. On success write <KIT ROOT>\upload.json and print success message
$uploadObj = [ordered]@{
    repo    = $Repo
    branch  = $Branch
    token   = $Token
    enabled = $true
    api     = $apiClean
}
$uploadJsonPath = Join-Path $Root 'upload.json'
$configText = ConvertTo-Json $uploadObj -Depth 4
[System.IO.File]::WriteAllText($uploadJsonPath, $configText, [System.Text.UTF8Encoding]::new($false))

Write-Host "Upload ready: results from this PC will go to https://github.com/$Repo" -ForegroundColor Green
exit 0
