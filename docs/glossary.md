# Glossary

This glossary keeps DeskBrief's common Simplified Chinese and English product terms consistent across UI, prompts, documentation, and tests.

## Term Rules

- Use `截屏` for the Chinese noun and adjective form of screenshots. Do not use `截图`.
- Use `screenshot` for the English noun and adjective form.
- Use `capture` only for the action or workflow of taking/saving a screenshot, such as `captured` or `screenshot capture`.
- Use `分析` / `analyze` for screenshot-analysis actions. Use `总结` / `summarize` for work-content and daily-report summary actions. Do not use legacy work-content analysis wording as a product term.
- Keep feature names in title case in English UI labels, and concise sentence-style wording in Chinese UI labels.

## Core Product

| Simplified Chinese | English | Notes |
| --- | --- | --- |
| 工迹 | DeskBrief | Product name. Use the localized app name in UI and alerts. |
| 截屏 | Screenshot | Noun/adjective for saved screen images. |
| 截屏分析 | Screenshot Analysis | Settings tab and model profile for analyzing screenshots. |
| 工作内容总结 | Work Content Summary | Settings tab and model profile for daily-report summarization. |
| 截屏间隔 | Screenshot interval | Time between periodic screenshots. |
| 测试截屏 | Test Screenshot | Button label for preview capture. |
| 正在测试截屏 | Testing screenshot | In-progress state for test screenshot capture. |
| 打开截屏文件夹 | Open Screenshots Folder | Folder command. |
| 清除早期截屏 | Clear Early Screenshots | Menu action for deleting old pending screenshot files. |
| 当前活跃的屏幕 | Current active display | Screenshot scope label. |
| 屏幕录制权限 | Screen recording permission | macOS permission required for screenshot capture. |

## Analysis Startup

| Simplified Chinese | English | Notes |
| --- | --- | --- |
| 分析启动模式 | Analysis startup mode | Picker/menu title for automatic startup behavior. |
| 不自动启动 | Do Not Auto Start | No automatic analysis trigger. |
| 定时启动 | Scheduled Start | Run analysis at the configured time. |
| 截屏后立即启动 | Start Immediately After Screenshot | Trigger analysis shortly after a screenshot is saved. |
| 定时分析时间 | Scheduled analysis time | Time field shown for scheduled start. |
| 仅在充电时自动分析 | Only run automatic analysis while charging | Charger requirement for automatic triggers. |
| 立即分析 | Analyze Now | Manual menu action. |
| 停止本次分析 | Stop Current Analysis | Manual stop action for the current analysis run. |
| 正在分析 | Analyzing | Current run status. |
| 正在停止本次分析 | Stopping | Transitional stop status for the current analysis run. |
| 待分析的截屏 | Screenshots pending analysis | Pending queue wording. |

## Model Settings

| Simplified Chinese | English | Notes |
| --- | --- | --- |
| 模型设置 | Model Settings | Section title. |
| 模型服务 | Model provider | Provider picker label. |
| 接口地址 | Base URL | Model API endpoint. |
| 模型名称 | Model name | Model identifier. |
| API 秘钥 | API key | Existing UI spelling; keep consistent unless changed deliberately. |
| 上下文长度 | Context length | LM Studio context length. |
| 图像分析方法 | Image analysis method | OCR vs multimodal mode. |
| OCR（大模型仅做语言分析） | OCR (LLM text-only analysis) | OCR-first analysis path. |
| 多模态（使用包含视觉能力的大模型） | Multimodal (vision-capable LLM) | Direct image analysis path. |
| 复制 Prompt | Copy Prompt | Prompt debugging action. |
| 测试模型 | Test Model | Model test action. |
| OCR 内容 | OCR text | Recognized text display. |
| 思考过程 | Reasoning | Optional model reasoning output. |

## Categories And Summaries

| Simplified Chinese | English | Notes |
| --- | --- | --- |
| 类别 | Category | Analysis category label. |
| 分类 | Category | Chart axis and report grouping label. |
| 类别名 | Category | Category-rule name field. |
| 描述 | Description | Category-rule description field. |
| 总结 | Summary | Generic summary noun. |
| 日报总结 | Daily Summary | Daily-report generated summary. |
| 临时总结 | Temporary Summary | Report result produced before the day is complete. |
| 离开 | Away | Derived absence category display name. |
| 其他 | Other | Preserved fallback category display name. |
| 颜色 | Color | Category color control label. |
| 自定义颜色 | Custom Color | Native color picker entry. |

## Reports

| Simplified Chinese | English | Notes |
| --- | --- | --- |
| 查看报告 | Reports | Window title and menu action. |
| 报告类型 | Report type | Report-kind picker label. |
| 日报 | Day | Daily report kind. |
| 周报 | Week | Weekly report kind. |
| 月报 | Month | Monthly report kind. |
| 年报 | Year | Yearly report kind. |
| 图表类型 | Chart type | Visualization picker label. |
| 柱状图 | Bar | Bar chart option. |
| 热力图 | Heatmap | Heatmap option. |
| 累计 | Total | Total duration prefix. |
| 日均 | Daily avg | Average duration prefix. |
| 累计小时 | Total Hours | Y-axis label. |
| 工作日 | Workdays | Report filter. |
| 周末 | Weekends | Report filter. |
| 叠加每日时间 | Overlay daily time | Heatmap overlay option. |
| 立即总结 | Summarize Now | Daily report generation action. |
| 总结中 | Summarizing | In-progress report generation state. |

## Logs And Errors

| Simplified Chinese | English | Notes |
| --- | --- | --- |
| 查看日志 | Logs | Logs window title/menu action. |
| 查看错误 | Errors | Errors window title/menu action. |
| 日志 | Log | Runtime log level/display term. |
| 错误 | Error | Error display term. |
| 显示日志 | Show Logs | Menu action. |
| 清空所有日志 | Clear All Logs | Logs command. |
| 清空所有错误 | Clear All Errors | Errors command. |
| 全部复制 | Copy All | Logs command. |
| 底层错误详情 | Underlying error details | Error detail header. |
| 模型返回无法解析为有效的 JSON 分析结果 | The model response could not be parsed into a valid JSON analysis result | Common analysis parse failure. |
