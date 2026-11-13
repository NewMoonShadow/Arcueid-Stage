param([switch]$DryRun)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\common\paths.ps1')
$identityFile = Join-Path $script:StageRoot '.runtime\services.json'
$identities = @{}
if (Test-Path -LiteralPath $identityFile) {
    $savedIdentities = Get-Content -Raw -LiteralPath $identityFile | ConvertFrom-Json
    foreach ($property in $savedIdentities.PSObject.Properties) { $identities[$property.Name] = $property.Value }
}
foreach ($service in @(@{Port=8765; Module='arcueid_core\.main'}, @{Port=8766; Module='service\.run_service'})) {
    $listeners = @(Get-NetTCPConnection -LocalPort $service.Port -State Listen -ErrorAction SilentlyContinue)
    foreach ($listener in $listeners) {
        $details = Get-CimInstance Win32_Process -Filter "ProcessId=$($listener.OwningProcess)" -ErrorAction SilentlyContinue
        $identity = $identities[[string]$service.Port]
        if (-not $details -or -not $identity -or $identity.pid -ne $listener.OwningProcess -or $details.ExecutablePath -ne $identity.executable -or
            $details.CreationDate.ToUniversalTime().Ticks.ToString() -ne $identity.created -or
            $details.CommandLine -notmatch ('(?:^|\s)-m\s+' + $service.Module + '(?:\s|$)')) {
            Write-Warning "Port $($service.Port) belongs to another process; leaving it running."
            continue
        }
        if ($DryRun) { Write-Host "[dry-run] Stop Stage service PID $($listener.OwningProcess)" }
        else { Stop-Process -Id $listener.OwningProcess -Force; Write-Host "Stopped Stage service port $($service.Port)" }
    }
}
& (Join-Path $script:StageRoot 'tools\stop_dual_voice_wsl.ps1') -DryRun:$DryRun
