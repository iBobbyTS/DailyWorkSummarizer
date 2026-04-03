# Xcode Workflow

适用场景：

- 查 Scheme / target / build configuration
- 编译失败定位
- 跑单元测试或缩小到指定测试
- 读取 `xcresult` 或排查 `xcodebuild` 在沙箱里的异常输出

项目事实：

- 工程文件：`DailyWorkSummarizer.xcodeproj`
- 默认 Scheme：`DailyWorkSummarizer`
- 平台：macOS
- 测试框架：`swift-testing`（源码里 `import Testing`），但运行入口仍然是 `xcodebuild test`

推荐命令：

```sh
xcodebuild -list -project DailyWorkSummarizer.xcodeproj
```

```sh
xcodebuild test \
  -project DailyWorkSummarizer.xcodeproj \
  -scheme DailyWorkSummarizer \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/DailyWorkSummarizerDerivedData \
  CODE_SIGNING_ALLOWED=NO
```

```sh
xcodebuild test \
  -project DailyWorkSummarizer.xcodeproj \
  -scheme DailyWorkSummarizer \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/DailyWorkSummarizerDerivedData \
  -only-testing:DailyWorkSummarizerTests \
  CODE_SIGNING_ALLOWED=NO
```

实践要点：

- 默认 DerivedData 路径在当前沙箱里容易触发日志目录权限错误，因此统一把 `-derivedDataPath` 指到 `/tmp`。
- `CoreSimulatorService connection became invalid`、`attempt to post distributed notification ... thwarted by sandboxing` 这类输出在 macOS CLI 环境里常见；只有在最终出现真正的 `SwiftCompile` / `Test Failure` 时才按失败处理。
- UI 测试默认不是首选排障入口。先跑 `DailyWorkSummarizerTests`，只有明确要验证窗口流程或系统权限交互时再考虑 `DailyWorkSummarizerUITests`。

常见回归点：

- 新增 `AnalysisModelSettings` 或 `AppSettingsSnapshot` 字段后，`DailyWorkSummarizerTests.swift` 里的手写初始化很容易报 `Missing argument for parameter ... in call`。
- 出现这类错误时，先搜：

```sh
rg -n "AnalysisModelSettings\\(|AppSettingsSnapshot\\(" DailyWorkSummarizer DailyWorkSummarizerTests DailyWorkSummarizerUITests
```

- 设置相关改动除了测试，还要同步检查：
  - `SettingsStore.snapshot`
  - `SettingsView`
  - 两个模型配置复制入口

