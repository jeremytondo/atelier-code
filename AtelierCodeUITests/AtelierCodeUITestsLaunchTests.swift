//
//  AtelierCodeUITestsLaunchTests.swift
//  AtelierCodeUITests
//
//  Created by Jeremy Margaritondo on 3/12/26.
//

import XCTest

final class AtelierCodeUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        app.launchEnvironment["ATELIERCODE_LAUNCH_MODE"] = "ui_test"
        app.launchEnvironment["ATELIERCODE_MOCK_SCENARIO"] = "ready"
        app.launch()

        // Insert steps here to perform after app launch but before taking a screenshot,
        // such as logging into a test account or navigating somewhere in the app

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
