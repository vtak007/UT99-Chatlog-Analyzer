<#
.SYNOPSIS
    Registers a Windows Task Scheduler entry that runs UT99 ChatLog Analyzer daily.

.DESCRIPTION
    Creates a scheduled task named "UT99 Chat Monitor - Daily" that runs at the
    chosen local time, every day, in your current Windows user context (so it
    has access to the saved WinSCP session and the ANTHROPIC_API_KEY env var).

    By default the task is registered to "Run whether user is logged on or not"
    (LogonType Password, RunLevel Limited), so it still runs after an unattended
    reboot with nobody logged in. This requires your Windows password, which you
    are prompted for and which Task Scheduler stores. Use -InteractiveOnly for
    the old behavior (runs only while you are logged on; no password needed).
    The task runs at Limited (not elevated): the script lives in a user-writable
    folder, so running it at Highest would be a privilege-escalation path.
    Registering/replacing a task may need an elevated (Administrator) PowerShell.

.PARAMETER Time
    Local time to run, in HH:mm 24-hour format. Default 08:00.

.PARAMETER StartDate
    Optional date (yyyy-MM-dd) on which the daily trigger begins. Defaults to today.

.PARAMETER TaskName
    Name of the scheduled task. Default "UT99 Chat Monitor - Daily".

.PARAMETER InteractiveOnly
    Register the task to run only while the user is logged on (LogonType
    Interactive, RunLevel Limited). A run is skipped if nobody is logged in.

.PARAMETER Unregister
    Remove an existing task with this name.

.EXAMPLE
    .\Register-DailyTask.ps1 -Time 08:00 -StartDate 2026-06-09
#>
[CmdletBinding()]
param(
    [string] $Time      = '08:00',
    [string] $StartDate = '',
    [string] $TaskName  = 'UT99 Chat Monitor - Daily',
    [switch] $InteractiveOnly,
    [switch] $Unregister
)

$ErrorActionPreference = 'Stop'

if ($Unregister) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Task '$TaskName' removed." -ForegroundColor Green
    } else {
        Write-Host "No task named '$TaskName' found." -ForegroundColor Yellow
    }
    return
}

# Resolve script paths
$BinDir     = $PSScriptRoot
$MainScript = Join-Path $BinDir 'UT99 ChatLog Analyzer.ps1'
if (-not (Test-Path $MainScript)) { throw "Cannot find $MainScript" }

# Prefer the real pwsh.exe from known install locations; the Get-Command result
# can be a Windows Store app stub (AppData\Local\Microsoft\WindowsApps\pwsh.exe)
# that does not work in non-interactive Task Scheduler sessions.
$pwshCandidates = @(
    'C:\Program Files\PowerShell\7\pwsh.exe',
    'C:\Program Files\PowerShell\7-preview\pwsh.exe'
)
$pwsh = $pwshCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $pwsh) {
    $pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
    $pwsh = if ($pwshCmd -and $pwshCmd.Source -notlike '*WindowsApps*') { $pwshCmd.Source } else { 'powershell.exe' }
}

$argString = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $MainScript

$action    = New-ScheduledTaskAction  -Execute $pwsh -Argument $argString -WorkingDirectory $BinDir
$startDT   = if ($StartDate) {
    [datetime]::ParseExact("$StartDate $Time", 'yyyy-MM-dd HH:mm', $null)
} else {
    [datetime]::ParseExact($Time, 'HH:mm', $null)
}
$trigger   = New-ScheduledTaskTrigger -Daily -At $startDT
$settings  = New-ScheduledTaskSettingsSet `
                -StartWhenAvailable `
                -RunOnlyIfNetworkAvailable `
                -DontStopIfGoingOnBatteries `
                -AllowStartIfOnBatteries `
                -ExecutionTimeLimit (New-TimeSpan -Minutes 30) `
                -RestartCount 3 `
                -RestartInterval (New-TimeSpan -Minutes 15)

# Run as the current user so env vars and the saved WinSCP session are available.
# Default: run whether logged on or not (stored password) so a reboot with nobody
# logged in does not skip the run. -InteractiveOnly: only while logged on.
$userId = "$env:USERDOMAIN\$env:USERNAME"
if ($InteractiveOnly) {
    $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited
} else {
    # Ask BEFORE unregistering any existing task so cancelling leaves it intact.
    $cred = Get-Credential -UserName $userId -Message "Windows password for '$userId' (stored by Task Scheduler so the task can run when logged off)"
    if (-not $cred) { throw 'No credential supplied; nothing changed.' }
    $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Password -RunLevel Limited
}

$task = New-ScheduledTask -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
        -Description "Downloads UT99 server WebChatLog files, analyzes with Claude, generates a daily HTML dashboard."

# Replace existing (Register-ScheduledTask -Force overwrites in place, so a failed
# registration, e.g. a wrong password, does not leave you with no task at all).
if ($InteractiveOnly) {
    Register-ScheduledTask -TaskName $TaskName -InputObject $task -Force | Out-Null
} else {
    Register-ScheduledTask -TaskName $TaskName -InputObject $task -User $cred.UserName `
        -Password $cred.GetNetworkCredential().Password -Force | Out-Null
}

Write-Host ""
Write-Host "Task '$TaskName' registered." -ForegroundColor Green
Write-Host "  First run: $($startDT.ToString('yyyy-MM-dd')) at $Time"
Write-Host "  Runs daily thereafter at $Time"
Write-Host "  Uses: $pwsh"
Write-Host ("  Logon: " + $(if ($InteractiveOnly) { 'only while logged on (Interactive)' } else { 'whether logged on or not (Password, Limited)' }))
Write-Host "  Script: $MainScript"
Write-Host ""
Write-Host "To run it manually right now:"           -ForegroundColor Cyan
Write-Host "  Start-ScheduledTask -TaskName '$TaskName'" -ForegroundColor Gray
Write-Host ""
Write-Host "To remove it later:" -ForegroundColor Cyan
Write-Host "  .\Register-DailyTask.ps1 -Unregister"   -ForegroundColor Gray