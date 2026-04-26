# Data Inspection

适用场景：

- 确认截图有没有真正落盘
- 查分析运行记录、分类结果、日报结果
- 排查设置持久化问题
- 快速验证某个功能改动是否影响 SQLite 或本地文件

关键落盘位置：

- Application Support 目录：`~/Library/Application Support/DailyWorkSummarizer/`
- SQLite 数据库：`~/Library/Application Support/DailyWorkSummarizer/daily-work-summarizer.sqlite`
- Sandboxed App SQLite 数据库：`~/Library/Containers/com.iBobby.DailyWorkSummarizer/Data/Library/Application Support/DailyWorkSummarizer/daily-work-summarizer.sqlite`
- 正式截图目录：`~/Library/Application Support/DailyWorkSummarizer/screenshots/`
- 预览截图目录：`~/Library/Application Support/DailyWorkSummarizer/screenshots/preview/`
- 模型测试临时截图目录：`~/Library/Application Support/DailyWorkSummarizer/screenshots/temp/`

数据库主表：

- `category_rules`
- `analysis_runs`
- `analysis_results`
- `daily_reports`
- `app_logs`

注意：

- `离开` 不再持久化为数据库表；报告窗口会根据相邻成功分析结果之间的空白，在内存中派生展示。
- 旧库里的 `absence_events` 表会在 Swift 数据库迁移中删除。

设置存储位置：

- `UserDefaults`
  保存定时、语言、provider、base URL、model name、imageAnalysisMethod 等普通设置。
- `Keychain`
  保存两套 API key：
  - 截图分析：`model-api-key.screenshot-analysis`
  - 工作内容分析：`model-api-key.work-content-analysis`

常用命令：

```sh
sqlite3 "$HOME/Library/Application Support/DailyWorkSummarizer/daily-work-summarizer.sqlite" '.tables'
```

```sh
sqlite3 "$HOME/Library/Application Support/DailyWorkSummarizer/daily-work-summarizer.sqlite" \
  "select id,status,model_name,total_items,success_count,failure_count,average_item_duration_seconds from analysis_runs order by id desc limit 20;"
```

```sh
sqlite3 "$HOME/Library/Application Support/DailyWorkSummarizer/daily-work-summarizer.sqlite" \
  "select id,datetime(captured_at,'unixepoch','localtime'),category_name,substr(ifnull(summary_text,''),1,80) from analysis_results order by id desc limit 20;"
```

```sh
sqlite3 "$HOME/Library/Application Support/DailyWorkSummarizer/daily-work-summarizer.sqlite" \
  "select id,datetime(day_start,'unixepoch','localtime'),substr(daily_summary_text,1,120) from daily_reports order by day_start desc limit 20;"
```

清理既有日报里的 `离开` 单项总结：

```sh
python3 scripts/clean_absence_daily_summaries.py \
  --database "$HOME/Library/Containers/com.iBobby.DailyWorkSummarizer/Data/Library/Application Support/DailyWorkSummarizer/daily-work-summarizer.sqlite"
```

清理旧 `analysis_results.status == 'failed'` 行：

```sh
python3 scripts/clean_failed_analysis_results.py \
  --database "$HOME/Library/Containers/com.iBobby.DailyWorkSummarizer/Data/Library/Application Support/DailyWorkSummarizer/daily-work-summarizer.sqlite"
```

```sh
ls -lah "$HOME/Library/Application Support/DailyWorkSummarizer/screenshots" | tail
```

额外事实：

- 截图文件名格式是 `yyyyMMdd-HHmm-i<minutes>.jpg`。
- 预览截图会带 `-preview` 后缀。
- 模型测试临时截图会带 `-model-test` 后缀。
- `AppDatabase.listScreenshotFiles` 通过文件名反推时间和时长，所以改文件命名规则时必须同步更新解析逻辑。
