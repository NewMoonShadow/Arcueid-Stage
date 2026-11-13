param([switch]$DryRun)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    Write-Host "WSL is unavailable; skipping WSL voices."
    return
}
. (Join-Path $PSScriptRoot '..\scripts\common\paths.ps1')
$distribution = $script:StagePaths.wsl_distribution
$running = @(& wsl.exe --list --running --quiet 2>$null)
if ($LASTEXITCODE -ne 0) {
    Write-Warning "Could not inspect running WSL distributions."
    return
}
$names = @($running | ForEach-Object { $_.Replace([string][char]0, '').Trim() })
if ($names -notcontains $distribution) {
    Write-Host "Ubuntu is not running; no WSL voices to stop."
    return
}

$profileRoot = ConvertTo-StageWslPath (Get-StagePath 'profiles')
$settings = @{
    root = ConvertTo-StageWslPath (Get-StagePath 'engine')
    python = ConvertTo-StageWslPath (Get-StagePath 'wsl_python')
    configs = @{ '9880' = "$profileRoot/arcueid.yaml"; '9881' = "$profileRoot/neco_arc.yaml"; '9882' = "$profileRoot/ciel.yaml" }
    dry_run = [bool]$DryRun
} | ConvertTo-Json -Compress
$encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($settings))
Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'stop_dual_voice_wsl.py') |
    & wsl.exe -d $distribution --exec /usr/bin/python3 - $encoded
if ($LASTEXITCODE -ne 0) {
    Write-Warning "WSL voice stop failed; inspect the message above."
}
