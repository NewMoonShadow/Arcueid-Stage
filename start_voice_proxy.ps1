Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "scripts\common\paths.ps1")
$voicePython = Get-StagePython
$serviceRoot = Join-Path $PSScriptRoot "voice/proxy"
if (-not (Test-Path (Join-Path $serviceRoot "service\config.json"))) {
    throw "Copy voice/proxy/service/config.example.json to service/config.json and configure it locally."
}
& (Join-Path $PSScriptRoot "voice\start-wsl.ps1") -ProfileOnly
Push-Location $serviceRoot
try { & $voicePython -m service.run_service }
finally { Pop-Location }
