# Apple Intelligence

适用场景：

- 修改 `apple_intelligence` provider
- 调整 `FoundationModels` 接入
- 排查 Apple Intelligence 可选性、语言支持和本地推理输出
- 判断某个需求能不能走 Apple 本地模型

先读这些文件：

- `DeskBrief/AppleIntelligenceSupport.swift`
- `DeskBrief/SettingsView.swift`
- `DeskBrief/AppSettings.swift`
- `DeskBrief/AnalysisService.swift`
- `DeskBrief/DailyReportSummaryService.swift`
- `DeskBrief/AppLocalization.swift`

当前项目里的真实接入方式：

- provider 枚举：`ModelProvider.appleIntelligence`
- 可选性判断：`AppleIntelligenceSupport.currentStatus(for:)`
- 截屏分析：
  - 先 Vision OCR
  - 再走 `LanguageModelSession.streamResponse`
  - use case 是 `SystemLanguageModel(useCase: .contentTagging)`
  - 测试模型面板会显示 OCR 文本；如果 LM Studio 返回 `type == "reasoning"` 的输出块，也会原样显示 reasoning 内容
- 日报汇总：
  - 直接把文本 prompt 送进 `LanguageModelSession.respond`
  - use case 是 `SystemLanguageModel(useCase: .general)`

必须记住的约束：

- 这个项目当前没有把截屏图片直接输入到 `FoundationModels`。
- 当 provider 是 `appleIntelligence` 时，`imageAnalysisMethod` 会被强制归一化成 `.ocr`。
- 所以如果看到 UI 里 Apple Intelligence 对应的图像分析方式不可编辑，这是预期行为，不是 bug。

修改时的判断原则：

- 需求是“总结文本、分类文本、基于 OCR 文本生成结构化结果”，优先考虑本地 Apple Intelligence。
- 需求是“直接看图片内容、复杂视觉布局、图表/纯视觉界面理解”，不要默认假设当前公开 `FoundationModels` API 已经能替代远程多模态；先验证 SDK 能力再改。

排查顺序：

- Apple Intelligence 在 UI 里不可选：
  先看 `AppleIntelligenceSupport.currentStatus(for:)` 返回的 availability 和支持语言集合。
- Apple Intelligence 可选但运行失败：
  先看 `ensureAppleIntelligenceAvailable` 的 unavailable reason，再看 `SettingsView` 文案映射是否一致。
- 本地结构化输出解析失败：
  先看 `appleIntelligenceAnalysisSchema`、`extractGuidedAnalysisResponse` 和解码失败时的原始内容抓取逻辑。

高频联动点：

- `SettingsView` 的 provider picker 后缀文案
- `AppSettings.resolvedProvider` / `resolvedImageAnalysisMethod`
- `AnalysisService.analyzeImageWithAppleIntelligence`
- `DailyReportSummaryService.requestSummary`
