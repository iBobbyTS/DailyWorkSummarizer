# Data and Testing

## Local storage layout

The app stores runtime data under Application Support:

- Database
  `~/Library/Application Support/DeskBrief/desk-brief.sqlite`
- Screenshot directory
  `~/Library/Application Support/DeskBrief/screenshots/`
- Preview captures
  `~/Library/Application Support/DeskBrief/screenshots/preview/`
- Model-test temporary captures
  `~/Library/Application Support/DeskBrief/screenshots/temp/`

## Database tables

- `category_rules`
  User-defined category definitions and ordering, without timestamp metadata.
- `analysis_runs`
  One compact record per analysis batch, including run status, model name, item counts, average item duration, and run-level error text.
  `total_items` can grow during an active run when new screenshots are appended to the same queue.
- `analysis_results`
  Successful per-item screenshot analysis output, including capture time, category, summary, and duration snapshot.
  `captured_at` is unique; duplicate inserts are ignored so an existing result is not overwritten.
- `daily_reports`
  Generated daily summaries and per-category summary payloads for reportable, non-away activity.
- `app_logs`
  Persistent runtime log entries for analysis errors and later debugging events, including LM Studio pause and unload traces under source `lm_studio`.

## Persistence model

### SQLite

SQLite is the source of truth for captured work history, analysis outputs, and generated daily reports.
It also stores lightweight runtime logs in `app_logs`, capped to the latest 1000 entries.
Away intervals are not persisted; report views derive display-only `离开` blocks from bounded gaps between adjacent successful analysis results.
Failed per-screenshot attempts are counted on `analysis_runs` but are not persisted as `analysis_results` rows.
Duplicate capture-time results are treated as already processed: the screenshot file is removed and the original `analysis_results` row remains unchanged.

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

Recent daily reports:

```sh
sqlite3 "$HOME/Library/Application Support/DeskBrief/desk-brief.sqlite" \
  "select id,datetime(day_start,'unixepoch','localtime'),substr(daily_summary_text,1,120) from daily_reports order by day_start desc limit 20;"
```

Remove legacy away-state category summaries from existing daily reports:

```sh
python3 scripts/clean_absence_daily_summaries.py \
  --database "$HOME/Library/Containers/com.iBobby.DeskBrief/Data/Library/Application Support/DeskBrief/desk-brief.sqlite"
```

Remove legacy failed rows before compacting `analysis_results`:

```sh
python3 scripts/clean_failed_analysis_results.py \
  --database "$HOME/Library/Containers/com.iBobby.DeskBrief/Data/Library/Application Support/DeskBrief/desk-brief.sqlite"
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
