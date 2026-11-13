param([switch]$SkipVoice, [switch]$VisibleServiceWindows)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\common\paths.ps1')
$python = Get-StagePython
$env:ARCUEID_PYTHON = $python
$logs = Join-Path $script:StageRoot '.runtime'
New-Item -ItemType Directory -Force -Path $logs | Out-Null
$identityFile = Join-Path $logs 'services.json'
$identities = @{}
if (Test-Path -LiteralPath $identityFile) {
    $savedIdentities = Get-Content -Raw -LiteralPath $identityFile | ConvertFrom-Json
    foreach ($property in $savedIdentities.PSObject.Properties) { $identities[$property.Name] = $property.Value }
}
if (-not $SkipVoice) {
    & (Join-Path $script:StageRoot 'voice\start-wsl.ps1') -VisibleServiceWindows:$VisibleServiceWindows
}
foreach ($service in @(@{Port=8765; Script='Run-Core.ps1'; Health='/api/v2/health'; Name='Core'},
                       @{Port=8766; Script='start_voice_proxy.ps1'; Health='/health'; Name='Proxy'})) {
    if ($SkipVoice -and $service.Port -eq 8766) { continue }
    $startedNow = $false
    if (-not (Get-NetTCPConnection -LocalPort $service.Port -State Listen -ErrorAction SilentlyContinue)) {
        $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $script:StageRoot $service.Script))
        Start-Process -FilePath 'powershell.exe' -ArgumentList (Join-StageNativeArguments $arguments) `
            -WorkingDirectory $script:StageRoot -WindowStyle $(if ($VisibleServiceWindows) { 'Normal' } else { 'Hidden' }) `
            -RedirectStandardOutput (Join-Path $logs ($service.Name + '.stdout.log')) `
            -RedirectStandardError (Join-Path $logs ($service.Name + '.stderr.log')) | Out-Null
        $startedNow = $true
    }
    $ready = $false
    $deadline = (Get-Date).AddSeconds(90)
    while ((Get-Date) -lt $deadline) {
        try {
            $health = Invoke-RestMethod -Uri ("http://127.0.0.1:" + $service.Port + $service.Health) -TimeoutSec 2
            if (($service.Port -eq 8765 -and $health.ok) -or ($service.Port -eq 8766 -and $health.status -eq 'ok')) { $ready = $true; break }
        } catch {}
        Start-Sleep -Milliseconds 500
    }
    if (-not $ready) { throw "$($service.Name) did not become healthy; inspect .runtime logs locally." }
    if ($startedNow) {
        $listener = Get-NetTCPConnection -LocalPort $service.Port -State Listen | Select-Object -First 1
        $details = Get-CimInstance Win32_Process -Filter "ProcessId=$($listener.OwningProcess)"
        $identities[[string]$service.Port] = @{ port=$service.Port; pid=$details.ProcessId; executable=$details.ExecutablePath; created=$details.CreationDate.ToUniversalTime().Ticks.ToString() }
        ConvertTo-Json -InputObject $identities -Depth 4 | Set-Content -Encoding UTF8 -LiteralPath $identityFile
    }
    Write-Host "$($service.Name) ready on 127.0.0.1:$($service.Port)"
}
