param([Parameter(Mandatory)][uri]$StreamUrl)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$voices = (Get-Content -Raw -Encoding UTF8 (Join-Path $PSScriptRoot 'profiles\voices.json') | ConvertFrom-Json).voices
# Keep the Japanese lines readable by Windows PowerShell regardless of its script encoding.
$readyText = -join ([char[]]@(0x6E96, 0x5099, 0x3067, 0x304D, 0x305F, 0x3088, 0x3002))
$necoText = -join ([char[]]@(0x304A, 0x306F, 0x3088, 0x3046, 0x306B, 0x3083, 0x3002))

foreach ($voice in $voices) {
    $text = if ($voice.speaker -eq 'neco_arc') { $necoText } else { $readyText }
    $payload = @{ text = $text; model_id = $voice.model_id; bypass_cache = $true } | ConvertTo-Json -Compress
    $body = [System.Text.Encoding]::UTF8.GetBytes($payload)
    $maxAttempts = 3
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            $response = Invoke-WebRequest -Uri $StreamUrl -Method Post -UseBasicParsing `
                -ContentType 'application/json; charset=utf-8' -Body $body -TimeoutSec 120
            $header = New-Object byte[] 12
            $response.RawContentStream.Position = 0
            $read = $response.RawContentStream.Read($header, 0, $header.Length)
            if ($response.Headers['X-Arcueid-Cache'] -ne 'miss' -or $response.RawContentLength -le 44 -or
                $read -ne $header.Length -or [System.Text.Encoding]::ASCII.GetString($header, 0, 4) -ne 'RIFF' -or
                [System.Text.Encoding]::ASCII.GetString($header, 8, 4) -ne 'WAVE') {
                throw 'The proxy did not return fresh WAV audio.'
            }
            Write-Host "$($voice.speaker) voice warm-up completed"
            break
        } catch {
            $statusCode = 0
            if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }
            if ($statusCode -in @(502, 503, 504) -and $attempt -lt $maxAttempts) {
                Start-Sleep -Seconds (3 * $attempt)
                continue
            }
            Write-Warning "$($voice.speaker) voice warm-up failed: $($_.Exception.Message)"
            break
        }
    }
}
