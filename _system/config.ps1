# ==============================================================================
#  UT99 Chat Monitor - Configuration
#  Edit the values below to match your setup. Save the file when done.
# ==============================================================================

$Config = @{

    # --- WinSCP --------------------------------------------------------------
    # The exact name of your saved session in WinSCP.
    WinSCPSessionName = 'FMJ FTP Server'

    # Full path to winscp.com (the scripting console, NOT WinSCP.exe).
    # Default install location for WinSCP 6.5.x on Windows 11:
    WinSCPcomPath     = 'C:\Program Files (x86)\WinSCP\WinSCP.com'

    # --- Server side ---------------------------------------------------------
    # Remote folder containing WebChatLog .htm files.
    RemoteLogFolder   = '/Logs/WebChatLog/'

    # Glob pattern for the log files to download. WebChatLog produces .htm files.
    RemoteLogPattern  = '*.htm'

    # Glob pattern for the local files the parser will read. Same as
    # RemoteLogPattern -- we now parse the .htm files directly in PowerShell,
    # so no external HTML-to-text conversion step is needed.
    LocalParsePattern = '*.htm'

    # Files modified within this many minutes are considered "live" (the mod
    # may still be writing to them). Such files are SKIPPED - not downloaded
    # and not deleted. 60 minutes is a safe default.
    ActiveFileBufferMinutes = 60

    # If $true, files are deleted from the server after a verified download.
    # If $false, files are downloaded and left on the server.
    DeleteAfterDownload = $true

    # --- Local paths ---------------------------------------------------------
    # Folder where downloaded raw .log files are kept (your existing folder).
    LocalLogFolder    = 'D:\Dropbox\Gaming\UTLogs\WebChatLog'

    # System folder for reports, state, and run logs. By default this is a
    # subfolder named "_system" inside your log folder so everything stays
    # together.
    SystemFolder      = 'D:\Dropbox\Computing1\BatchFiles_Scripts\Claude Projects\UT99\UT99 ChatLog Analyzer\_system'

    # --- Analysis ------------------------------------------------------------
    # Anthropic API model. claude-sonnet-4-6 is the current default and gives
    # the best categorization quality. claude-haiku-4-5-20251001 is cheaper
    # and faster if cost matters.
    ApiModel          = 'claude-sonnet-4-6'

    # Maximum tokens in the model's response. Raised from 8192 after busy days
    # (500+ chat lines) truncated mid-JSON and failed the whole run.
    ApiMaxTokens      = 16000

    # Time window for each report, in hours. 24 = a full day.
    ReportWindowHours = 24

    # How the window is positioned in time:
    #   'Rolling'             - last N hours ending at the moment the script runs.
    #                           A morning run captures overnight chat (incl. 0000-0700)
    #                           in the SAME morning's report. Consecutive scheduled runs
    #                           at the same time of day produce non-overlapping windows.
    #   'PreviousCalendarDay' - yesterday midnight to midnight (legacy behavior).
    #                           Today's overnight chat would not appear until tomorrow's
    #                           run. No overlap, predictable boundaries.
    # In both modes, passing -Date <yyyy-MM-dd> on the command line forces a
    # midnight-to-midnight report for that specific calendar date.
    ReportMode = 'Rolling'

    # --- Reports -------------------------------------------------------------
    # If $true, the latest report is also copied to "latest.html" for easy
    # bookmarking.
    PublishLatestSymlink = $true

    # If $true, the generated HTML report is uploaded to the FTP server after
    # each run. Set to $false to disable without touching the script.
    UploadReport       = $true
    ReportUploadFolder = '/Logs/Daily Game Summaries/'

    # If $true, opens the report in your default browser when the script
    # finishes a non-scheduled run. Has no effect when run by Task Scheduler.
    OpenReportOnInteractiveRun = $true

    # If $true, moves all processed .htm source files into an "Archived Chats"
    # subfolder of LocalLogFolder after a successful run so they don't
    # accumulate and get re-parsed on future runs. Files remain on disk there
    # and can be reviewed or deleted manually at any time.
    ArchiveProcessedLogs = $true
}

# Export the hashtable so dot-sourcing scripts can use it.
$Config