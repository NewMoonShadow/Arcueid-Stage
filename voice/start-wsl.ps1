param(
    [ValidateSet('arcueid','neco_arc','ciel')][string]$Speaker,
    [switch]$ProfileOnly,
    [switch]$VisibleServiceWindows
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\scripts\common\paths.ps1')
$engine = Get-StagePath 'engine'
$profiles = Get-StagePath 'profiles'
$references = Get-StagePath 'references'
$wslEngine = ConvertTo-StageWslPath $engine
$wslPython = ConvertTo-StageWslPath (Get-StagePath 'wsl_python')
$wslReferences = ConvertTo-StageWslPath $references

# These environment variables are consumed by the canonical voice proxy.
$env:ARCUEID_ARCUEID_REF_AUDIO_PATH = "$wslReferences/arcueid.wav"
$env:ARCUEID_NECO_TTS_ENDPOINT = 'http://127.0.0.1:9881/tts'
$env:ARCUEID_NECO_REF_AUDIO_PATH = "$wslReferences/neco_arc.wav"
$env:ARCUEID_NECO_PROMPT_TEXT = 'ほうほう、やるもんですにゅう。'
$env:ARCUEID_CIEL_TTS_ENDPOINT = 'http://127.0.0.1:9882/tts'
$env:ARCUEID_CIEL_REF_AUDIO_PATH = "$wslReferences/ciel.wav"
$referenceFile = Join-Path $references 'ciel.json'
if (-not (Test-Path -LiteralPath $referenceFile)) { throw 'Missing models\references\ciel.json; see voice\README.md.' }
$reference = Get-Content -Raw -Encoding UTF8 -LiteralPath $referenceFile | ConvertFrom-Json
if ($reference.boundary_policy -ne 'full_original_utterance') { throw 'Ciel requires the accepted full-original reference.' }
$env:ARCUEID_CIEL_PROMPT_TEXT = $reference.text
if ($ProfileOnly) { return }
$hasher = [Security.Cryptography.SHA256]::Create()
try { $lockKey = [BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($script:StageRoot.ToLowerInvariant()))).Replace('-', '') }
finally { $hasher.Dispose() }
$startupMutex = [Threading.Mutex]::new($false, ('Local\ArcueidStageVoice' + $lockKey))
$startupOwned = $false
try {
    try { $startupOwned = $startupMutex.WaitOne(360000) }
    catch [Threading.AbandonedMutexException] { $startupOwned = $true }
    if (-not $startupOwned) { throw 'Another Stage voice startup is still in progress.' }
$python = Get-StagePython
& $python (Join-Path $script:StageRoot 'scripts\setup\prepare_voice_profiles.py')
if ($LASTEXITCODE -ne 0) { throw 'Voice dependencies are incomplete; see voice\README.md.' }
$voices = (Get-Content -Raw -Encoding UTF8 (Join-Path $PSScriptRoot 'profiles\voices.json') | ConvertFrom-Json).voices
if ($Speaker) { $voices = @($voices | Where-Object { $_.speaker -eq $Speaker }) }
$logs = Join-Path $script:StageRoot '.runtime'
New-Item -ItemType Directory -Force -Path $logs | Out-Null
foreach ($voice in $voices) {
    $port = [int]$voice.port
    if (Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue) {
        Write-Host "Reusing $($voice.speaker) on 127.0.0.1:$port"
        continue
    }
    $config = ConvertTo-StageWslPath (Join-Path $profiles ($voice.speaker + '.yaml'))
    $arguments = @('-d', $script:StagePaths.wsl_distribution, '--cd', $wslEngine, '--',
        '/usr/bin/env', 'PYTHONPATH=GPT_SoVITS:.', $wslPython, 'api_v2.py', '-a', '127.0.0.1', '-p', "$port", '-c', $config)
    $process = Start-Process -FilePath 'wsl.exe' -ArgumentList (Join-StageNativeArguments $arguments) `
        -WorkingDirectory $engine -WindowStyle $(if ($VisibleServiceWindows) { 'Normal' } else { 'Hidden' }) `
        -RedirectStandardOutput (Join-Path $logs ($voice.speaker + '_gsv.stdout.log')) `
        -RedirectStandardError (Join-Path $logs ($voice.speaker + '_gsv.stderr.log')) -PassThru
    $deadline = (Get-Date).AddSeconds(120)
    $ready = $false
    while ((Get-Date) -lt $deadline) {
        if (Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue) { $ready = $true; break }
        if ($process.HasExited) { throw "Voice process exited: $($voice.speaker); inspect .runtime logs locally." }
        Start-Sleep -Milliseconds 500
    }
    if (-not $ready) { throw "Voice did not become ready: $($voice.speaker) port $port" }
    Write-Host "$($voice.speaker) ready on 127.0.0.1:$port"
}
} finally {
    if ($startupOwned) { $startupMutex.ReleaseMutex() }
    $startupMutex.Dispose()
}
