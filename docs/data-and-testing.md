# Data and Testing

## Local storage layout

The app stores runtime data under Application Support:

- Database
  `~/Library/Application Support/DeskBrief/desk-brief.sqlite`
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
- `analysis_results`
  Successful per-item screenshot analysis output, including capture time, category, summary, and duration snapshot.
  `captured_at` is unique; duplicate inserts are ignored so an existing result is not overwritten.
- `daily_reports`
  Generated daily summaries and per-category summary payloads for reportable, non-away activity. `is_temporary` marks summaries that may be replaced after the next day has activity.
- `daily_work_block_summaries`
  Daily heatmap hover summaries for contiguous same-category work blocks. The schema is intentionally minimal: `id`, `category_name`, `start_at`, `end_at`, and `summary_text`, with `(start_at, end_at)` unique. Cross-day blocks are stored as one interval instead of being split by date.
- `app_logs`
  Persistent runtime log entries for recoverable runtime failures and debugging events. Sources include analysis, LM Studio, screenshot capture, reports, daily summaries, settings, and app-level status refreshes.

## Persistence model

### SQLite

SQLite is the source of truth for captured work history, analysis outputs, and generated daily reports.
It also stores lightweight runtime logs in `app_logs`, capped to the latest 1000 entries.
Away intervals are not persisted; report views derive display-only `离开` blocks from bounded gaps between adjacent successful analysis results.
Failed per-screenshot attempts are counted on `analysis_runs` but are not persisted as `analysis_results` rows.
Duplicate capture-time results are treated as already processed: the screenshot file is removed and the original `analysis_results` row remains unchanged.
Temporary daily reports are tracked by `daily_reports.is_temporary`.
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

### Keychain

Keychain stores API keys for the two model profiles:

- screenshot analysis key
- work-content summary key

## File conventions

- Screenshot files are saved as JPEG.
- The filename format is `yyyyMMdd-HHmm-i<minutes>.jpg`.
- Preview screenshots add a `-preview` suffix.
- Model-test screenshots add a `-model-test` suffix.

The filename is not just cosmetic: the app derives capture time and duration metadata from it when loading pending screenshot files.
The Clear Early Screenshots menu only scans and deletes pending JPEG files in the screenshot directory root. It does not inspect or remove files from the `preview/` or `temp/` subdirectories, and its count cache is in memory only.

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

## Known testing caveats

- Sandboxed CLI environments may print CoreSimulator warnings even for macOS targets.
- Distributed-notification warnings from `xcodebuild` are common in restricted environments and do not automatically indicate a product bug.
- When settings-model fields change, hand-written test initializers are a common failure point.
- `DeskBriefTests` is one serialized Swift Testing suite split across themed `extension DeskBriefTests` files. Shared fixtures, mock sessions, SQLite helpers, and `MockURLProtocol` live in `TestSupport.swift`.

## Useful inspection commands

List tables:

```sh
sqlite3 "$HOME/Library/Application Support/DeskBrief/desk-brief.sqlite" '.tables'
```

Recent analysis runs:

```sh
sqlite3 "$HOME/Library/Application Support/DeskBrief/desk-brief.sqlite" \
  "select id,status,model_name,total_items,success_count,failure_count,average_item_duration_seconds from analysis_runs order by id desc limit 20;"
```

Recent analysis results:

```sh
sqlite3 "$HOME/Library/Application Support/DeskBrief/desk-brief.sqlite" \
  "select id,datetime(captured_at,'unixepoch','localtime'),category_name,substr(ifnull(summary_text,''),1,80) from analysis_results order by id desc limit 20;"
```

Daily report activity items are based on the target day plus the immediately preceding result when that result overlaps the day by `duration_minutes_snapshot`.
The summarizer clips overlapping activity to the day interval before building the model prompt, so a result captured at 23:53 for 10 minutes appears in the next day's prompt as a 00:00 activity for the overlapping minutes.
It does not read the first result after the day because persisted result durations already define each result's end time.
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
