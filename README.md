# UT99 Chat Monitor

An automated pipeline that downloads chat logs from an Unreal Tournament 1999 server, analyzes them with Anthropic's Claude API, and produces a daily HTML dashboard highlighting complaints, issues, compliments, requests, notable events, and any contact info or external links shared in chat.

Built for a single-server admin running NFO-hosted UT99 with the WebChatLog mod and using WinSCP for FTP. Designed to run unattended on Windows 11 via Task Scheduler.

---

## Table of Contents

1. [What it does](#what-it-does)
2. [Pipeline overview](#pipeline-overview)
3. [File structure](#file-structure)
4. [Configuration reference](#configuration-reference)
5. [Installation](#installation)
6. [Running it](#running-it)
7. [Command-line flags](#command-line-flags)
8. [The report](#the-report)
9. [How each component works](#how-each-component-works)
10. [Troubleshooting](#troubleshooting)
11. [Maintenance](#maintenance)

---

## What it does

Every morning (or whenever you trigger it), the system:

1. Logs into your NFO FTP account using your saved WinSCP session.
2. Downloads any new `.htm` chat log files from `/Logs/WebChatLog/`, skipping the file currently being written to by the mod.
3. Optionally deletes the originals from the server (you control this in config).
4. Parses the HTML chat tables directly in PowerShell — no external converter needed.
5. Filters down to the last 24 hours of `Say` and `TeamSay` lines (configurable). By default this is a *rolling* window ending at the moment the script runs, so a morning run sees the overnight session (including the 0000-0700 hours) in the same morning's report.
6. Applies a noise filter that removes low-signal messages before any further processing — GG variants, LOL/laugh variants, greetings, and punctuation-only lines are dropped. The run log reports both the raw count and the post-filter count.
7. Runs two parallel passes over the filtered messages:
   - A deterministic regex sweep for emails, URLs, phone numbers, and IP/server addresses.
   - A Claude API call that categorizes notable lines into complaints / issues / compliments / requests / notable.
8. Renders a single self-contained HTML dashboard you open in any browser.

You stop having to read raw chat logs line by line — the dashboard surfaces only the items worth your attention.

---

## Pipeline overview

```
+------------------+
| NFO FTP Server   |
| /Logs/WebChatLog |
+--------+---------+
         |  WinSCP (saved session "FMJ FTP Server")
         |  filemask: *.htm older than 60 minutes
         v
+------------------+
| Local folder     |  D:\Dropbox\Gaming\UTLogs\WebChatLog\
| .htm files       |
+--------+---------+
         |  Direct HTML parsing in PowerShell
         |  (regex over <tr>/<td>)
         v
+------------------+
| Record stream    |  one record per chat row
| (Timestamp,      |  filtered to the report window
|  Type, Player,   |  (default: previous 24 hours)
|  Message)        |
+--------+---------+
         |
         |  Noise filter (Test-ChatNoise)
         |  removes gg / lol / greetings / empty
         v
+------------------+
| Filtered Say     |
| records          |
+--------+---------+
         |
   +-----+--------------------+
   |                          |
   v                          v
+------------------+    +-------------------------+
| Regex pass       |    | Claude API call         |
| Find emails,     |    | Categorize into 5 buckets|
| URLs, phones,    |    | (claude-sonnet-4-6)      |
| IP:port          |    | Returns JSON             |
+--------+---------+    +------------+------------+
         |                           |
         +--------------+------------+
                        v
            +------------------------+
            | HTML dashboard         |
            | _system/reports/       |
            | chat-report-YYYY-MM-DD |
            | .html + latest.html    |
            +------------------------+
```

---

## File structure

```
D:\Dropbox\Gaming\UTLogs\WebChatLog\
|
\-- *.htm                       <- raw downloads from FTP (kept for reference)

D:\Dropbox\Computing1\BatchFiles_Scripts\Claude Projects\UT99 ChatLog Analyzer\_system\
|-- config.ps1              <- editable settings (paths, model, schedule)
|
|-- bin\
|   |-- UT99 ChatLog Analyzer.ps1   <- the main worker script
|   |-- Setup.ps1                   <- interactive first-time setup wizard
|   \-- Register-DailyTask.ps1      <- registers the scheduled task
|
|-- reports\
|   |-- chat-report-2026-05-01.html   <- one per day
|   |-- chat-report-2026-05-02.html
|   \-- latest.html                   <- copy of the newest report
|
|-- runlogs\
|   \-- run-2026-05-02-080000.log     <- one per script invocation
|
\-- state\
    |-- last-run.json                  <- timestamp + counts of last run
    |-- weekly-wins.json               <- current week win tallies
    |-- prev-weekly-winners.json       <- top 3 from previous week (written on Monday rollover)
    |-- winscp-2026-05-02-080000.xml   <- WinSCP transfer log
    \-- api-raw-*.txt                  <- raw API responses if JSON parse fails
```

Reports, runlogs, and state are auto-created on first run. Old runlogs accumulate — see [Maintenance](#maintenance) for cleanup.

---

## Configuration reference

All settings live in `config.ps1`. Edit with any text editor, save, and the next run picks up the changes.

### WinSCP

| Setting | Default | Purpose |
|---|---|---|
| `WinSCPSessionName` | `FMJ FTP Server` | Exact name of your saved WinSCP session. Must match what's shown in the WinSCP login dialog. |
| `WinSCPcomPath` | `C:\Program Files (x86)\WinSCP\WinSCP.com` | Full path to `WinSCP.com` (the scripting console — *not* `WinSCP.exe`, the GUI). Comes from a standard install of WinSCP 6.5+. |

### Server side

| Setting | Default | Purpose |
|---|---|---|
| `RemoteLogFolder` | `/Logs/WebChatLog/` | Absolute path on the FTP server to your WebChatLog folder. |
| `RemoteLogPattern` | `*.htm` | Glob for files to download. WebChatLog produces `.htm`. |
| `ActiveFileBufferMinutes` | `60` | Files modified within the last N minutes are skipped — they may still be open for writing by the mod. 60 minutes is a safe default. |
| `DeleteAfterDownload` | `$true` | When `$true`, files are removed from the server after a verified download. Set to `$false` if you want server-side copies kept. |

### Local paths

| Setting | Default | Purpose |
|---|---|---|
| `LocalLogFolder` | `D:\Dropbox\Gaming\UTLogs\WebChatLog` | Where downloaded `.htm` files land. Same folder you've been using manually with WinSCP. |
| `SystemFolder` | `D:\Dropbox\Computing1\BatchFiles_Scripts\Claude Projects\UT99 ChatLog Analyzer\_system` | Where reports, runlogs, state, and scripts live. |
| `LocalParsePattern` | `*.htm` | What file pattern the parser looks at locally. |

### Analysis

| Setting | Default | Purpose |
|---|---|---|
| `ApiModel` | `claude-sonnet-4-6` | Anthropic model used for categorization. Switch to `claude-haiku-4-5-20251001` for a cheaper / faster option with slightly less nuance. |
| `ApiMaxTokens` | `4096` | Max tokens in the API response. 4096 fits a busy day's report with headroom. |
| `ReportWindowHours` | `24` | Hours of chat to include in each report. |
| `ReportMode` | `Rolling` | How the window is positioned. `Rolling` = last N hours ending at script run time (a morning run captures overnight chat). `PreviousCalendarDay` = yesterday midnight to midnight (legacy; today's overnight chat appears in tomorrow's report). |

### Reports

| Setting | Default | Purpose |
|---|---|---|
| `PublishLatestSymlink` | `$true` | Also write `latest.html` so you can bookmark a URL that always shows the newest report. |
| `OpenReportOnInteractiveRun` | `$true` | When you run the script manually (not via Task Scheduler), open the report in your default browser when done. |
| `RecycleProcessedLogs` | `$true` | After a successful run, sends all `.htm` source files in `LocalLogFolder` to the Windows Recycle Bin so they don't accumulate and get re-parsed on future runs. Files can be restored from the Recycle Bin if needed. Set to `$false` when running with `-NoFetch` to reprocess files you still need on disk. |

---

## Installation

### Prerequisites

- Windows 11 (PowerShell 5.1 or PowerShell 7 — both work; 7 is preferred).
- WinSCP 6.5.6 or later (https://winscp.net) with your FTP session saved as `FMJ FTP Server`.
- An Anthropic API key (console.anthropic.com -> Settings -> API Keys).
- The saved WinSCP session must have its **password saved** (Edit session in WinSCP -> Save -> tick "Save password").

### Steps

1. Place the `_system` folder at `D:\Dropbox\Computing1\BatchFiles_Scripts\Claude Projects\UT99 ChatLog Analyzer\_system\`, containing `config.ps1`, `bin\`, etc.
2. Open PowerShell 7 (search Start for "PowerShell" — black icon, not blue).
3. Allow local script execution (one time, per user):
   ```powershell
   Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
   ```
4. Run the setup wizard:
   ```powershell
   cd 'D:\Dropbox\Computing1\BatchFiles_Scripts\Claude Projects\UT99 ChatLog Analyzer\_system\bin'
   .\Setup.ps1
   ```
   It will create folders, verify WinSCP is installed, probe your saved session, prompt for your API key (stored as a user-scoped environment variable), and smoke-test the API.
5. Do a safe dry run:
   ```powershell
   & '.\UT99 ChatLog Analyzer.ps1' -NoDelete -NoAnalysis
   ```
   This downloads but doesn't delete from the server, and skips the API call so you spend no credits. Check `_system\runlogs\` for the log file and confirm the parsed counts look right.
6. Run for real:
   ```powershell
   & '.\UT99 ChatLog Analyzer.ps1'
   ```
   This is the moment files actually delete from the server. The report opens in your browser when done.
7. Schedule it:
   ```powershell
   .\Register-DailyTask.ps1 -Time 08:00 -StartDate 2026-06-09
   ```
   Registers a Windows Task Scheduler entry that runs the script every morning at 08:00, starting on the given date, in your user context (so it has access to the saved session and API key). Omit `-StartDate` to start from today.

---

## Running it

### Scheduled

Once `Register-DailyTask.ps1` has been run, the system runs itself daily at the configured time. You'll find a fresh report in `_system\reports\` each morning, and `latest.html` always points to the newest one. Bookmark `latest.html` for one-click access.

### Manually (any time)

From the `_system\bin` folder:

```powershell
# Default: yesterday's window, full pipeline
& '.\UT99 ChatLog Analyzer.ps1'

# Today's chat (run anytime)
& '.\UT99 ChatLog Analyzer.ps1' -Date (Get-Date)

# Specific past day
& '.\UT99 ChatLog Analyzer.ps1' -NoFetch -Date '2026-04-30'

# Trigger the scheduled task right now (uses scheduled config)
Start-ScheduledTask -TaskName 'UT99 Chat Monitor - Daily'
```

---

## Command-line flags

All flags are switches (no values needed) unless noted.

| Flag | Effect |
|---|---|
| `-Date <datetime>` | Generate a report for a specific date instead of yesterday. Example: `-Date '2026-04-30'`. |
| `-NoFetch` | Skip the WinSCP download step. Use when reprocessing logs already on disk. |
| `-NoDelete` | Download files but do not delete from the server, regardless of `DeleteAfterDownload`. Useful for first runs. |
| `-NoAnalysis` | Skip the Claude API call. Produces a report with empty categories but full stats, Players Who Joined, contact-info findings, and raw chat. Useful for testing without spending credits. |
| `-ConfigPath <path>` | Use an alternate config file. Defaults to `..\config.ps1` next to the script. |

Examples:

```powershell
# Safe first-run dry test
& '.\UT99 ChatLog Analyzer.ps1' -NoDelete -NoAnalysis

# Reprocess a past day from local logs
& '.\UT99 ChatLog Analyzer.ps1' -NoFetch -Date '2026-04-30'

# Today's report, leaving server logs alone (e.g. mid-day check)
& '.\UT99 ChatLog Analyzer.ps1' -Date (Get-Date) -NoDelete
```

---

## The report

Each report is a single self-contained HTML file you can email, archive, or just open locally.

### Sections

- **Summary** — 2-3 sentence overview from Claude.
- **Stats grid** — four cards: total chat lines (after noise filter), unique chatters (players who said something, after noise filter), unique players joined (distinct player names with a Join record), and total events.
- **Complaints** — gameplay/server/admin/player complaints.
- **Issues** — technical problems (lag, crashes, broken mods).
- **Requests** — map adds, mod tweaks, admin actions, balance asks.
- **Compliments** — positive feedback worth knowing about.
- **Notable** — slurs, harassment, suspected cheating, drama.
- **Map Comments** — any player opinion, reaction, or preference about a specific map. Each entry includes the map name when Claude can identify it.
- **Server Comments** — comments about the current server or any other game server, including performance feedback and references to other servers.
- **Contact Info & Links** — deterministic regex matches for emails, URLs, phone numbers, and IP/server addresses (independent of the LLM).
- **Top chatters** — leaderboard of who said the most that day.
- **Previous Week's Top 3 Winners** — appears in reports for the new week, showing the top 3 from the week just ended. Persists in every daily report until the *next* Monday rollover overwrites it with newer data, giving you the full week to document the results. Run `Clear-WeeklyWinners.ps1` to remove it early.
- **Top 3 Weekly Winners** — cumulative win leaderboard for the current Mon 00:00 – Sun 23:59 week, labelled *Week Ending [Sunday date]*. Tallies accumulate across daily runs and reset automatically each Monday. Only games whose timestamp falls within the current week are counted — games from Sunday are never carried into Monday's new week. Run `Clear-WeeklyWinners.ps1` to reset the tally early.
- **Players Who Joined** — alphabetical grid of every unique player name that has a Join record in the reporting window. The count appears in the section header. This is distinct from the "All players" concept — it shows specifically who connected to the server during this period.
- **Show/hide all chat lines (raw)** — collapsible full list of every Say/TeamSay line that survived the noise filter. The toggle label shows the total count (e.g., *Show / hide all chat lines (raw) — 82 lines*) so you know what to expect before expanding. The list expands fully on the page when opened.

### Categorization rules

Before any analysis, a noise filter (`Test-ChatNoise`) removes messages that carry no useful admin signal. These are dropped from the Claude prompt, contact detection, stats, and the raw chat section:

| Category | Examples |
|---|---|
| GG variants | `gg`, `ggs`, `ggg`, `tgg`, `good game`, `good game all` |
| LOL / laugh | `lol`, `lolol`, `lmao`, `lmfao`, `haha`, `hehe`, `xd` |
| Greetings | `hi`, `hey`, `hello`, `yo`, `sup`, `wsp`, `howdy`, `hola`, `heya`, `hey guys`, `hi everyone`, `what's up`, etc. |
| Empty / punctuation-only | `:(`, `?`, `!` |

After noise filtering, Claude is instructed to further ignore casual banter and only flag lines with real signal. Each flagged line includes the timestamp, player name, the verbatim quote, and a short "why flagged" note.

The Claude summary and the stats card both use the same computed unique-chatter count, so the numbers agree.

---

## How each component works

### 1. Server fetch (WinSCP)

The script writes a temporary WinSCP script file containing:

```
option batch abort
option confirm off
option transfer binary
option reconnecttime 30
open "FMJ FTP Server"
cd "/Logs/WebChatLog/"
get -delete -filemask="*.htm<60N" * "D:\Dropbox\Gaming\UTLogs\WebChatLog\*"
exit
```

It then invokes `WinSCP.com /script=<temp> /xmllog=<state>\winscp-*.xml` and checks the exit code. The XML log records every transfer. Key points:

- The filemask `*.htm<60N` means "files matching `*.htm` AND modified more than 60 minutes ago." This protects the file the mod is currently writing to.
- `option batch abort` makes WinSCP non-interactive — any prompt becomes an error rather than hanging the script.
- The saved session must have its password stored, or WinSCP will prompt for one in batch mode and fail with `Access denied. Credentials were not specified.`
- `-delete` removes each file from the server only after a successful transfer.

### 2. HTML parsing

Instead of relying on an external HTML-to-text converter (which proved unreliable for unattended runs), the parser walks the HTML directly in PowerShell:

```powershell
$rowRegex  = [regex]::new('<tr[^>]*>(.*?)</tr>',     'IgnoreCase, Singleline')
$cellRegex = [regex]::new('<td[^>]*>(.*?)</td>',     'IgnoreCase, Singleline')
```

Each `<tr>` is matched, and rows are filtered:

- Rows containing `<th>` are the column header — skipped.
- Rows containing `<td colspan=4>` are the Game Summary block — skipped.
- Rows with fewer than 4 `<td>` cells are non-data — skipped.

For each valid chat row, the four cells map to `Timestamp`, `Type`, `Player`, `Message`. The player cell is stripped of its `<font color=...>` wrapper, `&nbsp;` becomes empty string, and HTML entities in the message are decoded.

### 3. Window filtering

The window is determined by `Config.ReportMode`:

- **`Rolling` (default)** — `WindowEnd = now`, `WindowStart = now - ReportWindowHours`. A scheduled 08:00 run on Tuesday produces a window of `Mon 08:00 -> Tue 08:00`, which captures both Monday's late-night gaming and Tuesday's 0000-0800 hours. Consecutive scheduled runs at the same time of day touch at the seam — every chat line appears in exactly one report.
- **`PreviousCalendarDay`** — `WindowEnd = today 00:00`, `WindowStart = yesterday 00:00`. Strict midnight-to-midnight of the previous day. Predictable boundaries, but today's overnight chat (0000-0800) does not appear until tomorrow's run.
- **`-Date <yyyy-MM-dd>`** (any mode) — overrides both. Forces midnight-to-midnight of the specified calendar date. Use for backfilling or revisiting.

Any record whose `Timestamp` falls inside the window is kept. The script also skips parsing files whose modification time is more than two days before the window start — a small performance optimization.

Report file naming follows the window:

- `Rolling` reports are named for the day they were generated (e.g. `chat-report-2026-05-05.html` for the report a Tuesday morning run produces).
- `PreviousCalendarDay` and `-Date` reports are named for the calendar date covered.

### 3.5. Noise filter

Before any analysis, the `Test-ChatNoise` function is applied to every `Say` and `TeamSay` record. Messages that return `$true` are removed from `$sayRecords` entirely — they never reach the contact-info regex, the Claude prompt, the stats card, the Players Who Joined list, or the raw chat section.

The function normalises the message to lowercase, strips punctuation, collapses whitespace, then checks:

- **GG variants** — regex `^t?g{2,}s?$` (gg, ggs, ggg, tgg, tggs) and `^good\s+games?...`
- **LOL / laugh variants** — regex `^l+o+l+o*$` (lol, lolol) and exact matches for `lmao`, `lmfao`, `rofl`, `haha`, `hehe`, `xd`, etc.
- **Greetings** — a set of base words (`hi`, `hey`, `hello`, `yo`, `sup`, `wsp`, `howdy`, `hola`, `heya`, `hai`, `wassup`, `salut`) with optional audience suffixes (`all`, `everyone`, `guys`, `people`, `fellas`, `team`), plus `what's up` variants.
- **Empty after stripping** — messages that reduce to an empty string after punctuation removal (e.g. `:(`, `?`).

The run log reports both counts: `N Say/TeamSay lines (M after noise filter)`. To add or adjust patterns, edit `Test-ChatNoise` in `UT99 ChatLog Analyzer.ps1`.

### 4. Contact-info detection

Independent of Claude, four regex patterns sweep all filtered `Say` and `TeamSay` messages:

- **Email** — `[A-Za-z0-9._+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+`
- **URL** — anything with `http://`, `https://`, `ftp://`, `www.`, or a recognized TLD (`com`, `net`, `org`, `io`, `gg`, `tv`, `me`, `info`, `co`, `gov`, `edu`, etc.)
- **Phone** — `\b(?:\+?\d{1,3}[-.\s]?)?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}\b`
- **IP / server** — `\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}(?::\d{2,5})?\b`

Findings only come from chat messages. The IP addresses recorded in `Join` rows (your players' real connect IPs) are intentionally excluded to avoid surfacing private data and to prevent false positives.

### 5. Claude analysis

The script POSTs to `https://api.anthropic.com/v1/messages` with the configured model. The system prompt asks for a strict JSON object with five categorized arrays plus a summary and stats block. Each filtered chat line is presented as `[MM/dd HH:mm] PlayerName: message`.

The user prompt includes the pre-computed unique chatter count so Claude's text summary uses the same figure that appears in the stats card — eliminating the discrepancy between the AI-written summary and the dashboard numbers.

The prompt explicitly instructs Claude to ignore casual banter and only flag lines with real signal. The `notable` category includes contact-info sharing, recruitment to other servers, and suspicious links — so even if a regex pattern misses something subtle (an obfuscated URL, a phone number written as words), Claude's pass can still catch it.

The response is parsed as JSON. If parsing fails, the raw text is dumped to `_system\state\api-raw-<timestamp>.txt` for inspection.

### 6. HTML dashboard

A `System.Text.StringBuilder` builds the page in memory using inline CSS (no external stylesheets — the file is fully portable). Sections:

- **Stats grid** — four cards: chat lines, unique chatters, unique players joined, events. "Unique chatters" counts only players who spoke (from Say records after noise filter). "Unique players joined" counts distinct player names from Join records, which is a broader measure of who was on the server regardless of whether they chatted.
- **Categorized sections** — five sections from Claude's JSON, each with a colour-coded badge.
- **Contact Info & Links** — from the deterministic regex pass, independent of Claude.
- **Top chatters** — from Claude's `stats.top_chatters` JSON field.
- **Previous Week's Top 3 Winners** — shown when `state\prev-weekly-winners.json` exists. Written automatically when the week rolls over on Monday; appears in every daily report of the new week so you have time to document the results before it's naturally replaced the following Monday.
- **Top 3 Weekly Winners** — built from the `state\weekly-wins.json` accumulator. Only `MatchPlayer` records whose timestamp falls within the current Mon 00:00 – Sun 23:59 week are counted, so a Monday morning run that processes Sunday's games never attributes those wins to the new week. The section header shows *Week Ending [Sunday date]*.
- **Players Who Joined** — a compact alphabetical grid built from Join records in the window. Each unique player name appears once. The count is shown in the section header.
- **Raw chat** — a collapsible `<pre>` block containing every filtered Say/TeamSay line. The toggle label shows the line count before you open it. The block expands fully on the page (no inner scroll cap) so all lines are visible when opened.

The output is saved to `_system\reports\chat-report-YYYY-MM-DD.html` and copied to `_system\reports\latest.html`.

### 7. Scheduling

`Register-DailyTask.ps1` creates a Windows Task Scheduler entry that:

- Runs daily at the time you specify (default 08:00).
- Starts on the date given by `-StartDate yyyy-MM-dd` (defaults to today if omitted).
- Uses `pwsh.exe` (PowerShell 7) if installed, otherwise `powershell.exe` (5.1).
- Runs as your current Windows user (so it has access to the saved WinSCP session and `ANTHROPIC_API_KEY` env var).
- Has a 30-minute execution time limit (a safety net in case the script ever hangs).

To remove it later: `.\Register-DailyTask.ps1 -Unregister`.

---

## Troubleshooting

### `WinSCP exit code 1: Access denied. Credentials were not specified.`

Your saved WinSCP session has the host and username but no password. Open WinSCP, edit the session, type the password, click **Save**, tick **Save password**, click OK. Re-run.

### `Cannot bind argument to parameter 'SayRecords' because it is null.`

Means the window contained no chat at all. Usually because:

- The default window is yesterday and you ran the script today before any chat happened. Use `-Date (Get-Date)` to look at today's data.
- Or: the parser isn't matching. Check the run log for `Parsed N total records.` — if N is 0 with `.htm` files present, an HTML format quirk needs handling.

### `HTMLAsText.exe did not finish within 120 seconds`

Should not occur in the current code — HTMLAsText was removed when we switched to native HTML parsing. If you see this, you're running an old version of `UT99 ChatLog Analyzer.ps1`.

### Setup.ps1 hangs at "Checking WinSCP install"

Old version. The current Setup reads the WinSCP version from file metadata instead of invoking `WinSCP.com /version` (which doesn't exist as a switch and causes WinSCP to drop into an interactive console waiting for input).

### `Unexpected token '}' in expression or statement`

Caused by Unicode characters (em-dashes, smart quotes) in `.ps1` files when read by Windows PowerShell 5.1, which assumes Windows-1252 encoding. The current scripts are pure ASCII. If you re-introduce Unicode characters when editing, either use PowerShell 7 (which reads UTF-8 by default) or save the file as UTF-8 with BOM.

### Empty report despite chat happening

Check `_system\runlogs\<latest>.log` for these lines:

```
[INFO] Report window (Rolling): 2026-05-04 08:00 to 2026-05-05 08:00
[INFO] Found N *.htm file(s) in D:\...
[INFO] Parsed M total records.
[INFO] In-window: X records, Y Say/TeamSay lines (Z after noise filter).
```

- `N=0` → no files were downloaded. Check WinSCP step.
- `M=0` despite N>0 → parser isn't matching. Likely a format change in WebChatLog.
- `X=0` despite M>0 → records exist but not in your window. The "Report window" line tells you exactly what was searched. Try `-Date (Get-Date)` to look at today, or pick a specific past date.
- `Y=0` despite X>0 → chat happened but no one talked, only events/joins. Genuinely quiet day.
- `Z=0` despite Y>0 → all Say lines were removed by the noise filter. This is unlikely unless the only chat was `gg` and `lol` — check `Test-ChatNoise` in the script if you think legitimate lines are being dropped.

### Scheduled task fires but nothing happens

Open Task Scheduler, find the task, look at History. If it ran but produced no report:

1. The task runs only when you're logged in (by design — needs your env vars).
2. Make sure your laptop wasn't asleep at the scheduled time.
3. Verify `pwsh.exe` is in PATH if you have PowerShell 7.

---

## Maintenance

### Processed log files and the Recycle Bin

With `RecycleProcessedLogs = $true` (the default), every `.htm` source file in `LocalLogFolder` is sent to the Windows Recycle Bin at the end of each successful run. The run log reports the count: `Recycled N processed log file(s) to Recycle Bin.`

Files are only recycled after the report is written — a failed run leaves them on disk. To restore a file, open the Recycle Bin and use *Restore*.

If you need to reprocess files already on disk (e.g. running with `-NoFetch -Date`), set `RecycleProcessedLogs = $false` in `config.ps1` first, then restore it afterward.

### Rotating runlogs

The `_system\runlogs\` folder gathers one log per script invocation forever. After a few months it'll be cluttered. To keep only the last 30 days:

```powershell
Get-ChildItem 'D:\Dropbox\Computing1\BatchFiles_Scripts\Claude Projects\UT99 ChatLog Analyzer\_system\Runlogs\*.log' |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } |
    Remove-Item
```

You can drop that into a separate scheduled task or just run it occasionally.

### Switching the Claude model

Open `config.ps1`, change `ApiModel`. As of May 2026:

- `claude-sonnet-4-6` (default) — best categorization quality, ~$3/$15 per million tokens.
- `claude-haiku-4-5-20251001` — about 4x cheaper and faster, slightly less nuance on edge cases.
- `claude-opus-4-7` — overkill for this workload but available if you want maximum quality.

### Updating the noise filter

The `Test-ChatNoise` function lives near the top of the functions section in `UT99 ChatLog Analyzer.ps1`. It normalises each message (lowercase, punctuation stripped, whitespace collapsed) then applies regex and exact-match checks. To add patterns:

- **New GG variant** — extend the `^t?g{2,}s?$` regex or add an exact match to the `$greetings`-style list.
- **New laugh variant** — add to the `lmao|lmfao|rofl|...` alternation.
- **New greeting word** — add to the `$greetBase` alternation string.

Changes take effect on the next run with no other edits required.

### Updating the contact-info patterns

The four regex patterns and the TLD list live in the `Find-ContactPatterns` function in `UT99 ChatLog Analyzer.ps1`. To add a TLD, append to the `$tldList` string. To loosen or tighten any pattern, edit the value in the `$patterns` hashtable. Changes take effect on the next run.

### Updating Claude's instructions

The system prompt sent to Claude lives in the `Invoke-ChatAnalysis` function. Edit the `$systemPrompt` here-string to change category definitions, ignore lists, JSON schema, etc.

### Removing the system

```powershell
.\Register-DailyTask.ps1 -Unregister                      # remove the scheduled task
[Environment]::SetEnvironmentVariable('ANTHROPIC_API_KEY', $null, 'User')   # remove the API key
Remove-Item -Recurse 'D:\Dropbox\Computing1\BatchFiles_Scripts\Claude Projects\UT99 ChatLog Analyzer\_system'
```

Your raw `.htm` log files in `D:\Dropbox\Gaming\UTLogs\WebChatLog\` are untouched.

---

## Credits

- Chat capture: WebChatLog mod by Bruce Bickar (BDB) — `www.planetunreal.com/BDBUnreal`.
- File transfer: WinSCP (https://winscp.net).
- Categorization: Anthropic Claude (https://www.anthropic.com).
- Pipeline assembled with assistance from Claude inside Cowork mode.
