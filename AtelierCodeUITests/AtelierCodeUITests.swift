//
//  AtelierCodeUITests.swift
//  AtelierCodeUITests
//
//  Created by Jeremy Margaritondo on 3/12/26.
//

import XCTest

final class AtelierCodeUITests: XCTestCase {
    private static let launchPerformanceEnvironmentKey = "ATELIERCODE_RUN_UI_PERF_TESTS"

    @MainActor
    private func makeApplication(scenario: String = "ready") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["ATELIERCODE_LAUNCH_MODE"] = "ui_test"
        app.launchEnvironment["ATELIERCODE_MOCK_SCENARIO"] = scenario
        return app
    }

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
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = makeApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
        XCTAssertTrue(app.staticTexts["AtelierCode"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["ACP session ready"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testLoadingScenarioLaunchesWithoutLiveSession() throws {
        let app = makeApplication(scenario: "loading")
        app.launch()

        XCTAssertTrue(app.staticTexts["Preparing mock workspace"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Rendering a deterministic non-live shell"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testLaunchPerformance() throws {
        try XCTSkipUnless(
            Self.shouldRunLaunchPerformanceTests,
            "Launch performance is opt-in for local dogfood work. Set \(Self.launchPerformanceEnvironmentKey)=1 to run it."
        )

        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            makeApplication().launch()
        }
    }

    private static var shouldRunLaunchPerformanceTests: Bool {
        let rawValue = ProcessInfo.processInfo.environment[launchPerformanceEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return rawValue == "1" || rawValue == "true" || rawValue == "yes"
    }
}
