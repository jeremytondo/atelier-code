//
//  AppShellModel.swift
//  AtelierCode
//
//  Created by Codex on 3/21/26.
//

import Foundation
import Observation

@MainActor
protocol AppWorkspaceSelectionPersisting: AnyObject {
    func selectedWorkspacePath() -> String?
    func saveSelectedWorkspacePath(_ workspacePath: String)
    func clearSelectedWorkspacePath()
}

@MainActor
final class AppWorkspaceSelectionStore: AppWorkspaceSelectionPersisting {
    static let standard = AppWorkspaceSelectionStore()

    private let userDefaults: UserDefaults
    private let storageKey: String

    init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = "AtelierCode.SelectedWorkspacePath"
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
    }

    func selectedWorkspacePath() -> String? {
        Self.canonicalWorkspacePath(userDefaults.string(forKey: storageKey))
    }

    func saveSelectedWorkspacePath(_ workspacePath: String) {
        guard let workspacePath = Self.canonicalWorkspacePath(workspacePath) else {
            clearSelectedWorkspacePath()
            return
        }

        userDefaults.set(workspacePath, forKey: storageKey)
    }

    func clearSelectedWorkspacePath() {
        userDefaults.removeObject(forKey: storageKey)
    }

    private static func canonicalWorkspacePath(_ workspacePath: String?) -> String? {
        guard
            let workspacePath = workspacePath?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !workspacePath.isEmpty
        else {
            return nil
        }

        return URL(fileURLWithPath: workspacePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }
}

@MainActor
final class TransientWorkspaceSelectionPersistence: AppWorkspaceSelectionPersisting {
    private var workspacePath: String?

    func selectedWorkspacePath() -> String? {
        workspacePath
    }

    func saveSelectedWorkspacePath(_ workspacePath: String) {
        self.workspacePath = workspacePath
    }

    func clearSelectedWorkspacePath() {
        workspacePath = nil
    }
}

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
        _ = currentDirectoryPath
        _ = userHomeDirectory
        let launchMode = AppLaunchMode.resolve(environment: environment)
        let mockScenario = AppMockScenario.resolve(environment: environment)
        let explicitWorkspacePath = trimmedPath(environment["ATELIERCODE_WORKSPACE_PATH"])

        let selectedWorkspacePath: String?
        switch launchMode {
        case .live:
            selectedWorkspacePath = explicitWorkspacePath
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
    @ObservationIgnored private let workspaceSelectionPersistence: AppWorkspaceSelectionPersisting
    @ObservationIgnored private let storeFactory: (String, ACPWorkspaceSessionPersisting) -> ACPStore
    @ObservationIgnored private let shouldAutostart: Bool
    @ObservationIgnored private var connectionTask: Task<Void, Never>?

    init(
        configuration: AppLaunchConfiguration = .fromCurrentEnvironment(),
        autostart: Bool = true,
        sessionPersistence: ACPWorkspaceSessionPersisting? = nil,
        workspaceSelectionPersistence: AppWorkspaceSelectionPersisting? = nil,
        storeFactory: @escaping (String, ACPWorkspaceSessionPersisting) -> ACPStore = { workspacePath, sessionPersistence in
            ACPStore(
                cwd: workspacePath,
                sessionPersistence: sessionPersistence
            )
        }
    ) {
        launchMode = configuration.launchMode
        shouldAutostart = autostart
        self.storeFactory = storeFactory
        self.sessionPersistence = sessionPersistence ?? (configuration.launchMode == .live
            ? ACPWorkspaceSessionStore.standard
            : TransientWorkspaceSessionPersistence())
        self.workspaceSelectionPersistence = workspaceSelectionPersistence ?? (configuration.launchMode == .live
            ? AppWorkspaceSelectionStore.standard
            : TransientWorkspaceSelectionPersistence())
        selectedWorkspacePath = Self.resolveInitialWorkspacePath(
            configuration: configuration,
            workspaceSelectionPersistence: self.workspaceSelectionPersistence
        )

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
        mountLiveWorkspace(
            path: selectedWorkspacePath,
            autostart: autostart,
            unavailableWorkspacePath: selectedWorkspacePath
        )
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

    func openWorkspace(at workspacePath: String) {
        guard launchMode == .live else { return }
        mountLiveWorkspace(path: workspacePath, autostart: shouldAutostart)
    }

    func closeWorkspace() {
        guard launchMode == .live else { return }

        teardownMountedStore()
        workspaceSelectionPersistence.clearSelectedWorkspacePath()
        selectedWorkspacePath = nil
        blockingSetupState = .message(
            title: "No workspace selected",
            detail: "Open a workspace to start a fresh ACP session."
        )
    }

    private func mountLiveWorkspace(
        path: String?,
        autostart: Bool,
        unavailableWorkspacePath: String? = nil
    ) {
        let canonicalWorkspacePath = canonicalExistingWorkspacePath(path)

        if
            let canonicalWorkspacePath,
            selectedWorkspacePath == canonicalWorkspacePath,
            mountedStore != nil
        {
            blockingSetupState = .none
            return
        }

        teardownMountedStore()

        guard let canonicalWorkspacePath else {
            workspaceSelectionPersistence.clearSelectedWorkspacePath()
            selectedWorkspacePath = nil
            blockingSetupState = .message(
                title: "No workspace selected",
                detail: unavailableWorkspacePath == nil
                    ? "Open a workspace to start a fresh ACP session."
                    : "The previously selected workspace is no longer available. Open a workspace to keep going."
            )
            return
        }

        selectedWorkspacePath = canonicalWorkspacePath
        workspaceSelectionPersistence.saveSelectedWorkspacePath(canonicalWorkspacePath)
        blockingSetupState = .none

        let store = storeFactory(canonicalWorkspacePath, sessionPersistence)
        mountedStore = store

        guard autostart else { return }

        connectionTask = Task { @MainActor [weak self, weak store] in
            guard let self, let store else { return }
            await store.connectIfNeeded()
            if self.mountedStore === store {
                self.connectionTask = nil
            }
        }
    }

    private func teardownMountedStore() {
        connectionTask?.cancel()
        connectionTask = nil
        mountedStore?.teardown()
        mountedStore = nil
    }

    private func canonicalExistingWorkspacePath(_ workspacePath: String?) -> String? {
        guard
            let workspacePath = workspacePath?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !workspacePath.isEmpty
        else {
            return nil
        }

        let canonicalPath = URL(fileURLWithPath: workspacePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path

        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: canonicalPath, isDirectory: &isDirectory) else {
            return nil
        }

        guard isDirectory.boolValue else {
            return nil
        }

        return canonicalPath
    }

    private static func resolveInitialWorkspacePath(
        configuration: AppLaunchConfiguration,
        workspaceSelectionPersistence: AppWorkspaceSelectionPersisting
    ) -> String? {
        switch configuration.launchMode {
        case .live:
            return configuration.selectedWorkspacePath
                ?? workspaceSelectionPersistence.selectedWorkspacePath()
        case .preview, .uiTest:
            return configuration.selectedWorkspacePath
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
