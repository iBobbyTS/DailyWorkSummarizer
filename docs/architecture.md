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

### 2. Capture flow

- `ScreenshotService` schedules captures using the configured screenshot interval.
- Before writing a screenshot, it checks whether the mouse location and frontmost app remain unchanged from the previous interval.
- If the user appears away, the app records an absence event instead of a screenshot.
- Otherwise it saves a JPEG for the preferred display into Application Support.

### 3. Screenshot analysis flow

- `AnalysisService` finds pending screenshot files from local storage.
- It creates an `analysis_runs` record and processes screenshots one by one.
- Depending on provider and analysis mode, it either:
  - runs local OCR first and sends text to a model, or
  - sends the screenshot image to a remote multimodal endpoint.
- `LLMService` translates the request into the provider-specific wire format and normalizes the response back into a shared result model.
- When the user pauses analysis while LM Studio is active, `AnalysisService` first waits for the in-flight generation request to stop and then issues the unload request.
- Parsed results are written to `analysis_results`.
- After a run completes, the service updates run status and may trigger daily-summary backfill.

### 4. Daily summary flow

- `DailyReportSummaryService` fetches analyzed activity items for a target day.
- Away or inactive intervals recorded in `absence_events` are excluded from daily-summary generation and per-category summaries.
- It builds a text timeline prompt from category, duration, and per-item summary data.
- The summary is generated through the configured work-content model profile via `LLMService`.
- Results are stored in `daily_reports`.

### 5. Reporting flow

- `ReportsViewModel` loads source items from the database.
- It builds date ranges for day, week, month, and year views.
- It transforms raw items into:
  - aggregated category durations for bar charts
  - normalized event blocks for heatmaps
  - daily summary records for the selected day

## Settings model

The app intentionally keeps two model profiles:

- Screenshot analysis profile
  Used by `AnalysisService` for classifying screenshots.
- Work-content analysis profile
  Used by `DailyReportSummaryService` for generating daily summaries.

This separation allows the app to use different providers, credentials, or model sizes for image-heavy analysis and text-only summarization.

## State propagation

- Persistence changes emit notifications through `NotificationCenter`.
- UI-facing observable objects subscribe to those notifications and reload derived state.
- `SettingsStore` is the authoritative source for user-editable configuration at runtime.
- Services consume immutable snapshots when starting work to avoid mid-run drift.
- `AppLogStore` is the authoritative source for runtime log entries shown in the UI; it reloads from SQLite after each mutation and emits `appLogsDidChange`.

## Architectural constraints

- The app is intentionally local-first.
- There is no dependency injection framework; services are wired manually at launch.
- The app relies on OS facilities for screen capture, OCR, Keychain access, and Apple Intelligence availability.
- The current codebase favors direct service composition over protocol-heavy abstraction.
- Provider-specific HTTP payloads are centralized in `LLMService.swift`, with LM Studio v1 request helpers isolated in `LMStudioAPI.swift`.
- Runtime debugging logs are persisted in SQLite rather than kept only in memory, so the log window survives relaunches and supports later instrumentation.
