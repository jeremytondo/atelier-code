//
//  AppShellModel.swift
//  AtelierCode
//
//  Created by Codex on 3/21/26.
//

import Foundation
import Observation

nonisolated enum AppLaunchMode: String, Sendable {
    case live
    case preview
    case uiTest = "ui_test"

    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AppLaunchMode {
        if
            let rawValue = environment["ATELIERCODE_LAUNCH_MODE"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
            let launchMode = AppLaunchMode(rawValue: rawValue)
        {
            return launchMode
        }

        if environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            return .preview
        }

        return .live
    }
}

nonisolated enum AppMockScenario: String, Sendable {
    case ready
    case activity
    case loading

    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AppMockScenario {
        guard
            let rawValue = environment["ATELIERCODE_MOCK_SCENARIO"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
            let scenario = AppMockScenario(rawValue: rawValue)
        else {
            return .ready
        }

        return scenario
    }

    var defaultWorkspacePath: String {
        switch self {
        case .ready:
            return "/tmp/ateliercode-mock-ready"
        case .activity:
            return "/tmp/ateliercode-mock-activity"
        case .loading:
            return "/tmp/ateliercode-mock-loading"
        }
    }
}

nonisolated enum AppBlockingSetupState: Equatable, Sendable {
    case none
    case loading(title: String, detail: String?)
    case message(title: String, detail: String?)

    var title: String? {
        switch self {
        case .none:
            return nil
        case .loading(let title, _), .message(let title, _):
            return title
        }
    }

    var detail: String? {
        switch self {
        case .none:
            return nil
        case .loading(_, let detail), .message(_, let detail):
            return detail
        }
    }
}

nonisolated struct AppLaunchConfiguration: Sendable {
    let launchMode: AppLaunchMode
    let selectedWorkspacePath: String?
    let mockScenario: AppMockScenario

    init(
        launchMode: AppLaunchMode,
        selectedWorkspacePath: String?,
        mockScenario: AppMockScenario = .ready
    ) {
        self.launchMode = launchMode
        self.selectedWorkspacePath = Self.trimmedPath(selectedWorkspacePath)
        self.mockScenario = mockScenario
    }

    static func fromCurrentEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectoryPath: String = FileManager.default.currentDirectoryPath,
        userHomeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> AppLaunchConfiguration {
        let launchMode = AppLaunchMode.resolve(environment: environment)
        let mockScenario = AppMockScenario.resolve(environment: environment)
        let explicitWorkspacePath = trimmedPath(environment["ATELIERCODE_WORKSPACE_PATH"])

        let selectedWorkspacePath: String?
        switch launchMode {
        case .live:
            selectedWorkspacePath =
                explicitWorkspacePath
                ?? AppWorkingDirectory.resolve(
                    currentEnvironment: environment,
                    currentDirectoryPath: currentDirectoryPath,
                    userHomeDirectory: userHomeDirectory
                )
        case .preview, .uiTest:
            selectedWorkspacePath = explicitWorkspacePath ?? mockScenario.defaultWorkspacePath
        }

        return AppLaunchConfiguration(
            launchMode: launchMode,
            selectedWorkspacePath: selectedWorkspacePath,
            mockScenario: mockScenario
        )
    }

    private static func trimmedPath(_ path: String?) -> String? {
        guard let path else { return nil }

        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return nil }
        return trimmedPath
    }
}

@MainActor
final class TransientWorkspaceSessionPersistence: ACPWorkspaceSessionPersisting {
    private var sessions: [String: String] = [:]

    func sessionID(for workspaceRoot: String) -> String? {
        sessions[workspaceRoot]
    }

    func save(sessionID: String, for workspaceRoot: String) {
        sessions[workspaceRoot] = sessionID
    }

    func removeSession(for workspaceRoot: String) {
        sessions.removeValue(forKey: workspaceRoot)
    }
}

@MainActor
@Observable
final class AppShellModel {
    let launchMode: AppLaunchMode

    var selectedWorkspacePath: String?
    var blockingSetupState: AppBlockingSetupState = .none
    var mountedStore: ACPStore?

    @ObservationIgnored private let sessionPersistence: ACPWorkspaceSessionPersisting

    init(
        configuration: AppLaunchConfiguration = .fromCurrentEnvironment(),
        autostart: Bool = true
    ) {
        launchMode = configuration.launchMode
        selectedWorkspacePath = configuration.selectedWorkspacePath
        sessionPersistence = configuration.launchMode == .live
            ? ACPWorkspaceSessionStore.standard
            : TransientWorkspaceSessionPersistence()

        configureInitialState(using: configuration, autostart: autostart)
    }

    static func preview(_ scenario: AppMockScenario) -> AppShellModel {
        let model = AppShellModel(
            configuration: AppLaunchConfiguration(
                launchMode: .preview,
                selectedWorkspacePath: scenario.defaultWorkspacePath,
                mockScenario: scenario
            ),
            autostart: false
        )

        if let store = model.mountedStore {
            switch scenario {
            case .ready:
                model.seedReadyPreview(into: store)
            case .activity:
                model.seedActivityPreview(into: store)
            case .loading:
                break
            }
        }

        return model
    }

    private func configureInitialState(using configuration: AppLaunchConfiguration, autostart: Bool) {
        switch configuration.launchMode {
        case .live:
            configureLiveState(autostart: autostart)
        case .preview, .uiTest:
            configureMockState(scenario: configuration.mockScenario, autostart: autostart)
        }
    }

    private func configureLiveState(autostart: Bool) {
        guard let workspacePath = selectedWorkspacePath else {
            blockingSetupState = .message(
                title: "No workspace selected",
                detail: "Phase 2 will add in-app workspace selection. For now the app uses the launch directory."
            )
            mountedStore = nil
            return
        }

        blockingSetupState = .none
        let store = ACPStore(
            cwd: workspacePath,
            sessionPersistence: sessionPersistence
        )
        mountedStore = store

        if autostart {
            Task { @MainActor in
                await store.connectIfNeeded()
            }
        }
    }

    private func configureMockState(scenario: AppMockScenario, autostart: Bool) {
        switch scenario {
        case .loading:
            mountedStore = nil
            blockingSetupState = .loading(
                title: "Preparing mock workspace",
                detail: "This non-live shell keeps Gemini offline while the app renders a deterministic loading state."
            )
        case .ready, .activity:
            blockingSetupState = .none

            let workspacePath = selectedWorkspacePath ?? scenario.defaultWorkspacePath
            selectedWorkspacePath = workspacePath

            let transportScenario: MockACPTransport.Scenario = scenario == .activity ? .activity : .ready
            let store = ACPStore(
                transport: MockACPTransport(scenario: transportScenario),
                cwd: workspacePath,
                sessionPersistence: sessionPersistence
            )
            mountedStore = store

            let shouldSeedSynchronously = !autostart || launchMode == .uiTest

            if shouldSeedSynchronously, scenario == .ready {
                seedReadyPreview(into: store)
            }

            if shouldSeedSynchronously, scenario == .activity {
                seedActivityPreview(into: store)
            }

            if autostart, launchMode != .uiTest {
                Task { @MainActor in
                    await store.connectIfNeeded()
                }
            }
        }
    }

    private func seedReadyPreview(into store: ACPStore) {
        store.connectionState = .ready
        store.messages = []
        store.activitiesByMessageID = [:]
        store.terminalStates = [:]
        store.draftPrompt = "Summarize the current workspace shell."
        store.isConnecting = false
        store.isSending = false
        store.lastErrorDescription = nil
        store.currentAssistantMessageIndex = nil
        store.scrollTargetMessageID = nil
    }

    private func seedActivityPreview(into store: ACPStore) {
        let userMessage = ConversationMessage(
            role: .user,
            text: "Give me a quick read on this repo."
        )
        let assistantMessage = ConversationMessage(
            role: .assistant,
            text: "I inspected the workspace and the Phase 1 shell is ready to separate live startup from preview and UI test launches."
        )

        store.connectionState = .ready
        store.messages = [userMessage, assistantMessage]
        store.activitiesByMessageID = [
            assistantMessage.id: [
                ACPMessageActivity(
                    sequence: 1,
                    kind: .availableCommands,
                    title: "Available commands updated",
                    detail: "read_file, run_tests"
                ),
                ACPMessageActivity(
                    sequence: 2,
                    kind: .thinking,
                    title: "Gemini is thinking",
                    detail: "Checking the app shell and launch seams."
                ),
                ACPMessageActivity(
                    sequence: 3,
                    kind: .tool,
                    title: "Tool: Read workspace",
                    detail: "Scanning the AtelierCode app target."
                ),
                ACPMessageActivity(
                    sequence: 4,
                    kind: .terminal,
                    title: "Terminal output",
                    detail: nil,
                    terminal: ACPTerminalActivitySnapshot(
                        terminalId: "terminal_preview",
                        command: "rg --files AtelierCode",
                        cwd: selectedWorkspacePath ?? AppMockScenario.activity.defaultWorkspacePath,
                        newOutput: "AtelierCode/ContentView.swift\nAtelierCode/ACPStore.swift",
                        fullOutput: "AtelierCode/ContentView.swift\nAtelierCode/ACPStore.swift",
                        truncated: false,
                        exitStatus: ACPTerminalExitStatus(exitCode: 0, signal: nil),
                        isReleased: true
                    )
                ),
            ]
        ]
        store.terminalStates = [
            "terminal_preview": ACPTerminalState(
                id: "terminal_preview",
                command: "rg --files AtelierCode",
                cwd: selectedWorkspacePath ?? AppMockScenario.activity.defaultWorkspacePath,
                output: "AtelierCode/ContentView.swift\nAtelierCode/ACPStore.swift",
                truncated: false,
                exitStatus: ACPTerminalExitStatus(exitCode: 0, signal: nil),
                isReleased: true
            )
        ]
        store.draftPrompt = "Review launch mode handling."
        store.isConnecting = false
        store.isSending = false
        store.lastErrorDescription = nil
        store.currentAssistantMessageIndex = nil
        store.scrollTargetMessageID = assistantMessage.id
    }
}
