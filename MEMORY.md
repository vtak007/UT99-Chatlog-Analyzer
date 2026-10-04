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

- 2026-10-04 — Report lagging (latest = 10/2 07:00 → 10/3 07:00; 10/4 run never happened). Root cause:
  Task Scheduler event 332 (Microsoft-Windows-TaskScheduler/Operational) — "did not launch task
  \UT99 Chatlog Analyzer because user Strix007\Perdi was not logged on". The task is `LogonType:
  Interactive`, `WakeToRun: False`. The machine (STRIX007) is restarted by `shutdown.EXE` under Perdi's
  account at ~05:00 every 3 days (seen 9/28, 10/1, 10/4; System event 1074 on 10/4 05:00:01, boot
  05:01), and nobody is logged on at 07:00 afterwards. `StartWhenAvailable: True` did NOT catch up
  (NextRunTime jumped to 10/5). Script itself is fine: last run 10/3 exited 0, `last-run.json` window
  end 2026-10-03T07:00. The 10/1 report exists only because of a manual run at 18:27.
  **STATUS: mitigated 2026-10-04** by enabling Windows auto-logon (takes effect at next restart; verify the
  07:00 run after the next 05:00 reboot, expected ~10/7). Still open: find what triggers the 05:00
  `shutdown.exe` restart every 3 days (not yet investigated).

- 2026-10-04 — Manual backfill run failed at the WinSCP fetch: saved session "FMJ FTP Server" had no stored
  password (WinSCP prompted `Password:`; non-interactive script exits -2147483647). Cause of the loss
  unknown. Fixed by re-saving the password in WinSCP. Had this gone unnoticed the 10/5 07:00 run would
  have failed the same way. Also saw one transient Anthropic API 400 (identical request succeeded on
  rerun; cause unknown — the script does not log the API error body).

## RULED-OUT THEORIES

- 2026-10-04 — Script/API failure (e.g. recurrence of the 9/22 truncation): ruled out, 10/3 run exited 0
  and the 10/4 run never started at all. Don't look in the script for this one.
- 2026-10-04 — Task disabled / trigger misconfigured: ruled out, trigger enabled, daily 07:00, runs fine
  when a user session exists.

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

- 2026-10-04 — `Invoke-ChatAnalysis` now logs the Anthropic API's HTTP status and error body to the run log on failure (previously opaque "400 Bad Request").
- 2026-10-04 — Set `ReportMode = 'PreviousCalendarDay'` (was `Rolling`) so each report covers a fixed midnight-to-midnight span; README updated. Rolling left gaps when a run was missed (10/3 07:00-12:45 was never reported).
- 2026-09-22 — Fixed daily task failing with exit 0x1 on busy days: raised `ApiMaxTokens` 8192 → 16000, added a 3-attempt retry around the Claude API call/JSON parse in `Invoke-ChatAnalysis`, and enabled Task Scheduler auto-restart (3 attempts, 15 min apart) on the live "UT99 Chatlog Analyzer" task via `Register-DailyTask.ps1`.
- 2026-08-22 — Replaced RecycleProcessedLogs with ArchiveProcessedLogs: processed .htm logs now move to WebChatLog\Archived Chats instead of the Windows Recycle Bin.
- 2026-08-22 — Fixed stale Key Files table in CLAUDE.md (all scripts/config live under `_system\`, not project root).
- 2026-08-02 — Created MEMORY.md skeleton (UT99 convention).
