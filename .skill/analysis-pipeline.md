# Analysis Pipeline

适用场景：

- 修改截屏分析链路
- 修改 OCR / multimodal / Apple Intelligence 切换逻辑
- 调整提示词、响应解析、fallback 行为
- 修改日报汇总逻辑
- 排查设置 UI 和运行时行为不一致的问题

先读这些文件：

- `DeskBrief/ScreenshotService.swift`
- `DeskBrief/AnalysisService.swift`
- `DeskBrief/ActiveAnalysisRun.swift`
- `DeskBrief/AnalysisServicePolicy.swift`
- `DeskBrief/AnalysisWorker.swift`
- `DeskBrief/DailyReportSummaryService.swift`
- `DeskBrief/LLMService.swift`
- `DeskBrief/LMStudioAPI.swift`
- `DeskBrief/AppSettings.swift`
- `DeskBrief/AppModels.swift`
- `DeskBrief/AnalysisErrorStore.swift`
- `DeskBrief/SettingsView.swift`
- `DeskBrief/AppLocalization.swift`

理解主链路时的顺序：

1. 看 `SettingsView.swift`
   先确认用户能改哪些配置，以及两套模型配置如何复制。
2. 看 `AppSettings.swift` 和 `AppModels.swift`
   先确认设置是怎样被裁剪、归一化、快照化的。
3. 看 `AnalysisService.swift`、`ActiveAnalysisRun.swift`、`AnalysisServicePolicy.swift` 和 `AnalysisWorker.swift`
   `AnalysisService` 负责主 actor 上的运行状态、计时器、取消、追加队列和通知；`ActiveAnalysisRun` 保存当前队列和计数；`AnalysisServicePolicy` 放解析、重试、充电器等纯策略；`AnalysisWorker` 负责非主线程的图片读取、OCR、多模态请求、Apple Intelligence、模型调用和测试面板输出。
4. 看 `DailyReportSummaryService.swift`
   这里处理日报汇总、按天补生成、模型请求和解析。
5. 看 `LLMService.swift`
   这里统一封装 OpenAI、Anthropic、LM Studio、Apple Intelligence 的请求构造、响应归一化、超时、取消和 provider 能力说明。
6. 看 `AnalysisErrorStore.swift`
   这里现在是持久化 `AppLogStore`，负责把分析错误和调试日志写进 SQLite，再同步到菜单栏日志窗口。

截屏分析的关键入口：

- `testCurrentSettings(with:)`
- `analyzeImageAttemptDetailed(at:settings:prompt:allowLengthRetry:)`
- `recognizedText(from:language:)`
- `LLMService.send(_:)`
- `LMStudioAPI.buildChatRequestBody`
- `extractAnalysisResponse`

日报汇总的关键入口：

- `summarizeMissingDailyReportsIfNeeded(lmStudioLifecyclePolicy:)`
- `summarizeDay(_:)`
- `summarizeDayLocked(_:lmStudioLifecyclePolicy:)`
- `withLMStudioLifecycleIfNeeded(settings:policy:operation:)`
- `requestSummary(prompt:settings:language:)`
- `extractDailyReportResponse`

共享 provider 入口：

- `LLMService.providerContract(for:)`
- `LLMService.send(_:)`
- `LMStudioAPI.parseChatResponse(from:)`
- `LMStudioModelLifecycle.load(settings:)`
- `LMStudioModelLifecycle.unload(settings:instanceID:)`
- `LMStudioAPI.hasEquivalentLoadConfiguration(_:_:)`
- `AppLogStore.add(level:source:message:)`

当前行为边界：

- 分析启动模式有三种：不自动分析只保留手动入口；定时分析只按 `analysisTimeMinutes` 触发并扫描 pending 截屏；实时分析在截屏成功保存后 1 秒触发一次 pending 截屏扫描，通知里的截屏 URL 只作为触发信号。
- “仅在充电时自动分析”只约束自动触发：定时和实时会检查充电器，手动“立即分析”不检查。
- 没有 pending 截屏时，触发分析不应创建空的 `analysis_runs`。
- 运行中再次触发分析时，不要取消、暂停或重启当前 run；manual/scheduled/realtime 都应扫描 pending 截屏，把新发现的截屏追加到当前队列末尾，并同步更新 `analysis_runs.total_items`。
- 用户取消分析时，当前 run 应立即停止接收追加；后续触发通过 `pendingRequestAfterCurrentRun` 合并成一次 follow-up pending 扫描，在当前 run 结束后重新启动。
- `analysis_results.captured_at` 有唯一约束；重复时间写入应被忽略，删除对应截屏文件，不覆盖旧结果。
- 截屏分析支持两种远程路径：
  - `ocr`：先本地 Vision OCR，再把文本发给远程模型
  - `multimodal`：直接把截屏图片发给远程模型
- 当 provider 是 `appleIntelligence` 时，截屏分析始终走 OCR-first，本地不会直接把图片字节送进 `FoundationModels`。
- 日报汇总始终是文本链路，不读取图片。
- 日报汇总读取当天 `captured_at` 结果时，会额外读取当天开始前最后一条结果；如果这条结果按 `duration_minutes_snapshot` 跨入当天，会裁剪成从当天 00:00 开始的活动项。当天内跨到次日的结果也裁剪到当天结束。日报汇总不需要读取次日第一条结果，因为截屏结果自身已经保存了持续时长。
- 工作内容总结始终走文本请求，不保留图像分析方法配置；设置页不在“工作内容总结”里展示截图专属分析控件。
- LM Studio 不在 `LLMService.send(_:)` 内隐式加载；所有业务入口必须先显式调用 `LMStudioModelLifecycle.load`，成功后再发 chat。
- 截屏分析 run 如果使用 LM Studio，只在 run 开始前加载一次分析模型，run 内多个截屏复用这次加载。
- 设置页模型测试如果使用 LM Studio，顺序必须是 `load -> chat -> unload`。
- 手动日报总结或普通补总结如果使用 LM Studio，顺序必须是 `load -> summary chat -> unload`。
- 截屏分析自动衔接工作内容总结时：
  - 分析和总结都是 LM Studio 且 endpoint/model/context 完全一致：不 unload、不 reload，直接总结，结束后仍保留该实例。
  - 分析和总结都是 LM Studio 但配置不同：先卸载分析实例，再加载总结实例，结束后保留总结实例。
  - 只有分析是 LM Studio：分析结束后先卸载，再跑总结。
  - 只有总结是 LM Studio：总结开始前加载，结束后卸载。
- LM Studio 配置等价只比较 `ModelProvider.lmStudio.requestURL(from:)` 规范化后的 chat endpoint、trimmed `modelName`、`lmStudioContextLength`；API key 不参与等价判断，但各请求仍使用自己 profile 的 key。

排查顺序：

- 截屏分析结果不对：
  先看 `AnalysisWorker.recognizedText` 是否为空，再看 `buildOCRAnalysisPrompt` 或多模态请求体是否真的带图。
- 响应解析失败：
  先看 `extractAnalysisResponse` / `extractDailyReportResponse`，再补单测覆盖新的输出包裹格式。
- 设置改了但运行时没生效：
  先看 `SettingsStore.snapshot`，再看调用方是否拿的是截屏分析配置还是工作内容总结配置。
- 要排查暂停、卸载或 provider 异常：
  先打开菜单里的“显示日志”，再结合 `app_logs` 表确认错误和调试事件是否真的落库。
- 用户手动暂停分析：
  先看 `AnalysisRuntimeState.stoppingStage`，LM Studio 正确顺序应该是先取消当前生成，再在取消完成后调用 unload；如果没有已记录的 `instance_id`，`LMStudioModelLifecycle` 会读取 `/api/v1/models` 并按模型名和 context length 匹配 loaded instance；调试时优先筛选 `source = lm_studio` 的日志。

改动时容易漏的点：

- provider 或模型配置字段一旦变化，要同时检查截屏分析和工作内容总结两套设置。
- 新增设置字段后，除了 `SettingsStore` 和 `SettingsView`，还要同步看测试里的手工初始化。
- 文案或提示词改动通常同时落在 `AppLocalization.swift` 和对应 service。
- LM Studio 请求格式或解析逻辑改动时，优先改 `LMStudioAPI.swift`，不要在两个 service 里各自复制一份。
- LM Studio `/api/v1/chat` 的多模态文本项在不同版本里可能出现 `"text"` 和 `"message"` 两种 discriminator；项目里统一通过 `LMStudioAPI.fallbackMultimodalTextInputStyle` 做一次兼容重试，不要把这种重试散落到业务层。
- OpenAI / Anthropic / Apple Intelligence 的请求或解析行为改动时，优先改 `LLMService.swift`，并同步更新 `docs/model-integration.md`。
- 分析错误和调试日志相关改动时，要同时检查 `AppLogStore`、`MenuBarApp`、`AnalysisErrorsView.swift`、`docs/data-and-testing.md`。
- 任何会读图片、跑 OCR、等待模型请求或循环处理大量截图的逻辑，都不要放回 `AnalysisService` 的主 actor 同步路径；优先放进 `AnalysisWorker`，必要时用 `Task.detached` 包住同步 CPU/IO 工作。
