<#
.SYNOPSIS
    UT99 Chat Monitor - downloads WebChatLog files from a UT99 server,
    analyzes them with Claude, and produces an HTML dashboard.

.DESCRIPTION
    Designed to run unattended on a daily schedule via Windows Task Scheduler,
    or interactively from a PowerShell prompt.

    Workflow:
        1. Connect to the FTP/SFTP server via WinSCP using the saved session.
        2. Download new .log files (skipping any modified within the last
           60 minutes - those are likely still being written by the mod).
        3. Verify each file landed locally, then optionally delete it from
           the server.
        4. Parse all newly-downloaded logs using the WebChatLog tab format.
        5. Filter to the last N hours of Say / TeamSay lines.
        6. Send to Claude (claude-sonnet-4-6) for categorization into
           complaints / issues / compliments / requests / notable.
        7. Render an HTML dashboard with quotes, timestamps, and stats.

.PARAMETER ConfigPath
    Path to config.ps1. Defaults to ..\config.ps1 next to this script.

.PARAMETER NoFetch
    Skip the server fetch step. Use when reprocessing logs already on disk.

.PARAMETER NoDelete
    Download files but never delete from server (overrides config).
    Useful for first runs while you verify everything works.

.PARAMETER NoAnalysis
    Skip the Claude API call. Produces a basic report from local data only.
    Useful for testing parsing without spending API credits.

.PARAMETER Date
    Generate a report for a specific date (yyyy-MM-dd). Default: yesterday.

.EXAMPLE
    .\UT99-ChatMonitor.ps1
    # Normal scheduled run.

.EXAMPLE
    .\UT99-ChatMonitor.ps1 -NoDelete -NoAnalysis
    # Safe first-run dry test: pulls files but leaves server alone, no API call.

.EXAMPLE
    .\UT99-ChatMonitor.ps1 -NoFetch -Date '2026-04-30'
    # Re-generate yesterday's report from local logs without touching server.
#>
[CmdletBinding()]
param(
    [string]   $ConfigPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'config.ps1'),
    [switch]   $NoFetch,
    [switch]   $NoDelete,
    [switch]   $NoAnalysis,
    [switch]   $ClearWeekly,
    [datetime] $Date
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# ========================================================================== #
#  Bootstrap                                                                  #
# ========================================================================== #

if (-not (Test-Path $ConfigPath)) {
    throw "Config file not found at $ConfigPath. Run Setup.ps1 or edit config.ps1 first."
}
$Config = & $ConfigPath

# Resolve key paths
$LogFolder    = $Config.LocalLogFolder
$SystemFolder = $Config.SystemFolder
$ReportFolder = Join-Path $SystemFolder 'reports'
$StateFolder  = Join-Path $SystemFolder 'state'
$RunLogFolder = Join-Path $SystemFolder 'runlogs'

foreach ($p in @($LogFolder, $SystemFolder, $ReportFolder, $StateFolder, $RunLogFolder)) {
    if (-not (Test-Path $p)) { $null = New-Item -ItemType Directory -Force -Path $p }
}

$ExcludedBots   = @('Assphyxiation', 'DyslexicFotherMucker')
$WeeklyWinsFile = Join-Path $StateFolder 'weekly-wins.json'

# Run logger
$RunStarted = Get-Date
$RunLogFile = Join-Path $RunLogFolder ("run-" + $RunStarted.ToString('yyyy-MM-dd-HHmmss') + ".log")

function Write-RunLog {
    param([string]$Level = 'INFO', [string]$Message)
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line = "[$ts] [$Level] $Message"
    Add-Content -Path $RunLogFile -Value $line
    if ($Level -eq 'ERROR') { Write-Host $line -ForegroundColor Red }
    elseif ($Level -eq 'WARN')  { Write-Host $line -ForegroundColor Yellow }
    else { Write-Host $line }
}

Write-RunLog INFO "UT99 Chat Monitor starting (PID $PID)"
Write-RunLog INFO "Config: $ConfigPath"
Write-RunLog INFO "Local log folder: $LogFolder"
Write-RunLog INFO "Report folder:    $ReportFolder"

# Window of interest -- driven by Config.ReportMode unless -Date overrides it.
#   'Rolling'             -> last N hours ending at the moment the script runs
#                            (catches overnight/early-morning chat in same-day report).
#   'PreviousCalendarDay' -> yesterday midnight to midnight (legacy, no overlap).
# Passing -Date always means "the calendar day specified" regardless of mode.
$mode = if ($Config.ReportMode) { $Config.ReportMode } else { 'Rolling' }

if ($Date) {
    # Manual override: a specific calendar date, midnight to midnight.
    $WindowEnd    = $Date.Date.AddDays(1)
    $WindowStart  = $Date.Date
    $reportLabel  = $Date.Date
    $modeLabelLog = ('Manual -Date {0:yyyy-MM-dd}' -f $Date)
}
elseif ($mode -eq 'PreviousCalendarDay') {
    $yesterday    = (Get-Date).Date.AddDays(-1)
    $WindowEnd    = $yesterday.AddDays(1)
    $WindowStart  = $WindowEnd.AddHours(-1 * $Config.ReportWindowHours)
    $reportLabel  = $yesterday
    $modeLabelLog = 'PreviousCalendarDay'
}
else {
    # Default: rolling window ending NOW. Captures overnight chat in same-day report.
    $WindowEnd    = Get-Date
    $WindowStart  = $WindowEnd.AddHours(-1 * $Config.ReportWindowHours)
    $reportLabel  = $WindowEnd.Date     # name the report by the day it was generated
    $modeLabelLog = 'Rolling'
}
Write-RunLog INFO ("Report window ({0}): {1:yyyy-MM-dd HH:mm} to {2:yyyy-MM-dd HH:mm}" -f $modeLabelLog, $WindowStart, $WindowEnd)

# ========================================================================== #
#  Step 1 - Fetch logs from server via WinSCP                                 #
# ========================================================================== #

function Invoke-ServerFetch {
    if ($NoFetch) {
        Write-RunLog INFO "Skipping fetch (-NoFetch)."
        return
    }

    if (-not (Test-Path $Config.WinSCPcomPath)) {
        throw "WinSCP.com not found at $($Config.WinSCPcomPath). Install WinSCP 6.5+ or update WinSCPcomPath in config.ps1."
    }

    $bufferMin = [int]$Config.ActiveFileBufferMinutes
    $deleteOnGet = $Config.DeleteAfterDownload -and (-not $NoDelete)
    $deleteFlag = if ($deleteOnGet) { '-delete ' } else { '' }

    # WinSCP filemask: only files older than $bufferMin minutes (likely already
    # rotated by the mod, safe to download/delete). WinSCP semantics:
    #   >=60N = modified WITHIN the last 60 minutes (the active log - DO NOT touch)
    #   <60N  = modified more than 60 minutes ago (older logs - safe targets)
    # Time units: Y=years M=months D=days H=hours N=miNutes S=seconds.
    $fileMask = ('{0}<{1}N' -f $Config.RemoteLogPattern, $bufferMin)

    # Build WinSCP script
    $localTarget = $LogFolder.TrimEnd('\') + '\'
    $remoteFolder = $Config.RemoteLogFolder
    if (-not $remoteFolder.EndsWith('/')) { $remoteFolder += '/' }

    $wscpLines = @(
        'option batch abort'
        'option confirm off'
        'option transfer binary'
        'option reconnecttime 30'
        ('open "{0}"' -f $Config.WinSCPSessionName)
        ('cd "{0}"'   -f $remoteFolder)
        ('get {0}-filemask="{1}" * "{2}*"' -f $deleteFlag, $fileMask, $localTarget)
        'exit'
    )
    $wscpScript = $wscpLines -join "`r`n"

    $tempScript  = Join-Path $env:TEMP ("ut99fetch-{0}.wscp" -f (Get-Date -Format 'yyyyMMddHHmmss'))
    $wscpXmlLog  = Join-Path $StateFolder ("winscp-{0}.xml" -f (Get-Date -Format 'yyyy-MM-dd-HHmmss'))
    Set-Content -Path $tempScript -Value $wscpScript -Encoding ASCII

    Write-RunLog INFO ("Fetching {0} from server (delete={1}, buffer={2}m)" -f $fileMask, $deleteOnGet, $bufferMin)

    $stdout = & $Config.WinSCPcomPath /script=$tempScript /xmllog=$wscpXmlLog /xmlgroups 2>&1 | Out-String
    $exit = $LASTEXITCODE
    Remove-Item $tempScript -Force -ErrorAction SilentlyContinue

    Add-Content -Path $RunLogFile -Value "----- WinSCP stdout -----"
    Add-Content -Path $RunLogFile -Value $stdout
    Add-Content -Path $RunLogFile -Value "----- end WinSCP stdout -----"

    if ($exit -ne 0) {
        Write-RunLog ERROR "WinSCP exit code $exit. See $wscpXmlLog and run log for details."
        throw "WinSCP fetch failed (exit $exit)."
    }

    Write-RunLog INFO "Fetch completed."
}

function Invoke-ReportUpload {
    param([Parameter(Mandatory)] [string] $ReportPath)

    if (-not $Config.UploadReport) {
        Write-RunLog INFO "Skipping report upload (UploadReport=false in config)."
        return
    }

    if (-not (Test-Path $Config.WinSCPcomPath)) {
        Write-RunLog WARN "WinSCP.com not found at $($Config.WinSCPcomPath) - skipping report upload."
        return
    }

    $remoteFolder = $Config.ReportUploadFolder
    if (-not $remoteFolder.EndsWith('/')) { $remoteFolder += '/' }

    $wscpLines = @(
        'option batch abort'
        'option confirm off'
        'option transfer binary'
        'option reconnecttime 30'
        ('open "{0}"' -f $Config.WinSCPSessionName)
        ('cd "{0}"'   -f $remoteFolder)
        ('put "{0}"'  -f $ReportPath)
        'exit'
    )
    $wscpScript = $wscpLines -join "`r`n"

    $tempScript = Join-Path $env:TEMP ("ut99upload-{0}.wscp" -f (Get-Date -Format 'yyyyMMddHHmmss'))
    $wscpXmlLog = Join-Path $StateFolder ("winscp-upload-{0}.xml" -f (Get-Date -Format 'yyyy-MM-dd-HHmmss'))
    Set-Content -Path $tempScript -Value $wscpScript -Encoding ASCII

    Write-RunLog INFO ("Uploading report to {0}..." -f $remoteFolder)

    $stdout = & $Config.WinSCPcomPath /script=$tempScript /xmllog=$wscpXmlLog /xmlgroups 2>&1 | Out-String
    $exit = $LASTEXITCODE
    Remove-Item $tempScript -Force -ErrorAction SilentlyContinue

    Add-Content -Path $RunLogFile -Value "----- WinSCP upload stdout -----"
    Add-Content -Path $RunLogFile -Value $stdout
    Add-Content -Path $RunLogFile -Value "----- end WinSCP upload stdout -----"

    if ($exit -ne 0) {
        Write-RunLog WARN ("Report upload failed (WinSCP exit {0}). See {1} for details." -f $exit, $wscpXmlLog)
    } else {
        Write-RunLog INFO ("Report uploaded: {0}{1}" -f $remoteFolder, (Split-Path $ReportPath -Leaf))
    }
}

# ========================================================================== #
#  Step 2 - Parse WebChatLog files                                            #
# ========================================================================== #

function ConvertFrom-WebChatLog {
    <#
        Parses a WebChatLog .htm file directly. The format is one <tr> per chat row,
        with exactly four <td> cells: DateTime, Type, PlayerName, Message.
        Empty PlayerName cells use &nbsp;. Player names are wrapped in <font color=...>.
        The Game Summary appears as a single <tr> with <td colspan=4> wrapping a
        nested table -- we identify and skip those rows.
    #>
    param([Parameter(Mandatory)] [string] $Path)

    $records    = New-Object System.Collections.Generic.List[object]
    $sourceName = Split-Path $Path -Leaf
    $invariant  = [System.Globalization.CultureInfo]::InvariantCulture

    $formats = @(
        'MM/dd/yyyy HH:mm:ss', 'MM/dd/yyyy HH:mm',
        'M/d/yyyy HH:mm:ss',   'M/d/yyyy HH:mm',
        'yyyy-MM-dd HH:mm:ss', 'yyyy-MM-dd HH:mm'
    )

    # Read the whole file as one string -- WebChatLog HTML can have multiple
    # rows per line and the head/banner sharing line 1 with the first row.
    $html = Get-Content -Path $Path -Raw -Encoding UTF8
    if (-not $html) { return $records }

    # Match every <tr ...>...</tr> block, case-insensitive, dot matches newlines.
    $rowRegex  = [regex]::new('<tr[^>]*>(.*?)</tr>',     'IgnoreCase, Singleline')
    $cellRegex = [regex]::new('<td[^>]*>(.*?)</td>',     'IgnoreCase, Singleline')

    foreach ($rowMatch in $rowRegex.Matches($html)) {
        $row = $rowMatch.Groups[1].Value

        # Skip header row (<th> column titles).
        if ($row -match '<th\b') { continue }

        # Skip the Game Summary block: a single row whose <td> spans 4 columns
        # and contains a nested table.
        if ($row -match '<td[^>]*\bcolspan\b') { continue }

        $cells = @($cellRegex.Matches($row))
        if ($cells.Count -lt 4) { continue }

        $rawDate = $cells[0].Groups[1].Value.Trim()
        $type    = $cells[1].Groups[1].Value.Trim()
        $player  = $cells[2].Groups[1].Value
        $message = $cells[3].Groups[1].Value

        # Strip <font color=...>...</font> wrapper from the player cell.
        $player = ($player -replace '<font[^>]*>', '' -replace '</font>', '').Trim()
        if ($player -eq '&nbsp;') { $player = '' }
        $player  = [System.Net.WebUtility]::HtmlDecode($player)
        $message = [System.Net.WebUtility]::HtmlDecode($message).Trim()

        # Parse date.
        $parsed = $null
        foreach ($fmt in $formats) {
            try {
                $parsed = [DateTime]::ParseExact($rawDate, $fmt, $invariant)
                break
            } catch { }
        }
        if (-not $parsed) { continue }

        $records.Add([pscustomobject]@{
            Timestamp  = $parsed
            Type       = $type
            Player     = $player
            Message    = $message
            SourceFile = $sourceName
        })
    }

    return $records
}

# ========================================================================== #
#  Step 2.5 - Deterministic contact-info / link / IP detection                #
# ========================================================================== #

function Find-ContactPatterns {
    <#
        Scans Say / TeamSay messages for emails, URLs, phone numbers, and
        IP[:port] addresses. Independent of the LLM call so detection is
        guaranteed even if Claude misses something.
        Returns a list of [pscustomobject] findings.
    #>
    param([AllowNull()][AllowEmptyCollection()] $Records)

    $findings = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Records -or $Records.Count -eq 0) { return $findings }

    # Common gaming/general TLDs we care about. Anything else (e.g. .biz)
    # still gets caught if the URL has http://, https://, ftp:// or www. prefix.
    $tldList = 'com|net|org|io|gg|tv|me|info|co|us|uk|de|fr|es|it|jp|cn|ru|br|ca|au|in|gov|edu|to|cc|ly|live|stream|xyz|chat|gaming'

    $patterns = [ordered]@{
        Email = '[A-Za-z0-9._+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+'
        URL   = '(?:(?:https?|ftp)://|www\.)\S+|\b[a-z0-9-]+(?:\.[a-z0-9-]+)*\.(?:' + $tldList + ')\b(?:/\S*)?'
        Phone = '\b(?:\+?\d{1,3}[-.\s]?)?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}\b'
        IP    = '\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}(?::\d{2,5})?\b'
    }

    foreach ($r in $Records) {
        if ($r.Type -notin @('Say', 'TeamSay')) { continue }
        $msg = [string]$r.Message
        if ([string]::IsNullOrWhiteSpace($msg)) { continue }

        foreach ($kind in $patterns.Keys) {
            $rx = [regex]::new($patterns[$kind], 'IgnoreCase')
            foreach ($m in $rx.Matches($msg)) {
                # Skip URL pattern when the match is purely numeric (let IP catch it).
                if ($kind -eq 'URL' -and $m.Value -match '^\d+(\.\d+)*(:\d+)?$') { continue }
                $findings.Add([pscustomobject]@{
                    Kind      = $kind
                    Match     = $m.Value
                    Player    = $r.Player
                    Timestamp = $r.Timestamp
                    Message   = $msg
                })
            }
        }
    }
    return $findings
}

# ========================================================================== #
#  Step 2.7 - Noise filter                                                    #
# ========================================================================== #

function Test-ChatNoise {
    <#
        Returns $true for Say messages that carry no useful signal for the admin:
        - GG variants  (gg, ggs, tgg, good game, ...)
        - LOL variants (lol, lmao, haha, xd, ...)
        - Greetings    (hi, hey, hello, yo, sup, wsp, howdy, hola, ...)
    #>
    param([string]$Message)

    # Normalise: lowercase, strip punctuation, collapse whitespace.
    $m = $Message.Trim().ToLower() `
         -replace "[!.,?;:\-\*\[\](){}/\\^~``'`"]", '' `
         -replace '\s+', ' '
    $m = $m.Trim()

    if ($m.Length -eq 0) { return $true }

    # GG variants: gg, ggg, ggs, tgg, tggs, good game [all|everyone|guys]
    if ($m -match '^t?g{2,}s?$')                                    { return $true }
    if ($m -match '^good\s+games?(\s+(all|everyone|guys|wp))?$')    { return $true }

    # LOL / laugh variants
    if ($m -match '^l+o+l+o*$')                                     { return $true }
    if ($m -match '^(lmao|lmfao|rofl|haha+|hehe+|hihi+|xd+)$')     { return $true }

    # Greetings - base words and common expansions with audience suffix
    $greetBase = 'hi|hey|hello|yo|sup|wsp|howdy|hola|heya|hai|wassup|salut'
    $audience  = '(\s+(all|everyone|guys|people|fellas|team))?'
    if ($m -match "^($greetBase)$audience$")                        { return $true }
    if ($m -match '^(whats?|what is)\s+up$')                        { return $true }

    return $false
}
# ========================================================================== #
#  Step 3 - Claude API analysis                                               #
# ========================================================================== #

function Invoke-ChatAnalysis {
    param(
        [AllowNull()][AllowEmptyCollection()] $SayRecords,
        [Parameter(Mandatory)] [string] $ApiKey,
        [string] $Model     = 'claude-sonnet-4-6',
        [int]    $MaxTokens = 8192,
        [int]    $WindowHours = 24
    )

    if ($null -eq $SayRecords) { $SayRecords = @() }
    if ($SayRecords.Count -eq 0) {
        return [pscustomobject]@{
            summary     = 'No chat messages in this period.'
            complaints  = @()
            issues      = @()
            requests    = @()
            compliments = @()
            notable     = @()
            toxicity    = @()
            contact     = @()
            strategy    = @()
            social      = @()
            stats       = [pscustomobject]@{
                total_say_lines = 0
                unique_players  = 0
                top_chatters    = @()
            }
        }
    }

    $chatText = ($SayRecords | ForEach-Object {
        '[{0}] {1}: {2}' -f $_.Timestamp.ToString('MM/dd HH:mm'), $_.Player, $_.Message
    }) -join "`n"

    $systemPrompt = @"
You are an analyst reviewing chat logs from an Unreal Tournament 1999 game server.
Your job is to identify items the server admin should pay attention to.

Categorize each notable line into ONE OR MORE of the nine categories below.
For every item include a severity level and the matching subcategory code.

CATEGORIES AND SUBCATEGORIES:

1. complaints  - Frustration, dissatisfaction, balance complaints, emotional venting
   1.1 Gameplay Frustration   - weapon/map hatred, balance rants, "dumb server", unfair mechanics
   1.2 Performance Complaints - lag, hitreg/noreg failures, "im shooting at air", newnet issues
   1.3 Self-Deprecation       - "i suck", "fuck im old", skill frustration (usually harmless)

2. issues      - Technical or server problems the admin should investigate
   2.1 Disconnects/Connectivity - getting dropped, kicked, failing to join, "did u get disconnected"
   2.2 Performance/Lag          - lag spikes, combo noreg, newnet artifacts, tickrate
   2.3 Client/System Problems   - audio issues, client crashes, "pc is ass"

3. requests    - Players asking for something to be done or wanting to participate
   3.1 Gameplay Requests      - "lets do 2v2", map vote requests, game mode changes
   3.2 Technical Assistance   - "can you help me test new version", config help
   3.3 Rescue/Stuck           - "help", "i am in the pit", map exploit/stuck locations

4. compliments - Positive feedback, praise, sportsmanship
   4.1 Skill Praise       - complimenting another player's performance
   4.2 Positive Reactions - "nice", "N1", "great map", admin/server praise

5. notable     - Admin-priority events: cheating, anomalies, disruption
   5.1 Cheating/Aimbot Accusations - direct accusation of cheating or using aimbot (HIGH priority)
   5.2 Abnormal Gameplay           - "how did u know", surviving impossible damage, wallhack suspicion
   5.3 Trolling/Disruption         - griefing accusations, team disruption, targeted harassment

6. contact     - Server advertising, recruitment, contact sharing beyond raw URLs/IPs
   6.1 Server Promotion    - "unreal://...", "add to your favs", redirecting players elsewhere
   6.2 Recruitment/Invites - inviting to clans, Discord servers, other communities

7. strategy    - Gameplay instruction, tactics, coaching, mentoring another player
   7.1 Tactical Advice     - map callouts, weapon tips, positioning, "get in their face"
   7.2 Training/Mentorship - coaching newer players, "keep practicing with it"

8. social      - Substantive community chatter that measures engagement (NOT trivial greetings)
   8.1 Casual Conversation  - friendly banter beyond single-word replies
   8.2 Real-Life Discussion - personal topics, "Mother's day stuff", "date night with the wifey"

9. toxicity    - Hostile language, insults, slurs, explicit/adult content
   9.1 Mild Toxicity        - profanity, mild insults, trash talk, "damn u"
   9.2 Explicit/Adult       - sexual content, graphic language, hate speech, slurs (CRITICAL)

SEVERITY LEVELS:
- LOW      Normal chatter, single minor complaint, casual banter
- MEDIUM   Repeated pattern, moderate issue, mild trash talk
- HIGH     Serious tech issue, cheating accusation, aggressive language
- CRITICAL Threats, doxxing, slurs, targeted harassment

RULES:
- Trivial GG / LOL / hi messages have already been pre-filtered - skip any that slip through
- A message CAN appear in multiple categories if it genuinely fits more than one
- Category 8 (social): only flag substantive conversation or real-life topics, not one-liners
- Category 6 (contact): raw URLs and IPs are caught by a separate regex pass - flag only context-meaningful promotion/recruitment
- Be conservative: don't flag generic chat. Only flag real signal.

Output ONLY a single JSON object. No prose, no markdown fences. Schema:
{
  "summary": "2-3 sentence overview of what happened",
  "complaints":  [{"timestamp":"MM/dd HH:mm","player":"name","message":"verbatim","why":"short reason","severity":"LOW","subcategory":"1.1"}],
  "issues":      [{"timestamp":"MM/dd HH:mm","player":"name","message":"verbatim","why":"short reason","severity":"MEDIUM","subcategory":"2.1"}],
  "requests":    [{"timestamp":"MM/dd HH:mm","player":"name","message":"verbatim","why":"short reason","severity":"LOW","subcategory":"3.1"}],
  "compliments": [{"timestamp":"MM/dd HH:mm","player":"name","message":"verbatim","why":"short reason","severity":"LOW","subcategory":"4.1"}],
  "notable":     [{"timestamp":"MM/dd HH:mm","player":"name","message":"verbatim","why":"short reason","severity":"HIGH","subcategory":"5.1"}],
  "toxicity":    [{"timestamp":"MM/dd HH:mm","player":"name","message":"verbatim","why":"short reason","severity":"HIGH","subcategory":"9.1"}],
  "contact":     [{"timestamp":"MM/dd HH:mm","player":"name","message":"verbatim","why":"short reason","severity":"MEDIUM","subcategory":"6.1"}],
  "strategy":    [{"timestamp":"MM/dd HH:mm","player":"name","message":"verbatim","why":"short reason","severity":"LOW","subcategory":"7.1"}],
  "social":      [{"timestamp":"MM/dd HH:mm","player":"name","message":"verbatim","why":"short reason","severity":"LOW","subcategory":"8.2"}],
  "stats": {
    "total_say_lines": <int>,
    "unique_players": <int>,
    "top_chatters": [{"player":"name","count":<int>}]
  }
}
If a category has nothing, return an empty array.
"@

    $computedUnique = ($SayRecords | Select-Object -ExpandProperty Player -Unique | Where-Object { $_ }).Count
    $userPrompt = "Server chat from the last $WindowHours hours.`nPre-computed stats (use these exact values in your stats output): $($SayRecords.Count) Say lines, $computedUnique unique chatting players.`nReturn only the JSON.`n`n$chatText"

    $body = @{
        model      = $Model
        max_tokens = $MaxTokens
        system     = $systemPrompt
        messages   = @(@{ role = 'user'; content = $userPrompt })
    } | ConvertTo-Json -Depth 12 -Compress

    Write-RunLog INFO ("Calling Anthropic API ({0}, {1} chat lines)..." -f $Model, $SayRecords.Count)

    $headers = @{
        'x-api-key'         = $ApiKey
        'anthropic-version' = '2023-06-01'
    }

    $response = Invoke-RestMethod `
        -Uri 'https://api.anthropic.com/v1/messages' `
        -Method Post -Headers $headers `
        -Body $body -ContentType 'application/json; charset=utf-8'

    $text = $response.content[0].text
    # Strip code fences if any
    $text = $text -replace '(?s)^\s*```(?:json)?\s*', '' -replace '(?s)\s*```\s*$', ''

    try {
        return ($text | ConvertFrom-Json)
    } catch {
        Write-RunLog ERROR "Failed to parse Claude response as JSON. Raw text saved to state."
        $rawPath = Join-Path $StateFolder ("api-raw-{0}.txt" -f (Get-Date -Format 'yyyy-MM-dd-HHmmss'))
        Set-Content -Path $rawPath -Value $text -Encoding UTF8
        throw
    }
}

# ========================================================================== #
#  Step 3.5 - Game Summary extraction (maps played per player)                #
# ========================================================================== #

function Get-MatchPlayerRecords {
    <#
        Scans a WebChatLog .htm file for Game Summary blocks and emits one
        Type='MatchPlayer' record per player per map.  Player=name, Message=map.
        Used to count how many distinct maps each joining player actually played.
    #>
    param([Parameter(Mandatory)] [string] $Path)

    $records    = New-Object System.Collections.Generic.List[object]
    $sourceName = Split-Path $Path -Leaf
    $html       = Get-Content -Path $Path -Raw -Encoding UTF8
    if (-not $html) { return $records }
    $invariant  = [System.Globalization.CultureInfo]::InvariantCulture

    $formats = @(
        'MM/dd/yyyy HH:mm:ss', 'MM/dd/yyyy HH:mm',
        'M/d/yyyy HH:mm:ss',   'M/d/yyyy HH:mm',
        'yyyy-MM-dd HH:mm:ss', 'yyyy-MM-dd HH:mm'
    )

    # Build ordered list of (character position, parsed datetime) for every
    # timestamp cell in the outer table so we can find the "last timestamp
    # before the Game Summary block" for accurate window filtering.
    $tsRegex  = [regex]::new('<td>(\d{1,2}/\d{1,2}/\d{4}\s+\d{2}:\d{2}(?::\d{2})?)</td>', 'IgnoreCase')
    $tsPosMap = New-Object System.Collections.Generic.List[object]
    foreach ($m in $tsRegex.Matches($html)) {
        $parsed = $null
        foreach ($fmt in $formats) {
            try { $parsed = [DateTime]::ParseExact($m.Groups[1].Value.Trim(), $fmt, $invariant); break } catch { }
        }
        if ($parsed) { $tsPosMap.Add([pscustomobject]@{ Pos = $m.Index; TS = $parsed }) }
    }
    if ($tsPosMap.Count -eq 0) { return $records }

    # Match each Game Summary block:  <td colspan=4>...Game Summary...</ table></td>
    $blockRegex     = [regex]::new('<td[^>]+colspan[^>]*>(.*?Game\s+Summary.*?</table>\s*</td>)', 'IgnoreCase, Singleline')
    $mapNameRegex   = [regex]::new('MapName\s*=\s*([^<]+)',                                       'IgnoreCase')
    # Player data rows: <tr><td>Name</td><td>Frags</td><td>Deaths</td></tr>
    # Group 2 captures frags so we can determine the per-game winner.
    $playerRowRegex = [regex]::new('<tr>\s*<td>([^<]+)</td>\s*<td>(-?\d+)</td>\s*<td>-?\d+</td>\s*</tr>', 'IgnoreCase, Singleline')

    foreach ($block in $blockRegex.Matches($html)) {
        $blockContent = $block.Groups[1].Value

        $mnMatch = $mapNameRegex.Match($blockContent)
        if (-not $mnMatch.Success) { continue }
        $mapName = $mnMatch.Groups[1].Value.Trim()

        # Timestamp = last outer-table timestamp before this block's position.
        $lastTs = $null
        foreach ($t in $tsPosMap) {
            if ($t.Pos -lt $block.Index) { $lastTs = $t.TS } else { break }
        }
        if (-not $lastTs) { continue }

        # Collect all players+frags for this game, then flag the winner(s).
        $gamePlayers = [System.Collections.Generic.List[object]]::new()
        foreach ($pm in $playerRowRegex.Matches($blockContent)) {
            $playerName = [System.Net.WebUtility]::HtmlDecode($pm.Groups[1].Value.Trim())
            if (-not $playerName) { continue }
            $gamePlayers.Add([pscustomobject]@{ Name = $playerName; Frags = [int]$pm.Groups[2].Value })
        }
        if ($gamePlayers.Count -eq 0) { continue }

        $maxFrags = ($gamePlayers | Measure-Object -Property Frags -Maximum).Maximum
        foreach ($gp in $gamePlayers) {
            $records.Add([pscustomobject]@{
                Timestamp  = $lastTs
                Type       = 'MatchPlayer'
                Player     = $gp.Name
                Message    = $mapName
                Won        = ($gp.Frags -eq $maxFrags)
                SourceFile = $sourceName
            })
        }
    }

    return $records
}

# ========================================================================== #
#  Step 3.7 - Weekly win tracking (Mon 00:00 - Sun 23:59)                    #
# ========================================================================== #

function Get-WeekMonday {
    param([datetime]$Date = (Get-Date))
    $dow      = [int]$Date.DayOfWeek   # Sunday=0 Monday=1 ... Saturday=6
    $daysBack = if ($dow -eq 0) { 6 } else { $dow - 1 }
    return $Date.Date.AddDays(-$daysBack)
}

function Update-WeeklyWins {
    param(
        [AllowNull()][AllowEmptyCollection()] $AllRecords,
        [string]   $FilePath,
        [string[]] $ExcludedBots
    )

    $monday = Get-WeekMonday
    $weekOf = $monday.ToString('yyyy-MM-dd')

    $prevFilePath = Join-Path (Split-Path $FilePath -Parent) 'prev-weekly-winners.json'

    # Load existing state; reset if week has rolled over
    $stored = $null
    if (Test-Path $FilePath) {
        try { $stored = Get-Content $FilePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
    }
    if ($null -eq $stored -or [string]$stored.weekOf -ne $weekOf) {
        # Week rolled over — snapshot the outgoing top 3 before resetting
        if ($null -ne $stored -and $stored.wins) {
            $oldWins = @{}
            foreach ($prop in $stored.wins.PSObject.Properties) { $oldWins[[string]$prop.Name] = [int]$prop.Value }
            if ($oldWins.Count -gt 0) {
                $prevTop3 = @($oldWins.Keys | Sort-Object { -$oldWins[$_] } | Select-Object -First 3 | ForEach-Object {
                    [pscustomobject]@{ player = $_; wins = $oldWins[$_] }
                })
                [pscustomobject]@{ weekOf = [string]$stored.weekOf; top3 = $prevTop3 } |
                    ConvertTo-Json -Depth 5 | Set-Content -Path $prevFilePath -Encoding UTF8
                Write-RunLog INFO ("Previous week top 3 saved: $prevFilePath")
            }
        }
        $stored = [pscustomobject]@{ weekOf = $weekOf; wins = [pscustomobject]@{}; seenGames = @() }
    }

    # Rebuild wins hashtable from stored JSON
    $wins = @{}
    if ($stored.wins) {
        foreach ($prop in $stored.wins.PSObject.Properties) { $wins[[string]$prop.Name] = [int]$prop.Value }
    }

    # Rebuild seenGames HashSet for deduplication across daily runs
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($stored.seenGames) { foreach ($g in $stored.seenGames) { $null = $seen.Add([string]$g) } }

    # Process MatchPlayer records — only those within the current week (Mon 00:00 – Sun 23:59:59)
    if ($null -ne $AllRecords) {
        $weekEnd   = $monday.AddDays(7)   # exclusive upper bound: Mon 00:00 of next week
        $matchRecs = @($AllRecords | Where-Object {
            $_.Type -eq 'MatchPlayer' -and
            $_.Timestamp -ge $monday -and
            $_.Timestamp -lt $weekEnd
        })
        if ($matchRecs.Count -gt 0) {
            $gameGroups = $matchRecs | Group-Object {
                '{0}|{1}|{2}' -f $_.SourceFile, $_.Message, $_.Timestamp.ToString('yyyyMMddHHmm')
            }
            foreach ($grp in $gameGroups) {
                $key = $grp.Name
                if ($seen.Contains($key)) { continue }
                $null = $seen.Add($key)
                foreach ($r in ($grp.Group | Where-Object { $_.Won -eq $true -and $_.Player })) {
                    if ($ExcludedBots -contains $r.Player) { continue }
                    if ($wins.ContainsKey($r.Player)) { $wins[$r.Player]++ } else { $wins[$r.Player] = 1 }
                }
            }
        }
    }

    # Serialize back
    $winsObj = [pscustomobject]@{}
    foreach ($k in ($wins.Keys | Sort-Object)) {
        Add-Member -InputObject $winsObj -NotePropertyName $k -NotePropertyValue $wins[$k] -Force
    }
    [pscustomobject]@{
        weekOf    = $weekOf
        wins      = $winsObj
        seenGames = @($seen)
    } | ConvertTo-Json -Depth 5 | Set-Content -Path $FilePath -Encoding UTF8

    Write-RunLog INFO ("Weekly wins updated: {0} player(s), week of {1}" -f $wins.Count, $weekOf)
    return [pscustomobject]@{ weekOf = $weekOf; wins = $wins }
}

# ========================================================================== #
#  Step 4 - HTML dashboard                                                    #
# ========================================================================== #

function ConvertTo-HtmlEncoded {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    # System.Net.WebUtility ships in both .NET Framework (PS 5.1) and .NET (PS 7).
    [System.Net.WebUtility]::HtmlEncode($Text)
}

function New-DashboardHtml {
    param(
        [Parameter(Mandatory)] $Analysis,
        [AllowNull()][AllowEmptyCollection()] $AllRecords,
        [AllowNull()][AllowEmptyCollection()] $SayRecords,
        [AllowNull()][AllowEmptyCollection()] $ContactFindings,
        [Parameter(Mandatory)] [datetime] $WindowStart,
        [Parameter(Mandatory)] [datetime] $WindowEnd,
        [Parameter(Mandatory)] [string]   $OutPath,
        [AllowNull()] $WeeklyWins,
        [AllowNull()] $PrevWeeklyWins
    )

    if ($null -eq $AllRecords) { $AllRecords = @() }
    if ($null -eq $SayRecords) { $SayRecords = @() }

    $sections = @(
        @{ Key = 'complaints';  Title = 'Complaints';          Icon = 'C'; Color = '#ff6b4a' }
        @{ Key = 'toxicity';    Title = 'Toxicity';            Icon = 'T'; Color = '#ff4444' }
        @{ Key = 'notable';     Title = 'Notable';             Icon = '!'; Color = '#c987ff' }
        @{ Key = 'issues';      Title = 'Issues';              Icon = 'I'; Color = '#ffb547' }
        @{ Key = 'requests';    Title = 'Requests';            Icon = 'R'; Color = '#4aa3ff' }
        @{ Key = 'compliments'; Title = 'Compliments';         Icon = '+'; Color = '#5dd39e' }
        @{ Key = 'contact';     Title = 'Contact (AI)';        Icon = '@'; Color = '#00b4ff' }
        @{ Key = 'strategy';    Title = 'Strategy / Coaching'; Icon = 'S'; Color = '#7ecfff' }
        @{ Key = 'social';      Title = 'Social / Community';  Icon = '~'; Color = '#7abf7a' }
    )

    $sb = [System.Text.StringBuilder]::new()
    $null = $sb.AppendLine('<!DOCTYPE html>')
    $null = $sb.AppendLine('<html lang="en"><head><meta charset="utf-8">')
    $null = $sb.AppendLine('<title>UT99 Chat Report - ' + $WindowStart.ToString('yyyy-MM-dd') + '</title>')
    $null = $sb.AppendLine(@'
<style>
:root{
  --bg:#0d0f14; --panel:#161a22; --panel2:#1d2230; --line:#2a3142;
  --text:#e7ecf2; --muted:#8a93a6; --accent:#00b4ff;
}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text);font:14px/1.55 -apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif}
header{background:linear-gradient(90deg,#13192b 0%,#1a2238 100%);padding:24px 32px;border-bottom:1px solid var(--line)}
header h1{margin:0 0 4px;font-size:22px;letter-spacing:.4px}
header .meta{color:var(--muted);font-size:13px}
.container{padding:24px 32px;max-width:1280px;margin:0 auto}
.summary{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:18px 22px;margin-bottom:24px}
.summary h2{margin:0 0 8px;font-size:16px;color:var(--accent);font-weight:600}
.stat-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:12px;margin-bottom:24px}
.stat{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:14px 18px}
.stat .num{font-size:28px;font-weight:700;color:var(--accent)}
.stat .label{color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.6px}
.section{margin:24px 0;background:var(--panel);border:1px solid var(--line);border-radius:10px;overflow:hidden}
.section h3{margin:0;padding:14px 18px;border-bottom:1px solid var(--line);font-size:15px;display:flex;align-items:center;gap:10px}
.section h3 .badge{display:inline-flex;width:28px;height:28px;border-radius:6px;align-items:center;justify-content:center;font-weight:700;color:#0d0f14}
.section h3 .count{margin-left:auto;color:var(--muted);font-size:12px}
.empty{padding:18px;color:var(--muted);font-style:italic}
.item{padding:12px 18px;border-bottom:1px solid var(--line)}
.item:last-child{border-bottom:none}
.item .row1{display:flex;align-items:baseline;gap:12px;flex-wrap:wrap}
.item .ts{color:var(--muted);font-family:Consolas,monospace;font-size:12px}
.item .player{font-weight:600;color:var(--accent)}
.item .msg{margin:6px 0 4px;white-space:pre-wrap}
.item .why{font-size:12px;color:var(--muted);font-style:italic}
.toggle{margin:24px 0 8px;cursor:pointer;color:var(--accent);user-select:none}
.toggle:hover{text-decoration:underline}
.raw{display:none;background:var(--panel2);border:1px solid var(--line);border-radius:10px;padding:14px 18px;font-family:Consolas,monospace;font-size:12px;white-space:pre}
.raw.open{display:block}
.top-list{padding:10px 18px}
.top-list .row{display:flex;justify-content:space-between;padding:4px 0;border-bottom:1px dashed var(--line)}
.top-list .row:last-child{border-bottom:none}
.pgrid{display:grid;grid-template-columns:repeat(auto-fill,minmax(160px,1fr));gap:4px;padding:12px 18px}
.pgrid-item{background:var(--panel2);border-radius:4px;padding:4px 10px;font-size:13px}
footer{padding:24px 32px;color:var(--muted);font-size:12px;text-align:center}
</style>
'@)
    $null = $sb.AppendLine('</head><body>')

    # Header
    $null = $sb.AppendLine('<header>')
    $null = $sb.AppendLine('<h1>UT99 Server Chat Report</h1>')
    $null = $sb.AppendLine('<div class="meta">' +
        ('Window: <strong>{0}</strong> &nbsp;to&nbsp; <strong>{1}</strong>' -f
            $WindowStart.ToString('yyyy-MM-dd HH:mm'),
            $WindowEnd.ToString('yyyy-MM-dd HH:mm')) +
        ' &nbsp;|&nbsp; Generated ' + (Get-Date).ToString('yyyy-MM-dd HH:mm') + '</div>')
    $null = $sb.AppendLine('</header>')

    $null = $sb.AppendLine('<div class="container">')

    # Summary
    $summaryText = if ($Analysis.summary) { $Analysis.summary } else { '(no summary)' }
    $null = $sb.AppendLine('<div class="summary"><h2>Summary</h2><div>' +
        (ConvertTo-HtmlEncoded $summaryText) + '</div></div>')

    # Stats grid
    $totalSay       = $SayRecords.Count
    $uniqueChatters = ($SayRecords | Select-Object -ExpandProperty Player -Unique | Where-Object { $_ }).Count
    $totalEvents    = ($AllRecords | Where-Object { $_.Type -eq 'Event' }).Count
    $uniqueJoinedPlayers = @(
        $AllRecords |
        Where-Object { $_.Type -eq 'Join' -and $_.Player } |
        Select-Object -ExpandProperty Player -Unique |
        Where-Object { $_ } |
        Sort-Object
    )
    # Build player -> set of distinct maps actually played (from Game Summary records).
    # Players with zero MatchPlayer records are spectator-only.
    $playerMapSets = @{}
    foreach ($r in ($AllRecords | Where-Object { $_.Type -eq 'MatchPlayer' -and $_.Player })) {
        if (-not $playerMapSets.ContainsKey($r.Player)) {
            $playerMapSets[$r.Player] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        }
        $null = $playerMapSets[$r.Player].Add($r.Message)
    }
    $uniqueJoins = ($uniqueJoinedPlayers | Where-Object { $playerMapSets.ContainsKey($_) }).Count

    $statHtml = @"
<div class="stat-grid">
  <div class="stat"><div class="num">$totalSay</div><div class="label">Chat lines</div></div>
  <div class="stat"><div class="num">$uniqueChatters</div><div class="label">Unique chatters</div></div>
  <div class="stat"><div class="num">$uniqueJoins</div><div class="label">Unique players joined</div></div>
  <div class="stat"><div class="num">$totalEvents</div><div class="label">Events</div></div>
</div>
"@
    $null = $sb.AppendLine($statHtml)

    # Categorized sections
    foreach ($s in $sections) {
        $items = $Analysis.($s.Key)
        if (-not $items) { $items = @() }
        $cnt = @($items).Count
        $null = $sb.AppendLine('<div class="section">')
        $null = $sb.AppendLine(('<h3><span class="badge" style="background:{0}">{1}</span>{2}<span class="count">{3}</span></h3>' -f $s.Color, $s.Icon, $s.Title, $cnt))
        if ($cnt -eq 0) {
            $null = $sb.AppendLine('<div class="empty">Nothing flagged in this category.</div>')
        } else {
            foreach ($it in $items) {
                $ts  = ConvertTo-HtmlEncoded ([string]$it.timestamp)
                $pl  = ConvertTo-HtmlEncoded ([string]$it.player)
                $msg = ConvertTo-HtmlEncoded ([string]$it.message)
                $why = ConvertTo-HtmlEncoded ([string]$it.why)
                $sev = ([string]$it.severity).ToUpper().Trim()
                $sub = ConvertTo-HtmlEncoded ([string]$it.subcategory)
                $sevColor = switch ($sev) {
                    'CRITICAL' { '#ff4444' }
                    'HIGH'     { '#ff7b39' }
                    'MEDIUM'   { '#ffb547' }
                    default    { '#6e7681' }
                }
                $sevBadge = if ($sev) {
                    ' <span style="font-size:10px;font-weight:700;color:{0};border:1px solid {0};border-radius:3px;padding:1px 5px;margin-left:4px">{1}</span>' -f $sevColor, $sev
                } else { '' }
                $subLabel = if ($sub -and $sub -ne '') {
                    ' <span style="font-size:11px;color:var(--muted);margin-left:6px">[{0}]</span>' -f $sub
                } else { '' }
                $null = $sb.AppendLine('<div class="item">')
                $null = $sb.AppendLine(('<div class="row1"><span class="ts">{0}</span><span class="player">{1}</span>{2}{3}</div>' -f $ts, $pl, $sevBadge, $subLabel))
                $null = $sb.AppendLine(('<div class="msg">{0}</div>' -f $msg))
                if ($why) { $null = $sb.AppendLine(('<div class="why">{0}</div>' -f $why)) }
                $null = $sb.AppendLine('</div>')
            }
        }
        $null = $sb.AppendLine('</div>')
    }

    # Contact info & links (regex-detected, independent of LLM)
    if ($null -eq $ContactFindings) { $ContactFindings = @() }
    $kindMeta = @{
        Email = @{ Color = '#f97583'; Label = 'Email' }
        URL   = @{ Color = '#79b8ff'; Label = 'URL' }
        Phone = @{ Color = '#ffab70'; Label = 'Phone' }
        IP    = @{ Color = '#b392f0'; Label = 'IP / Server' }
    }
    $totalContacts = @($ContactFindings).Count
    $null = $sb.AppendLine('<div class="section">')
    $null = $sb.AppendLine(('<h3><span class="badge" style="background:#00b4ff">@</span>Contact Info &amp; Links (Regex)<span class="count">{0}</span></h3>' -f $totalContacts))
    if ($totalContacts -eq 0) {
        $null = $sb.AppendLine('<div class="empty">No emails, URLs, phone numbers, or server IPs detected in chat.</div>')
    } else {
        # Group by Kind for readability
        $byKind = $ContactFindings | Group-Object -Property Kind
        foreach ($g in $byKind) {
            $meta = $kindMeta[$g.Name]
            if (-not $meta) { $meta = @{ Color = '#888888'; Label = $g.Name } }
            foreach ($f in $g.Group) {
                $ts  = ConvertTo-HtmlEncoded ($f.Timestamp.ToString('MM/dd HH:mm'))
                $pl  = ConvertTo-HtmlEncoded ([string]$f.Player)
                $mt  = ConvertTo-HtmlEncoded ([string]$f.Match)
                $msg = ConvertTo-HtmlEncoded ([string]$f.Message)
                $null = $sb.AppendLine('<div class="item">')
                $null = $sb.AppendLine(('<div class="row1"><span class="ts">{0}</span><span class="player">{1}</span> <span style="color:{2};font-weight:600">[{3}]</span> <code style="background:#0d0f14;padding:2px 6px;border-radius:4px;color:#fff">{4}</code></div>' -f $ts, $pl, $meta.Color, $meta.Label, $mt))
                $null = $sb.AppendLine(('<div class="why">in: "{0}"</div>' -f $msg))
                $null = $sb.AppendLine('</div>')
            }
        }
    }
    $null = $sb.AppendLine('</div>')

    # Winners section
    $excludedBots = @('Assphyxiation', 'DyslexicFotherMucker')
    $winCounts = @{}
    foreach ($r in ($AllRecords | Where-Object { $_.Type -eq 'MatchPlayer' -and $_.Won -eq $true -and $_.Player -and $_.Player -notin $excludedBots })) {
        if ($winCounts.ContainsKey($r.Player)) { $winCounts[$r.Player]++ } else { $winCounts[$r.Player] = 1 }
    }
    $sortedWinners = @($winCounts.Keys | Sort-Object)
    $maxWins = if ($winCounts.Count -gt 0) { ($winCounts.Values | Measure-Object -Maximum).Maximum } else { 0 }

    $null = $sb.AppendLine('<div class="section">')
    $null = $sb.AppendLine('<h3><span class="badge" style="background:#7791ff">W</span>Winners<span class="count">' + $sortedWinners.Count + '</span></h3>')
    if ($sortedWinners.Count -eq 0) {
        $null = $sb.AppendLine('<div class="empty">No game results in this window.</div>')
    } else {
        $null = $sb.AppendLine('<div class="pgrid">')
        foreach ($w in $sortedWinners) {
            $wc = $winCounts[$w]
            $style = if ($wc -eq $maxWins) { ' style="color:#ff4444;font-weight:700"' } else { '' }
            $null = $sb.AppendLine('<div class="pgrid-item"' + $style + '>' + (ConvertTo-HtmlEncoded $w) + ' (' + $wc + ')</div>')
        }
        $null = $sb.AppendLine('</div>')
    }
    $null = $sb.AppendLine('</div>')

    # Previous Week's Winners section (persists in every daily report until next Monday rollover)
    if ($PrevWeeklyWins -and $PrevWeeklyWins.top3 -and @($PrevWeeklyWins.top3).Count -gt 0) {
        $pwWeekOf = [string]$PrevWeeklyWins.weekOf
        $pwWeekEndLabel = $pwWeekOf
        if ($pwWeekOf) {
            try {
                $pwMondayDt     = [datetime]::ParseExact($pwWeekOf, 'yyyy-MM-dd', $null)
                $pwWeekEndLabel = $pwMondayDt.AddDays(6).ToString('MMM d, yyyy')
            } catch {}
        }
        $pwTop3      = @($PrevWeeklyWins.top3)
        $rankColors  = @('#ffd700', '#c0c0c0', '#cd7f32')
        $null = $sb.AppendLine('<div class="section">')
        $null = $sb.AppendLine(('<h3><span class="badge" style="background:#b8a0ff">&#9733;</span>Previous Week''s Top 3 Winners &nbsp;<span style="font-size:11px;color:var(--muted)">Week Ending {0}</span><span class="count">{1}</span></h3>' -f (ConvertTo-HtmlEncoded $pwWeekEndLabel), $pwTop3.Count))
        $null = $sb.AppendLine('<div style="padding:4px 18px 8px">')
        for ($i = 0; $i -lt $pwTop3.Count; $i++) {
            $pl    = [string]$pwTop3[$i].player
            $wc    = [int]$pwTop3[$i].wins
            $unit  = if ($wc -eq 1) { 'Game Won' } else { 'Games Won' }
            $rc    = $rankColors[$i]
            $entry = ConvertTo-HtmlEncoded ('[Week Ending {0}] - {1} - {2} {3}' -f $pwWeekEndLabel, $pl, $wc, $unit)
            $null = $sb.AppendLine(('<div style="display:flex;align-items:center;gap:10px;padding:7px 0;border-bottom:1px dashed var(--line)"><span style="color:{0};font-weight:700;font-size:16px;min-width:26px">#{1}</span><span>{2}</span></div>' -f $rc, ($i + 1), $entry))
        }
        $null = $sb.AppendLine('</div>')
        $null = $sb.AppendLine('</div>')
    }

    # Top 3 Weekly Winners section
    $wwData   = $WeeklyWins
    $wwWeekOf = if ($wwData) { [string]$wwData.weekOf } else { (Get-WeekMonday).ToString('yyyy-MM-dd') }
    $wwWins   = if ($wwData -and $wwData.wins -is [hashtable]) {
        $wwData.wins
    } else {
        $h = @{}
        if ($wwData -and $wwData.wins) {
            foreach ($prop in $wwData.wins.PSObject.Properties) { $h[$prop.Name] = [int]$prop.Value }
        }
        $h
    }
    $wwTop3 = @($wwWins.Keys | Sort-Object { -$wwWins[$_] } | Select-Object -First 3)
    $wwWeekLabel    = $wwWeekOf
    $wwWeekEndLabel = $wwWeekOf
    if ($wwWeekOf) {
        try {
            $mondayDt       = [datetime]::ParseExact($wwWeekOf, 'yyyy-MM-dd', $null)
            $wwWeekLabel    = $mondayDt.ToString('MMM d, yyyy')
            $wwWeekEndLabel = $mondayDt.AddDays(6).ToString('MMM d, yyyy')
        } catch {}
    }

    $null = $sb.AppendLine('<div class="section" id="ww-section">')
    $null = $sb.AppendLine(('<h3><span class="badge" style="background:#ffd700">&#9733;</span>Top 3 Weekly Winners &nbsp;<span style="font-size:11px;color:var(--muted)">Week Ending {0}</span><span class="count">{1}</span></h3>' -f (ConvertTo-HtmlEncoded $wwWeekEndLabel), $wwTop3.Count))
    $null = $sb.AppendLine('<div id="ww-body">')
    if ($wwTop3.Count -eq 0) {
        $null = $sb.AppendLine('<div class="empty">No wins recorded this week yet.</div>')
    } else {
        $rankColors = @('#ffd700', '#c0c0c0', '#cd7f32')
        $null = $sb.AppendLine('<div style="padding:4px 18px 8px">')
        for ($i = 0; $i -lt $wwTop3.Count; $i++) {
            $pl   = $wwTop3[$i]
            $wc   = $wwWins[$pl]
            $unit = if ($wc -eq 1) { 'Game Won' } else { 'Games Won' }
            $rc   = $rankColors[$i]
            $entry = ConvertTo-HtmlEncoded ('[Week Ending {0}] - {1} - {2} {3}' -f $wwWeekEndLabel, $pl, $wc, $unit)
            $null = $sb.AppendLine(('<div style="display:flex;align-items:center;gap:10px;padding:7px 0;border-bottom:1px dashed var(--line)"><span style="color:{0};font-weight:700;font-size:16px;min-width:26px">#{1}</span><span>{2}</span></div>' -f $rc, ($i + 1), $entry))
        }
        $null = $sb.AppendLine('</div>')
    }
    $null = $sb.AppendLine('</div>')
    $null = $sb.AppendLine('</div>')

    # Players who joined -- split into active players and spectators
    $activePlayers = @($uniqueJoinedPlayers | Where-Object { $playerMapSets.ContainsKey($_) })
    $spectators    = @($uniqueJoinedPlayers | Where-Object { -not $playerMapSets.ContainsKey($_) })

    $null = $sb.AppendLine('<div class="section">')
    $null = $sb.AppendLine('<h3><span class="badge" style="background:#5dd39e">J</span>Players Who Joined<span class="count">' + $activePlayers.Count + '</span></h3>')
    if ($activePlayers.Count -eq 0) {
        $null = $sb.AppendLine('<div class="empty">No active players joined in this window.</div>')
    } else {
        $null = $sb.AppendLine('<div class="pgrid">')
        foreach ($p in $activePlayers) {
            $null = $sb.AppendLine('<div class="pgrid-item">' + (ConvertTo-HtmlEncoded $p) + ' (' + $playerMapSets[$p].Count + ')</div>')
        }
        $null = $sb.AppendLine('</div>')
    }
    $null = $sb.AppendLine('</div>')

    # Spectators who joined
    $null = $sb.AppendLine('<div class="section">')
    $null = $sb.AppendLine('<h3><span class="badge" style="background:#5dd39e">S</span>Spectators Who Joined<span class="count">' + $spectators.Count + '</span></h3>')
    if ($spectators.Count -eq 0) {
        $null = $sb.AppendLine('<div class="empty">No spectators in this window.</div>')
    } else {
        $null = $sb.AppendLine('<div class="pgrid">')
        foreach ($p in $spectators) {
            $null = $sb.AppendLine('<div class="pgrid-item">' + (ConvertTo-HtmlEncoded $p) + '</div>')
        }
        $null = $sb.AppendLine('</div>')
    }
    $null = $sb.AppendLine('</div>')

    # Maps Played section — count distinct (SourceFile, MapName) pairs = one game instance each
    $mapInstances = @{}
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($r in ($AllRecords | Where-Object { $_.Type -eq 'MatchPlayer' -and $_.Message })) {
        $instanceKey = $r.SourceFile + '|' + $r.Message
        if ($seen.Add($instanceKey)) {
            if ($mapInstances.ContainsKey($r.Message)) { $mapInstances[$r.Message]++ } else { $mapInstances[$r.Message] = 1 }
        }
    }
    $sortedMaps = @($mapInstances.Keys | Sort-Object)

    $null = $sb.AppendLine('<div class="section">')
    $null = $sb.AppendLine('<h3><span class="badge" style="background:#ffb547">M</span>Maps Played<span class="count">' + $sortedMaps.Count + '</span></h3>')
    if ($sortedMaps.Count -eq 0) {
        $null = $sb.AppendLine('<div class="empty">No map data in this window.</div>')
    } else {
        $null = $sb.AppendLine('<div class="pgrid">')
        foreach ($m in $sortedMaps) {
            $null = $sb.AppendLine('<div class="pgrid-item">' + (ConvertTo-HtmlEncoded $m) + ' (' + $mapInstances[$m] + ')</div>')
        }
        $null = $sb.AppendLine('</div>')
    }
    $null = $sb.AppendLine('</div>')

    # Collapsible raw chat
    $rawLineCount = $SayRecords.Count
    $null = $sb.AppendLine('<div class="toggle" onclick="document.getElementById(''raw'').classList.toggle(''open'')">&#x25BE; Show / hide all chat lines (raw) &mdash; ' + $rawLineCount + ' lines</div>')
    $rawText = ($SayRecords | ForEach-Object {
        '[{0}] {1}: {2}' -f $_.Timestamp.ToString('MM/dd HH:mm'), $_.Player, $_.Message
    }) -join "`n"
    $null = $sb.AppendLine('<pre id="raw" class="raw">' + (ConvertTo-HtmlEncoded $rawText) + '</pre>')

    $null = $sb.AppendLine('</div>')  # /container
    $null = $sb.AppendLine('<footer>UT99 Chat Monitor &middot; Powered by Anthropic Claude (' + $Config.ApiModel + ')</footer>')
    $null = $sb.AppendLine('</body></html>')

    Set-Content -Path $OutPath -Value $sb.ToString() -Encoding UTF8
    Write-RunLog INFO "Report written: $OutPath"
}

# ========================================================================== #
#  Step 6 - Recycle processed source logs                                     #
# ========================================================================== #

function Remove-ProcessedLogs {
    param([string]$Folder, [string]$Pattern)
    if (-not $Config.RecycleProcessedLogs) { return }
    Add-Type -AssemblyName Microsoft.VisualBasic
    $files = @(Get-ChildItem -Path $Folder -Filter $Pattern -File -ErrorAction SilentlyContinue)
    $count = 0
    foreach ($f in $files) {
        try {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
                $f.FullName,
                [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
            )
            $count++
        } catch {
            Write-RunLog WARN ("Could not recycle {0}: {1}" -f $f.Name, $_.Exception.Message)
        }
    }
    Write-RunLog INFO ("Recycled {0} processed log file(s) to Recycle Bin." -f $count)
}

# ========================================================================== #
#  MAIN                                                                       #
# ========================================================================== #

try {
    # Handle -ClearWeekly before any other work
    if ($ClearWeekly) {
        if (Test-Path $WeeklyWinsFile) {
            Remove-Item $WeeklyWinsFile -Force
            Write-RunLog INFO "Weekly wins state file cleared: $WeeklyWinsFile"
        } else {
            Write-RunLog INFO "No weekly wins state file found to clear."
        }
        exit 0
    }

    # 1. Fetch .htm files from server
    Invoke-ServerFetch

    # 2. Discover .htm files to parse
    $parsePattern = if ($Config.LocalParsePattern) { $Config.LocalParsePattern } else { '*.htm' }
    $allLogFiles = @(Get-ChildItem -Path $LogFolder -Filter $parsePattern -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime)
    Write-RunLog INFO ("Found {0} {1} file(s) in {2}" -f $allLogFiles.Count, $parsePattern, $LogFolder)

    if ($allLogFiles.Count -eq 0) {
        Write-RunLog WARN "No log files to process. Generating empty report."
    }

    # Parse all and filter by window
    $allRecords = New-Object System.Collections.Generic.List[object]
    foreach ($f in $allLogFiles) {
        # Skip files whose mtime is far before the window - performance optimization
        if ($f.LastWriteTime -lt $WindowStart.AddDays(-2)) { continue }
        try {
            $recs = ConvertFrom-WebChatLog -Path $f.FullName
            foreach ($r in $recs) { $allRecords.Add($r) }
            $matchRecs = Get-MatchPlayerRecords -Path $f.FullName
            foreach ($r in $matchRecs) { $allRecords.Add($r) }
        } catch {
            Write-RunLog WARN "Failed to parse $($f.Name): $_"
        }
    }
    Write-RunLog INFO ("Parsed {0} total records." -f $allRecords.Count)

    # Force array context: Where-Object returns $null when no items match,
    # which would break Mandatory parameter binding downstream. @(...) coerces
    # to an empty array in that case.
    $windowRecords  = @($allRecords | Where-Object { $_.Timestamp -ge $WindowStart -and $_.Timestamp -lt $WindowEnd })
    $allSayRecords  = @($windowRecords | Where-Object { $_.Type -in @('Say','TeamSay') })
    $sayRecords     = @($allSayRecords | Where-Object { -not (Test-ChatNoise $_.Message) })

    Write-RunLog INFO ("In-window: {0} records, {1} Say/TeamSay lines ({2} after noise filter)." -f $windowRecords.Count, $allSayRecords.Count, $sayRecords.Count)

    if ($sayRecords.Count -eq 0) {
        Write-RunLog WARN "No Say/TeamSay lines in the window - the report will show empty categories."
    }

    # 2.5 Deterministic detection of contact info / links / IPs
    $contactFindings = Find-ContactPatterns -Records $sayRecords
    Write-RunLog INFO ("Contact-pattern findings: {0} (emails/URLs/phones/IPs in chat)." -f $contactFindings.Count)

    # 2.7 Update weekly win totals (accumulates across daily runs, resets each Monday)
    $weeklyWins = Update-WeeklyWins -AllRecords $windowRecords -FilePath $WeeklyWinsFile -ExcludedBots $ExcludedBots

    $prevWeeklyWinsFile = Join-Path $StateFolder 'prev-weekly-winners.json'
    $prevWeeklyWins = $null
    if (Test-Path $prevWeeklyWinsFile) {
        try { $prevWeeklyWins = Get-Content $prevWeeklyWinsFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
    }

    # 3. Analysis
    $analysis = $null
    if ($NoAnalysis) {
        Write-RunLog INFO "Skipping Claude analysis (-NoAnalysis)."
        $analysis = [pscustomobject]@{
            summary     = '(Analysis skipped - running in -NoAnalysis mode.)'
            complaints  = @(); issues = @(); requests = @(); compliments = @(); notable = @()
            toxicity    = @(); contact = @(); strategy = @(); social = @()
            stats       = [pscustomobject]@{ total_say_lines = $sayRecords.Count; unique_players = 0; top_chatters = @() }
        }
    } else {
        $apiKey = $env:ANTHROPIC_API_KEY
        if (-not $apiKey) {
            throw "ANTHROPIC_API_KEY environment variable is not set. Run Setup.ps1 to configure it."
        }
        $analysis = Invoke-ChatAnalysis `
            -SayRecords  $sayRecords `
            -ApiKey      $apiKey `
            -Model       $Config.ApiModel `
            -MaxTokens   $Config.ApiMaxTokens `
            -WindowHours $Config.ReportWindowHours
    }

    # 4. Report -- file name uses $reportLabel set in the window-mode block above
    # so that Rolling reports are named for the day they were generated, while
    # PreviousCalendarDay and -Date reports are named for the calendar day covered.
    $reportName = ('chat-report-{0}.html' -f $reportLabel.ToString('yyyy-MM-dd'))
    $reportPath = Join-Path $ReportFolder $reportName
    New-DashboardHtml `
        -Analysis        $analysis `
        -AllRecords      $windowRecords `
        -SayRecords      $sayRecords `
        -ContactFindings $contactFindings `
        -WindowStart     $WindowStart `
        -WindowEnd       $WindowEnd `
        -OutPath         $reportPath `
        -WeeklyWins      $weeklyWins `
        -PrevWeeklyWins  $prevWeeklyWins

    if ($Config.PublishLatestSymlink) {
        $latestPath = Join-Path $ReportFolder 'latest.html'
        Copy-Item -Path $reportPath -Destination $latestPath -Force
    }

    # 4b. Upload report to FTP server
    Invoke-ReportUpload -ReportPath $reportPath

    # 5. State
    $stateFile = Join-Path $StateFolder 'last-run.json'
    @{
        last_run_utc       = (Get-Date).ToUniversalTime().ToString('o')
        last_window_start  = $WindowStart.ToString('o')
        last_window_end    = $WindowEnd.ToString('o')
        last_report_path   = $reportPath
        records_processed  = $windowRecords.Count
        say_lines_analyzed = $sayRecords.Count
    } | ConvertTo-Json | Set-Content -Path $stateFile -Encoding UTF8

    # 5b. Recycle processed source log files
    Remove-ProcessedLogs -Folder $LogFolder -Pattern $parsePattern

    # 6. Open in browser if interactive
    $isInteractive = ([Environment]::UserInteractive) -and ($Host.Name -ne 'ServerRemoteHost')
    if ($isInteractive -and $Config.OpenReportOnInteractiveRun) {
        try { Start-Process $reportPath } catch {}
    }

    Write-RunLog INFO ("Done. Elapsed: {0:N1}s" -f ((Get-Date) - $RunStarted).TotalSeconds)
    Write-RunLog INFO ("Report: $reportPath")

} catch {
    Write-RunLog ERROR ("FATAL: {0}" -f $_.Exception.Message)
    Write-RunLog ERROR ($_.ScriptStackTrace)
    exit 1
}