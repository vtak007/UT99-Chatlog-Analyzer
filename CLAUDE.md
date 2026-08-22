# UT99 Chat Monitor — Project Instructions

## README auto-update

This project's README is `README.md` in the project root. Whenever changes are made to any script or config file, check whether those changes affect the README content. If they do, update `README.md` as part of completing the same task — no separate approval is needed for README edits that directly reflect code or config changes already approved.

## Key files

All script/config/state files live under `_system\`, not the project root.

| File | Purpose |
|---|---|
| `_system\config.ps1` | All user-facing settings |
| `_system\Bin\UT99 ChatLog Analyzer.ps1` | Main pipeline script |
| `_system\Bin\Register-DailyTask.ps1` | Windows Task Scheduler registration |
| `_system\Bin\Clear-WeeklyWinners.ps1` | Resets the weekly wins state file |
| `_system\Bin\Setup.ps1` | First-time setup |
| `README.md` (project root) | User documentation |
| `_system\reports\` | Generated HTML dashboards |
| `_system\runlogs\` | Per-run log files |
| `_system\State\weekly-wins.json` | Accumulated win tallies for the current week |
| `_system\State\prev-weekly-winners.json` | Top 3 from the previous week; written on Monday rollover, deleted by Clear-WeeklyWinners.ps1 |
| `_system\State\last-run.json` | Timestamp and counts from the last run |

Raw downloaded `.htm` chatlogs live in `config.ps1`'s `LocalLogFolder` (currently
`D:\Dropbox\Gaming\UTLogs\WebChatLog`), outside this repo. They're deleted from the server
after verified download, then moved into a local `Archived Chats` subfolder once processed
into a report (see `ArchiveProcessedLogs` in config.ps1).
