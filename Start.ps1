param([switch]$SkipVoice, [switch]$Editor, [switch]$CheckOnly, [switch]$VisibleServiceWindows)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'scripts\common\paths.ps1')
$python = Get-StagePython
& $python (Join-Path $PSScriptRoot 'scripts\check\assets.py')
if ($LASTEXITCODE -ne 0) { throw 'External resources are incomplete. See docs/ASSETS.md.' }
if ($CheckOnly) { return }
$godot = $env:GODOT_PATH
if (-not $godot) { $godot = Join-Path $PSScriptRoot 'runtime\godot\Godot_v4.7.2-stable_win64.exe' }
if (-not (Test-Path -LiteralPath $godot)) { throw 'Set GODOT_PATH to your Godot 4.7.2 executable. See docs/SETUP.md.' }
$env:APPDATA = Join-Path $PSScriptRoot 'userdata\appdata'
$env:LOCALAPPDATA = Join-Path $PSScriptRoot 'userdata\localappdata'
New-Item -ItemType Directory -Force -Path $env:APPDATA,$env:LOCALAPPDATA | Out-Null
& (Join-Path $PSScriptRoot 'scripts\launch\services.ps1') -SkipVoice:$SkipVoice -VisibleServiceWindows:$VisibleServiceWindows
$arguments = @('--path', (Join-Path $PSScriptRoot 'game\ArcueidStage'))
if ($Editor) { $arguments = @('--editor') + $arguments }
Start-Process -FilePath $godot -ArgumentList (Join-StageNativeArguments $arguments) -WorkingDirectory $PSScriptRoot -WindowStyle Normal
