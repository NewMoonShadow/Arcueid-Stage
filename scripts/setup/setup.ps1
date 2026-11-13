param([switch]$FetchVoiceEngine)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\common\paths.ps1')
$python = Get-StagePython
$venv = Join-Path $script:StageRoot 'runtime\python'
$venvPython = Join-Path $venv 'Scripts\python.exe'
if (-not (Test-Path -LiteralPath $venvPython)) {
    & $python -m venv $venv
    if ($LASTEXITCODE -ne 0) { throw 'Could not create Python 3.11 environment.' }
}
foreach ($name in @('core\requirements-runtime.txt','voice\proxy\service\requirements-runtime.txt')) {
    & $venvPython -m pip install -r (Join-Path $script:StageRoot $name)
    if ($LASTEXITCODE -ne 0) { throw 'Dependency installation failed.' }
}
if ($FetchVoiceEngine) {
    $lock = Get-Content -Raw (Join-Path $script:StageRoot 'dependencies\gpt-sovits.lock.json') | ConvertFrom-Json
    $engine = Get-StagePath 'engine'
    if (Test-Path -LiteralPath $engine) { throw 'Engine directory exists; no files were overwritten.' }
    & git clone --no-checkout $lock.repository $engine
    if ($LASTEXITCODE -ne 0) { throw 'Engine download failed.' }
    & git -C $engine checkout --detach $lock.commit
    if ($LASTEXITCODE -ne 0) { throw 'Pinned engine checkout failed.' }
}
Write-Host 'Core/proxy dependencies are ready. Restore external resources and set GODOT_PATH; see docs/SETUP.md.'
