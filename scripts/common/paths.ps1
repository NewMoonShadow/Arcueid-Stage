# Shared path-only configuration. Do not put API keys in paths.local.json.
$script:StageRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$script:StagePaths = @{
    engine = 'runtime\gpt-sovits'
    wsl_python = 'runtime\voice-venv\bin\python'
    wsl_distribution = 'Ubuntu'
    profiles = 'runtime\voice-profiles'
    references = 'models\references'
    python = 'runtime\python\Scripts\python.exe'
}
$stageLocalPaths = Join-Path $script:StageRoot 'runtime\paths.local.json'
if (Test-Path -LiteralPath $stageLocalPaths) {
    $stageOverrides = Get-Content -Raw -Encoding UTF8 -LiteralPath $stageLocalPaths | ConvertFrom-Json
    foreach ($property in $stageOverrides.PSObject.Properties) {
        if (-not $script:StagePaths.ContainsKey($property.Name)) { throw "Unknown runtime path: $($property.Name)" }
        $script:StagePaths[$property.Name] = [string]$property.Value
    }
}
function Get-StagePath([string]$Name) {
    $value = $script:StagePaths[$Name]
    if (-not $value) { throw "Unknown Stage path: $Name" }
    if ([IO.Path]::IsPathRooted($value)) { return [IO.Path]::GetFullPath($value) }
    return [IO.Path]::GetFullPath((Join-Path $script:StageRoot $value))
}
function ConvertTo-StageWslPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if ($full -notmatch '^[A-Za-z]:\\') { throw "WSL requires a local drive path: $full" }
    return '/mnt/{0}{1}' -f $full.Substring(0, 1).ToLowerInvariant(), $full.Substring(2).Replace('\', '/')
}
function Get-StagePython {
    $candidate = if ($env:ARCUEID_PYTHON) { $env:ARCUEID_PYTHON } else { Get-StagePath 'python' }
    if (-not (Test-Path -LiteralPath $candidate)) {
        $installed = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Programs\Python\Python311\python.exe'
        if (Test-Path -LiteralPath $installed) { $candidate = $installed }
        elseif (Get-Command py -ErrorAction SilentlyContinue) {
            $candidate = (& py -3.11 -c 'import sys; print(sys.executable)')
            if ($LASTEXITCODE -ne 0) { throw 'Python 3.11 is required. Set ARCUEID_PYTHON or run scripts\setup\setup.ps1.' }
        }
    }
    if (-not $candidate -or -not (Test-Path -LiteralPath $candidate)) { throw 'Python 3.11 was not found.' }
    $version = (& $candidate -c 'import sys; print(str(sys.version_info.major)+chr(46)+str(sys.version_info.minor))').Trim()
    if ($LASTEXITCODE -ne 0 -or $version -ne '3.11') { throw "Stage requires Python 3.11; found $version." }
    return $candidate
}
function Join-StageNativeArguments([string[]]$Values) {
    # Start-Process joins its array without preserving argument boundaries.
    return (($Values | ForEach-Object {
        if ($_ -match '[\s"]' -or $_ -eq '') { '"' + $_.Replace('"', '\"') + '"' }
        else { $_ }
    }) -join ' ')
}
