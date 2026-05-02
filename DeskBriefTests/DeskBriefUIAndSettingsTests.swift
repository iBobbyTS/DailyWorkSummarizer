import AppKit
import CoreGraphics
import Foundation
import FoundationModels
import SQLite3
import Testing
@testable import DeskBrief

@MainActor
extension DeskBriefTests {
    @Test func reportDurationsUseSharedMinuteHourAndHourOnlyThresholds() async throws {
        let fiftyNineMinutes = 59.0 / 60.0
        let sixtyMinutes = 60.0 / 60.0
        let fiveThousandNineHundredNinetyNineMinutes = 5_999.0 / 60.0
        let sixThousandThirtyMinutes = 6_030.0 / 60.0

        for kind in ReportKind.allCases {
            #expect(fiftyNineMinutes.durationText(for: kind, language: .simplifiedChinese) == "59 分钟")
            #expect(sixtyMinutes.durationText(for: kind, language: .simplifiedChinese) == "1 小时")
            #expect(fiveThousandNineHundredNinetyNineMinutes.durationText(for: kind, language: .simplifiedChinese) == "99 小时 59 分")
            #expect(sixThousandThirtyMinutes.durationText(for: kind, language: .simplifiedChinese) == "100 小时")

            #expect(fiftyNineMinutes.durationText(for: kind, language: .english) == "59 minutes")
            #expect(sixtyMinutes.durationText(for: kind, language: .english) == "1 hr")
            #expect(fiveThousandNineHundredNinetyNineMinutes.durationText(for: kind, language: .english) == "99 hrs 59 min")
            #expect(sixThousandThirtyMinutes.durationText(for: kind, language: .english) == "100 hrs")
        }
    }

    @Test func reportDayDisplayTextIncludesLocalizedWeekdaySuffix() async throws {
        let dayStart = makeScreenshotDate(year: 2026, month: 4, day: 27, hour: 9, minute: 0)

        #expect(L10n.reportDayDisplayText(for: dayStart, language: .simplifiedChinese) == "2026年4月27日·星期一")
        #expect(L10n.reportDayDisplayText(for: dayStart, language: .english) == "Apr 27, 2026·Monday")
    }

    @Test func legendHoverRectsBridgeRowsWithoutCoveringTrailingEmptySpace() async throws {
        let rects = LegendHoverGeometry.hoverRects(for: [
            CGRect(x: 90, y: 0, width: 70, height: 30),
            CGRect(x: 0, y: 40, width: 50, height: 30),
            CGRect(x: 60, y: 40, width: 50, height: 30),
            CGRect(x: 0, y: 0, width: 80, height: 30)
        ])

        #expect(rects.count == 2)
        let firstRow = try #require(rects.first)
        let secondRow = try #require(rects.last)

        #expect(firstRow.contains(CGPoint(x: 85, y: 15)))
        #expect(secondRow.contains(CGPoint(x: 55, y: 55)))
        #expect(secondRow.contains(CGPoint(x: 112, y: 55)))
        #expect(!secondRow.contains(CGPoint(x: 120, y: 55)))
        #expect(!LegendHoverGeometry.contains(CGPoint(x: 120, y: 55), in: rects))
        #expect(abs(firstRow.maxY - secondRow.minY) < 0.001)
        #expect(secondRow.contains(CGPoint(x: 10, y: firstRow.maxY)))
    }

    @Test func legendHoverRectsIgnoreInvalidFrames() async throws {
        let rects = LegendHoverGeometry.hoverRects(for: [
            .zero,
            CGRect(x: 0, y: 0, width: 80, height: 30),
            CGRect(x: 0, y: 50, width: -10, height: 20),
            CGRect(x: 0, y: 40, width: 50, height: 30)
        ])

        #expect(rects.count == 2)
        #expect(LegendHoverGeometry.hoverRects(for: []).isEmpty)
    }

    @Test func captureSkipsWhenMouseLocationAndFrontmostAppAreUnchanged() async throws {
        let shouldSkip = ScreenshotService.shouldSkipCapture(
            currentMouseLocation: CGPoint(x: 120, y: 240),
            lastMouseLocation: CGPoint(x: 120, y: 240),
            currentFrontmostAppIdentifier: "com.apple.Safari",
            lastFrontmostAppIdentifier: "com.apple.Safari"
        )

        #expect(shouldSkip)
    }

    @Test func captureDoesNotSkipWhenFrontmostAppChanges() async throws {
        let shouldSkip = ScreenshotService.shouldSkipCapture(
            currentMouseLocation: CGPoint(x: 120, y: 240),
            lastMouseLocation: CGPoint(x: 120, y: 240),
            currentFrontmostAppIdentifier: "com.apple.Safari",
            lastFrontmostAppIdentifier: "com.apple.dt.Xcode"
        )

        #expect(!shouldSkip)
    }

    @Test func retryPolicyRetriesServerAndInvalidResponseErrorsBeforeMaxAttempts() async throws {
        #expect(
            AnalysisService.shouldRetryAnalysis(
                after: AnalysisServiceError.httpError(statusCode: 500, body: "server error"),
                attempt: 1
            )
        )
        #expect(
            AnalysisService.shouldRetryAnalysis(
                after: AnalysisServiceError.invalidResponse("no output"),
                attempt: 2
            )
        )
    }

    @Test func retryPolicyDoesNotRetryLengthOrFourthAttempt() async throws {
        #expect(
            !AnalysisService.shouldRetryAnalysis(
                after: AnalysisServiceError.lengthTruncated("truncated"),
                attempt: 1
            )
        )
        #expect(
            !AnalysisService.shouldRetryAnalysis(
                after: AnalysisServiceError.invalidResponse("invalid category"),
                attempt: 3
            )
        )
    }

    @Test func pauseAfterFiveConsecutiveFailures() async throws {
        #expect(!AnalysisService.shouldPauseAfterConsecutiveFailures(4))
        #expect(AnalysisService.shouldPauseAfterConsecutiveFailures(5))
    }

    @Test func lmStudioPauseTransitionsToUnloadStageAfterGenerationStops() async throws {
        #expect(AnalysisService.stoppingStageAfterGenerationStops(for: .lmStudio) == .unloadingModel)
        #expect(AnalysisService.stoppingStageAfterGenerationStops(for: .openAI) == nil)
        #expect(AnalysisService.stoppingStageAfterGenerationStops(for: .anthropic) == nil)
        #expect(AnalysisService.stoppingStageAfterGenerationStops(for: .appleIntelligence) == nil)
    }

    @Test func pausingStagesUseDistinctMenuLabels() async throws {
        #expect(
            L10n.string(.menuAnalyzeNowPausingStoppingGeneration, language: .simplifiedChinese)
                == "正在停止本次分析（正在停止生成）"
        )
        #expect(
            L10n.string(.menuAnalyzeNowPausingUnloadingModel, language: .simplifiedChinese)
                == "正在停止本次分析（正在卸载模型）"
        )
        #expect(
            L10n.string(.menuAnalyzeNowPausingStoppingGeneration, language: .english)
                == "Stopping (Stopping Generation)"
        )
        #expect(
            L10n.string(.menuAnalyzeNowPausingUnloadingModel, language: .english)
                == "Stopping (Unloading Model)"
        )
    }

    @Test func lmStudioLifecycleToggleStringsAreLocalized() async throws {
        #expect(L10n.string(.appName, language: .simplifiedChinese) == "工迹")
        #expect(L10n.string(.appName, language: .english) == "DeskBrief")
        #expect(
            L10n.string(.settingsModelLMStudioAutoLoadUnloadModel, language: .simplifiedChinese)
                == "主动装卸载模型"
        )
        #expect(
            L10n.string(.settingsModelLMStudioAutoLoadUnloadModelHelp, language: .simplifiedChinese)
                == "App会在开始分析前后主动加载和卸载模型，如果使用的模型是始终保持在后台的，请关闭这个选项"
        )
        #expect(
            L10n.string(.settingsModelLMStudioAutoLoadUnloadModel, language: .english)
                == "Auto load/unload model"
        )
        #expect(
            L10n.string(.settingsModelLMStudioAutoLoadUnloadModelHelp, language: .english)
                == "The app will proactively load and unload the model before and after analysis. If the model stays loaded in the background, turn this off."
        )
        #expect(L10n.string(.menuForceUnloadScreenshotAnalysisModel, language: .simplifiedChinese) == "强制卸载截屏分析模型")
        #expect(L10n.string(.menuForceUnloadWorkContentSummaryModel, language: .english) == "Force Unload Work Content Summary Model")
        #expect(L10n.string(.menuBackfillMissingSummaries, language: .simplifiedChinese) == "检查并补充过去遗漏的总结")
        #expect(L10n.string(.menuBackfillMissingSummaries, language: .english) == "Fill Missing Summaries")
    }

    @Test func summaryInstructionEditorKeepsTextAwayFromClippingEdge() async throws {
        let textView = NSTextView()
        SummaryInstructionTextViewTextSystem.apply(to: textView)

        #expect(textView.textContainerInset.width == 12)
        #expect(textView.textContainerInset.height == 12)
        #expect(textView.textContainer?.lineFragmentPadding == 0)
        #expect(!textView.drawsBackground)
    }

    @MainActor
    @Test func statusMenuPlacesReportsBelowCurrentStatusAndUtilitiesBelowSettings() async throws {
        let delegate = AppDelegate()
        let menu = delegate.statusMenuForTesting
        let topLevelItems = menu.items

        func selectorName(for item: NSMenuItem) -> String? {
            guard let action = item.action else { return nil }
            return NSStringFromSelector(action)
        }

        let cleanupValues = topLevelItems[2].submenu?.items.compactMap { $0.representedObject as? Int }
        let startupModeValues = topLevelItems[5].submenu?.items.compactMap { $0.representedObject as? String }
        let statusSubmenuActions = topLevelItems[0].submenu?.items.compactMap { selectorName(for: $0) }
        let statusSubmenu = try #require(topLevelItems[0].submenu)

        #expect(topLevelItems.count == 9)
        #expect(topLevelItems[0].submenu != nil)
        #expect(selectorName(for: topLevelItems[1]) == "openReports")
        #expect(cleanupValues == EarlyScreenshotCleanupScope.allCases.map(\.rawValue))
        #expect(topLevelItems[3].isSeparatorItem)
        #expect(selectorName(for: topLevelItems[4]) == "openSettings")
        #expect(startupModeValues == AnalysisStartupMode.allCases.map(\.rawValue))
        #expect(selectorName(for: topLevelItems[6]) == "openLogs")
        #expect(topLevelItems[7].isSeparatorItem)
        #expect(selectorName(for: topLevelItems[8]) == "quit")
        #expect(statusSubmenuActions?.contains("openLogs") == false)
        #expect(statusSubmenuActions?.contains("runAnalysisNow") == true)
        #expect(statusSubmenu.items.count == 15)
        #expect(statusSubmenu.items[8].isSeparatorItem)
        #expect(selectorName(for: statusSubmenu.items[9]) == "openScreenshotsFolder")
        #expect(selectorName(for: statusSubmenu.items[10]) == "runAnalysisNow")
        #expect(selectorName(for: statusSubmenu.items[11]) == "backfillMissingSummaries")
        #expect(statusSubmenu.items[12].isSeparatorItem)
        #expect(statusSubmenu.items[13].action != nil)
        #expect(statusSubmenu.items[14].action != nil)
        #expect(selectorName(for: statusSubmenu.items[13]) == "forceUnloadModel:")
        #expect(selectorName(for: statusSubmenu.items[14]) == "forceUnloadModel:")
    }

    @Test func statusMenuTextBuildersFormatRunningAnalysisAndSummaryState() async throws {
        let analysisProfile = makeModelSettings(
            provider: .lmStudio,
            apiBaseURL: "http://127.0.0.1:1234",
            modelName: "analysis-model"
        )
        let summaryProfile = makeModelSettings(
            provider: .openAI,
            apiBaseURL: "https://summary.example.com",
            modelName: "summary-model"
        )
        let analysisState = AnalysisRuntimeState(
            isRunning: true,
            stoppingStage: nil,
            startedAt: makeScreenshotDate(year: 2026, month: 4, day: 30, hour: 9, minute: 0),
            modelName: "analysis-model",
            completedCount: 2,
            totalCount: 5
        )
        let stoppingAnalysisState = AnalysisRuntimeState(
            isRunning: true,
            stoppingStage: .unloadingModel,
            startedAt: makeScreenshotDate(year: 2026, month: 4, day: 30, hour: 9, minute: 0),
            modelName: "analysis-model",
            completedCount: 3,
            totalCount: 5
        )
        let summaryState = DailyReportSummaryRuntimeState(
            isRunning: true,
            isStopping: false,
            modelName: "summary-model",
            completedCount: 1,
            totalCount: 4
        )

        #expect(
            MenuBarStatusPresentation.currentModelLine(profile: analysisProfile, language: .simplifiedChinese)
                == "当前加载模型：analysis-model"
        )
        #expect(
            MenuBarStatusPresentation.currentModelLine(profile: summaryProfile, language: .english)
                == "Current model: summary-model"
        )
        #expect(
            MenuBarStatusPresentation.analysisRunningTitle(language: .simplifiedChinese)
                == "正在进行：截屏分析"
        )
        #expect(
            MenuBarStatusPresentation.summaryRunningTitle(language: .english)
                == "Running: Work Content Summary"
        )
        #expect(
            MenuBarStatusPresentation.summaryProgressLine(state: summaryState, language: .simplifiedChinese)
                == "进度：25%"
        )
        #expect(
            MenuBarStatusPresentation.summaryProgressLine(state: summaryState, language: .english)
                == "Progress: 25%"
        )
        #expect(
            MenuBarStatusPresentation.analysisProgressLine(
                state: analysisState,
                startedAt: analysisState.startedAt ?? Date(),
                language: .simplifiedChinese
            ).contains("正在分析从")
        )
        #expect(
            MenuBarStatusPresentation.analysisProgressLine(
                state: stoppingAnalysisState,
                startedAt: stoppingAnalysisState.startedAt ?? Date(),
                language: .simplifiedChinese
            ).contains("正在停止本次分析")
        )
        #expect(
            MenuBarStatusPresentation.forceUnloadButtonTitle(for: .workContentSummary, language: .simplifiedChinese)
                == "强制卸载工作内容总结模型"
        )
        #expect(
            MenuBarStatusPresentation.lifecycleDisabledConfirmation(appName: "工迹", language: .simplifiedChinese)
                == "根据当前设置，模型装卸载不由工迹管理，是否仍要发起卸载请求？"
        )
        #expect(
            MenuBarStatusPresentation.stopCurrentWorkConfirmation(language: .english)
                == "Stop the current analysis or summary?"
        )
    }

    @MainActor
    @Test func forceUnloadScreenshotAnalysisUsesLoadedModelsListWhenInstanceIDIsNotTracked() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "DeskBriefTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: suiteName)

        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            keychain.set("", for: AppDefaults.apiKeyAccount)
            keychain.set("", for: AppDefaults.workContentSummaryAPIKeyAccount)
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(at: supportURL)
            MockURLProtocol.reset()
        }

        let database = try AppDatabase(databaseURL: databaseURL, applicationSupportDirectory: supportURL)
        let store = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)
        store.provider = .lmStudio
        store.apiBaseURL = "http://127.0.0.1:1234"
        store.modelName = "analysis-model"
        store.screenshotAnalysisLMStudioAutoLoadUnloadModel = false
        store.imageAnalysisMethod = .multimodal

        let session = makeMockSession { request in
            try lmStudioLifecycleTestResponse(for: request)
        }
        let service = AnalysisService(
            database: database,
            settingsStore: store,
            logStore: AppLogStore(database: database),
            dailyReportSummaryService: DailyReportSummaryService(database: database, settingsStore: store, session: session),
            session: session
        )

        let didUnload = try await service.forceUnloadManagedModel()

        #expect(didUnload)
        #expect(MockURLProtocol.requestPaths == ["/api/v1/models", "/api/v1/models/unload"])
    }

    @Test func settingsTerminologySeparatesScreenshotAnalysisAndWorkContentSummary() async throws {
        #expect(L10n.string(.settingsTabScreenshotAnalysis, language: .simplifiedChinese) == "截屏分析")
        #expect(L10n.string(.settingsTabWorkContentSummary, language: .simplifiedChinese) == "工作内容总结")
        #expect(L10n.string(.settingsModelCopyToWorkContentSummary, language: .simplifiedChinese) == "复制到“工作内容总结”")
        #expect(L10n.string(.settingsModelCopyToScreenshotAnalysis, language: .simplifiedChinese) == "复制到“截屏分析”")

        #expect(L10n.string(.settingsTabScreenshotAnalysis, language: .english) == "Screenshot Analysis")
        #expect(L10n.string(.settingsTabWorkContentSummary, language: .english) == "Work Content Summary")
        #expect(L10n.string(.settingsModelCopyToWorkContentSummary, language: .english) == "Copy to Work Content Summary")
        #expect(L10n.string(.settingsModelCopyToScreenshotAnalysis, language: .english) == "Copy to Screenshot Analysis")

        let deprecatedChineseWorkContentTerm = "工作内容" + "分析"
        let deprecatedEnglishWorkContentTerm = "Work Content " + "Analysis"
        let visibleWorkContentStrings = [
            L10n.string(.settingsTabWorkContentSummary, language: .simplifiedChinese),
            L10n.string(.settingsModelCopyToWorkContentSummary, language: .simplifiedChinese),
            L10n.string(.settingsModelCopyToWorkContentSummaryConfirmMessage, language: .simplifiedChinese)
        ]
        #expect(visibleWorkContentStrings.allSatisfy { !$0.contains(deprecatedChineseWorkContentTerm) })

        let visibleEnglishWorkContentStrings = [
            L10n.string(.settingsTabWorkContentSummary, language: .english),
            L10n.string(.settingsModelCopyToWorkContentSummary, language: .english),
            L10n.string(.settingsModelCopyToWorkContentSummaryConfirmMessage, language: .english)
        ]
        #expect(visibleEnglishWorkContentStrings.allSatisfy { !$0.contains(deprecatedEnglishWorkContentTerm) })
    }

    @Test func lmStudioPauseTransitionsRespectLifecycleToggle() async throws {
        #expect(AnalysisService.stoppingStageAfterGenerationStops(for: .lmStudio) == .unloadingModel)
        #expect(AnalysisService.stoppingStageAfterGenerationStops(for: .lmStudio, lifecycleEnabled: false) == nil)
        #expect(AnalysisService.stoppingStageAfterGenerationStops(for: .openAI) == nil)
        #expect(AnalysisService.stoppingStageAfterGenerationStops(for: .anthropic) == nil)
        #expect(AnalysisService.stoppingStageAfterGenerationStops(for: .appleIntelligence) == nil)
    }

    @Test func runtimeErrorRecordingFiltersOutNonAPIErrors() async throws {
        #expect(AnalysisService.shouldRecordRuntimeError(AnalysisServiceError.invalidResponse("empty output")))
        #expect(AnalysisService.shouldRecordRuntimeError(AnalysisServiceError.httpError(statusCode: 500, body: "server error")))
        #expect(!AnalysisService.shouldRecordRuntimeError(AnalysisServiceError.invalidConfiguration("missing url")))
        #expect(!AnalysisService.shouldRecordRuntimeError(CancellationError()))
    }

    @Test func analysisPromptIncludesSummaryInstructionAndJSONContract() async throws {
        let rules = [
            CategoryRule(name: "专注工作", description: "写代码和做项目"),
            CategoryRule(name: "上课学习", description: "上课或完成课程作业"),
        ]
        let instruction = "请关注课程名称和项目仓库名"

        let prompt = L10n.analysisPrompt(
            with: rules,
            summaryInstruction: instruction,
            language: .simplifiedChinese
        )

        #expect(prompt.contains("描述要求："))
        #expect(prompt.contains(instruction))
        #expect(prompt.contains("\"summary\""))
        #expect(prompt.contains("专注工作：写代码和做项目"))
    }

    @Test func analysisResponseParsingHandlesThinkAndCodeFenceJSON() async throws {
        let rules = [
            CategoryRule(name: "专注工作", description: "写代码和做项目"),
            CategoryRule(name: "上课学习", description: "上课或完成课程作业"),
        ]
        let rawText = """
        <think>先看一下窗口内容</think>
        ```json
        {"category":"专注工作","summary":"开发 DeskBrief 菜单栏项目"}
        ```
        """

        let response = AnalysisService.extractAnalysisResponse(from: rawText, validRules: rules)

        #expect(response?.category == "专注工作")
        #expect(response?.summary == "开发 DeskBrief 菜单栏项目")
    }

    @Test func analysisResponseParsingRejectsInvalidStructuredPayloads() async throws {
        let rules = [
            CategoryRule(name: "专注工作", description: "写代码和做项目"),
        ]

        #expect(
            AnalysisService.extractAnalysisResponse(
                from: #"{"category":"错误类别","summary":"开发项目"}"#,
                validRules: rules
            ) == nil
        )
        #expect(
            AnalysisService.extractAnalysisResponse(
                from: #"{"category":"   ","summary":"开发项目"}"#,
                validRules: rules
            ) == nil
        )
        #expect(
            AnalysisService.extractAnalysisResponse(
                from: #"{"category":"专注工作","summary":"   "}"#,
                validRules: rules
            ) == nil
        )
        #expect(
            AnalysisService.extractAnalysisResponse(
                from: #"{"category":"专注工作"}"#,
                validRules: rules
            ) == nil
        )
        #expect(
            AnalysisService.extractAnalysisResponse(
                from: "专注工作",
                validRules: rules
            ) == nil
        )
    }

    @Test func defaultCategoryRulesAlwaysAppendPreservedOther() async throws {
        let chineseRules = AppDefaults.defaultCategoryRules(language: .simplifiedChinese)
        let englishRules = AppDefaults.defaultCategoryRules(language: .english)

        #expect(chineseRules.last?.name == AppDefaults.preservedOtherCategoryName)
        #expect(englishRules.last?.name == AppDefaults.preservedOtherCategoryName)
        #expect(chineseRules.last?.description == AppDefaults.preservedOtherCategoryDescription(language: .simplifiedChinese))
        #expect(chineseRules.map(\.colorHex) == [
            AppDefaults.categoryColorPreset(at: 0),
            AppDefaults.categoryColorPreset(at: 1),
            AppDefaults.categoryColorPreset(at: 2),
            AppDefaults.categoryColorPreset(at: 15),
        ])
    }

    @MainActor
    @Test func settingsStorePersistsSummaryInstruction() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let suiteName = "DeskBriefTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: suiteName)
        userDefaults.set(AppLanguage.simplifiedChinese.rawValue, forKey: AppLanguage.userDefaultsKey)

        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            keychain.set("", for: AppDefaults.apiKeyAccount)
            keychain.set("", for: AppDefaults.workContentSummaryAPIKeyAccount)
            try? FileManager.default.removeItem(at: databaseURL)
        }

        let database = try AppDatabase(databaseURL: databaseURL)
        let store = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)
        let updatedInstruction = "最近在做操作系统课程项目和 DeskBrief 重构"

        #expect(
            store.summaryInstruction == AppDefaults.defaultSummaryInstruction(language: .simplifiedChinese)
        )

        store.summaryInstruction = updatedInstruction

        let reloadedStore = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)

        #expect(store.snapshot.summaryInstruction == updatedInstruction)
        #expect(reloadedStore.summaryInstruction == updatedInstruction)
        #expect(reloadedStore.workContentSummaryProvider == store.provider)
    }

    @MainActor
    @Test func settingsStorePersistsAnalysisStartupMode() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let suiteName = "DeskBriefTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: suiteName)
        userDefaults.set(AnalysisStartupMode.scheduled.rawValue, forKey: "settings.analysisStartupMode")

        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            keychain.set("", for: AppDefaults.apiKeyAccount)
            keychain.set("", for: AppDefaults.workContentSummaryAPIKeyAccount)
            try? FileManager.default.removeItem(at: databaseURL)
        }

        let database = try AppDatabase(databaseURL: databaseURL)
        let store = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)

        #expect(store.analysisStartupMode == .scheduled)

        store.analysisStartupMode = .realtime
        let reloadedStore = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)

        #expect(reloadedStore.analysisStartupMode == .realtime)
        #expect(reloadedStore.snapshot.analysisStartupMode == .realtime)
        #expect(userDefaults.string(forKey: "settings.analysisStartupMode") == AnalysisStartupMode.realtime.rawValue)
    }

    @Test func analysisStartupModeTitlesAreLocalized() async throws {
        #expect(AnalysisStartupMode.manual.title(in: .simplifiedChinese) == "不自动启动")
        #expect(AnalysisStartupMode.scheduled.title(in: .simplifiedChinese) == "定时启动")
        #expect(AnalysisStartupMode.realtime.title(in: .simplifiedChinese) == "截屏后立即启动")
        #expect(AnalysisStartupMode.manual.title(in: .english) == "Do Not Auto Start")
        #expect(AnalysisStartupMode.scheduled.title(in: .english) == "Scheduled Start")
        #expect(AnalysisStartupMode.realtime.title(in: .english) == "Start Immediately After Screenshot")
    }

    @Test func chargerRequirementAppliesOnlyToAutomaticAnalysisTriggers() async throws {
        #expect(
            !AnalysisService.shouldSkipForChargerRequirement(
                trigger: .manual,
                requiresCharger: true,
                isConnectedToCharger: false
            )
        )
        #expect(
            AnalysisService.shouldSkipForChargerRequirement(
                trigger: .scheduled,
                requiresCharger: true,
                isConnectedToCharger: false
            )
        )
        #expect(
            AnalysisService.shouldSkipForChargerRequirement(
                trigger: .realtime,
                requiresCharger: true,
                isConnectedToCharger: false
            )
        )
        #expect(
            !AnalysisService.shouldSkipForChargerRequirement(
                trigger: .realtime,
                requiresCharger: false,
                isConnectedToCharger: false
            )
        )
        #expect(
            !AnalysisService.shouldSkipForChargerRequirement(
                trigger: .scheduled,
                requiresCharger: true,
                isConnectedToCharger: true
            )
        )
    }

}
