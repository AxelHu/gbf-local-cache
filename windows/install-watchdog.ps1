param(
    [string]$Distro = '',
    [string]$RepoPath = '',
    [string]$LinuxUser = '',
    [int]$EveryMinutes = 5
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::UTF8

if ($EveryMinutes -lt 1) { throw 'EveryMinutes must be >= 1.' }

if ([string]::IsNullOrWhiteSpace($Distro)) {
    $Distro = (wsl.exe -l -q | Where-Object { $_.Trim() } | Select-Object -First 1).Trim()
}
if ([string]::IsNullOrWhiteSpace($Distro)) { throw 'No WSL distro found.' }

if ([string]::IsNullOrWhiteSpace($RepoPath)) {
    $winRepo = (Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath
    if ($winRepo -match '^\\\\wsl\.localhost\\[^\\]+(?<path>\\.*)$') {
        $RepoPath = $Matches.path.Replace('\', '/')
    } elseif ($winRepo -match '^\\\\wsl\$\\[^\\]+(?<path>\\.*)$') {
        $RepoPath = $Matches.path.Replace('\', '/')
    } else {
        throw 'RepoPath must be supplied when this script is not run from a WSL UNC checkout.'
    }
}

$RepoPath = $RepoPath.TrimEnd('/')
$taskName = 'GBF Local Cache Watchdog'
if ($RepoPath.Contains("'")) {
    throw "RepoPath containing a single quote is not supported by the watchdog launcher: $RepoPath"
}
if ($Distro -notmatch '^[A-Za-z0-9._-]+$') {
    throw "Unsupported WSL distro name for watchdog: $Distro"
}
if ([string]::IsNullOrWhiteSpace($LinuxUser)) {
    $LinuxUser = (& wsl.exe -d $Distro -u root -- sh -lc "stat -c %U '$RepoPath'" 2>$null).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($LinuxUser)) {
        throw "Could not determine the Linux owner of $RepoPath. Pass -LinuxUser explicitly."
    }
}
if ($LinuxUser -notmatch '^[A-Za-z0-9._-]+$') {
    throw "Unsupported Linux user name for watchdog: $LinuxUser"
}
$bashCommand = "cd '$RepoPath' && ./bin/start.sh >/dev/null 2>&1"
$arguments = "-d $Distro -u $LinuxUser -- bash -lc `"$bashCommand`""

$action = New-ScheduledTaskAction -Execute 'wsl.exe' -Argument $arguments
$logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$repeatTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes $EveryMinutes)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger @($logonTrigger, $repeatTrigger) -Settings $settings -Principal $principal -Force | Out-Null
Write-Host "Installed watchdog task: $taskName (logon + every $EveryMinutes minutes)"
Write-Host "WSL distro: $Distro"
Write-Host "Linux user: $LinuxUser"
Write-Host "Repo path: $RepoPath"
