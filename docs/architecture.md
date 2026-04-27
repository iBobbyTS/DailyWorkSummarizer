# Architecture

## Runtime composition

The app is centered around a small set of long-lived services created at launch by `AppDelegate`:

- `AppDatabase`
  SQLite-backed persistence and migration layer.
- `SettingsStore`
  UserDefaults and Keychain-backed settings state exposed to SwiftUI.
- `ScreenshotService`
  Periodic capture scheduling, permission checks, and idle detection.
- `AnalysisService`
  Pending screenshot processing, OCR, model invocation, structured parsing, and retry behavior.
- `DailyReportSummaryService`
  Daily-summary generation and backfill for missing days.
- `LLMService`
  Shared provider adapter for OpenAI, Anthropic, LM Studio, and Apple Intelligence.
- `LMStudioModelLifecycle`
  Explicit LM Studio load/unload helper used by analysis, summaries, and settings model tests.
- `ReportsViewModel`
  Report range construction, chart data, heatmap data, and daily report presentation.
- `AppLogStore`
  SQLite-backed runtime log list used by the menu-bar log window.

## High-level flow

### 1. App startup

- `MenuBarApp` boots through `AppDelegate`.
- The app opens or creates the SQLite database.
- Settings are loaded from UserDefaults and Keychain.
- Services are created and started.
- The menu bar UI reflects pending screenshots, active analysis state, and the log viewer entry point.

### 2. Screenshot capture flow

- `ScreenshotService` schedules screenshot captures using the configured screenshot interval.
- Before writing a screenshot, it checks whether the mouse location and frontmost app remain unchanged from the previous interval.
- If the user appears away, the app skips that capture without writing a screenshot or database record.
- Otherwise it saves a JPEG for the preferred display into Application Support.
- A successful saved screenshot emits a capture-saved notification. When the analysis startup mode is realtime, `AnalysisService` waits one second and triggers a pending-screenshot scan.

### 3. Screenshot analysis flow

- `AnalysisService` can be started manually, by the configured scheduled time, or by realtime capture-saved notifications.
- Manual, scheduled, and realtime analysis all scan the pending screenshot folder. Realtime analysis is triggered by the capture-saved notification, but the notification URL is only a timing signal.
- If no pending screenshots exist, a trigger returns without creating an `analysis_runs` record.
- If a new analysis request arrives while a run is already active, the service scans pending screenshots and appends newly discovered files to the current queue instead of cancelling, pausing, or restarting the run.
- When the user cancels a run, the active queue stops accepting appends immediately; later triggers are coalesced into one follow-up pending scan instead of being merged into the cancelling run.
- The charger requirement applies to automatic triggers: scheduled and realtime analysis honor it, while manual "Analyze Now" always starts when selected.
- It creates a compact `analysis_runs` record for run-level status/counts and processes screenshots one by one.
- `analysis_runs.total_items` is updated when the active queue grows so the run progress stays aligned with the appended screenshots.
- Depending on provider and analysis mode, it either:
  - runs local OCR first and sends text to a model, or
  - sends the screenshot image to a remote multimodal endpoint.
- If the screenshot-analysis profile uses LM Studio, the service explicitly loads that model before processing the run and reuses the loaded instance across all screenshots in the run.
- `LLMService` translates the request into the provider-specific wire format and normalizes the response back into a shared result model.
- When the user pauses analysis while LM Studio is active, `AnalysisService` first waits for the in-flight generation request to stop and then issues the unload request for the loaded instance.
- Successful parsed results are written to `analysis_results`; duplicate capture times are ignored and the already-processed screenshot file is removed without overwriting the existing result.
- Failed per-screenshot attempts only update run-level counts and errors.
- After a run completes, the service updates run status and may trigger daily-summary backfill. If LM Studio is involved, the analysis-to-summary handoff decides whether to reuse, unload, switch, or temporarily load a summary model based on the two model profiles.

### 4. Daily summary flow

- `DailyReportSummaryService` fetches analyzed activity items that overlap the target day.
- The fetch includes the last result before the target day only when its stored duration crosses into the day, then clips that item to start at the report day boundary.
- Items captured during the target day are clipped at the next day boundary when their stored duration crosses midnight.
- The service does not need the first result from the following day for daily-summary generation because each persisted result already carries its own `duration_minutes_snapshot`.
- Away or inactive intervals are not persisted and are not included in daily-summary generation or per-category summaries.
- It builds a text timeline prompt from category, duration, and per-item summary data.
- The summary is generated through the configured work-content model profile via `LLMService`.
- If a standalone daily summary uses LM Studio, `DailyReportSummaryService` explicitly loads the summary model before generation and unloads it after generation.
- When called by `AnalysisService` immediately after a completed analysis run, `DailyReportSummaryService` can instead reuse an already loaded LM Studio model or load a different summary model and keep it loaded according to the handoff policy.
- Results are stored in `daily_reports`.

### 5. Reporting flow

- `ReportsViewModel` loads successfully analyzed source items from the database.
- It derives display-only away intervals from gaps between adjacent persisted analysis results; it does not derive leading gaps before the first item or trailing gaps after the latest item.
- Cross-day away gaps are split at report-day boundaries before aggregation.
- It builds date ranges for day, week, month, and year views.
- It transforms raw items into:
  - aggregated category durations for bar charts
  - normalized event blocks for heatmaps
  - daily summary records for the selected day
- Chart legends, bars, and heatmap blocks use the fixed color stored on each category rule, with a preset fallback for historical categories that are no longer configured.

## Settings model

The app intentionally keeps two model profiles:

- Screenshot analysis profile
  Used by `AnalysisService` for classifying screenshots.
- Work-content summary profile
  Used by `DailyReportSummaryService` for generating daily summaries.

This separation allows the app to use different providers, credentials, or model sizes for image-heavy analysis and text-only summarization.
For LM Studio handoff, two profiles are considered the same loaded model only when their normalized chat endpoint, trimmed model name, and context length are equal. API keys are used for requests but are not part of the equivalence check.

## State propagation

- Persistence changes emit notifications through `NotificationCenter`.
- UI-facing observable objects subscribe to those notifications and reload derived state.
- `SettingsStore` is the authoritative source for user-editable configuration at runtime.
- Services consume immutable snapshots when starting work to avoid mid-run drift.
- `AppLogStore` is the authoritative source for runtime log entries shown in the UI; it reloads from SQLite after each mutation and emits `appLogsDidChange`.

## Architectural constraints

- The app is intentionally local-first.
- There is no dependency injection framework; services are wired manually at launch.
- The app relies on OS facilities for screenshot capture, OCR, Keychain access, and Apple Intelligence availability.
- The current codebase favors direct service composition over protocol-heavy abstraction.
- Provider-specific HTTP payloads are centralized in `LLMService.swift`, with LM Studio v1 request helpers isolated in `LMStudioAPI.swift`.
- LM Studio model lifecycle is explicit at feature-entry boundaries and must not be hidden inside `LLMService.send(_:)`.
- Runtime debugging logs are persisted in SQLite rather than kept only in memory, so the log window survives relaunches and supports later instrumentation.
