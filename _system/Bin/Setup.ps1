<#
.SYNOPSIS
    Interactive first-time setup for UT99 Chat Monitor.

.DESCRIPTION
    Creates required folders, validates prerequisites, captures the
    Anthropic API key as a user-scoped environment variable, and runs
    a dry test (download only, no delete, no API call) so you can
    verify everything before scheduling.

.EXAMPLE
    cd D:\Dropbox\Gaming\UTLogs\WebChatLog\_system\bin
    .\Setup.ps1
#>
[CmdletBinding()]
param(
    [string] $ConfigPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'config.ps1')
)

$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$msg) Write-Host "`n--> $msg" -ForegroundColor Cyan }
function Write-OK   { param([string]$msg) Write-Host "    OK  $msg" -ForegroundColor Green }
function Write-Warn { param([string]$msg) Write-Host "    !!  $msg" -ForegroundColor Yellow }
function Write-Err  { param([string]$msg) Write-Host "    XX  $msg" -ForegroundColor Red }

Write-Host "================================================" -ForegroundColor Cyan
Write-Host "  UT99 Chat Monitor - Setup"                       -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan

# ---- 1. Load config ---------------------------------------------------------
Write-Step "Loading config from $ConfigPath"
if (-not (Test-Path $ConfigPath)) { Write-Err "Config file not found."; exit 1 }
$Config = & $ConfigPath
Write-OK "Config loaded."

# ---- 2. Create folders ------------------------------------------------------
Write-Step "Creating folder structure"
$folders = @(
    $Config.LocalLogFolder
    $Config.SystemFolder
    (Join-Path $Config.SystemFolder 'reports')
    (Join-Path $Config.SystemFolder 'state')
    (Join-Path $Config.SystemFolder 'runlogs')
)
foreach ($p in $folders) {
    if (-not (Test-Path $p)) {
        $null = New-Item -ItemType Directory -Force -Path $p
        Write-OK "Created $p"
    } else {
        Write-OK "Exists  $p"
    }
}

# ---- 3. Verify WinSCP -------------------------------------------------------
Write-Step "Checking WinSCP install"
if (-not (Test-Path $Config.WinSCPcomPath)) {
    Write-Err "WinSCP.com not found at $($Config.WinSCPcomPath)."
    Write-Host "    Download WinSCP 6.5.6 (or later) from https://winscp.net" -ForegroundColor Yellow
    Write-Host "    After install, edit config.ps1 and update WinSCPcomPath if needed." -ForegroundColor Yellow
    exit 1
}
# NOTE: Don't invoke "winscp.com /version" -- WinSCP.com doesn't recognize that
# switch and drops into interactive console mode, which hangs forever waiting
# for stdin. Read the version straight from the file's metadata instead.
try {
    $verInfo = (Get-Item $Config.WinSCPcomPath).VersionInfo
    $verText = if ($verInfo.ProductVersion) { $verInfo.ProductVersion } else { $verInfo.FileVersion }
    Write-OK "WinSCP found: $verText  ($($Config.WinSCPcomPath))"
} catch {
    Write-Warn "Found WinSCP at $($Config.WinSCPcomPath) but couldn't read version. Continuing."
}

# ---- 4. Verify saved session exists ----------------------------------------
Write-Step "Checking saved WinSCP session '$($Config.WinSCPSessionName)'"
# WinSCP stores sessions in HKCU\Software\Martin Prikryl\WinSCP 2\Sessions\<encoded name>
# (or in WinSCP.ini if portable). We probe by attempting a lightweight no-op script.

$probeScript = @(
    'option batch abort'
    'option confirm off'
    ('open "{0}"' -f $Config.WinSCPSessionName)
    'exit'
) -join "`r`n"

$tmp = Join-Path $env:TEMP ("ut99probe-{0}.wscp" -f (Get-Random))
Set-Content -Path $tmp -Value $probeScript -Encoding ASCII
Write-Host "    Attempting to open the session (this will connect briefly)..." -ForegroundColor Gray
# Use ONLY /script= (the temp file already contains "exit"). Combining
# /script= with /command= can cause WinSCP to wait for additional input.
$probeOut  = & $Config.WinSCPcomPath /script=$tmp /timeout=20 2>&1 | Out-String
$probeExit = $LASTEXITCODE
Remove-Item $tmp -Force -ErrorAction SilentlyContinue

if ($probeExit -eq 0) {
    Write-OK "Session '$($Config.WinSCPSessionName)' opened successfully."
} else {
    Write-Warn "Session probe exit code $probeExit. Output:"
    Write-Host $probeOut -ForegroundColor Gray
    Write-Warn "Continuing - verify the session name in WinSCP if the test run fails."
}

# ---- 5. API key -------------------------------------------------------------
Write-Step "Checking Anthropic API key"
$existing = [Environment]::GetEnvironmentVariable('ANTHROPIC_API_KEY', 'User')
if ($existing) {
    Write-OK ("ANTHROPIC_API_KEY already set (length {0})." -f $existing.Length)
    $resp = Read-Host "    Replace it? [y/N]"
    if ($resp -notmatch '^[yY]') {
        $env:ANTHROPIC_API_KEY = $existing
    } else {
        $existing = $null
    }
}

if (-not $existing) {
    Write-Host "    Get a key from https://console.anthropic.com/settings/keys" -ForegroundColor Yellow
    Write-Host "    Paste it below (it will not echo)." -ForegroundColor Yellow
    $secure = Read-Host "    API key" -AsSecureString
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
    if ([string]::IsNullOrWhiteSpace($plain)) {
        Write-Err "Empty key. Setup aborted."
        exit 1
    }
    [Environment]::SetEnvironmentVariable('ANTHROPIC_API_KEY', $plain, 'User')
    $env:ANTHROPIC_API_KEY = $plain
    Write-OK "API key stored as user environment variable ANTHROPIC_API_KEY."
}

# ---- 6. Smoke-test the API -------------------------------------------------
Write-Step "Smoke-testing the Anthropic API"
try {
    $body = @{
        model      = $Config.ApiModel
        max_tokens = 32
        messages   = @(@{ role = 'user'; content = 'Reply with exactly: OK' })
    } | ConvertTo-Json -Depth 6 -Compress
    $r = Invoke-RestMethod -Uri 'https://api.anthropic.com/v1/messages' -Method Post -Headers @{
        'x-api-key'         = $env:ANTHROPIC_API_KEY
        'anthropic-version' = '2023-06-01'
    } -Body $body -ContentType 'application/json; charset=utf-8'
    Write-OK ("API responded: '{0}'" -f $r.content[0].text.Trim())
} catch {
    Write-Err "API call failed: $($_.Exception.Message)"
    Write-Warn "Check that the key is valid and the model name '$($Config.ApiModel)' is current."
    exit 1
}

# ---- 7. Done ---------------------------------------------------------------
Write-Host ""
Write-Host "================================================" -ForegroundColor Green
Write-Host "  Setup complete."                                 -ForegroundColor Green
Write-Host "================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Run a safe dry test (no deletes, no API call):" -ForegroundColor White
Write-Host "       .\UT99-ChatMonitor.ps1 -NoDelete -NoAnalysis" -ForegroundColor Gray
Write-Host ""
Write-Host "  2. Run a full one-off (will delete from server if config says so):" -ForegroundColor White
Write-Host "       .\UT99-ChatMonitor.ps1" -ForegroundColor Gray
Write-Host ""
Write-Host "  3. When you're happy, install the daily Task Scheduler entry:" -ForegroundColor White
Write-Host "       .\Register-DailyTask.ps1" -ForegroundColor Gray
Write-Host ""