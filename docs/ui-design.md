# UI Design

DeskBrief is a compact macOS menu bar utility. Its UI should feel like a focused desktop tool: dense enough for repeated use, visually quiet, and aligned with native macOS controls.

## Overall Direction

- Prefer native SwiftUI and AppKit-backed macOS controls before custom drawing.
- Keep settings, menu items, report views, and log views optimized for scanning rather than marketing-style presentation.
- Use system-adaptive colors and semantic foreground styles so Light and Dark mode remain readable.
- Use custom surfaces sparingly. Framed cards are appropriate for repeated settings rows, previews, list items, and dialogs, but page sections should not become nested cards.
- Use SF Symbols in buttons and menu-adjacent actions when a familiar symbol exists.

## Settings Layout

- `SettingsView` uses tabs for product areas: screenshot analysis, work content summary, general, and report.
- Each tab uses a leading-aligned vertical layout with `Layout.sectionSpacing` between major sections.
- Section titles use `title2` semibold and should introduce the controls immediately below them.
- Group related settings inside one rounded settings surface with row dividers.
- Setting rows use a label on the left and the editable control aligned to the right.
- Pickers, text fields, and date pickers should use fixed or proportional widths so controls line up across rows.
- Rows inside a settings surface use shared horizontal and vertical padding constants.
- Dividers that separate major sections should have equal visual spacing above and below. If a section owns the divider, the content before it should include bottom spacing matching the parent section spacing after it.
- Do not add extra explanatory text inside settings unless the user needs a persistent warning, provider limitation, or validation message.

## Screenshot Analysis Settings

- The capture section keeps the screenshot interval and automatic-analysis controls in one settings surface.
- Analysis startup mode is the primary control for automatic startup behavior and should leave enough picker width for the longest localized option.
- Scheduled analysis time is only visible when the startup mode is scheduled analysis.
- The charger requirement is displayed below scheduled analysis time and is disabled only when automatic analysis is off.
- Utility actions such as test screenshot and opening folders live below the settings surface, not inside it.
- The divider below the capture section should maintain the same vertical spacing above and below.
- Category rows expose a compact color control before the name field. The control should offer the built-in 16-color preset palette and use the native macOS color picker for custom colors.
- The image-analysis method picker belongs only to screenshot analysis. Work content summary uses a text-only model profile and should not expose screenshot-specific analysis controls.
- The LM Studio-only lifecycle toggle sits directly below context length in both model tabs. Hovering that row should explain that the app can proactively load and unload the model before and after analysis, and the row should stay hidden for non-LM Studio providers.

## Menu Bar UI

- Menu bar labels should be short and scannable.
- Keep long runtime details in status lines or dedicated windows rather than long action labels.
- Mutating actions should use explicit menu items; state display should stay separate from commands.
- Keep first-level commands ordered as Current Status, Reports, Clear Early Screenshots, divider, Settings, Analysis startup mode, Show Logs, divider, then Quit.
- Nested menus are appropriate for compact first-level option groups such as analysis startup mode.
- The Current Status submenu should switch between an idle summary, a running screenshot-analysis block, a running work-content-summary block, or both running blocks when both services are active.
- When either model profile uses LM Studio, the Current Status submenu should expose a force-unload command for that specific profile as a third block after the status text and the regular action section. Keep `Open Screenshots Folder` and `Analyze Now` together in the second block.
- The Clear Early Screenshots submenu calculates counts asynchronously when opened. It should show calculating, empty, count, and failure states without blocking the menu bar UI, and destructive cleanup requires confirmation.

## Reports And Logs

- Reports should prioritize timeline and aggregate comprehension over decorative layout.
- Keep report responsibilities split by file: `ReportsView.swift` composes the window, `ReportsViewModel.swift` derives report state, `ReportLegendViews.swift` owns legend layout and hover geometry, and `ReportHeatmapViews.swift` owns timeline renderers.
- Report charts and heatmaps should use the fixed colors saved on category rules instead of assigning colors from the current chart order.
- Report durations use one shared format across day, week, month, and year views: under 60 minutes uses minutes, 60 to 5,999 minutes uses hours and minutes, and 6,000 minutes or more uses whole hours.
- Heatmap legends are clickable category filter buttons rather than explicit checkboxes. Selected and unselected states are conveyed through opacity, with every category selected by default.
- Category ordering should keep regular categories first, preserved Other second last, and Away last. Bar charts hide Away bars while keeping Away in the legend for color and filtering consistency.
- Weekly heatmap brightness uses one normalization pool for all selected non-away categories and a separate pool for Away.
- Daily heatmap blocks may represent merged contiguous work summaries even when the visual span matches the underlying raw events. Hover text appears only from `daily_work_block_summaries`, not directly from raw analysis rows, and is positioned over the left report-selection area so the heatmap itself does not shift when hover content changes.
- Daily report legends keep category-summary hover stable across chip gaps by checking pointer locations against row-union hover rectangles with a small margin; individual chip exits should not clear the hovered category, and trailing empty space after the last row should not count as hovered.
- Derived statuses such as temporary daily reports should be visually marked where the result appears, not explained in a detached help block.
- Runtime logs should remain dense, sortable or filterable when needed, and copy/export friendly.

## Localization

- All visible UI strings must go through `AppLocalization.swift`.
- When adding or changing UI copy, update both Chinese and English entries in the same change.
- Prefer concise labels that fit in existing row widths before increasing layout constants.

## Verification

- Run `DeskBriefTests` after UI changes that alter settings behavior, localization, or persisted preferences.
- For purely visual spacing changes, a build or the existing unit test suite is usually sufficient unless the change affects window flow, permissions, or menu behavior.
- Use GUI testing only when the interaction itself is under test; do not rely on it for simple spacing adjustments.
