# Re-evaluates a saved results.json with the current lib\Rules.ps1 (lib\ObserverRules.ps1 for meta.role "observer")
# and re-renders it with the current report-template.html. For checking rule or template changes without re-running
# the tests.
#   powershell -ExecutionPolicy Bypass -File tests\Render-Report.ps1 -Results results\<stamp>\results.json [-Out x.html] [-UpdateJson]
# -UpdateJson also writes the new verdict back into results.json, so it stays in step with report.html.
param(
    [Parameter(Mandatory = $true)][string]$Results,
    [string]$Out = '',
    [switch]$UpdateJson
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\Rules.ps1')
. (Join-Path $root 'lib\ObserverRules.ps1')

$config = [System.IO.File]::ReadAllText((Join-Path $root 'config.json'), [System.Text.Encoding]::UTF8) | ConvertFrom-Json
$r = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $Results).Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
if ((SRV_Str (SRV_Get $r 'meta', 'role')) -eq 'observer') {
    $r.verdict = Get-SRObserverVerdict -Config $config -Hardware $r.hardware -Sender $r.sender
}
else {
    $lan = $null
    if ($null -ne (SRV_Get $r 'lan')) { $lan = $r.lan }
    $r.verdict = Get-SRVerdict -Config $config -Hardware $r.hardware -Network $r.network -LoadTest $r.loadtest -Lan $lan
}

$json = ConvertTo-Json -InputObject $r -Depth 12
$evaluator = [System.Text.RegularExpressions.MatchEvaluator]{ param($m) '\u' + ([int][char]$m.Value[0]).ToString('x4') }
$json = [System.Text.RegularExpressions.Regex]::Replace($json, '[^\x00-\x7E]', $evaluator)

$tpl = [System.IO.File]::ReadAllText((Join-Path $root 'report-template.html'), [System.Text.Encoding]::UTF8)
$html = $tpl.Replace('/*__SHOWREADY_DATA__*/null', $json.Replace('</', '<\/'))
if ($Out -eq '') { $Out = Join-Path (Split-Path -Parent (Resolve-Path -LiteralPath $Results).Path) 'report.html' }
[System.IO.File]::WriteAllText($Out, $html, (New-Object System.Text.UTF8Encoding($false)))
if ($UpdateJson) { [System.IO.File]::WriteAllText((Resolve-Path -LiteralPath $Results).Path, $json, (New-Object System.Text.UTF8Encoding($false))) }
Write-Host ('overall ' + $r.verdict.overall + ' -> ' + $Out)
