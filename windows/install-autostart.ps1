$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::UTF8

$Startup = [Environment]::GetFolderPath('Startup')
$Target = Join-Path $Startup 'GBF Local Cache.vbs'
$Command = 'wsl.exe -d Ubuntu-24.04 -- bash -lc "cd /home/axelhu/.openclaw/workspace-chatgpt-web-agent/projects/gbf-local-cache && ./bin/start.sh"'

$escaped = $Command.Replace('"', '""')
$content = @"
Set shell = CreateObject("WScript.Shell")
shell.Run "$escaped", 0, False
"@

Set-Content -LiteralPath $Target -Value $content -Encoding ASCII
Write-Host "Installed per-user silent startup: $Target"
