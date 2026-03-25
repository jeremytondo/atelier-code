//
//  AtelierCodeTests.swift
//  AtelierCodeTests
//
//  Created by Jeremy Margaritondo on 3/23/26.
//

import Foundation
import Testing
@testable import AtelierCode

@MainActor
struct AppModelTests {
    @Test func loadsPersistedPreferences() async throws {
        let workspaceURL = try temporaryDirectory()
        let codexURL = workspaceURL.appendingPathComponent("codex", isDirectory: false)
        FileManager.default.createFile(atPath: codexURL.path, contents: Data())

        let snapshot = AppPreferencesSnapshot(
            recentWorkspaces: [WorkspaceRecord(url: workspaceURL, lastOpenedAt: .distantPast)],
            lastSelectedWorkspacePath: nil,
            codexPathOverride: codexURL.path
        )
        let store = InMemoryAppPreferencesStore(snapshot: snapshot)
        let runtimeCoordinator = TestRuntimeCoordinator()

        let appModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            runtimeFactory: { TestWorkspaceRuntime(controller: $0, coordinator: runtimeCoordinator) }
        )

        #expect(appModel.recentWorkspaces == snapshot.recentWorkspaces)
        #expect(appModel.codexPathOverride == codexURL.path)
        #expect(appModel.startupDiagnostics.isEmpty)
    }

    @Test func restoresValidLastSelectedWorkspace() async throws {
        let workspaceURL = try temporaryDirectory()
        let snapshot = AppPreferencesSnapshot(
            recentWorkspaces: [WorkspaceRecord(url: workspaceURL, lastOpenedAt: .now)],
            lastSelectedWorkspacePath: workspaceURL.path,
            codexPathOverride: nil
        )
        let store = InMemoryAppPreferencesStore(snapshot: snapshot)
        let runtimeCoordinator = TestRuntimeCoordinator()

        let appModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            runtimeFactory: { TestWorkspaceRuntime(controller: $0, coordinator: runtimeCoordinator) }
        )
        try await waitUntil { appModel.activeWorkspaceController?.connectionStatus == .ready }

        #expect(appModel.lastSelectedWorkspacePath == workspaceURL.path)
        #expect(appModel.activeWorkspaceController?.workspace.canonicalPath == workspaceURL.path)
        #expect(appModel.activeWorkspaceController?.connectionStatus == .ready)
        #expect(appModel.startupDiagnostics.isEmpty)
        #expect(runtimeCoordinator.startCount == 1)
    }

    @Test func clearsInvalidRestoredWorkspaceAndRecordsDiagnostic() async throws {
        let workspaceURL = try temporaryDirectory()
        try FileManager.default.removeItem(at: workspaceURL)

        let snapshot = AppPreferencesSnapshot(
            recentWorkspaces: [],
            lastSelectedWorkspacePath: workspaceURL.path,
            codexPathOverride: nil
        )
        let store = InMemoryAppPreferencesStore(snapshot: snapshot)

        let appModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            runtimeFactory: { TestWorkspaceRuntime(controller: $0, coordinator: TestRuntimeCoordinator()) }
        )

        #expect(appModel.lastSelectedWorkspacePath == nil)
        #expect(appModel.activeWorkspaceController == nil)
        #expect(appModel.startupDiagnostics.contains(where: { $0.source == .restoredWorkspace && $0.severity == .warning }))
        #expect(try store.loadSnapshot()?.lastSelectedWorkspacePath == nil)
    }

    @Test func deduplicatesAndCapsRecentWorkspaces() async throws {
        let store = InMemoryAppPreferencesStore()
        let runtimeCoordinator = TestRuntimeCoordinator()
        let appModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            runtimeFactory: { TestWorkspaceRuntime(controller: $0, coordinator: runtimeCoordinator) }
        )
        var workspaceURLs: [URL] = []

        for index in 0..<21 {
            let workspaceURL = try temporaryDirectory(named: "workspace-\(index)")
            workspaceURLs.append(workspaceURL)
            appModel.activateWorkspace(at: workspaceURL)
        }

        appModel.activateWorkspace(at: workspaceURLs[5])

        #expect(appModel.recentWorkspaces.count == 20)
        #expect(appModel.recentWorkspaces.first?.canonicalPath == workspaceURLs[5].path)
        #expect(Set(appModel.recentWorkspaces.map(\.canonicalPath)).count == appModel.recentWorkspaces.count)
    }

    @Test func roundTripsCodexOverride() async throws {
        let store = InMemoryAppPreferencesStore()
        let runtimeCoordinator = TestRuntimeCoordinator()
        let appModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            runtimeFactory: { TestWorkspaceRuntime(controller: $0, coordinator: runtimeCoordinator) }
        )
        let codexURL = try temporaryDirectory(named: "codex-bin").appendingPathComponent("codex")
        FileManager.default.createFile(atPath: codexURL.path, contents: Data())

        appModel.setCodexPathOverride(codexURL.path)

        let restoredModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            runtimeFactory: { TestWorkspaceRuntime(controller: $0, coordinator: runtimeCoordinator) }
        )

        #expect(restoredModel.codexPathOverride == codexURL.path)
    }

    @Test func firstSendCreatesThreadBeforeStartingTurn() async throws {
        let store = InMemoryAppPreferencesStore()
        let runtimeCoordinator = TestRuntimeCoordinator()
        let appModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            runtimeFactory: { TestWorkspaceRuntime(controller: $0, coordinator: runtimeCoordinator) }
        )
        let workspaceURL = try temporaryDirectory(named: "conversation-send")

        appModel.activateWorkspace(at: workspaceURL)
        try await waitUntil { appModel.activeWorkspaceController?.connectionStatus == .ready }

        let didSend = await appModel.sendPrompt("Ship the conversation shell.")

        #expect(didSend)
        #expect(runtimeCoordinator.startThreadCount == 1)
        #expect(runtimeCoordinator.startTurnPrompts == ["Ship the conversation shell."])
        #expect(appModel.activeWorkspaceController?.activeThreadSession?.messages.map(\.text) == ["Ship the conversation shell."])
        #expect(appModel.activeWorkspaceController?.connectionStatus == .streaming)
    }

    @Test func sendAndCancelGatingTracksWorkspaceState() async throws {
        let store = InMemoryAppPreferencesStore()
        let runtimeCoordinator = TestRuntimeCoordinator()
        let appModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            runtimeFactory: { TestWorkspaceRuntime(controller: $0, coordinator: runtimeCoordinator) }
        )
        let workspaceURL = try temporaryDirectory(named: "conversation-gating")

        appModel.activateWorkspace(at: workspaceURL)
        try await waitUntil { appModel.activeWorkspaceController?.connectionStatus == .ready }

        #expect(appModel.canSendPrompt("Ready to go"))
        #expect(appModel.canCancelTurn == false)

        _ = await appModel.sendPrompt("Ready to go")

        #expect(appModel.canSendPrompt("Second turn") == false)
        #expect(appModel.canCancelTurn)

        await appModel.cancelActiveTurn()

        #expect(runtimeCoordinator.cancelCount == 1)
        #expect(appModel.canCancelTurn == false)
        #expect(appModel.canSendPrompt("Second turn"))
        #expect(appModel.activeWorkspaceController?.activeThreadSession?.turnState.phase == .cancelled)
    }

    @Test func resolveApprovalForwardsDecisionToActiveRuntime() async throws {
        let store = InMemoryAppPreferencesStore()
        let runtimeCoordinator = TestRuntimeCoordinator()
        let appModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            runtimeFactory: { TestWorkspaceRuntime(controller: $0, coordinator: runtimeCoordinator) }
        )
        let workspaceURL = try temporaryDirectory(named: "conversation-approval")

        appModel.activateWorkspace(at: workspaceURL)
        try await waitUntil { appModel.activeWorkspaceController?.connectionStatus == .ready }
        _ = await appModel.sendPrompt("Wait for approval")

        let session = try #require(appModel.activeWorkspaceController?.activeThreadSession)
        session.enqueueApprovalRequest(
            ApprovalRequest(
                id: "approval-1",
                kind: .command,
                title: "Approve command execution",
                detail: "swift test",
                command: ApprovalCommandContext(command: "swift test", workingDirectory: workspaceURL.path),
                files: [],
                riskLevel: .medium
            )
        )

        let didResolve = await appModel.resolveApproval(id: "approval-1", resolution: .approved)

        #expect(didResolve)
        #expect(runtimeCoordinator.resolveApprovalCalls.count == 1)
        #expect(runtimeCoordinator.resolveApprovalCalls.first?.0 == "approval-1")
        #expect(runtimeCoordinator.resolveApprovalCalls.first?.1 == .approved)
        #expect(session.pendingApprovals.isEmpty)
    }

    @Test func resolveApprovalIgnoresDuplicateInFlightDecision() async throws {
        let store = InMemoryAppPreferencesStore()
        let runtimeCoordinator = TestRuntimeCoordinator()
        runtimeCoordinator.shouldDelayApprovalResolution = true
        let appModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            runtimeFactory: { TestWorkspaceRuntime(controller: $0, coordinator: runtimeCoordinator) }
        )
        let workspaceURL = try temporaryDirectory(named: "conversation-approval-dedup")

        appModel.activateWorkspace(at: workspaceURL)
        try await waitUntil { appModel.activeWorkspaceController?.connectionStatus == .ready }
        _ = await appModel.sendPrompt("Wait for approval")

        let session = try #require(appModel.activeWorkspaceController?.activeThreadSession)
        session.enqueueApprovalRequest(
            ApprovalRequest(
                id: "approval-1",
                kind: .command,
                title: "Approve command execution",
                detail: "swift test",
                command: ApprovalCommandContext(command: "swift test", workingDirectory: workspaceURL.path),
                files: [],
                riskLevel: .medium
            )
        )

        async let firstResult = appModel.resolveApproval(id: "approval-1", resolution: .approved)
        try await waitUntil { session.pendingApprovals.first?.pendingResolution == .approved }
        let secondResult = await appModel.resolveApproval(id: "approval-1", resolution: .declined)

        runtimeCoordinator.releaseDelayedApprovalResolutions()
        let firstDidResolve = await firstResult

        #expect(firstDidResolve)
        #expect(secondResult == false)
        #expect(runtimeCoordinator.resolveApprovalCalls.count == 1)
        #expect(runtimeCoordinator.resolveApprovalCalls.first?.1 == .approved)
    }

    @Test func reselectingActiveWorkspaceKeepsCurrentConversationSession() async throws {
        let store = InMemoryAppPreferencesStore()
        let runtimeCoordinator = TestRuntimeCoordinator()
        let appModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            runtimeFactory: { TestWorkspaceRuntime(controller: $0, coordinator: runtimeCoordinator) }
        )
        let workspaceURL = try temporaryDirectory(named: "conversation-preserve")

        appModel.activateWorkspace(at: workspaceURL)
        try await waitUntil { appModel.activeWorkspaceController?.connectionStatus == .ready }
        _ = await appModel.sendPrompt("Keep this transcript")

        let originalController = try #require(appModel.activeWorkspaceController)
        let originalSession = try #require(originalController.activeThreadSession)

        appModel.reopenWorkspace(WorkspaceRecord(url: workspaceURL, lastOpenedAt: .now))

        #expect(appModel.activeWorkspaceController === originalController)
        #expect(appModel.activeWorkspaceController?.activeThreadSession === originalSession)
        #expect(appModel.activeWorkspaceController?.activeThreadSession?.messages.first?.text == "Keep this transcript")
        #expect(runtimeCoordinator.startCount == 1)
    }

    @Test func sendPromptUsesWorkspaceWriteTurnConfiguration() async throws {
        let store = InMemoryAppPreferencesStore()
        let runtimeCoordinator = TestRuntimeCoordinator()
        let appModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            runtimeFactory: { TestWorkspaceRuntime(controller: $0, coordinator: runtimeCoordinator) }
        )
        let workspaceURL = try temporaryDirectory(named: "conversation-config")

        appModel.activateWorkspace(at: workspaceURL)
        try await waitUntil { appModel.activeWorkspaceController?.connectionStatus == .ready }
        _ = await appModel.sendPrompt("Create a README")

        let configuration = try #require(runtimeCoordinator.startTurnConfigurations.last ?? nil)
        #expect(configuration.cwd == workspaceURL.path)
        #expect(configuration.sandboxPolicy == "workspace-write")
        #expect(configuration.approvalPolicy == "on-request")
        #expect(configuration.summaryMode == "concise")
    }

    @Test func secondSendIsRejectedWhileWaitingForTurnStartAcknowledgement() async throws {
        let store = InMemoryAppPreferencesStore()
        let runtimeCoordinator = TestRuntimeCoordinator()
        runtimeCoordinator.shouldDelayTurnStart = true
        let appModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            runtimeFactory: { TestWorkspaceRuntime(controller: $0, coordinator: runtimeCoordinator) }
        )
        let workspaceURL = try temporaryDirectory(named: "conversation-double-send")

        appModel.activateWorkspace(at: workspaceURL)
        try await waitUntil { appModel.activeWorkspaceController?.connectionStatus == .ready }

        let firstSendTask = Task { await appModel.sendPrompt("Ship the first turn") }
        try await waitUntil { runtimeCoordinator.pendingDelayedTurnStartCount == 1 }

        #expect(appModel.activeWorkspaceController?.isAwaitingTurnStart == true)
        #expect(appModel.canSendPrompt("Second turn") == false)

        let secondSend = await appModel.sendPrompt("Second turn")
        #expect(secondSend == false)
        #expect(runtimeCoordinator.startTurnPrompts == ["Ship the first turn"])

        runtimeCoordinator.releaseDelayedTurnStarts()

        let firstSend = await firstSendTask.value
        #expect(firstSend)
        #expect(appModel.activeWorkspaceController?.isAwaitingTurnStart == false)
        #expect(appModel.activeWorkspaceController?.activeThreadSession?.messages.map(\.text) == ["Ship the first turn"])
    }

    @Test func switchingWorkspacesKeepsEachWorkspaceRuntimeRunning() async throws {
        let store = InMemoryAppPreferencesStore()
        let runtimeCoordinator = LifecycleProbeCoordinator(startDelayNanoseconds: 80_000_000)
        let appModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            runtimeFactory: { LifecycleProbeRuntime(controller: $0, coordinator: runtimeCoordinator) }
        )
        let firstWorkspaceURL = try temporaryDirectory(named: "stale-runtime-a")
        let secondWorkspaceURL = try temporaryDirectory(named: "stale-runtime-b")

        appModel.activateWorkspace(at: firstWorkspaceURL)
        appModel.activateWorkspace(at: secondWorkspaceURL)

        try await waitUntil {
            appModel.activeWorkspaceController?.workspace.canonicalPath == secondWorkspaceURL.path &&
            appModel.activeWorkspaceController?.connectionStatus == .ready &&
            runtimeCoordinator.records(for: firstWorkspaceURL.path).last?.isRunning == true &&
            runtimeCoordinator.records(for: secondWorkspaceURL.path).last?.isRunning == true
        }

        #expect(runtimeCoordinator.records(for: firstWorkspaceURL.path).count == 1)
        #expect(runtimeCoordinator.records(for: secondWorkspaceURL.path).count == 1)
        #expect(runtimeCoordinator.records(for: firstWorkspaceURL.path).last?.stopCount == 0)
        #expect(runtimeCoordinator.records(for: secondWorkspaceURL.path).last?.stopCount == 0)
    }

    @Test func retryKeepsOnlyNewestRuntimeRunning() async throws {
        let store = InMemoryAppPreferencesStore()
        let runtimeCoordinator = LifecycleProbeCoordinator(startDelayNanoseconds: 80_000_000)
        let appModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            runtimeFactory: { LifecycleProbeRuntime(controller: $0, coordinator: runtimeCoordinator) }
        )
        let workspaceURL = try temporaryDirectory(named: "stale-retry")

        appModel.activateWorkspace(at: workspaceURL)
        try await waitUntil { appModel.activeWorkspaceController?.connectionStatus == .ready }

        appModel.retryActiveWorkspaceConnection()
        appModel.retryActiveWorkspaceConnection()

        try await waitUntil {
            let records = runtimeCoordinator.records(for: workspaceURL.path)
            return records.count == 3 &&
                records.dropLast().allSatisfy { $0.isRunning == false && $0.stopCount >= 1 } &&
                records.last?.isRunning == true &&
                appModel.activeWorkspaceController?.connectionStatus == .ready
        }

        #expect(runtimeCoordinator.records(for: workspaceURL.path).count == 3)
    }
}

func temporaryDirectory(named name: String = UUID().uuidString) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private final class InMemoryAppPreferencesStore: AppPreferencesStore {
    private var storedSnapshot: AppPreferencesSnapshot?

    init(snapshot: AppPreferencesSnapshot? = nil) {
        self.storedSnapshot = snapshot
    }

    func loadSnapshot() throws -> AppPreferencesSnapshot? {
        storedSnapshot
    }

    func saveSnapshot(_ snapshot: AppPreferencesSnapshot) throws {
        storedSnapshot = snapshot
    }
}

@MainActor
private final class TestRuntimeCoordinator {
    var startCount = 0
    var stopCount = 0
    var startThreadCount = 0
    var startTurnPrompts: [String] = []
    var startTurnConfigurations: [BridgeTurnStartConfiguration?] = []
    var cancelCount = 0
    var resolveApprovalCalls: [(String, ApprovalResolution)] = []
    var shouldDelayTurnStart = false
    var shouldDelayApprovalResolution = false
    private var pendingDelayedTurnStarts: [CheckedContinuation<Void, Never>] = []
    private var pendingDelayedApprovalResolutions: [CheckedContinuation<Void, Never>] = []

    var pendingDelayedTurnStartCount: Int {
        pendingDelayedTurnStarts.count
    }

    func enqueueDelayedTurnStart(_ continuation: CheckedContinuation<Void, Never>) {
        pendingDelayedTurnStarts.append(continuation)
    }

    func releaseDelayedTurnStarts() {
        let continuations = pendingDelayedTurnStarts
        pendingDelayedTurnStarts.removeAll()
        continuations.forEach { $0.resume() }
    }

    func awaitDelayedApprovalResolutionIfNeeded() async {
        guard shouldDelayApprovalResolution else {
            return
        }

        await withCheckedContinuation { continuation in
            pendingDelayedApprovalResolutions.append(continuation)
        }
    }

    func releaseDelayedApprovalResolutions() {
        let continuations = pendingDelayedApprovalResolutions
        pendingDelayedApprovalResolutions.removeAll()
        continuations.forEach { $0.resume() }
    }
}

@MainActor
private final class TestWorkspaceRuntime: WorkspaceConversationRuntime {
    private let controller: WorkspaceController
    private let coordinator: TestRuntimeCoordinator

    init(controller: WorkspaceController, coordinator: TestRuntimeCoordinator) {
        self.controller = controller
        self.coordinator = coordinator
    }

    func start() async throws {
        coordinator.startCount += 1
        controller.setBridgeLifecycleState(.idle)
        controller.setConnectionStatus(.ready)
    }

    func stop() async {
        coordinator.stopCount += 1
        controller.setAwaitingTurnStart(false)
        controller.setConnectionStatus(.disconnected)
    }

    func listThreads(archived: Bool) async throws {
        controller.setShowingArchivedThreads(archived)
    }

    func startThreadAndWait(title: String?) async throws -> ThreadSession {
        coordinator.startThreadCount += 1
        return controller.openThread(
            id: "thread-\(coordinator.startThreadCount)",
            title: title ?? "New Conversation"
        )
    }

    func resumeThreadAndWait(id: String) async throws -> ThreadSession {
        controller.resumeThread(id: id, title: "Resumed Conversation")
    }

    func readThreadAndWait(id: String, includeTurns: Bool) async throws -> ThreadSession {
        controller.resumeThread(id: id, title: "Read Conversation")
    }

    func forkThreadAndWait(id: String) async throws -> ThreadSession {
        coordinator.startThreadCount += 1
        return controller.resumeThread(
            id: "\(id)-fork-\(coordinator.startThreadCount)",
            title: "Forked Conversation",
            messages: controller.threadSession(id: id)?.messages ?? []
        )
    }

    func archiveThread(id: String) async throws {
        controller.setThreadArchived(true, for: id)
    }

    func unarchiveThreadAndWait(id: String) async throws -> ThreadSession {
        controller.setThreadArchived(false, for: id)
        return controller.resumeThread(id: id, title: "Resumed Conversation")
    }

    func rollbackThreadAndWait(id: String, numTurns: Int) async throws -> ThreadSession {
        let messages = Array((controller.threadSession(id: id)?.messages ?? []).dropLast(max(0, numTurns)))
        return controller.resumeThread(id: id, title: "Resumed Conversation", messages: messages)
    }

    func startTurn(threadID: String, prompt: String, configuration: BridgeTurnStartConfiguration?) async throws {
        coordinator.startTurnPrompts.append(prompt)
        coordinator.startTurnConfigurations.append(configuration)

        if coordinator.shouldDelayTurnStart {
            await withCheckedContinuation { continuation in
                coordinator.enqueueDelayedTurnStart(continuation)
            }
        }

        let session = controller.threadSession(id: threadID) ?? controller.openThread(id: threadID, title: "New Conversation")
        session.beginTurn(userPrompt: prompt)
        controller.setAwaitingTurnStart(false, for: threadID)
        controller.setCurrentTurnID("test-turn", for: threadID)
        controller.setConnectionStatus(.streaming)
    }

    func cancelTurn(threadID: String, reason: String?) async throws {
        coordinator.cancelCount += 1
        controller.setConnectionStatus(.cancelling)
        controller.setAwaitingTurnStart(false, for: threadID)
        controller.threadSession(id: threadID)?.cancelTurn()
        controller.setCurrentTurnID(nil, for: threadID)
        controller.setConnectionStatus(.ready)
    }

    func resolveApproval(threadID: String, id: String, resolution: ApprovalResolution) async throws {
        coordinator.resolveApprovalCalls.append((id, resolution))
        await coordinator.awaitDelayedApprovalResolutionIfNeeded()
        controller.threadSession(id: threadID)?.resolveApprovalRequest(id: id, resolution: resolution)
    }
}

@MainActor
private final class LifecycleProbeCoordinator {
    final class Record {
        let workspacePath: String
        private(set) var startCount = 0
        private(set) var stopCount = 0
        private(set) var isRunning = false

        init(workspacePath: String) {
            self.workspacePath = workspacePath
        }

        func recordStart() {
            startCount += 1
            isRunning = true
        }

        func recordStop() {
            stopCount += 1
            isRunning = false
        }
    }

    let startDelayNanoseconds: UInt64
    private(set) var recordsByWorkspacePath: [String: [Record]] = [:]

    init(startDelayNanoseconds: UInt64) {
        self.startDelayNanoseconds = startDelayNanoseconds
    }

    func register(workspacePath: String) -> Record {
        let record = Record(workspacePath: workspacePath)
        recordsByWorkspacePath[workspacePath, default: []].append(record)
        return record
    }

    func records(for workspacePath: String) -> [Record] {
        recordsByWorkspacePath[workspacePath] ?? []
    }
}

@MainActor
private final class LifecycleProbeRuntime: WorkspaceConversationRuntime {
    private let controller: WorkspaceController
    private let coordinator: LifecycleProbeCoordinator
    private let record: LifecycleProbeCoordinator.Record

    init(controller: WorkspaceController, coordinator: LifecycleProbeCoordinator) {
        self.controller = controller
        self.coordinator = coordinator
        self.record = coordinator.register(workspacePath: controller.workspace.canonicalPath)
    }

    func start() async throws {
        controller.setBridgeLifecycleState(.starting)
        controller.setConnectionStatus(.connecting)

        do {
            try await Task.sleep(nanoseconds: coordinator.startDelayNanoseconds)
        } catch {}

        record.recordStart()
        controller.setBridgeLifecycleState(.idle)
        controller.setConnectionStatus(.ready)
    }

    func stop() async {
        record.recordStop()
        controller.setAwaitingTurnStart(false)
        controller.setBridgeLifecycleState(.idle)
        controller.setConnectionStatus(.disconnected)
    }

    func listThreads(archived: Bool) async throws {
        controller.setShowingArchivedThreads(archived)
    }

    func startThreadAndWait(title: String?) async throws -> ThreadSession {
        controller.openThread(id: UUID().uuidString, title: title ?? "New Conversation")
    }

    func resumeThreadAndWait(id: String) async throws -> ThreadSession {
        controller.resumeThread(id: id, title: "Recovered Conversation")
    }

    func readThreadAndWait(id: String, includeTurns: Bool) async throws -> ThreadSession {
        controller.resumeThread(id: id, title: "Recovered Conversation")
    }

    func forkThreadAndWait(id: String) async throws -> ThreadSession {
        controller.resumeThread(id: "\(id)-fork", title: "Recovered Conversation")
    }

    func archiveThread(id: String) async throws {
        controller.setThreadArchived(true, for: id)
    }

    func unarchiveThreadAndWait(id: String) async throws -> ThreadSession {
        controller.setThreadArchived(false, for: id)
        return controller.resumeThread(id: id, title: "Recovered Conversation")
    }

    func rollbackThreadAndWait(id: String, numTurns: Int) async throws -> ThreadSession {
        let messages = Array((controller.threadSession(id: id)?.messages ?? []).dropLast(max(0, numTurns)))
        return controller.resumeThread(id: id, title: "Recovered Conversation", messages: messages)
    }

    func startTurn(threadID: String, prompt: String, configuration: BridgeTurnStartConfiguration?) async throws {
        let session = controller.threadSession(id: threadID) ?? controller.openThread(id: threadID, title: "New Conversation")
        session.beginTurn(userPrompt: prompt)
        controller.setAwaitingTurnStart(false, for: threadID)
        controller.setCurrentTurnID("probe-turn", for: threadID)
        controller.setConnectionStatus(.streaming)
    }

    func cancelTurn(threadID: String, reason: String?) async throws {
        controller.setAwaitingTurnStart(false, for: threadID)
        controller.threadSession(id: threadID)?.cancelTurn()
        controller.setCurrentTurnID(nil, for: threadID)
        controller.setConnectionStatus(.ready)
    }

    func resolveApproval(threadID: String, id: String, resolution: ApprovalResolution) async throws {
        controller.threadSession(id: threadID)?.resolveApprovalRequest(id: id, resolution: resolution)
    }
}

private func waitUntil(
    timeoutNanoseconds: UInt64 = 1_000_000_000,
    pollNanoseconds: UInt64 = 10_000_000,
    _ condition: @escaping @MainActor () -> Bool
) async throws {
    let deadline = ContinuousClock.now + .nanoseconds(Int64(timeoutNanoseconds))

    while ContinuousClock.now < deadline {
        if await condition() {
            return
        }

        try await Task.sleep(nanoseconds: pollNanoseconds)
    }

    Issue.record("Timed out waiting for test condition.")
}
