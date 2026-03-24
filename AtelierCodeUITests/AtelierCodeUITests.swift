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

    func testSelectingRecentWorkspaceShowsConversationShell() throws {
        let app = try makeApp(scenario: "recent-selection", workspaceName: "RecentSelection")
        app.launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))

        app.buttons["recent-workspace-RecentSelection"].click()

        let readyState = app.staticTexts["Ready"]
        XCTAssertTrue(readyState.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Start the First Turn"].exists)
    }

    func testSendingPromptRendersTranscript() throws {
        let app = try makeApp(scenario: "ready", workspaceName: "TranscriptWorkspace")
        app.launch()

        let composer = app.textViews["conversation-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.click()
        composer.typeText("Build the conversation MVP")

        app.buttons["conversation-send-button"].click()

        XCTAssertTrue(app.staticTexts["Build the conversation MVP"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Working through the request in the UI test harness."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Reasoning"].exists)
        XCTAssertFalse(app.staticTexts["Approvals"].exists)
        XCTAssertFalse(app.staticTexts["Activity"].exists)
    }

    func testPhase2TurnShowsInlineRowsAndApproveKeepsCompletedTurnVisible() throws {
        let app = try makeApp(scenario: "phase2", workspaceName: "Phase2ApproveWorkspace")
        app.launch()

        let composer = app.textViews["conversation-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.click()
        composer.typeText("Show the grouped turn details")

        app.buttons["conversation-send-button"].click()
        app.scrollViews.firstMatch.swipeUp()

        XCTAssertTrue(app.buttons["Approve"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Approvals"].exists)
        XCTAssertTrue(app.staticTexts["I grouped the current turn details under the transcript."].exists)
        XCTAssertTrue(app.staticTexts["Reasoning"].exists)
        XCTAssertTrue(app.staticTexts["Run tests"].exists)
        XCTAssertTrue(app.staticTexts["Plan"].exists)
        XCTAssertTrue(app.staticTexts["Turn Diff"].exists)
        XCTAssertTrue(app.buttons["Approve"].exists)

        app.buttons["Approve"].click()

        XCTAssertFalse(app.staticTexts["Approvals"].waitForExistence(timeout: 1))
        XCTAssertTrue(app.staticTexts["Reasoning"].exists)
        XCTAssertTrue(app.staticTexts["Plan"].exists)
        XCTAssertTrue(app.staticTexts["Turn Diff"].exists)
        XCTAssertTrue(app.staticTexts["Run tests"].exists)
        XCTAssertTrue(app.staticTexts["I grouped the current turn details under the transcript."].exists)
    }

    func testPhase2TurnDeclineRemovesApprovalAndKeepsTurnDetailsVisible() throws {
        let app = try makeApp(scenario: "phase2", workspaceName: "Phase2DeclineWorkspace")
        app.launch()

        let composer = app.textViews["conversation-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.click()
        composer.typeText("Decline the pending approval")

        app.buttons["conversation-send-button"].click()
        app.scrollViews.firstMatch.swipeUp()

        XCTAssertTrue(app.buttons["Decline"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Decline"].exists)

        app.buttons["Decline"].click()

        XCTAssertFalse(app.staticTexts["Approvals"].waitForExistence(timeout: 1))
        XCTAssertTrue(app.staticTexts["Reasoning"].exists)
        XCTAssertTrue(app.staticTexts["Plan"].exists)
        XCTAssertTrue(app.staticTexts["Turn Diff"].exists)
        XCTAssertTrue(app.staticTexts["I grouped the current turn details under the transcript."].exists)
    }

    func testPhase2InlineTurnRowsAppearBeforeFooterPanels() throws {
        let app = try makeApp(scenario: "phase2", workspaceName: "Phase2OrderingWorkspace")
        app.launch()

        let composer = app.textViews["conversation-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.click()
        composer.typeText("Check inline ordering")

        app.buttons["conversation-send-button"].click()
        app.scrollViews.firstMatch.swipeUp()

        let promptText = app.staticTexts["Check inline ordering"]
        let assistantText = app.staticTexts["I grouped the current turn details under the transcript."]
        let reasoningHeading = app.staticTexts["Reasoning"]
        let toolTitle = app.staticTexts["Run tests"]
        let approvalsHeading = app.staticTexts["Approvals"]

        XCTAssertTrue(promptText.waitForExistence(timeout: 5))
        XCTAssertTrue(assistantText.exists)
        XCTAssertTrue(reasoningHeading.exists)
        XCTAssertTrue(toolTitle.exists)
        XCTAssertTrue(approvalsHeading.exists)

        XCTAssertLessThan(promptText.frame.minY, assistantText.frame.minY)
        XCTAssertLessThan(assistantText.frame.minY, reasoningHeading.frame.minY)
        XCTAssertLessThan(reasoningHeading.frame.minY, toolTitle.frame.minY)
        XCTAssertLessThan(toolTitle.frame.minY, approvalsHeading.frame.minY)
    }

    func testRetryRecoversFromConnectionError() throws {
        let app = try makeApp(scenario: "retry", workspaceName: "RetryWorkspace")
        app.launch()

        let retryButton = app.buttons["retry-connection-button"]
        XCTAssertTrue(retryButton.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Connection Error"].exists)

        retryButton.click()

        let composer = app.textViews["conversation-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Ready"].waitForExistence(timeout: 5))
    }

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
