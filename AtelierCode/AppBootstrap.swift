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
        case phase2
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

        if coordinator.scenario == .phase2 {
            let changedFiles = [
                DiffFileChange(id: "phase2-content", path: "AtelierCode/ContentView.swift", additions: 24, deletions: 8),
                DiffFileChange(id: "phase2-session", path: "AtelierCode/ThreadSession.swift", additions: 18, deletions: 4)
            ]

            try await Task.sleep(nanoseconds: 900_000_000)
            session.appendAssistantTextDelta("I grouped the current turn details under the transcript.")
            session.appendThinkingDelta("Inspecting activity, approvals, plan state, and diff summaries for the active turn.")
            session.startActivity(
                id: "phase2-tool-success",
                kind: .tool,
                title: "Run tests",
                detail: "Checking the session and runtime wiring.",
                command: "swift test --filter ThreadSessionTests",
                workingDirectory: controller.workspace.canonicalPath
            )
            session.appendActivityOutput(
                id: "phase2-tool-success",
                delta: "Building AtelierCode...\nRunning ThreadSessionTests...\n"
            )
            session.completeActivity(
                id: "phase2-tool-success",
                status: .completed,
                detail: "ThreadSessionTests finished successfully.",
                exitCode: 0
            )
            session.startActivity(
                id: "phase2-tool-failed",
                kind: .tool,
                title: "Run runtime tests",
                detail: "Validating the grouped failure state.",
                command: "swift test --filter WorkspaceBridgeRuntimeTests",
                workingDirectory: controller.workspace.canonicalPath
            )
            session.appendActivityOutput(
                id: "phase2-tool-failed",
                delta: "Running WorkspaceBridgeRuntimeTests...\nAssertion failed.\n"
            )
            session.completeActivity(
                id: "phase2-tool-failed",
                status: .failed,
                detail: "WorkspaceBridgeRuntimeTests failed.",
                exitCode: 1
            )
            session.startActivity(
                id: "phase2-files",
                kind: .fileChange,
                title: "2 files changed",
                detail: "Preparing the phase 2 UI update.",
                files: changedFiles
            )
            session.completeActivity(
                id: "phase2-files",
                status: .completed,
                detail: "Applied the current patch set.",
                files: changedFiles
            )
            session.startActivity(
                id: "phase2-tool-running",
                kind: .tool,
                title: "Run final verification",
                detail: "Collecting final UI polish output.",
                command: "xcodebuild test -scheme AtelierCode",
                workingDirectory: controller.workspace.canonicalPath
            )
            session.appendActivityOutput(
                id: "phase2-tool-running",
                delta: "Testing in progress...\n"
            )
            session.replacePlanState(
                PlanState(
                    summary: "Finish the grouped turn inspection UI.",
                    steps: [
                        PlanStep(id: "phase2-step-1", title: "Preserve structured activity data", status: .completed),
                        PlanStep(id: "phase2-step-2", title: "Render grouped turn sections", status: .inProgress),
                        PlanStep(id: "phase2-step-3", title: "Verify inline approvals in UI tests", status: .pending)
                    ]
                )
            )
            session.replaceAggregatedDiff(
                AggregatedDiff(
                    summary: "2 files changed",
                    files: changedFiles
                )
            )
            session.enqueueApprovalRequest(
                ApprovalRequest(
                    id: "phase2-approval",
                    kind: .command,
                    title: "Approve command execution",
                    detail: "The harness is waiting for an inline decision before wrapping up the turn.",
                    command: ApprovalCommandContext(
                        command: "xcodebuild test -scheme AtelierCode",
                        workingDirectory: controller.workspace.canonicalPath
                    ),
                    files: changedFiles,
                    riskLevel: .medium
                )
            )
            return
        }

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

    func resolveApproval(id: String, resolution: ApprovalResolution) async throws {
        controller.activeThreadSession?.resolveApprovalRequest(id: id, resolution: resolution)
        controller.activeThreadSession?.completeTurn()
        controller.setConnectionStatus(.ready)
    }
}
