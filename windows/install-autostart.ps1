param(
    [Parameter(Mandatory = $true)]
    [string]$RepoPath,
    [string]$Distro = '',
    [string]$LinuxUser = ''
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
if ($Distro -notmatch '^[A-Za-z0-9._-]+$') {
    throw "Unsupported WSL distro name for startup helper: $Distro"
}
if ([string]::IsNullOrWhiteSpace($LinuxUser)) {
    $LinuxUser = (& wsl.exe -d $Distro -u root -- sh -lc "stat -c %U '$RepoPath'" 2>$null).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($LinuxUser)) {
        throw "Could not determine the Linux owner of $RepoPath. Pass -LinuxUser explicitly."
    }
}
if ($LinuxUser -notmatch '^[A-Za-z0-9._-]+$') {
    throw "Unsupported Linux user name for startup helper: $LinuxUser"
}

$Startup = [Environment]::GetFolderPath('Startup')
$Target = Join-Path $Startup 'GBF Local Cache.vbs'
$Command = "wsl.exe -d $Distro -u $LinuxUser -- bash -lc `"cd '$RepoPath' && ./bin/start.sh`""

$escaped = $Command.Replace('"', '""')
$content = @"
Set shell = CreateObject("WScript.Shell")
shell.Run "$escaped", 0, False
"@

Set-Content -LiteralPath $Target -Value $content -Encoding ASCII
Write-Host "Installed per-user silent startup: $Target"
Write-Host "WSL distro: $Distro"
Write-Host "Linux user: $LinuxUser"
Write-Host "Repo path: $RepoPath"
