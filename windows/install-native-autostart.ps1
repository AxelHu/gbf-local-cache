param([string]$RepoPath)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::UTF8

if (-not $RepoPath) { $RepoPath = (Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath }
$resolvedRepo = Resolve-Path $RepoPath
$RepoPath = if ($resolvedRepo.ProviderPath) { $resolvedRepo.ProviderPath } else { $resolvedRepo.Path }
$startScript = Join-Path $RepoPath 'windows\start-native.ps1'
if (-not (Test-Path $startScript)) { throw "start-native.ps1 not found: $startScript" }

$startup = [Environment]::GetFolderPath('Startup')
$target = Join-Path $startup 'GBF Local Cache Native.vbs'
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$command = '"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}"' -f $ps, $startScript
$escaped = $command.Replace('"', '""')
@"
Set shell = CreateObject("WScript.Shell")
shell.Run "$escaped", 0, False
"@ | Set-Content -LiteralPath $target -Encoding ASCII
Write-Host "Installed native Windows startup: $target"
