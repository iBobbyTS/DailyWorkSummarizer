# Analysis Pipeline

适用场景：

- 修改截图分析链路
- 修改 OCR / multimodal / Apple Intelligence 切换逻辑
- 调整提示词、响应解析、fallback 行为
- 修改日报汇总逻辑
- 排查设置 UI 和运行时行为不一致的问题

先读这些文件：

- `DailyWorkSummarizer/ScreenshotService.swift`
- `DailyWorkSummarizer/AnalysisService.swift`
- `DailyWorkSummarizer/DailyReportSummaryService.swift`
- `DailyWorkSummarizer/LLMService.swift`
- `DailyWorkSummarizer/LMStudioAPI.swift`
- `DailyWorkSummarizer/AppSettings.swift`
- `DailyWorkSummarizer/AppModels.swift`
- `DailyWorkSummarizer/SettingsView.swift`
- `DailyWorkSummarizer/AppLocalization.swift`

理解主链路时的顺序：

1. 看 `SettingsView.swift`
   先确认用户能改哪些配置，以及两套模型配置如何复制。
2. 看 `AppSettings.swift` 和 `AppModels.swift`
   先确认设置是怎样被裁剪、归一化、快照化的。
3. 看 `AnalysisService.swift`
   这里处理截图分析、OCR、多模态请求、Apple Intelligence、重试、解析和测试面板输出。
4. 看 `DailyReportSummaryService.swift`
   这里处理日报汇总、按天补生成、模型请求和解析。
5. 看 `LLMService.swift`
   这里统一封装 OpenAI、Anthropic、LM Studio、Apple Intelligence 的请求构造、响应归一化、超时、取消和 provider 能力说明。

截图分析的关键入口：

- `testCurrentSettings(with:)`
- `analyzeImageAttemptDetailed(at:settings:prompt:allowLengthRetry:)`
- `recognizedText(from:language:)`
- `LLMService.send(_:)`
- `LMStudioAPI.buildChatRequestBody`
- `extractAnalysisResponse`

日报汇总的关键入口：

- `summarizeMissingDailyReportsIfNeeded()`
- `summarizeDay(_:)`
- `requestSummary(prompt:settings:language:)`
- `extractDailyReportResponse`

共享 provider 入口：

- `LLMService.providerContract(for:)`
- `LLMService.send(_:)`
- `LMStudioAPI.parseChatResponse(from:)`

当前行为边界：

- 截图分析支持两种远程路径：
  - `ocr`：先本地 Vision OCR，再把文本发给远程模型
  - `multimodal`：直接把截图图片发给远程模型
- 当 provider 是 `appleIntelligence` 时，截图分析始终走 OCR-first，本地不会直接把图片字节送进 `FoundationModels`。
- 日报汇总始终是文本链路，不读取图片。
- `workContentImageAnalysisMethod` 目前是配置层字段，主要用于两套模型配置保持一致；`DailyReportSummaryService` 当前并不会根据它决定不同请求体。

排查顺序：

- 截图分析结果不对：
  先看 `recognizedText` 是否为空，再看 `buildOCRAnalysisPrompt` 或多模态请求体是否真的带图。
- 响应解析失败：
  先看 `extractAnalysisResponse` / `extractDailyReportResponse`，再补单测覆盖新的输出包裹格式。
- 设置改了但运行时没生效：
  先看 `SettingsStore.snapshot`，再看调用方是否拿的是截图分析配置还是工作内容分析配置。

改动时容易漏的点：

- provider 或模型配置字段一旦变化，要同时检查截图分析和工作内容分析两套设置。
- 新增设置字段后，除了 `SettingsStore` 和 `SettingsView`，还要同步看测试里的手工初始化。
- 文案或提示词改动通常同时落在 `AppLocalization.swift` 和对应 service。
- LM Studio 请求格式或解析逻辑改动时，优先改 `LMStudioAPI.swift`，不要在两个 service 里各自复制一份。
- OpenAI / Anthropic / Apple Intelligence 的请求或解析行为改动时，优先改 `LLMService.swift`，并同步更新 `docs/model-integration.md`。
