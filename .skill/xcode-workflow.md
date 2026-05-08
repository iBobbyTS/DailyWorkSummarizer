# Xcode Workflow

适用场景：

- 查 Scheme / target / build configuration
- 编译失败定位
- 跑单元测试或缩小到指定测试
- 读取 `xcresult` 或排查 `xcodebuild` 在沙箱里的异常输出

项目事实：

- 工程文件：`DeskBrief.xcodeproj`
- 默认 Scheme：`DeskBrief`
- 平台：macOS
- 测试框架：`swift-testing`（源码里 `import Testing`），但运行入口仍然是 `xcodebuild test`
- target 使用 Xcode 文件系统同步分组；新增 Swift 源文件放进 `DeskBrief/` 或 `DeskBriefTests/` 后会自动进入对应 target，一般不需要改 `project.pbxproj`。

推荐命令：

```sh
xcodebuild -list -project DeskBrief.xcodeproj
```

```sh
xcodebuild test \
  -project DeskBrief.xcodeproj \
  -scheme DeskBrief \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/DeskBriefDerivedData \
  CODE_SIGNING_ALLOWED=NO
```

```sh
xcodebuild test \
  -project DeskBrief.xcodeproj \
  -scheme DeskBrief \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/DeskBriefDerivedData \
  -only-testing:DeskBriefTests \
  CODE_SIGNING_ALLOWED=NO
```

```sh
xcodebuild test \
  -project DeskBrief.xcodeproj \
  -scheme DeskBrief \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/DeskBriefDerivedData \
  -only-testing:DeskBriefUITests \
  CODE_SIGNING_ALLOWED=NO
```

```sh
xcodebuild build \
  -project DeskBrief.xcodeproj \
  -scheme DeskBrief \
  -configuration Release \
  -derivedDataPath /tmp/DeskBriefReleaseDerivedData \
  CODE_SIGNING_ALLOWED=NO
```

```sh
scripts/archive-release.sh
```

实践要点：

- 默认 DerivedData 路径在当前沙箱里容易触发日志目录权限错误，因此统一把 `-derivedDataPath` 指到 `/tmp`。
- 需要生成 Release archive 和可直接检查的 `.app` 时，优先用 `scripts/archive-release.sh`。它会生成 `build/DeskBrief.xcarchive`，并从归档中复制出 `build/DeskBrief.app`；默认使用 `/tmp/DeskBriefArchiveDerivedData` 且 `CODE_SIGNING_ALLOWED=NO`，可通过同名环境变量覆盖。
- 在受限沙箱里跑 `xcodebuild test` 可能需要 macOS test runner 权限。常见失败是 `Connection init failed at lookup with error 159 - Sandbox restriction` 或 `attempt to post distributed notification ... thwarted by sandboxing`；如果当前运行环境明确给了 runner 权限，就不要再请求提权。
- `CoreSimulatorService connection became invalid`、`attempt to post distributed notification ... thwarted by sandboxing` 这类输出在 macOS CLI 环境里常见；只有在最终出现真正的 `SwiftCompile` / `Test Failure` 时才按失败处理。
- UI 测试默认不是首选排障入口。先跑 `DeskBriefTests`，只有明确要验证窗口流程或系统权限交互时再考虑 `DeskBriefUITests`。
- `DeskBriefUITests` 使用 `--deskbrief-ui-testing`，并由测试注入隔离的 support directory、UserDefaults suite 和 Keychain service；测试 hooks 可打开设置、报告、日志窗口，后台截图和分析服务会禁用，避免污染真实用户数据。
- `DeskBriefTests` 主 suite 可以通过多个 `extension DeskBriefTests` 文件拆分；保留 `@Suite(.serialized)` 在主类型上，公共 fixture 放 `TestSupport.swift`。
- 菜单栏 accessory app 在 CLI 下使用 `XCTApplicationLaunchMetric` 可能出现某次 iteration 没有 metric 的不稳定失败；如果只需要覆盖 launch block 耗时，优先改用 `XCTClockMetric` 并在每次迭代后显式 `terminate()`。

常见回归点：

- 新增 `ModelProfileSettings` 或 `AppSettingsSnapshot` 字段后，`DeskBriefTests.swift` 里的手写初始化很容易报 `Missing argument for parameter ... in call`。
- 出现这类错误时，先搜：

```sh
rg -n "ModelProfileSettings\\(|AppSettingsSnapshot\\(" DeskBrief DeskBriefTests DeskBriefUITests
```

- 设置相关改动除了测试，还要同步检查：
  - `SettingsStore.snapshot`
  - `SettingsView`
  - 两个模型配置复制入口
