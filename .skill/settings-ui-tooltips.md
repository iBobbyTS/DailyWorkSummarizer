# Settings UI Tooltips 模式

适用于在 `SettingsView.swift` 内为一行的配置项添加 `info.circle` 图标 + popover tooltip。

## 核心组件：`InfoTooltipButton`

这是一个自包含的 SwiftUI 子视图，管理自己的 `@State`，无需父视图维护额外的状态变量。

```swift
private struct InfoTooltipButton: View {
    let text: String
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            parsedTooltip(text)
        }
    }

    private func parsedTooltip(_ raw: String) -> some View {
        let parts = raw.components(separatedBy: "*")
        var result = Text("")
        for (i, part) in parts.enumerated() {
            guard !part.isEmpty else { continue }
            if i.isMultiple(of: 2) {
                result = result + Text(part)
            } else {
                result = result + Text(part).bold()
            }
        }
        return VStack(alignment: .leading, spacing: 8) {
            result.fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(width: 280)
    }
}
```

定义位置：放在 `SettingsView.swift` 文件末尾，作为文件级别的 `private struct`。

## 两种插入模式

### A. `proportionalFieldRow` / `modelLifecycleToggleRow` 参数化

已有封装的行：给函数签名加 `tooltip: String? = nil` 参数，在 `field(resolvedFieldWidth)` 或 `.frame(...)` 之后插入 if-let。

```swift
// 函数签名
private func proportionalFieldRow<Content: View>(
    _ title: String,
    fieldWidth: CGFloat? = nil,
    tooltip: String? = nil,
    @ViewBuilder field: @escaping (CGFloat) -> Content
) -> some View { ... }

// 调用时传参
proportionalFieldRow(text(.settingsModelService), tooltip: "...") { fieldWidth in ... }
```

### B. 非参数化 inline 行

直接用 `sed`/`Python` 在控件修饰符链之后插入 `InfoTooltipButton`。

## Tooltip 文本规范

- `*加粗文本*`：单星号包起来，`parsedTooltip` 内部会解析为加粗
- `\n`：用两个字符反斜杠 + n，Swift 编译器会解释为换行
- 内部含 `"` 时需转义为 `\"`
- 宽度固定 280pt，可以按内容调整
- padding 为 12pt 内边距

## 实施最佳实践

- **避免用 sed 处理含中文的多行插入**：sed 容易损坏 UTF-8 编码。改用 Python 脚本做基于内容标记的替换。
- **工具提示文本较长时先用 temp 变量存好再拼接**，避免 Python 字符串嵌套过多。
- **替换策略**：使用 context-based text replacement（Python `str.replace`），找到唯一上下文标记做替换。不要依赖行号。
- **修改后必须完整编译**：`xcodebuild -project DeskBrief.xcodeproj -scheme DeskBrief -derivedDataPath /tmp/DeskBriefDerivedData build`
- **一个文件内有多个 `.toggleStyle(.switch)` 时注意区分**：截图区域的充电开关与 `modelLifecycleToggleRow` 内的开关用不同上下文标记区分。
