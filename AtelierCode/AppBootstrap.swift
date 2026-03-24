import Foundation

enum AppBootstrap {
    @MainActor
    static func makeAppModel(processInfo: ProcessInfo = .processInfo) -> AppModel {
        guard let scenario = UITestScenario(processInfo: processInfo) else {
            return AppModel()
        }

        let workspaceURL = scenario.workspaceURL
        try? FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)

        let preferencesStore = InMemoryBootstrapPreferencesStore(
            snapshot: AppPreferencesSnapshot(
                recentWorkspaces: [WorkspaceRecord(url: workspaceURL, lastOpenedAt: .now)],
                lastSelectedWorkspacePath: scenario.startsWithSelectedWorkspace ? workspaceURL.path : nil,
                codexPathOverride: nil,
                uiPreferences: UIPreferences(showsStartupDiagnostics: true)
            )
        )
        let coordinator = UITestRuntimeCoordinator(scenario: scenario.kind)

        return AppModel(
            preferencesStore: preferencesStore,
            bridgeDiagnosticProvider: { .bridgePresent(at: workspaceURL.appendingPathComponent("mock-bridge")) },
            runtimeFactory: { UITestWorkspaceRuntime(controller: $0, coordinator: coordinator) }
        )
    }
}

private struct UITestScenario {
    enum Kind: String {
        case recentSelection = "recent-selection"
        case ready
        case retry
    }

    let kind: Kind
    let workspaceURL: URL

    var startsWithSelectedWorkspace: Bool {
        kind != .recentSelection
    }

    init?(processInfo: ProcessInfo) {
        guard let scenarioValue = processInfo.environment["ATELIERCODE_UI_TEST_SCENARIO"],
              let kind = Kind(rawValue: scenarioValue) else {
            return nil
        }

        let workspacePath = processInfo.environment["ATELIERCODE_UI_TEST_WORKSPACE"]
            ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("AtelierCodeUITestWorkspace", isDirectory: true)
            .path

        self.kind = kind
        workspaceURL = URL(fileURLWithPath: workspacePath, isDirectory: true)
    }
}

private final class InMemoryBootstrapPreferencesStore: AppPreferencesStore {
    private var storedSnapshot: AppPreferencesSnapshot?

    init(snapshot: AppPreferencesSnapshot?) {
        storedSnapshot = snapshot
    }

    func loadSnapshot() throws -> AppPreferencesSnapshot? {
        storedSnapshot
    }

    func saveSnapshot(_ snapshot: AppPreferencesSnapshot) throws {
        storedSnapshot = snapshot
    }
}

@MainActor
private final class UITestRuntimeCoordinator {
    let scenario: UITestScenario.Kind
    private(set) var startAttempts = 0

    init(scenario: UITestScenario.Kind) {
        self.scenario = scenario
    }

    func nextStartAttempt() -> Int {
        startAttempts += 1
        return startAttempts
    }
}

@MainActor
private final class UITestWorkspaceRuntime: WorkspaceConversationRuntime {
    private let controller: WorkspaceController
    private let coordinator: UITestRuntimeCoordinator

    init(controller: WorkspaceController, coordinator: UITestRuntimeCoordinator) {
        self.controller = controller
        self.coordinator = coordinator
    }

    func start() async throws {
        controller.setBridgeLifecycleState(.starting)
        controller.setConnectionStatus(.connecting)

        try await Task.sleep(nanoseconds: 75_000_000)

        let attempt = coordinator.nextStartAttempt()
        controller.setBridgeLifecycleState(.idle)
        controller.setAuthState(.signedIn(accountDescription: "UI Test Account"))

        if coordinator.scenario == .retry && attempt == 1 {
            controller.setConnectionStatus(.error(message: "The embedded bridge exited unexpectedly with status 9."))
            return
        }

        controller.setConnectionStatus(.ready)
    }

    func stop() async {
        controller.setBridgeLifecycleState(.idle)
        controller.setAwaitingTurnStart(false)
        controller.setConnectionStatus(.disconnected)
    }

    func startThreadAndWait(title: String?) async throws -> ThreadSession {
        controller.openThread(id: "ui-test-thread", title: title ?? "New Conversation")
    }

    func resumeThreadAndWait(id: String) async throws -> ThreadSession {
        controller.resumeThread(id: id, title: "Recovered Conversation")
    }

    func startTurn(prompt: String, configuration: BridgeTurnStartConfiguration?) async throws {
        let session = controller.activeThreadSession ?? controller.openThread(id: "ui-test-thread", title: "New Conversation")

        session.beginTurn(userPrompt: prompt)
        controller.setAwaitingTurnStart(false)
        controller.setConnectionStatus(.streaming)

        try await Task.sleep(nanoseconds: 40_000_000)
        session.appendAssistantTextDelta("Working through the request")
        try await Task.sleep(nanoseconds: 40_000_000)
        session.appendAssistantTextDelta(" in the UI test harness.")
        session.completeTurn()
        controller.setConnectionStatus(.ready)
    }

    func cancelTurn(reason: String?) async throws {
        controller.setConnectionStatus(.cancelling)
        controller.setAwaitingTurnStart(false)
        controller.activeThreadSession?.cancelTurn()
        controller.setConnectionStatus(.ready)
    }
}
