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

    func testExpandingRecentWorkspaceShowsWorkspaceContents() throws {
        let app = try makeApp(scenario: "recent-selection", workspaceName: "RecentSelection")
        app.launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))

        app.buttons["recent-workspace-RecentSelection"].click()

        XCTAssertTrue(app.staticTexts["No active threads yet."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Start a Thread"].exists)
    }

    func testSendingPromptRendersTranscript() throws {
        let app = try makeApp(scenario: "ready", workspaceName: "TranscriptWorkspace")
        app.launch()

        let composer = app.textViews["conversation-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.click()
        composer.typeText("Build the conversation MVP")
        composer.typeText("\r")

        XCTAssertTrue(app.staticTexts["Build the conversation MVP"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Working through the request in the UI test harness."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Reasoning"].exists)
        XCTAssertFalse(app.staticTexts["Approvals"].exists)
        XCTAssertFalse(app.staticTexts["Activity"].exists)
    }

    func testStartedThreadSurvivesCollapseAndRefreshOmission() throws {
        let app = try makeApp(scenario: "refresh-omits-thread", workspaceName: "RefreshOmission")
        app.launch()

        let composer = app.textViews["conversation-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.click()
        composer.typeText("Keep this thread visible")
        composer.typeText("\r")

        let threadRow = app.descendants(matching: .any)["thread-row-ui-test-thread"]
        XCTAssertTrue(threadRow.waitForExistence(timeout: 5))

        let workspaceButton = app.buttons["recent-workspace-RefreshOmission"]
        workspaceButton.click()
        workspaceButton.click()

        XCTAssertTrue(threadRow.waitForExistence(timeout: 5))
    }

    func testPhase2TurnShowsCollapsedGroupedSectionsWithApprovalVisible() throws {
        let app = try makeApp(scenario: "phase2", workspaceName: "Phase2ApproveWorkspace")
        app.launch()

        let scrollView = app.scrollViews.firstMatch
        let composer = app.textViews["conversation-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.click()
        composer.typeText("Show the grouped turn details")
        composer.typeText("\r")
        XCTAssertTrue(app.staticTexts["I grouped the current turn details under the transcript."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Approve"].waitForExistence(timeout: 5))
        scrollView.swipeUp()

        XCTAssertTrue(app.staticTexts["I grouped the current turn details under the transcript."].exists)
        XCTAssertTrue(app.staticTexts["Reasoning"].exists)
        XCTAssertTrue(app.staticTexts["Plan"].exists)
        XCTAssertTrue(app.staticTexts["Turn Diff"].exists)
        XCTAssertTrue(app.buttons["Approve"].exists)
        let mixedToolsToggle = app.buttons["turn-tools-section-1-toggle"]
        XCTAssertTrue(mixedToolsToggle.exists)
        XCTAssertTrue(app.buttons["turn-file-changes-section-1-toggle"].exists)
        XCTAssertEqual(mixedToolsToggle.value as? String, "1 completed, 1 failed")
        XCTAssertTrue(app.otherElements["turn-item-phase2-tool-running-status-accessory"].exists)
        XCTAssertFalse(app.otherElements["turn-item-assistant-status-accessory"].exists)
        XCTAssertFalse(app.staticTexts["Run tests"].exists)
        XCTAssertFalse(app.staticTexts["swift test --filter ThreadSessionTests"].exists)

        mixedToolsToggle.click()
        app.buttons["turn-file-changes-section-1-toggle"].click()

        XCTAssertTrue(app.staticTexts["Run tests"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["swift test --filter ThreadSessionTests"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Run runtime tests"].waitForExistence(timeout: 2))
    }

    func testPhase2TurnShowsGroupedSectionsWithDeclineAction() throws {
        let app = try makeApp(scenario: "phase2", workspaceName: "Phase2DeclineWorkspace")
        app.launch()

        let scrollView = app.scrollViews.firstMatch
        let composer = app.textViews["conversation-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.click()
        composer.typeText("Decline the pending approval")
        composer.typeText("\r")
        XCTAssertTrue(app.buttons["Decline"].waitForExistence(timeout: 5))
        scrollView.swipeUp()

        XCTAssertTrue(app.buttons["turn-tools-section-1-toggle"].exists)
        XCTAssertTrue(app.buttons["turn-file-changes-section-1-toggle"].exists)
        XCTAssertTrue(app.buttons["Decline"].exists)
        XCTAssertTrue(app.staticTexts["Approvals"].exists)
        XCTAssertTrue(app.staticTexts["Reasoning"].exists)
        XCTAssertTrue(app.staticTexts["Plan"].exists)
        XCTAssertTrue(app.staticTexts["Turn Diff"].exists)
        XCTAssertTrue(app.staticTexts["I grouped the current turn details under the transcript."].exists)
    }

    func testPhase2GroupedTurnSectionsAppearBeforeFooterPanels() throws {
        let app = try makeApp(scenario: "phase2", workspaceName: "Phase2OrderingWorkspace")
        app.launch()

        let scrollView = app.scrollViews.firstMatch
        let composer = app.textViews["conversation-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.click()
        composer.typeText("Check inline ordering")
        composer.typeText("\r")
        scrollView.swipeUp()

        let assistantText = app.staticTexts["I grouped the current turn details under the transcript."]
        let reasoningHeading = app.staticTexts["Reasoning"]
        let toolsSection = app.buttons["turn-tools-section-1-toggle"]
        let approvalsHeading = app.staticTexts["Approvals"]
        reveal(approvalsHeading, in: scrollView)

        XCTAssertTrue(assistantText.waitForExistence(timeout: 5))
        XCTAssertTrue(reasoningHeading.exists)
        XCTAssertTrue(toolsSection.exists)
        XCTAssertTrue(approvalsHeading.exists)

        XCTAssertLessThan(assistantText.frame.minY, reasoningHeading.frame.minY)
        XCTAssertLessThan(reasoningHeading.frame.minY, toolsSection.frame.minY)
        XCTAssertLessThan(toolsSection.frame.minY, approvalsHeading.frame.minY)
    }

    func testConversationHeaderOmitsRemovedToolbarControls() throws {
        let app = try makeApp(scenario: "ready", workspaceName: "ToolbarlessWorkspace")
        app.launch()

        let composer = app.textViews["conversation-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.click()
        composer.typeText("Confirm the top status bar is clean")
        composer.typeText("\r")

        XCTAssertTrue(app.staticTexts["Confirm the top status bar is clean"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Working through the request in the UI test harness."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["sidebar-new-thread-button"].exists)

        let removedControlIdentifiers = [
            "workspace-connection-status",
            "new-thread-button",
            "fork-thread-button",
            "archive-thread-button",
            "unarchive-thread-button",
            "rollback-thread-button",
            "retry-connection-button",
            "clear-selection-button"
        ]

        for identifier in removedControlIdentifiers {
            XCTAssertFalse(app.descendants(matching: .any)[identifier].exists, "\(identifier) should not be present in the conversation header")
        }
    }

    func testSettingsScreenShowsGeneralSectionAndReturnsToConversation() throws {
        let app = try makeApp(scenario: "ready", workspaceName: "SettingsWorkspace")
        app.launch()

        let settingsButton = app.buttons["sidebar-settings-button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))

        settingsButton.click()

        XCTAssertTrue(app.staticTexts["Dark Mode"].exists)
        XCTAssertTrue(app.buttons["System"].exists)
        XCTAssertTrue(app.buttons["Light"].exists)
        XCTAssertTrue(app.buttons["Dark"].exists)

        app.buttons["Dark"].click()
        XCTAssertTrue(app.staticTexts["Always use the dark appearance."].waitForExistence(timeout: 2))

        app.buttons["recent-workspace-SettingsWorkspace"].click()
        XCTAssertTrue(app.textViews["conversation-composer"].waitForExistence(timeout: 5))
    }

    func testStatusBarShowsNoWorkspacePlaceholderWhenNothingIsSelected() throws {
        let app = try makeApp(scenario: "empty", workspaceName: "NoSelectionWorkspace")
        app.launch()

        let statusItem = app.otherElements["workspace-status-git-reference"]
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        XCTAssertEqual(statusItem.label, "No workspace selected")
    }

    func testStatusBarShowsNoGitBranchPlaceholderForNonRepository() throws {
        let app = try makeApp(scenario: "ready", workspaceName: "NoBranchWorkspace")
        app.launch()

        let statusItem = app.otherElements["workspace-status-git-reference"]
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        XCTAssertEqual(statusItem.label, "No Git branch")
    }

    func testStatusBarShowsSelectedWorkspaceGitBranch() throws {
        let app = try makeApp(scenario: "git-branch", workspaceName: "BranchWorkspace")
        app.launch()

        let statusItem = app.otherElements["workspace-status-git-reference"]
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        XCTAssertEqual(statusItem.label, "feature/status-bar")
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

    private func reveal(_ element: XCUIElement, in scrollView: XCUIElement, maxSwipes: Int = 3) {
        for _ in 0..<maxSwipes where element.exists == false {
            scrollView.swipeUp()
        }
    }
}
