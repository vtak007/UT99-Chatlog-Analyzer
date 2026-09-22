# UT99 ChatLog Analyzer — Project Memory

Persistent notes for this project. Read at the start of every session.
See `CLAUDE.md` for project-specific details.

## CONFIRMED ROOT CAUSES

- 2026-09-22 — Daily task showed Task Scheduler exit 0x1, no chat report generated. Root cause: the
  Anthropic API response for `Invoke-ChatAnalysis` was truncated mid-JSON (`ApiMaxTokens = 8192` was
  too low for a busy day, 549 chat lines). `ConvertFrom-Json` threw "Unterminated string", and the
  function had no retry — it just logged the raw text to `_system\State\api-raw-*.txt` and rethrew,
  killing the run. Confirmed by inspecting `api-raw-2026-09-22-070220.txt`, which ends mid-sentence.
  9 prior occurrences found in `_system\State\` dating back to May 2026 — this had been silently
  recurring for months. Fix: raised `ApiMaxTokens` to 16000 and added a 3-attempt retry loop around
  the API call + JSON parse in `Invoke-ChatAnalysis` (`UT99 ChatLog Analyzer.ps1`).

## RULED-OUT THEORIES

- 2026-09-22 — Task name confusion: the user's report initially named the task "UT99 ServerLog
  Analyzer - Daily", but that is a separate, unrelated stale task (leftover from before this project
  was renamed from "UT99 ServerLog Analyzer") pointing at a different folder/script/report entirely
  (`FMJ Server Log Analysis`). It ran fine (exit 0) at 04:25. The task that actually failed is named
  "UT99 Chatlog Analyzer" (07:00 trigger) — don't confuse the two when debugging this project again.

## PROJECT CONVENTIONS

- The live Task Scheduler entry is named **"UT99 Chatlog Analyzer"**, not the
  `Register-DailyTask.ps1` default of "UT99 Chat Monitor - Daily" — always pass
  `-TaskName "UT99 Chatlog Analyzer"` when re-registering, or you'll create a duplicate task.
- Modifying/re-registering the live scheduled task requires an elevated (Administrator) PowerShell
  session — `Unregister-ScheduledTask`/`Register-ScheduledTask` fail with Access Denied otherwise.

## CHANGE LOG

Newest first. Format: `- YYYY-MM-DD — what changed`.

- 2026-09-22 — Fixed daily task failing with exit 0x1 on busy days: raised `ApiMaxTokens` 8192 → 16000, added a 3-attempt retry around the Claude API call/JSON parse in `Invoke-ChatAnalysis`, and enabled Task Scheduler auto-restart (3 attempts, 15 min apart) on the live "UT99 Chatlog Analyzer" task via `Register-DailyTask.ps1`.
- 2026-08-22 — Replaced RecycleProcessedLogs with ArchiveProcessedLogs: processed .htm logs now move to WebChatLog\Archived Chats instead of the Windows Recycle Bin.
- 2026-08-22 — Fixed stale Key Files table in CLAUDE.md (all scripts/config live under `_system\`, not project root).
- 2026-08-02 — Created MEMORY.md skeleton (UT99 convention).
