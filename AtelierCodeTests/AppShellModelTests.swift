//
//  AppShellModelTests.swift
//  AtelierCodeTests
//
//  Created by Codex on 3/21/26.
//

import Foundation
import Testing
@testable import AtelierCode

@MainActor
struct AppShellModelTests {

    @Test func launchConfigurationReadsExplicitLaunchModeAndWorkspace() {
        let configuration = AppLaunchConfiguration.fromCurrentEnvironment(
            environment: [
                "ATELIERCODE_LAUNCH_MODE": "ui_test",
                "ATELIERCODE_MOCK_SCENARIO": "activity",
                "ATELIERCODE_WORKSPACE_PATH": "/tmp/custom-workspace",
            ],
            currentDirectoryPath: "/tmp/live-workspace",
            userHomeDirectory: "/Users/tester"
        )

        #expect(configuration.launchMode == .uiTest)
        #expect(configuration.mockScenario == .activity)
        #expect(configuration.selectedWorkspacePath == "/tmp/custom-workspace")
    }

    @Test func previewEnvironmentDefaultsToPreviewLaunchMode() {
        let configuration = AppLaunchConfiguration.fromCurrentEnvironment(
            environment: ["XCODE_RUNNING_FOR_PREVIEWS": "1"],
            currentDirectoryPath: "/tmp/live-workspace",
            userHomeDirectory: "/Users/tester"
        )

        #expect(configuration.launchMode == .preview)
        #expect(configuration.mockScenario == .ready)
        #expect(configuration.selectedWorkspacePath == AppMockScenario.ready.defaultWorkspacePath)
    }

    @Test func uiTestModeSeedsDeterministicReadyShell() {
        let model = AppShellModel(
            configuration: AppLaunchConfiguration(
                launchMode: .uiTest,
                selectedWorkspacePath: "/tmp/ateliercode-ui-test",
                mockScenario: .ready
            )
        )

        #expect(model.blockingSetupState == .none)
        #expect(model.selectedWorkspacePath == "/tmp/ateliercode-ui-test")
        #expect(model.mountedStore?.statusText == "ACP session ready")
        #expect(model.mountedStore?.messages.isEmpty == true)
    }

    @Test func previewLoadingScenarioKeepsStoreUnmounted() {
        let model = AppShellModel.preview(.loading)

        #expect(model.launchMode == .preview)
        #expect(model.mountedStore == nil)
        #expect(
            model.blockingSetupState ==
            .loading(
                title: "Preparing mock workspace",
                detail: "This non-live shell keeps Gemini offline while the app renders a deterministic loading state."
            )
        )
    }
}
