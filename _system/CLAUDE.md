# UT99 Chat Monitor — Project Instructions

## README auto-update

This project's README is `README.md` in the project root. Whenever changes are made to any script or config file, check whether those changes affect the README content. If they do, update `README.md` as part of completing the same task — no separate approval is needed for README edits that directly reflect code or config changes already approved.

## Key files

| File | Purpose |
|---|---|
| `config.ps1` | All user-facing settings |
| `Bin\UT99 ChatLog Analyzer.ps1` | Main pipeline script |
| `Bin\Register-DailyTask.ps1` | Windows Task Scheduler registration |
| `Bin\Clear-WeeklyWinners.ps1` | Resets the weekly wins state file |
| `README.md` (project root) | User documentation |
| `State\weekly-wins.json` | Accumulated win tallies for the current week |
| `State\last-run.json` | Timestamp and counts from the last run |
