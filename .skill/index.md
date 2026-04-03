# DailyWorkSummarizer Skill Index

这些 skill 只给 Codex/代理自己用，用来快速决定在这个仓库里应该怎样调用工具、先读哪些文件、哪些命令最少踩坑。

进入仓库后，先按任务类型选一个入口：

- `xcode-workflow.md`
  适用：构建、测试、编译报错、Scheme 查询、DerivedData/xcresult 排障。
- `analysis-pipeline.md`
  适用：截图分析、OCR、多模态请求、日报汇总、提示词、响应解析、设置联动。
- `data-inspection.md`
  适用：SQLite、截图产物、Application Support、UserDefaults/Keychain 持久化排查。
- `apple-intelligence.md`
  适用：Apple Intelligence / FoundationModels 接入、可用性判断、OCR-first 本地分析路径。

全局约定：

- 这是原生 macOS Xcode 项目，不是 Node 项目，也没有以 Docker 作为主开发入口。
- 运行 `xcodebuild` 时总是显式传 `-derivedDataPath /tmp/DailyWorkSummarizerDerivedData`，避免沙箱环境下写默认 `~/Library/Developer/Xcode/DerivedData` 时报权限问题。
- 涉及 `AnalysisModelSettings`、`AppSettingsSnapshot`、`SettingsStore.snapshot` 的字段变更时，先全局搜索手写初始化点，尤其是 `DailyWorkSummarizerTests/`。
- 涉及模型配置时，始终同时检查两套配置：
  - 截图分析：`provider` / `imageAnalysisMethod` / `apiBaseURL` / `modelName`
  - 工作内容分析：`workContentProvider` / `workContentImageAnalysisMethod` / `workContentAPIBaseURL` / `workContentModelName`

