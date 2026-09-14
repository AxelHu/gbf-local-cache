param(
    [Parameter(Mandatory = $true)]
    [string]$RepoPath,
    [string]$Distro = ''
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::UTF8

if ([string]::IsNullOrWhiteSpace($Distro)) {
    $Distro = (& wsl.exe -l -q | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1).Trim()
}
if ([string]::IsNullOrWhiteSpace($Distro)) {
    throw 'Could not determine a WSL distribution. Pass -Distro explicitly.'
}
if ([string]::IsNullOrWhiteSpace($RepoPath) -or -not $RepoPath.StartsWith('/')) {
    throw 'RepoPath must be an absolute Linux path inside WSL, for example /home/user/src/gbf-local-cache.'
}
if ($RepoPath.Contains("'")) {
    throw "RepoPath containing a single quote is not supported by this helper."
}

$Startup = [Environment]::GetFolderPath('Startup')
$Target = Join-Path $Startup 'GBF Local Cache.vbs'
$Command = "wsl.exe -d `"$Distro`" -- bash -lc `"cd '$RepoPath' && ./bin/start.sh`""

$escaped = $Command.Replace('"', '""')
$content = @"
Set shell = CreateObject("WScript.Shell")
shell.Run "$escaped", 0, False
"@

Set-Content -LiteralPath $Target -Value $content -Encoding ASCII
Write-Host "Installed per-user silent startup: $Target"
Write-Host "WSL distro: $Distro"
Write-Host "Repo path: $RepoPath"
