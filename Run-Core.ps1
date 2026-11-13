Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'scripts\common\paths.ps1')
$python = Get-StagePython
$manifest = Join-Path $PSScriptRoot 'corpus\stage_index\manifest.json'
if (Test-Path -LiteralPath $manifest) {
    $metadata = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifest | ConvertFrom-Json
    if ($metadata.embedding -eq 'BAAI/bge-m3') { $env:ARCUEID_ENABLE_LOCAL_MODELS = '1' }
}
Push-Location (Join-Path $PSScriptRoot 'core')
try { & $python -m arcueid_core.main }
finally { Pop-Location }
