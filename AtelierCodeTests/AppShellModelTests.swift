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

    @Test func liveModeWithoutWorkspaceSelectionShowsIdleShellState() {
        let model = AppShellModel(
            configuration: AppLaunchConfiguration(
                launchMode: .live,
                selectedWorkspacePath: nil
            ),
            autostart: false,
            sessionPersistence: TransientWorkspaceSessionPersistence(),
            workspaceSelectionPersistence: InMemoryWorkspaceSelectionPersistence()
        )

        #expect(model.selectedWorkspacePath == nil)
        #expect(model.mountedStore == nil)
        #expect(
            model.blockingSetupState ==
            .message(
                title: "No workspace selected",
                detail: "Open a workspace to start a fresh ACP session."
            )
        )
    }

    @Test func liveModeRestoresPersistedWorkspaceSelection() throws {
        let fileManager = FileManager.default
        let workspaceURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: workspaceURL)
        }

        let selectionPersistence = InMemoryWorkspaceSelectionPersistence(
            selectedWorkspacePath: workspaceURL.path
        )
        let model = AppShellModel(
            configuration: AppLaunchConfiguration(
                launchMode: .live,
                selectedWorkspacePath: nil
            ),
            autostart: false,
            sessionPersistence: TransientWorkspaceSessionPersistence(),
            workspaceSelectionPersistence: selectionPersistence
        )

        #expect(model.blockingSetupState == .none)
        #expect(model.selectedWorkspacePath == workspaceURL.path)
        #expect(model.mountedStore?.workspacePath == workspaceURL.path)
    }

    @Test func openingAndSwitchingWorkspaceReplacesMountedStoreAndClearsTransientState() throws {
        let fileManager = FileManager.default
        let firstWorkspaceURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let secondWorkspaceURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: firstWorkspaceURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: secondWorkspaceURL, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: firstWorkspaceURL)
            try? fileManager.removeItem(at: secondWorkspaceURL)
        }

        let selectionPersistence = InMemoryWorkspaceSelectionPersistence()
        let model = AppShellModel(
            configuration: AppLaunchConfiguration(
                launchMode: .live,
                selectedWorkspacePath: nil
            ),
            autostart: false,
            sessionPersistence: TransientWorkspaceSessionPersistence(),
            workspaceSelectionPersistence: selectionPersistence
        )

        model.openWorkspace(at: firstWorkspaceURL.path)

        let firstStore = try #require(model.mountedStore)
        firstStore.connectionState = .ready
        firstStore.messages = [ConversationMessage(role: .assistant, text: "Old workspace transcript")]
        firstStore.activitiesByMessageID = [UUID(): []]
        firstStore.terminalStates = [
            "terminal_1": ACPTerminalState(
                id: "terminal_1",
                command: "pwd",
                cwd: firstWorkspaceURL.path,
                output: firstWorkspaceURL.path,
                truncated: false,
                exitStatus: nil,
                isReleased: false
            )
        ]
        firstStore.draftPrompt = "old prompt"
        firstStore.lastErrorDescription = "Old failure"

        model.openWorkspace(at: secondWorkspaceURL.path)

        let secondStore = try #require(model.mountedStore)
        #expect(firstStore !== secondStore)
        #expect(model.selectedWorkspacePath == secondWorkspaceURL.path)
        #expect(secondStore.workspacePath == secondWorkspaceURL.path)
        #expect(selectionPersistence.selectedWorkspacePath() == secondWorkspaceURL.path)
        #expect(firstStore.connectionState == .disconnected)
        #expect(firstStore.messages.isEmpty)
        #expect(firstStore.activitiesByMessageID.isEmpty)
        #expect(firstStore.terminalStates.isEmpty)
        #expect(firstStore.draftPrompt.isEmpty)
        #expect(firstStore.lastErrorDescription == nil)
    }

    @Test func closingWorkspaceClearsPersistedSelection() throws {
        let fileManager = FileManager.default
        let workspaceURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: workspaceURL)
        }

        let selectionPersistence = InMemoryWorkspaceSelectionPersistence()
        let model = AppShellModel(
            configuration: AppLaunchConfiguration(
                launchMode: .live,
                selectedWorkspacePath: nil
            ),
            autostart: false,
            sessionPersistence: TransientWorkspaceSessionPersistence(),
            workspaceSelectionPersistence: selectionPersistence
        )

        model.openWorkspace(at: workspaceURL.path)
        model.closeWorkspace()

        #expect(model.selectedWorkspacePath == nil)
        #expect(model.mountedStore == nil)
        #expect(selectionPersistence.selectedWorkspacePath() == nil)
        #expect(
            model.blockingSetupState ==
            .message(
                title: "No workspace selected",
                detail: "Open a workspace to start a fresh ACP session."
            )
        )
    }
}

@MainActor
private final class InMemoryWorkspaceSelectionPersistence: AppWorkspaceSelectionPersisting {
    private var storedWorkspacePath: String?

    init(selectedWorkspacePath: String? = nil) {
        storedWorkspacePath = selectedWorkspacePath
    }

    func selectedWorkspacePath() -> String? {
        storedWorkspacePath
    }

    func saveSelectedWorkspacePath(_ workspacePath: String) {
        storedWorkspacePath = workspacePath
    }

    func clearSelectedWorkspacePath() {
        storedWorkspacePath = nil
    }
}
