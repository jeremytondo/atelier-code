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
                codexPathOverride: nil
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
        case repeatedWaiting = "repeated-waiting"
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
    private(set) var startedTurnCount = 0

    init(scenario: UITestScenario.Kind) {
        self.scenario = scenario
    }

    func nextStartAttempt() -> Int {
        startAttempts += 1
        return startAttempts
    }

    func nextTurnCount() -> Int {
        startedTurnCount += 1
        return startedTurnCount
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

    func listThreads(archived: Bool) async throws {
        controller.setShowingArchivedThreads(archived)
    }

    func startThreadAndWait(title: String?) async throws -> ThreadSession {
        controller.openThread(id: "ui-test-thread", title: title ?? "New Conversation")
    }

    func resumeThreadAndWait(id: String) async throws -> ThreadSession {
        controller.resumeThread(id: id, title: "Recovered Conversation")
    }

    func readThreadAndWait(id: String, includeTurns: Bool) async throws -> ThreadSession {
        let messages: [ConversationMessage] = includeTurns
            ? [
                ConversationMessage(id: "ui-read-user", role: .user, text: "Loaded thread \(id)."),
                ConversationMessage(id: "ui-read-assistant", role: .assistant, text: "Thread transcript restored.")
            ]
            : []
        return controller.resumeThread(id: id, title: "Recovered Conversation", messages: messages)
    }

    func forkThreadAndWait(id: String) async throws -> ThreadSession {
        controller.resumeThread(
            id: "\(id)-fork",
            title: "Forked Conversation",
            messages: controller.threadSession(id: id)?.messages ?? []
        )
    }

    func renameThread(id: String, title: String) async throws {
        controller.updateThreadSummary(id: id) { summary in
            summary.title = title
        }
        controller.threadSession(id: id)?.updateThreadIdentity(id: id, title: title)
    }

    func archiveThread(id: String) async throws {
        controller.setThreadArchived(true, for: id)
    }

    func unarchiveThreadAndWait(id: String) async throws -> ThreadSession {
        controller.setThreadArchived(false, for: id)
        return controller.resumeThread(id: id, title: controller.threadSummary(id: id)?.title ?? "Recovered Conversation")
    }

    func rollbackThreadAndWait(id: String, numTurns: Int) async throws -> ThreadSession {
        let existingMessages = controller.threadSession(id: id)?.messages ?? []
        let rolledBackMessages = Array(existingMessages.dropLast(max(0, numTurns)))
        return controller.resumeThread(
            id: id,
            title: controller.threadSummary(id: id)?.title ?? "Recovered Conversation",
            messages: rolledBackMessages
        )
    }

    func startTurn(threadID: String, prompt: String, configuration: BridgeTurnStartConfiguration?) async throws {
        let session = controller.threadSession(id: threadID) ?? controller.openThread(id: threadID, title: "New Conversation")
        let turnNumber = coordinator.nextTurnCount()

        session.beginTurn(userPrompt: prompt)
        controller.setAwaitingTurnStart(false, for: threadID)
        controller.setCurrentTurnID("ui-test-turn-\(turnNumber)", for: threadID)
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

        if coordinator.scenario == .repeatedWaiting {
            Task { @MainActor [controller] in
                try? await Task.sleep(nanoseconds: 900_000_000)
                session.startActivity(
                    id: "repeated-waiting-tool-\(turnNumber)",
                    kind: .tool,
                    title: "Read Files",
                    detail: "Scanning the current workspace.",
                    command: "find . -type f | head -20",
                    workingDirectory: controller.workspace.canonicalPath
                )
                session.appendActivityOutput(
                    id: "repeated-waiting-tool-\(turnNumber)",
                    delta: "Collecting Swift files...\n"
                )
                try? await Task.sleep(nanoseconds: 900_000_000)
                session.completeActivity(
                    id: "repeated-waiting-tool-\(turnNumber)",
                    status: .completed,
                    detail: "Finished reading files.",
                    exitCode: 0
                )
                session.appendAssistantTextDelta("Completed repeated waiting test turn \(turnNumber).")
                session.completeTurn()
                controller.setCurrentTurnID(nil, for: threadID)
                controller.setConnectionStatus(.ready)
            }
            return
        }

        try await Task.sleep(nanoseconds: 40_000_000)
        session.appendAssistantTextDelta("Working through the request")
        try await Task.sleep(nanoseconds: 40_000_000)
        session.appendAssistantTextDelta(" in the UI test harness.")
        session.completeTurn()
        controller.setCurrentTurnID(nil, for: threadID)
        controller.setConnectionStatus(.ready)
    }

    func cancelTurn(threadID: String, reason: String?) async throws {
        controller.setConnectionStatus(.cancelling)
        controller.setAwaitingTurnStart(false, for: threadID)
        controller.threadSession(id: threadID)?.cancelTurn()
        controller.setCurrentTurnID(nil, for: threadID)
        controller.setConnectionStatus(.ready)
    }

    func resolveApproval(threadID: String, id: String, resolution: ApprovalResolution) async throws {
        controller.threadSession(id: threadID)?.resolveApprovalRequest(id: id, resolution: resolution)
        controller.threadSession(id: threadID)?.completeTurn()
        controller.setCurrentTurnID(nil, for: threadID)
        controller.setConnectionStatus(.ready)
    }
}
