import XCTest

final class DeskBriefUITests: XCTestCase {
    private var launchedApps: [XCUIApplication] = []
    private var cleanupURLs: [URL] = []

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        for app in launchedApps {
            app.terminate()
        }
        launchedApps.removeAll()

        for url in cleanupURLs {
            try? FileManager.default.removeItem(at: url)
        }
        cleanupURLs.removeAll()
    }

    @MainActor
    func testSettingsWindowSmoke() throws {
        let app = launchIsolatedApp(opening: "--deskbrief-open-settings")

        XCTAssertTrue(app.windows.element(boundBy: 0).waitForExistence(timeout: 5))
        XCTAssertTrue(accessibilityElement("settings.root", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(hasAnyElement(["Screenshot Analysis", "截屏分析"], in: app))
        XCTAssertTrue(hasAnyElement(["Work Content Summary", "工作内容总结"], in: app))
        XCTAssertTrue(hasAnyElement(["General", "通用"], in: app))
        XCTAssertTrue(hasAnyElement(["Model Settings", "模型设置"], in: app))
    }

    @MainActor
    func testModelCopyButtonShowsConfirmation() throws {
        let app = launchIsolatedApp(opening: "--deskbrief-open-settings")

        XCTAssertTrue(accessibilityElement("settings.root", in: app).waitForExistence(timeout: 5))

        button(matchingLabels: ["Copy to Work Content Summary", "复制到“工作内容总结”"], in: app).click()

        XCTAssertTrue(hasAnyElement(["Confirm model config copy", "确认复制模型配置"], in: app))
        XCTAssertTrue(hasAnyElement([
            "This will overwrite the model configuration in Work Content Summary.",
            "确认后会覆盖“工作内容总结”里的模型配置。"
        ], in: app))
    }

    @MainActor
    func testReportsWindowSmoke() throws {
        let app = launchIsolatedApp(opening: "--deskbrief-open-reports")

        XCTAssertTrue(app.windows.element(boundBy: 0).waitForExistence(timeout: 5))
        XCTAssertTrue(accessibilityElement("reports.root", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(hasAnyElement(["Report type", "报告类型"], in: app))
        XCTAssertTrue(hasAnyElement(["Chart type", "图表类型"], in: app))
    }

    @MainActor
    func testLogsWindowSmoke() throws {
        let app = launchIsolatedApp(opening: "--deskbrief-open-logs")

        XCTAssertTrue(app.windows.element(boundBy: 0).waitForExistence(timeout: 5))
        XCTAssertTrue(accessibilityElement("logs.root", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(hasAnyElement(["All", "全部"], in: app))
        XCTAssertTrue(hasAnyElement(["No Logs", "当前没有日志"], in: app))
    }

    @MainActor
    func testAnalysisRunsWindowShowsSeededRun() throws {
        let app = launchIsolatedApp(
            opening: "--deskbrief-open-analysis-runs",
            additionalArguments: ["--deskbrief-seed-ui-test-data"]
        )

        XCTAssertTrue(app.windows.element(boundBy: 0).waitForExistence(timeout: 5))
        XCTAssertTrue(accessibilityElement("analysisRuns.root", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(hasAnyElement(["Analysis Runs", "分析记录"], in: app))
        XCTAssertTrue(app.staticTexts["ui-test-model-with-long-name-for-horizontal-scroll"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["2/1"].exists)
        XCTAssertTrue(app.staticTexts["1520/2440"].exists)
        XCTAssertTrue(app.staticTexts["980/1120"].exists)
        XCTAssertTrue(app.staticTexts["ui test long analysis error message"].exists)
    }

    @MainActor
    func testLogsFilteringAndClearAll() throws {
        let app = launchIsolatedApp(
            opening: "--deskbrief-open-logs",
            additionalArguments: ["--deskbrief-seed-ui-test-data"]
        )

        XCTAssertTrue(accessibilityElement("logs.root", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["ui test log message"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["ui test error message"].waitForExistence(timeout: 5))

        accessibilityElement("logs.filter.error", in: app).click()
        XCTAssertTrue(app.staticTexts["ui test error message"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["ui test log message"].exists)

        accessibilityElement("logs.filter.all", in: app).click()
        XCTAssertTrue(app.staticTexts["ui test log message"].waitForExistence(timeout: 5))

        button(matchingLabels: ["Clear All Logs", "清空所有日志"], in: app).click()
        XCTAssertTrue(hasAnyElement(["No Logs", "当前没有日志"], in: app))
        XCTAssertFalse(app.staticTexts["ui test error message"].exists)
    }

    @MainActor
    func testNotificationActionOpensReportsAndLogs() throws {
        let app = launchIsolatedApp(
            opening: "--deskbrief-open-notification-action=openReportsAndLogs",
            additionalArguments: ["--deskbrief-seed-ui-test-data"]
        )

        XCTAssertTrue(accessibilityElement("reports.root", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(accessibilityElement("logs.root", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(hasAnyElement(["Report type", "报告类型"], in: app))
        XCTAssertTrue(app.staticTexts["ui test error message"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testDatabaseEncryptionEnableConfirmation() throws {
        let app = launchIsolatedApp(opening: "--deskbrief-open-settings-general")

        XCTAssertTrue(accessibilityElement("settings.root", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(accessibilityElement("settings.tab.general", in: app).waitForExistence(timeout: 5))

        accessibilityElement("settings.databaseEncryptionToggle", in: app).click()
        XCTAssertTrue(hasAnyElement(["Confirm Database Key", "确认数据库密钥"], in: app))

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(hasAnyElement(["Change Database Key", "修改数据库密钥"], in: app))

        accessibilityElement("settings.databaseEncryptionToggle", in: app).click()
        XCTAssertTrue(hasAnyElement(["Confirm Database Key", "确认数据库密钥"], in: app))
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(hasAnyElement(["Change Database Key", "修改数据库密钥"], in: app))
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTClockMetric()]) {
            let app = makeIsolatedApp()
            app.launch()
            app.terminate()
        }
    }

    private func launchIsolatedApp(
        opening launchArgument: String,
        additionalArguments: [String] = []
    ) -> XCUIApplication {
        let app = makeIsolatedApp(opening: launchArgument, additionalArguments: additionalArguments)
        app.launch()
        launchedApps.append(app)
        return app
    }

    private func makeIsolatedApp(
        opening launchArgument: String? = nil,
        additionalArguments: [String] = []
    ) -> XCUIApplication {
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeskBriefUITests-\(UUID().uuidString)", isDirectory: true)
        cleanupURLs.append(supportURL)

        let app = XCUIApplication()
        app.launchArguments = ["--deskbrief-ui-testing"]
        if let launchArgument {
            app.launchArguments.append(launchArgument)
        }
        app.launchArguments.append(contentsOf: additionalArguments)
        app.launchEnvironment["DESKBRIEF_UI_TEST_SUPPORT_DIR"] = supportURL.path
        app.launchEnvironment["DESKBRIEF_UI_TEST_DEFAULTS_SUITE"] = "DeskBriefUITests.\(UUID().uuidString)"
        app.launchEnvironment["DESKBRIEF_UI_TEST_KEYCHAIN_SERVICE"] = "DeskBriefUITests.\(UUID().uuidString)"
        app.launchEnvironment["AppleLanguages"] = "(en)"
        app.launchEnvironment["AppleLocale"] = "en_US"
        return app
    }

    private func accessibilityElement(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func hasAnyElement(_ labels: [String], in app: XCUIApplication) -> Bool {
        labels.contains { label in
            app.descendants(matching: .any)[label].exists
        }
    }

    private func button(matchingLabels labels: [String], in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(labelIn: labels).firstMatch
    }
}

private extension XCUIElementQuery {
    func matching(labelIn labels: [String]) -> XCUIElementQuery {
        matching(NSPredicate(format: "label IN %@", labels))
    }
}
