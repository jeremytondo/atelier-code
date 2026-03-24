//
//  AtelierCodeUITests.swift
//  AtelierCodeUITests
//
//  Created by Jeremy Margaritondo on 3/23/26.
//

import XCTest

final class AtelierCodeUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testSelectingRecentWorkspaceShowsConversationShell() throws {
        let app = try makeApp(scenario: "recent-selection", workspaceName: "RecentSelection")
        app.launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))

        app.buttons["recent-workspace-RecentSelection"].click()

        let readyState = app.staticTexts["Ready"]
        XCTAssertTrue(readyState.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Start the First Turn"].exists)
    }

    @MainActor
    func testSendingPromptRendersTranscript() throws {
        let app = try makeApp(scenario: "ready", workspaceName: "TranscriptWorkspace")
        app.launch()

        let composer = app.textFields["conversation-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.click()
        composer.typeText("Build the conversation MVP")

        app.buttons["conversation-send-button"].click()

        XCTAssertTrue(app.staticTexts["Build the conversation MVP"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Working through the request in the UI test harness."].waitForExistence(timeout: 5))
    }

    @MainActor
    func testRetryRecoversFromConnectionError() throws {
        let app = try makeApp(scenario: "retry", workspaceName: "RetryWorkspace")
        app.launch()

        let retryButton = app.buttons["retry-connection-button"]
        XCTAssertTrue(retryButton.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Connection Error"].exists)

        retryButton.click()

        let composer = app.textFields["conversation-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Ready"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }

    private func makeApp(scenario: String, workspaceName: String) throws -> XCUIApplication {
        let workspaceURL = FileManager.default.temporaryDirectory.appendingPathComponent(workspaceName, isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)

        let app = XCUIApplication()
        app.launchEnvironment["ATELIERCODE_UI_TEST_SCENARIO"] = scenario
        app.launchEnvironment["ATELIERCODE_UI_TEST_WORKSPACE"] = workspaceURL.path
        return app
    }
}
