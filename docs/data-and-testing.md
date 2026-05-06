# Data and Testing

## Local storage layout

The app stores runtime data under Application Support:

- Database
  `~/Library/Application Support/DeskBrief/desk-brief.sqlite`
  The SQLite file is encrypted with SQLCipher. The database passphrase is stored in Keychain under service `com.iBobby.DeskBrief` and account `database-passphrase.main`.
- Screenshot directory
  `~/Library/Application Support/DeskBrief/screenshots/`
- Preview screenshots
  `~/Library/Application Support/DeskBrief/screenshots/preview/`
- Model-test temporary screenshots
  `~/Library/Application Support/DeskBrief/screenshots/temp/`

## Database tables

- `category_rules`
  User-defined category definitions, fixed display colors, and ordering, without timestamp metadata.
- `analysis_runs`
  One compact record per analysis batch, including run status, model name, item counts, average item duration, and run-level error text.
  `total_items` can grow during an active run when new screenshots are appended to the same queue.
- `summary_runs`
  One record per work-content summary batch, including status, model name, item counts, token usage, average item duration, and error text. Optionally linked to its originating `analysis_runs` row via `analysis_run_id`.
- `analysis_results`
  Successful per-item screenshot analysis output, including capture time, category, summary, and duration snapshot.
  `captured_at` is unique; duplicate inserts are ignored so an existing result is not overwritten.
  Screenshots whose decoded 8-bit RGB average is 2 or less are stored as the internal away category `离开` without making an OCR or model request, then the pending screenshot file is removed.
  Invalid or unreadable screenshot image data is not stored as a successful result; it is counted as a failed screenshot, logged, and removed from the pending queue.
- `daily_reports`
  Generated daily summaries and per-category summary payloads for reportable, non-away activity. `is_temporary` marks manual summaries for the latest reportable activity day, which may be replaced after later activity exists.
- `daily_work_block_summaries`
  Daily heatmap hover summaries for contiguous same-category work blocks. The schema is intentionally minimal: `id`, `category_name`, `start_at`, `end_at`, and `summary_text`, with `(start_at, end_at)` unique. Cross-day blocks are stored as one interval instead of being split by date.
- `app_logs`
  Persistent runtime log entries for recoverable runtime failures and debugging events. Sources include analysis, LM Studio, screenshot capture, reports, daily summaries, settings, and app-level status refreshes.

## Persistence model

### SQLite / SQLCipher

SQLite is the source of truth for captured work history, analysis outputs, and generated daily reports. Runtime access goes through SQLCipher; a missing or invalid database passphrase blocks startup before services are created.
The system `sqlite3` CLI is expected to fail against the encrypted runtime database unless it is pointed at a plaintext backup or an unencrypted test fixture. Runtime database inspection should use a SQLCipher-linked helper that loads the passphrase from Keychain.
It also stores lightweight runtime logs in `app_logs`, capped to the latest 1000 entries.
Away intervals caused by missing captures are not persisted; report views derive those display-only `离开` blocks from bounded gaps between adjacent successful analysis results. Fully dark screenshots can be persisted as `离开` results so their capture time is retained without sending the image to a model.
Failed per-screenshot attempts are counted on `analysis_runs` but are not persisted as `analysis_results` rows.
Invalid screenshot image data follows the failed-attempt path instead of the inactive-screenshot path. The app validates decodeability before OCR, brightness checks, Apple Intelligence, or multimodal dispatch, then logs and removes the pending file so a damaged image cannot retry forever or turn into an empty OCR fallback classification.
Duplicate capture-time results are treated as already processed: the screenshot file is removed and the original `analysis_results` row remains unchanged.
Temporary daily reports are tracked by `daily_reports.is_temporary`. Automatic backfill only writes final reports for days before the latest reportable activity day; manual immediate summaries use the same day-completion rule to decide whether the requested day is temporary.
Daily report generation expects every reportable `analysis_results` row in the requested day to have a non-empty `summary_text`. Rows without summaries are treated as not ready; the app no longer uses compatibility placeholder text for old summary-less analysis results.
Analysis-triggered summary work is queued as one work-content summary run with separate scopes for work-block summaries and daily reports. Manual and scheduled analysis only check daily reports in the processed screenshot day range. Realtime analysis only checks daily reports when the new run crosses a day boundary compared with the previous persisted analysis result. Manual backfill remains the only path that scans all missing work-block summaries and all final-ready missing daily reports.
Daily work-block summaries are derived from `analysis_results` and stored only when the source data is useful enough for hover text. A single source item keeps its original non-empty summary. A multi-item block calls the work-content model only when at least two source items have non-empty summaries; otherwise the block is skipped and logged as an ignorable summary event.
When report rendering mixes `daily_work_block_summaries` with raw `analysis_results`, summary rows take precedence and raw rows are clipped around them to avoid overlap. Raw `analysis_results.summary_text` values are not shown directly in daily heatmap hover text; they must be copied or summarized into `daily_work_block_summaries` first.

Runtime failures that the app can recover from should still be visible in `app_logs`:

- `error`
  Actionable failures that likely need user or developer attention, such as database writes, screenshot capture failures, report loading failures, model calls, and LM Studio lifecycle failures.
- `log`
  Diagnostic or user-ignorable outcomes, such as cancellation, no reportable activity, missing already-pending screenshot files, and expected lifecycle traces.

Intentional parsing probes, fallback candidate decoding, and cancellation sleeps are not logged by themselves; the caller records a single higher-level failure if all candidates or retries fail.

### UserDefaults

UserDefaults stores lightweight preferences such as:

- screenshot interval
- analysis time
- analysis startup mode
- automatic-analysis charger requirement
- language
- provider selection
- base URLs
- model names
- LM Studio auto load/unload toggles for the screenshot-analysis and work-content-summary profiles
- image analysis methods
- screenshot auto-deletion retention (off, 7 days, 14 days, 28 days; default 28 days)
- screenshot storage location (com.deskbrief.settings.screenshotStorageLocation, raw values "disk" / "memory", default "disk")

### Memory screenshot storage

When `ScreenshotStorageLocation` is set to `Memory`, scheduled screenshots are captured as in-memory JPEG data and held in `PendingScreenshotStore` without writing files to the screenshot directory. Memory-backed screenshots exist only during the current process lifetime — there is no file persistence and no SQLite entry for the raw screenshot image. The analysis pipeline treats memory-backed `PendingScreenshot` values identically to disk-backed ones: the storage difference is transparent to OCR, model analysis, duplicate detection, and result persistence.

### Keychain

Keychain stores the database passphrase and API keys for the two model profiles:

- encrypted database passphrase (`database-passphrase.main`)
- screenshot analysis key
- work-content summary key

Keychain writes and deletes are not silent. If saving or deleting either API key fails, `SettingsStore` rolls the visible setting back to the last persisted value, writes a `settings` error to `app_logs`, and publishes a localized blocking alert for `SettingsView`.

## File conventions

- Screenshot files are saved as JPEG.
- The filename format is `yyyyMMdd-HHmm-i<minutes>.jpg`.
- Preview screenshots add a `-preview` suffix.
- Model-test screenshots add a `-model-test` suffix.

The filename is not just cosmetic: the app derives capture time and duration metadata from it when loading pending screenshot files.
The Clear Early Screenshots menu scans and deletes pending JPEG files in the screenshot directory root, and also clears memory-backed pending screenshots from `PendingScreenshotStore`. It does not inspect or remove files from the `preview/` or `temp/` subdirectories, and its count cache is in memory only.

The Automatic Screenshot Deletion setting scans and deletes pending JPEG files in the screenshot directory root, and also clears memory-backed pending screenshots from `PendingScreenshotStore` (memory screenshots are always older than the retention threshold if any real time has passed, since they cannot survive an app restart). It never touches `preview/` or `temp/` subdirectories. The retention period is measured from the parsed screenshot capture timestamp (`capturedAt`), not filesystem modification time. The timer checks once per hour.

When storage location is `Disk`, all pending screenshots are files in the screenshot directory and the store mirrors the filesystem. When storage location is `Memory`, pending screenshots exist only in the store and the filesystem directory is not involved.

## Recommended test command

Use an explicit DerivedData path in sandboxed or automation-driven environments:

```sh
xcodebuild test \
  -project DeskBrief.xcodeproj \
  -scheme DeskBrief \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/DeskBriefDerivedData \
  CODE_SIGNING_ALLOWED=NO
```

To focus on unit-style coverage first:

```sh
xcodebuild test \
  -project DeskBrief.xcodeproj \
  -scheme DeskBrief \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/DeskBriefDerivedData \
  -only-testing:DeskBriefTests \
  CODE_SIGNING_ALLOWED=NO
```

To run the UI smoke tests only:

```sh
xcodebuild test \
  -project DeskBrief.xcodeproj \
  -scheme DeskBrief \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/DeskBriefDerivedData \
  -only-testing:DeskBriefUITests \
  CODE_SIGNING_ALLOWED=NO
```

Release build verification:

```sh
xcodebuild build \
  -project DeskBrief.xcodeproj \
  -scheme DeskBrief \
  -configuration Release \
  -derivedDataPath /tmp/DeskBriefReleaseDerivedData \
  CODE_SIGNING_ALLOWED=NO
```

## Known testing caveats

- Sandboxed CLI environments may print CoreSimulator warnings even for macOS targets.
- Distributed-notification warnings from `xcodebuild` are common in restricted environments and do not automatically indicate a product bug.
- When settings-model fields change, hand-written test initializers are a common failure point.
- `DeskBriefTests` is one serialized Swift Testing suite split across themed `extension DeskBriefTests` files. Shared fixtures, mock sessions, SQLite helpers, and `MockURLProtocol` live in `TestSupport.swift`.
- Memory-backed pending screenshots exist only during process lifetime, so tests that exercise the memory storage path must create `PendingScreenshot` values directly in `PendingScreenshotStore` rather than writing files to the screenshots directory. On tear-down, the store is cleared and no cleanup of the filesystem screenshot directory is needed for the memory path.
- `DeskBriefUITests` uses `--deskbrief-ui-testing` plus isolated support directory, UserDefaults suite, and Keychain service environment variables. That launch mode disables background services and supports hooks for opening settings, reports, and logs windows, so smoke tests do not touch real user data.
- UI launch performance uses `XCTClockMetric` with explicit app termination between iterations to avoid flaky missing launch metrics for a menu-bar accessory app.

## Useful inspection commands

The following `sqlite3` examples apply to plaintext backups or unencrypted test fixtures. They are intentionally not suitable for the encrypted runtime database.

List tables:

```sh
sqlite3 "$HOME/Library/Application Support/DeskBrief/desk-brief.sqlite" '.tables'
```

Recent analysis runs:

```sh
sqlite3 "$HOME/Library/Application Support/DeskBrief/desk-brief.sqlite" \
  "select id,status,model_name,total_items,success_count,failure_count,average_item_duration_seconds from analysis_runs order by id desc limit 20;"
```

Recent summary runs (token usage and duration per item):

```sh
sqlite3 "$HOME/Library/Application Support/DeskBrief/desk-brief.sqlite" \
  "select id,status,model_name,total_items,success_count,failure_count,input_mean_tokens,output_mean_tokens,average_item_duration_seconds,error_message from summary_runs order by id desc limit 20;"
```

Recent analysis results:

```sh
sqlite3 "$HOME/Library/Application Support/DeskBrief/desk-brief.sqlite" \
  "select id,datetime(captured_at,'unixepoch','localtime'),category_name,substr(ifnull(summary_text,''),1,80) from analysis_results order by id desc limit 20;"
```

Daily report activity items are based on the target day plus the immediately preceding result when that result overlaps the day by `duration_minutes_snapshot`.
The summarizer clips overlapping activity to the day interval before building the model prompt, so a result captured at 23:53 for 10 minutes appears in the next day's prompt as a 00:00 activity for the overlapping minutes.
It does not read the first result after the day because persisted result durations already define each result's end time.
Automatic daily-report candidate discovery uses the same half-open activity intervals to enumerate every covered day. A cross-midnight result can candidate the next day without a capture timestamp on that day, but a result ending exactly at 00:00 does not include the following day.
Work-block summary generation uses the uncropped `analysis_results` timeline so cross-day blocks remain intact for storage and AI summarization.

Recent daily reports:

```sh
sqlite3 "$HOME/Library/Application Support/DeskBrief/desk-brief.sqlite" \
  "select id,datetime(day_start,'unixepoch','localtime'),is_temporary,substr(daily_summary_text,1,120) from daily_reports order by day_start desc limit 20;"
```

Recent daily work-block summaries:

```sh
sqlite3 "$HOME/Library/Application Support/DeskBrief/desk-brief.sqlite" \
  "select id,category_name,datetime(start_at,'unixepoch','localtime'),datetime(end_at,'unixepoch','localtime'),substr(summary_text,1,120) from daily_work_block_summaries order by start_at desc limit 20;"
```

Recent runtime logs:

```sh
sqlite3 "$HOME/Library/Application Support/DeskBrief/desk-brief.sqlite" \
  "select datetime(created_at,'unixepoch','localtime'),level,source,substr(message,1,160) from app_logs order by created_at desc limit 50;"
```

Recent screenshots:

```sh
ls -lah "$HOME/Library/Application Support/DeskBrief/screenshots" | tail
```

## Persistence safety changes (2026-05-05)

### F9: Parameterized LIMIT in log queries
`fetchAppLogs(limit:)` uses `LIMIT ?` with `sqlite3_bind_int64` instead of string interpolation. `limit <= 0` returns an empty array; `nil` omits the LIMIT clause.
`pruneAppLogsIfNeeded(lock:maxEntries:)` uses the same pattern. `maxEntries <= 0` still deletes all entries.

### F14: SQLite text binding with sqlite3_malloc64 + sqlite3_free
`DatabaseConnection.bind(_:at:to:)` allocates a buffer with `sqlite3_malloc64`, copies the Swift string's UTF-8 bytes, and passes `sqlite3_free` as the `sqlite3_bind_text` destructor. On allocation or bind failure it throws `DatabaseError.execute(...)`. Callers use `try lock.bind(...)`.

### F16: Error enum Equatable conformance
All custom error enums now conform to `Equatable`:
- `DatabaseError`
- `AnalysisServiceError`
- `DailyReportSummaryServiceError`
- `ModelMemoryError`
- `LMStudioModelLifecycleError`
- `LLMServiceError` (manual implementation uses `String(reflecting:)` for the `appleIntelligenceUnavailable` case's `SystemLanguageModel.Availability.UnavailableReason`)

`LocalizedError` conformance and message formatting are unchanged.

### UserDefaults key namespacing
All `SettingsStore.Keys` and `AppLanguage.userDefaultsKey` now use the `com.deskbrief.settings.` prefix:

| Scope | Old key | New key |
|-------|---------|---------|
| Settings keys | `settings.*` | `com.deskbrief.settings.*` |
| App language | `settings.appLanguage` | `com.deskbrief.settings.appLanguage` |

Reading uses `UserDefaults.objectWithFallback(newKey:oldKey:)` which checks the new key first, falls back to the old key, and migrates the value to the new key. Writing only updates the new key. Old keys are not removed.
