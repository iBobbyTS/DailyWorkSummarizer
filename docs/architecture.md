# Architecture

## Runtime composition

The app is centered around a small set of long-lived services created at launch by `AppDelegate`:

- `AppDatabase`
  SQLite persistence, SQLCipher-backed encryption mode, plaintext mode, runtime encryption conversion, and current schema setup.
- `SettingsStore`
  UserDefaults and Keychain-backed settings state exposed to SwiftUI.
- `ScreenshotService`
  Periodic capture scheduling, permission checks, and idle detection.
- `AutomaticScreenshotCleanupTimer`
  Hourly timer that deletes root screenshot JPEG files older than the configured retention period. Started alongside ScreenshotService and AnalysisService when background services are enabled; respects the Off retention setting.
- `AppRunCoordinator`
  Main-actor run gate that keeps screenshot analysis and work-content summary runs mutually exclusive, with one coalesced pending bucket per run kind.
- `AnalysisService`
  Main-actor coordinator for pending screenshot runs, timers, cancellation, appends, runtime model labels, and UI-facing progress.
- `ActiveAnalysisRun`
  Per-run queue and counters used by `AnalysisService`, isolated in `ActiveAnalysisRun.swift`.
- `AnalysisServicePolicy`
  Static parsing, retry, charger, and runtime-error policy helpers in `AnalysisServicePolicy.swift`.
- `AnalysisWorker`
  Non-main async worker in `AnalysisWorker.swift` used by `AnalysisService` for image loading, OCR, model invocation, structured parsing, and retry behavior.
- `DailyReportSummaryService`
  Daily-summary generation, contiguous daily work-block summary generation, runtime state, cancellation, and backfill for missing work summaries.
- `SystemAppNotificationService`
  Lazy-authorized macOS local notifications for background run completion and failure messages.
- `LLMService`
  Shared provider adapter for OpenAI, Anthropic, LM Studio, and Apple Intelligence.
- `LMStudioModelLifecycle`
  Explicit LM Studio load/unload helper used by analysis, summaries, and settings model tests when the corresponding model profile has lifecycle management enabled.
- `MenuBarApp` / `AppDelegate`
  Menu bar state rendering, current-status sections, force-unload actions, window/menu orchestration, and the Analysis Runs window entry point below Show Logs.
- `ReportsViewModel`
  Report range construction, chart data, heatmap data, daily work-block summary mixing, and daily report presentation in `ReportsViewModel.swift`.
- `ReportsView`
  Report window composition in `ReportsView.swift`, with legend helpers in `ReportLegendViews.swift` and heatmap renderers in `ReportHeatmapViews.swift`.
- `AnalysisRunsView` / `AnalysisRunsViewModel`
  Dedicated SwiftUI window showing a scrollable table of past analysis runs and their linked summary runs, with model, success/failure counts, token statistics, timing, and error messages. The view model subscribes to `appDatabaseDidChange` and reloads automatically.
- `AppLogStore`
  SQLite-backed runtime log list used by the menu-bar log window and the shared sink for non-fatal runtime failures.

## High-level flow

### 1. App startup

- `MenuBarApp` boots through `AppDelegate`.
- The app reads `databaseEncryptionEnabled` from UserDefaults before opening the database. If the setting is missing, the default is `false` and `SettingsStore` writes that explicit value back after startup. When enabled, it loads or creates the database passphrase in Keychain and opens or creates the SQLCipher database. When disabled, it opens the same database file as plaintext SQLite and does not require the Keychain database passphrase.
- If an existing encrypted database cannot be opened because the passphrase is missing or invalid, startup presents a recovery alert that can accept a manual key, delete only the database files, or quit.
- Settings are loaded from UserDefaults and Keychain.
- Services are created and started.
- The menu bar UI reflects pending screenshots, the single active run state, force-unload actions, and the log viewer entry point.

### Database encryption management

- The General settings tab exposes a Database Settings section with an encryption switch, a hidden new-key field, and an Open Database Location button below the settings surface.
- Encryption is disabled by default so first launch does not request Keychain access for the database. Enabling encryption generates a 16-character random passphrase and stores it in Keychain account `database-passphrase.main`.
- Turning encryption off decrypts the database to a temporary plaintext file through SQLCipher export, verifies the exported copy, replaces the database file and sidecars, and deletes the Keychain passphrase.
- Turning encryption back on generates a new passphrase, shows it once for confirmation, exports the plaintext database into an encrypted copy, verifies it, replaces the database file and sidecars, and stores the passphrase in Keychain.
- Changing the key uses SQLCipher `PRAGMA rekey` and then updates Keychain. If the Keychain write fails, the store attempts to rekey back to the previous passphrase before surfacing the error.
- Database encryption operations are blocked while screenshot analysis or work-content summary is running, because those flows may hold active database work and should not race a file replacement.

### 2. Screenshot capture flow

- `ScreenshotService` schedules screenshot captures using the configured screenshot interval.
- Before writing a screenshot, it checks whether the mouse location and frontmost app remain unchanged from the previous interval.
- If the user appears away, the app skips that capture without writing a screenshot or database record.
- Otherwise the capture path depends on `ScreenshotStorageLocation`:
  - **Disk** (default): saves a JPEG for the preferred display into Application Support, same as the original behavior.
  - **Memory**: encodes the screenshot as in-memory JPEG data and adds a `PendingScreenshot` value to `PendingScreenshotStore` without writing any file to the screenshots directory.
- A `PendingScreenshot` is the unified representation of a pending screenshot regardless of its backing storage. The rest of the pipeline — idle detection, analysis scanning, and cleanup — treats disk-backed and memory-backed `PendingScreenshot` values identically.
- `PendingScreenshotStore` is the combined manager that lists, removes, and counts both disk-backed and memory-backed pending screenshots. Analysis triggers, Clear Early Screenshots, and the automatic deletion timer all query the store instead of scanning the filesystem directly.
- Memory-backed screenshots exist only during the current process lifetime. They are discarded on app exit or system restart and are never written to the filesystem, SQLite, or Keychain.
- A successful capture (disk or memory) emits a capture-saved notification. When the analysis startup mode is realtime, `AnalysisService` waits one second and triggers a pending-screenshot scan.

### 3. Screenshot analysis flow

- `AnalysisService` can be started manually, by the configured scheduled time, or by realtime capture-saved notifications.
- Manual, scheduled, and realtime analysis all scan for pending screenshots through `PendingScreenshotStore`, which unifies the disk screenshot folder and in-memory pending screenshots into a single listing. Realtime analysis is triggered by the capture-saved notification, but the notification itself is only a timing signal.
- Every analysis trigger first passes through `AppRunCoordinator`. A trigger starts immediately only when no summary run is active; if a summary is running, the trigger is coalesced into the pending analysis bucket and is scanned after the summary finishes.
- If no pending screenshots exist, a trigger returns without creating an `analysis_runs` record.
- If a new analysis request arrives while a run is already active, the service scans pending screenshots and appends newly discovered files to the current queue instead of cancelling, pausing, or restarting the run.
- When the user cancels a run, the active queue stops accepting appends immediately; later triggers are coalesced into one follow-up pending scan instead of being merged into the cancelling run.
- The charger requirement applies to automatic triggers on devices with an internal battery: scheduled and realtime analysis honor it on MacBooks, while manual "Analyze Now" always starts when selected. Desktop Macs have no internal battery, so automatic triggers are treated as allowed even if an old stored preference still requires a charger.
- It creates a compact `analysis_runs` record for run-level status/counts and processes screenshots one by one. Each screenshot — whether file-backed or memory-backed — is loaded through `PendingScreenshotStore` and decoded by the same `AnalysisWorker` code path, so the storage mode is transparent to analysis.
- `analysis_runs.total_items` is updated when the active queue grows so the run progress stays aligned with the appended screenshots. Appended screenshots are sourced from `PendingScreenshotStore`, which includes both disk and memory entries.
- `AnalysisService` keeps run state on the main actor, but delegates each screenshot's long-running image load, OCR, model request, and response parsing to `AnalysisWorker` so UI state updates and cancellation stay responsive.
- `MenuBarApp` subscribes to both analysis and summary runtime notifications so the Current Status submenu can show the active analysis or summary run and manual LM Studio force-unload actions without relying on internal loaded-instance caches.
- Runtime state marks explicit LM Studio load phases separately, so the Current Status submenu can distinguish "Loading model" from a model that has already been loaded for active work.
- Before OCR, brightness checks, Apple Intelligence, or a multimodal model request, `AnalysisWorker` validates that the screenshot data can be decoded as an image. Invalid image data is recorded as a per-screenshot failure, logged to `app_logs`, removed from the pending screenshot directory, and never produces a fallback successful analysis result.
- After decode validation, `AnalysisWorker` decodes the screenshot into an 8-bit RGB buffer and averages all RGB pixel values. Screenshots with an average value of 2 or less are treated as inactive, recorded as `离开`, and removed through the same processed-file cleanup path.
- Depending on provider and analysis mode, the worker either:
  - runs local OCR first and sends text to a model, or
  - sends the screenshot image to a remote multimodal endpoint.
- If the screenshot-analysis profile uses LM Studio, the service explicitly loads that model before processing the run and reuses the loaded instance across all screenshots in the run.
- If the screenshot-analysis profile disables LM Studio lifecycle management, the service skips explicit load/unload calls and sends chat requests directly.
- `LLMService` translates the request into the provider-specific wire format and normalizes the response back into a shared result model.
- When the user pauses analysis while LM Studio is active, `AnalysisService` first waits for the in-flight generation request to stop and then issues the unload request for the loaded instance.
- Successful parsed results are written to `analysis_results`; duplicate capture times are ignored and the already-processed screenshot (file or memory) is removed from `PendingScreenshotStore` without overwriting the existing result.
- Failed per-screenshot attempts update run-level counts and also write actionable runtime errors to `app_logs`.
- After a run completes, the service updates run status and submits one unified summary request to the coordinator. That request has separate scopes for daily work-block summaries and daily report generation, but both pieces run inside the same work-content summary run. The summary run starts only after the analysis runtime state is idle. If LM Studio is involved, the analysis-to-summary handoff still decides whether to reuse, unload, switch, or temporarily load a summary model based on the two model profiles and their lifecycle toggles.
- Manual analysis sends a completion notification after the run result is known. If daily reports are candidates, the notification is deferred until the unified summary run finishes so the message can include generated daily reports or summary failures. Scheduled and realtime runs stay quiet when they only succeed at screenshot analysis, but they notify when daily reports are generated or when the run fails.
- While realtime startup mode is active, `AnalysisService` also samples the pending screenshot count every five minutes. If the count has grown by at least five since the previous sample, it sends a local warning notification that realtime analysis may be backlogged. This monitor only observes the screenshot folder and does not create, cancel, or reprioritize runs.

### 4. Daily summary flow

- Summary entry points also pass through `AppRunCoordinator`: backfill, missing daily reports, analysis-triggered work-block plus daily-report work, affected-day work-block summaries, and manually generated daily reports all share the same summary run kind.
- If a summary request arrives while a summary run is active, it is merged into the active summary accumulator. If it arrives during screenshot analysis, it is coalesced into the pending summary bucket and starts after analysis finishes.
- Summary requests carry an optional notification intent. Backfill intents merge into one completion notification, while analysis-completion intents carry screenshot success and failure counts from the originating analysis run.
- A summary request explicitly separates its work-block scope from its daily-report scope. Work-block scopes target affected days or all missing blocks. Daily-report scopes target explicit candidate days or all missing final-ready reports. Affected work-block days do not imply a global daily-report scan.
- Analysis-triggered daily-report scopes depend on the run trigger. Manual and scheduled analysis use the continuous day range covered by successfully processed screenshots in that run. Pure realtime analysis compares successfully processed result days with the last persisted analysis result before the run; it only candidates earlier days when a day boundary was crossed. If a manual or scheduled trigger merges into an active realtime run, that run upgrades to the bounded day-range behavior.
- `DailyReportSummaryService` fetches analyzed activity items that overlap the target day.
- Automatic daily-report candidate discovery enumerates every day overlapped by each reportable activity's half-open `[capturedAt, capturedAt + duration_minutes_snapshot)` interval. An activity that crosses midnight can therefore candidate the next day even when that day has no new capture timestamp, while an activity ending exactly at midnight does not candidate the following day.
- The fetch includes the last result before the target day only when its stored duration crosses into the day, then clips that item to start at the report day boundary.
- Items captured during the target day are clipped at the next day boundary when their stored duration crosses midnight.
- The service does not need the first result from the following day for daily-summary generation because each persisted result already carries its own `duration_minutes_snapshot`.
- Away or inactive intervals are not persisted and are not included in daily-summary generation or per-category summaries.
- It builds a text timeline prompt from category, duration, and per-item summary data. Reportable rows without non-empty analysis summaries are treated as not ready and are not handled with historical fallback placeholders.
- The summary is generated through the configured work-content model profile via `LLMService`.
- If the work-content summary profile enables LM Studio lifecycle management, `DailyReportSummaryService` explicitly loads the summary model before generation and unloads it after generation. If the user stops an active summary run, the service cancels the in-flight model request and still issues the LM Studio unload request before returning to idle.
- When called by `AnalysisService` immediately after a completed analysis run, `DailyReportSummaryService` can instead reuse an already loaded LM Studio model or load a different summary model according to the handoff policy and the two lifecycle toggles.
- `DailyReportSummaryService` also exposes observable runtime state so the menu bar can render "Running: Work Content Summary", a progress percentage, explicit model loading, and the stop/unload phase while cancellation is in progress.
- Results are stored in `daily_reports`; temporary summaries are marked with `is_temporary` instead of encoded into summary text.
- Automatic daily-summary backfill writes only final reports for reportable days before the latest reportable activity day, so automatic output is never marked temporary. Manual immediate summarization uses the same completion rule: the latest reportable activity day is temporary, and any earlier reportable day is final even when there are empty calendar days in between.
- Contiguous same-category work blocks are also summarized into `daily_work_block_summaries` for daily heatmap hover text. Cross-day blocks stay whole for model summarization and storage, and rendering clips them to the visible report range.
- Work-block summary prompts include only category and source summary text. They intentionally do not include explicit start times, end times, durations, or dates so the model does not evaluate the schedule itself.
- A single source item with a non-empty summary is stored directly. A multi-item block calls the model only when at least two source items have non-empty summaries, and each model request summarizes exactly one block.
- Background summary failures are recorded in `app_logs`; cancellation and no-activity outcomes are diagnostic `log` entries, while provider, database, and lifecycle failures are `error` entries. Backfill completion notifications report newly created work-block summaries and daily reports; analysis-triggered notifications report screenshot and daily-report counts only.

### 5. Reporting flow

- `ReportsViewModel` loads successfully analyzed source items from the database.
- It derives display-only away intervals from gaps between adjacent persisted analysis results; it does not derive leading gaps before the first item or trailing gaps after the latest item.
- Cross-day away gaps are split at report-day boundaries before aggregation.
- It builds date ranges for day, week, month, and year views.
- Real activity is split into day-clipped half-open segments before report ranges are built. Day, week, month, and year totals, item counts, and average hours per day are derived from those clipped segments, so activity that crosses a day, week, month, or year boundary appears in every overlapped reporting period with only the duration that belongs to that period.
- It transforms raw items into:
  - aggregated category durations for bar charts
  - normalized event blocks for heatmaps
  - daily summary records for the selected day
- Daily heatmaps prefer `daily_work_block_summaries` where records overlap the visible range. Uncovered time ranges fall back to `analysis_results` for visual blocks only; hover text is shown only for records stored in `daily_work_block_summaries`. Overlaps are subtracted so a stored work-block summary owns its full interval.
- Weekly heatmaps normalize brightness for selected non-away categories as one combined pool, while away time is normalized separately. The preserved Other category and Away are ordered last in legends and heatmap rows; bar charts omit Away bars but keep Away in the legend.
- Daily heatmap hover details are shown in the left report-selection area so hover text does not move the heatmap layout. The visible rectangle is clipped to the selected day, but the hover title uses the full stored work-block time span.
- Chart legends, bars, and heatmap blocks use the fixed color stored on each category rule, with a preset fallback for historical categories that are no longer configured.
- `ReportsView.swift` stays focused on panel composition and high-level chart selection. `ReportLegendViews.swift` owns legend hover geometry and wrapping layout, while `ReportHeatmapViews.swift` owns day, week, month, and year heatmap rendering.

## Settings model

The app intentionally keeps two model profiles:

- Screenshot analysis profile
  Used by `AnalysisService` for classifying screenshots.
- Work-content summary profile
  Used by `DailyReportSummaryService` for generating daily summaries.

This separation allows the app to use different providers, credentials, or model sizes for image-heavy analysis and text-only summarization.
For LM Studio handoff, two profiles are considered the same loaded model only when their normalized chat endpoint, trimmed model name, and context length are equal. API keys are used for requests but are not part of the equivalence check.
Each profile also carries its own LM Studio lifecycle toggle so the app can skip explicit load/unload calls when the model is already resident in the background.
API key writes are treated as durable settings changes: `SettingsStore` records Keychain write or delete failures in `app_logs`, rolls the affected setting back to the last persisted value, and exposes a `SettingsPersistenceAlert` so `SettingsView` can block with a localized alert instead of letting the user leave with an unsaved credential.

## State propagation

- Persistence changes emit notifications through `NotificationCenter`.
- UI-facing observable objects subscribe to those notifications and reload derived state.
- `AnalysisService` and `DailyReportSummaryService` both post status-change notifications so the menu bar can update current-state text and force-unload button availability without polling.
- `SettingsStore` is the authoritative source for user-editable configuration at runtime.
- Services consume immutable snapshots when starting work to avoid mid-run drift.
- `AppLogStore` is the authoritative source for runtime log entries shown in the UI; it reloads from SQLite after each mutation and emits `appLogsDidChange`.
- Services should not silently swallow filesystem, database, screenshot, model-lifecycle, or report-loading failures. Expected parse probes and cancellation sleeps can stay local, but ignored operational failures should be classified as user-ignorable `log` entries or actionable `error` entries in `AppLogStore`.
- `SystemAppNotificationService` requests notification authorization only when a message is first sent. Denied permission or notification delivery failures are logged through `AppLogStore` and must not change analysis or summary run outcomes.

## Architectural constraints

- The app is intentionally local-first.
- There is no dependency injection framework; services are wired manually at launch.
- The app relies on OS facilities for screenshot capture, OCR, Keychain access, and Apple Intelligence availability.
- The current codebase favors direct service composition over protocol-heavy abstraction.
- Provider-specific HTTP payloads are centralized in `LLMService.swift`, with LM Studio v1 request helpers isolated in `LMStudioAPI.swift`.
- LM Studio model lifecycle is explicit at feature-entry boundaries and must not be hidden inside `LLMService.send(_:)`.
- Runtime debugging logs are persisted in SQLite rather than kept only in memory, so the log window survives relaunches and supports later instrumentation.
