<#
.SYNOPSIS
    ShowReady - Upload Results (Upload-Results.ps1)
.DESCRIPTION
    Scans for pending un-uploaded results folders in results\ and uploads them to GitHub.
    Complies with ShowReady PREP-CONTRACT.md and works under Windows PowerShell 5.1 and pwsh.
#>

[CmdletBinding()]
param(
    [string]$Root,
    [scriptblock]$Log
)

$ErrorActionPreference = 'Continue'

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

$libUpload = Join-Path $Root 'lib\Upload.ps1'
if (-not (Test-Path -LiteralPath $libUpload)) {
    Write-Host "Error: Upload library not found at $libUpload" -ForegroundColor Red
    exit 1
}

. $libUpload

Write-Host "Scanning for pending results in $Root\results..." -ForegroundColor Cyan

$pendingResults = Send-SRPendingResults -Root $Root -Log $Log

if (-not $pendingResults -or $pendingResults.Count -eq 0) {
    Write-Host "No pending results to upload." -ForegroundColor Yellow
} else {
    foreach ($res in $pendingResults) {
        if ($res.ok) {
            Write-Host "Uploaded: $($res.url)" -ForegroundColor Green
        } else {
            Write-Host "Failed: $($res.error)" -ForegroundColor Red
        }
    }
}
