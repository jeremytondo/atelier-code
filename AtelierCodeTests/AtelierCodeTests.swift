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
            codexPathOverride: codexURL.path,
            uiPreferences: UIPreferences(showsStartupDiagnostics: false)
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
        #expect(appModel.uiPreferences == UIPreferences(showsStartupDiagnostics: false))
        #expect(appModel.startupDiagnostics.contains(where: { $0.source == .embeddedBridge }))
        #expect(appModel.startupDiagnostics.contains(where: { $0.source == .codexOverridePath }))
    }

    @Test func restoresValidLastSelectedWorkspace() async throws {
        let workspaceURL = try temporaryDirectory()
        let snapshot = AppPreferencesSnapshot(
            recentWorkspaces: [WorkspaceRecord(url: workspaceURL, lastOpenedAt: .now)],
            lastSelectedWorkspacePath: workspaceURL.path,
            codexPathOverride: nil,
            uiPreferences: UIPreferences()
        )
        let store = InMemoryAppPreferencesStore(snapshot: snapshot)
        let runtimeCoordinator = TestRuntimeCoordinator()

        let appModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            runtimeFactory: { TestWorkspaceRuntime(controller: $0, coordinator: runtimeCoordinator) }
        )
        await settle()

        #expect(appModel.lastSelectedWorkspacePath == workspaceURL.path)
        #expect(appModel.activeWorkspaceController?.workspace.canonicalPath == workspaceURL.path)
        #expect(appModel.activeWorkspaceController?.connectionStatus == .ready)
        #expect(appModel.startupDiagnostics.contains(where: { $0.source == .restoredWorkspace && $0.severity == .info }))
        #expect(runtimeCoordinator.startCount == 1)
    }

    @Test func clearsInvalidRestoredWorkspaceAndRecordsDiagnostic() async throws {
        let workspaceURL = try temporaryDirectory()
        try FileManager.default.removeItem(at: workspaceURL)

        let snapshot = AppPreferencesSnapshot(
            recentWorkspaces: [],
            lastSelectedWorkspacePath: workspaceURL.path,
            codexPathOverride: nil,
            uiPreferences: UIPreferences()
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

    @Test func roundTripsCodexOverrideAndUIPreferences() async throws {
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
        appModel.updateUIPreferences { preferences in
            preferences.showsStartupDiagnostics = false
        }

        let restoredModel = AppModel(
            preferencesStore: store,
            bridgeDiagnosticProvider: { .bridgePresent(at: URL(fileURLWithPath: "/tmp/bridge")) },
            runtimeFactory: { TestWorkspaceRuntime(controller: $0, coordinator: runtimeCoordinator) }
        )

        #expect(restoredModel.codexPathOverride == codexURL.path)
        #expect(restoredModel.uiPreferences == UIPreferences(showsStartupDiagnostics: false))
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
        await settle()

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
        await settle()

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
        await settle()
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
        await settle()
        _ = await appModel.sendPrompt("Create a README")

        let configuration = try #require(runtimeCoordinator.startTurnConfigurations.last ?? nil)
        #expect(configuration.cwd == workspaceURL.path)
        #expect(configuration.sandboxPolicy == "workspace-write")
        #expect(configuration.approvalPolicy == "on-request")
        #expect(configuration.summaryMode == "concise")
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
        controller.setConnectionStatus(.disconnected)
    }

    func startThreadAndWait(title: String?) async throws -> ThreadSession {
        coordinator.startThreadCount += 1
        return controller.openThread(
            id: "thread-\(coordinator.startThreadCount)",
            title: title ?? "New Conversation"
        )
    }

    func startTurn(prompt: String, configuration: BridgeTurnStartConfiguration?) async throws {
        coordinator.startTurnPrompts.append(prompt)
        coordinator.startTurnConfigurations.append(configuration)
        let session = controller.activeThreadSession ?? controller.openThread(id: "thread-fallback", title: "New Conversation")
        session.beginTurn(userPrompt: prompt)
        controller.setConnectionStatus(.streaming)
    }

    func cancelTurn(reason: String?) async throws {
        coordinator.cancelCount += 1
        controller.setConnectionStatus(.cancelling)
        controller.activeThreadSession?.cancelTurn()
        controller.setConnectionStatus(.ready)
    }
}

private func settle() async {
    for _ in 0..<10 {
        await Task.yield()
    }
}
