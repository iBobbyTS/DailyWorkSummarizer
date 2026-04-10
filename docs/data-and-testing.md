# Data and Testing

## Local storage layout

The app stores runtime data under Application Support:

- Database
  `~/Library/Application Support/DailyWorkSummarizer/daily-work-summarizer.sqlite`
- Screenshot directory
  `~/Library/Application Support/DailyWorkSummarizer/screenshots/`
- Preview captures
  `~/Library/Application Support/DailyWorkSummarizer/screenshots/preview/`
- Model-test temporary captures
  `~/Library/Application Support/DailyWorkSummarizer/screenshots/temp/`

## Database tables

- `category_rules`
  User-defined category definitions and ordering.
- `analysis_runs`
  One record per analysis batch, including prompt snapshot and run status.
- `analysis_results`
  Per-item output for screenshots, including category, summary, duration snapshot, and error fields.
- `absence_events`
  Idle or away intervals recorded without screenshots.
- `daily_reports`
  Generated daily summaries and per-category summary payloads.
- `app_logs`
  Persistent runtime log entries for analysis errors and later debugging events, including LM Studio pause and unload traces under source `lm_studio`.

## Persistence model

### SQLite

SQLite is the source of truth for captured work history, analysis outputs, and generated daily reports.
It also stores lightweight runtime logs in `app_logs`, capped to the latest 1000 entries.

### UserDefaults

UserDefaults stores lightweight preferences such as:

- screenshot interval
- analysis time
- automatic analysis toggles
- language
- provider selection
- base URLs
- model names
- image analysis methods

### Keychain

Keychain stores API keys for the two model profiles:

- screenshot analysis key
- work-content analysis key

## File conventions

- Screenshot files are saved as JPEG.
- The filename format is `yyyyMMdd-HHmm-i<minutes>.jpg`.
- Preview captures add a `-preview` suffix.
- Model-test captures add a `-model-test` suffix.

The filename is not just cosmetic: the app derives capture time and duration metadata from it when loading pending screenshot files.

## Recommended test command

Use an explicit DerivedData path in sandboxed or automation-driven environments:

```sh
xcodebuild test \
  -project DailyWorkSummarizer.xcodeproj \
  -scheme DailyWorkSummarizer \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/DailyWorkSummarizerDerivedData \
  CODE_SIGNING_ALLOWED=NO
```

To focus on unit-style coverage first:

```sh
xcodebuild test \
  -project DailyWorkSummarizer.xcodeproj \
  -scheme DailyWorkSummarizer \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/DailyWorkSummarizerDerivedData \
  -only-testing:DailyWorkSummarizerTests \
  CODE_SIGNING_ALLOWED=NO
```

## Known testing caveats

- Sandboxed CLI environments may print CoreSimulator warnings even for macOS targets.
- Distributed-notification warnings from `xcodebuild` are common in restricted environments and do not automatically indicate a product bug.
- When settings-model fields change, hand-written test initializers are a common failure point.

## Useful inspection commands

List tables:

```sh
sqlite3 "$HOME/Library/Application Support/DailyWorkSummarizer/daily-work-summarizer.sqlite" '.tables'
```

Recent analysis runs:

```sh
sqlite3 "$HOME/Library/Application Support/DailyWorkSummarizer/daily-work-summarizer.sqlite" \
  "select id,status,provider,model_name,total_items,success_count,failure_count,datetime(started_at,'unixepoch','localtime') from analysis_runs order by id desc limit 20;"
```

Recent analysis results:

```sh
sqlite3 "$HOME/Library/Application Support/DailyWorkSummarizer/daily-work-summarizer.sqlite" \
  "select id,datetime(captured_at,'unixepoch','localtime'),category_name,status,substr(ifnull(summary_text,''),1,80) from analysis_results order by id desc limit 20;"
```

Recent daily reports:

```sh
sqlite3 "$HOME/Library/Application Support/DailyWorkSummarizer/daily-work-summarizer.sqlite" \
  "select id,datetime(day_start,'unixepoch','localtime'),substr(daily_summary_text,1,120) from daily_reports order by day_start desc limit 20;"
```

Recent runtime logs:

```sh
sqlite3 "$HOME/Library/Application Support/DailyWorkSummarizer/daily-work-summarizer.sqlite" \
  "select datetime(created_at,'unixepoch','localtime'),level,source,substr(message,1,160) from app_logs order by created_at desc limit 50;"
```

Recent screenshots:

```sh
ls -lah "$HOME/Library/Application Support/DailyWorkSummarizer/screenshots" | tail
```
