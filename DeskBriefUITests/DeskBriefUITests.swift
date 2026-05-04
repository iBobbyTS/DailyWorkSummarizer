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
        XCTAssertTrue(hasAnyElement(["Report", "报告"], in: app))
        XCTAssertTrue(hasAnyElement(["Model Settings", "模型设置"], in: app))
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
    func testLaunchPerformance() throws {
        measure(metrics: [XCTClockMetric()]) {
            let app = makeIsolatedApp()
            app.launch()
            app.terminate()
        }
    }

    private func launchIsolatedApp(opening launchArgument: String) -> XCUIApplication {
        let app = makeIsolatedApp(opening: launchArgument)
        app.launch()
        launchedApps.append(app)
        return app
    }

    private func makeIsolatedApp(opening launchArgument: String? = nil) -> XCUIApplication {
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeskBriefUITests-\(UUID().uuidString)", isDirectory: true)
        cleanupURLs.append(supportURL)

        let app = XCUIApplication()
        app.launchArguments = ["--deskbrief-ui-testing"]
        if let launchArgument {
            app.launchArguments.append(launchArgument)
        }
        app.launchEnvironment["DESKBRIEF_UI_TEST_SUPPORT_DIR"] = supportURL.path
        app.launchEnvironment["DESKBRIEF_UI_TEST_DEFAULTS_SUITE"] = "DeskBriefUITests.\(UUID().uuidString)"
        app.launchEnvironment["DESKBRIEF_UI_TEST_KEYCHAIN_SERVICE"] = "DeskBriefUITests.\(UUID().uuidString)"
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
}
