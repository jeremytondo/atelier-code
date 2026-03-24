import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    private(set) var recentWorkspaces: [WorkspaceRecord]
    private(set) var lastSelectedWorkspacePath: String?
    private(set) var codexPathOverride: String?
    private(set) var uiPreferences: UIPreferences
    private(set) var startupDiagnostics: [StartupDiagnostic]
    private(set) var activeWorkspaceController: WorkspaceController?

    @ObservationIgnored private let preferencesStore: any AppPreferencesStore
    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let bridgeDiagnosticProvider: () -> StartupDiagnostic
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let runtimeFactory: @MainActor (WorkspaceController) -> any WorkspaceConversationRuntime
    @ObservationIgnored private var activeWorkspaceRuntime: (any WorkspaceConversationRuntime)?

    init(
        preferencesStore: any AppPreferencesStore = UserDefaultsAppPreferencesStore(),
        fileManager: FileManager = .default,
        bridgeDiagnosticProvider: @escaping () -> StartupDiagnostic = { StartupDiagnostic.defaultBridgeDiagnostic() },
        now: @escaping () -> Date = Date.init,
        runtimeFactory: @escaping @MainActor (WorkspaceController) -> any WorkspaceConversationRuntime = { WorkspaceBridgeRuntime(controller: $0) }
    ) {
        self.preferencesStore = preferencesStore
        self.fileManager = fileManager
        self.bridgeDiagnosticProvider = bridgeDiagnosticProvider
        self.now = now
        self.runtimeFactory = runtimeFactory

        let loadedSnapshot = try? preferencesStore.loadSnapshot()
        let normalizedRecentWorkspaces = Self.normalizeRecentWorkspaces(loadedSnapshot?.recentWorkspaces ?? [])
        let selectedPath = loadedSnapshot?.lastSelectedWorkspacePath.map(WorkspaceRecord.canonicalizedPath(for:))
        let codexOverridePath = loadedSnapshot?.codexPathOverride
        let preferences = loadedSnapshot?.uiPreferences ?? UIPreferences()

        recentWorkspaces = normalizedRecentWorkspaces
        lastSelectedWorkspacePath = selectedPath
        codexPathOverride = codexOverridePath
        uiPreferences = preferences
        startupDiagnostics = [bridgeDiagnosticProvider()]
        activeWorkspaceController = nil

        if let codexOverridePath {
            startupDiagnostics.append(Self.codexOverrideDiagnostic(path: codexOverridePath, fileManager: fileManager))
        }

        if let selectedPath {
            if Self.workspaceExists(atPath: selectedPath, fileManager: fileManager) {
                let restoredWorkspace = normalizedRecentWorkspaces.first(where: { $0.canonicalPath == selectedPath })
                    ?? WorkspaceRecord(
                        canonicalPath: selectedPath,
                        displayName: URL(fileURLWithPath: selectedPath).lastPathComponent,
                        lastOpenedAt: now()
                    )
                let controller = WorkspaceController(workspace: restoredWorkspace)
                activeWorkspaceController = controller
                activeWorkspaceRuntime = runtimeFactory(controller)
                startupDiagnostics.append(.restoredWorkspacePresent(restoredWorkspace))
            } else {
                lastSelectedWorkspacePath = nil
                startupDiagnostics.append(.restoredWorkspaceMissing(path: selectedPath))
            }
        }

        if let loadedSnapshot, loadedSnapshot != snapshot {
            persistPreferences()
        }

        if activeWorkspaceRuntime != nil {
            startActiveWorkspaceRuntime()
        }
    }

    var snapshot: AppPreferencesSnapshot {
        AppPreferencesSnapshot(
            recentWorkspaces: recentWorkspaces,
            lastSelectedWorkspacePath: lastSelectedWorkspacePath,
            codexPathOverride: codexPathOverride,
            uiPreferences: uiPreferences
        )
    }

    func activateWorkspace(at url: URL) {
        let workspace = WorkspaceRecord(url: url, lastOpenedAt: now())

        if activeWorkspaceController?.workspace.canonicalPath == workspace.canonicalPath {
            lastSelectedWorkspacePath = workspace.canonicalPath
            recentWorkspaces = Self.upsertingRecentWorkspace(workspace, into: recentWorkspaces)
            persistPreferences()
            return
        }

        replaceActiveWorkspace(with: workspace)
        lastSelectedWorkspacePath = workspace.canonicalPath
        recentWorkspaces = Self.upsertingRecentWorkspace(workspace, into: recentWorkspaces)
        persistPreferences()
    }

    func reopenWorkspace(_ workspace: WorkspaceRecord) {
        activateWorkspace(at: workspace.url)
    }

    func clearSelectedWorkspace() {
        let previousRuntime = activeWorkspaceRuntime
        activeWorkspaceRuntime = nil
        activeWorkspaceController = nil
        lastSelectedWorkspacePath = nil
        persistPreferences()

        Task {
            await previousRuntime?.stop()
        }
    }

    func setCodexPathOverride(_ path: String?) {
        codexPathOverride = path?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        persistPreferences()
    }

    func updateUIPreferences(_ update: (inout UIPreferences) -> Void) {
        update(&uiPreferences)
        persistPreferences()
    }

    func retryActiveWorkspaceConnection() {
        guard let controller = activeWorkspaceController else {
            return
        }

        let previousRuntime = activeWorkspaceRuntime
        let runtime = runtimeFactory(controller)
        activeWorkspaceRuntime = runtime

        Task {
            await previousRuntime?.stop()
            await startRuntime(runtime)
        }
    }

    func canSendPrompt(_ prompt: String) -> Bool {
        guard let controller = activeWorkspaceController else {
            return false
        }

        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedPrompt.isEmpty == false else {
            return false
        }

        guard controller.bridgeLifecycleState == .idle else {
            return false
        }

        guard controller.connectionStatus == .ready else {
            return false
        }

        return controller.activeThreadSession?.turnState.phase != .inProgress
    }

    var canCancelTurn: Bool {
        guard let controller = activeWorkspaceController,
              controller.activeThreadSession?.turnState.phase == .inProgress else {
            return false
        }

        return controller.connectionStatus == .streaming
    }

    var canRetryActiveWorkspace: Bool {
        guard let controller = activeWorkspaceController else {
            return false
        }

        return controller.connectionStatus.isRetryable
    }

    @discardableResult
    func sendPrompt(_ prompt: String) async -> Bool {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSendPrompt(trimmedPrompt),
              let controller = activeWorkspaceController,
              let runtime = activeWorkspaceRuntime else {
            return false
        }

        do {
            if controller.activeThreadSession == nil {
                _ = try await runtime.startThreadAndWait(title: nil)
            }

            try await runtime.startTurn(
                prompt: trimmedPrompt,
                configuration: defaultTurnConfiguration(for: controller)
            )
            return true
        } catch is CancellationError {
            return false
        } catch {
            controller.setConnectionStatus(.error(message: error.localizedDescription))
            if controller.activeThreadSession?.turnState.phase == .inProgress {
                controller.activeThreadSession?.failTurn(error.localizedDescription)
            }
            return false
        }
    }

    func cancelActiveTurn() async {
        guard canCancelTurn,
              let controller = activeWorkspaceController,
              let runtime = activeWorkspaceRuntime else {
            return
        }

        do {
            try await runtime.cancelTurn(reason: "User cancelled the current turn.")
        } catch is CancellationError {
            return
        } catch {
            controller.setConnectionStatus(.error(message: error.localizedDescription))
            controller.activeThreadSession?.failTurn(error.localizedDescription)
        }
    }

    private func persistPreferences() {
        try? preferencesStore.saveSnapshot(snapshot)
    }

    private func replaceActiveWorkspace(with workspace: WorkspaceRecord) {
        let previousRuntime = activeWorkspaceRuntime
        let controller = WorkspaceController(workspace: workspace)
        let runtime = runtimeFactory(controller)

        activeWorkspaceController = controller
        activeWorkspaceRuntime = runtime

        Task {
            await previousRuntime?.stop()
            await startRuntime(runtime)
        }
    }

    private func startActiveWorkspaceRuntime() {
        guard let runtime = activeWorkspaceRuntime else {
            return
        }

        Task {
            await startRuntime(runtime)
        }
    }

    private func startRuntime(_ runtime: any WorkspaceConversationRuntime) async {
        do {
            try await runtime.start()
        } catch is CancellationError {
            return
        } catch {
            // Runtime state is already updated by the concrete implementation.
        }
    }

    private func defaultTurnConfiguration(for controller: WorkspaceController) -> BridgeTurnStartConfiguration {
        BridgeTurnStartConfiguration(
            cwd: controller.workspace.canonicalPath,
            model: nil,
            reasoningEffort: nil,
            sandboxPolicy: "workspace-write",
            approvalPolicy: "on-request",
            summaryMode: "concise",
            environment: nil
        )
    }

    private static func normalizeRecentWorkspaces(_ workspaces: [WorkspaceRecord]) -> [WorkspaceRecord] {
        var seenPaths = Set<String>()
        let normalized = workspaces
            .map {
                WorkspaceRecord(
                    canonicalPath: $0.canonicalPath,
                    displayName: $0.displayName,
                    lastOpenedAt: $0.lastOpenedAt
                )
            }
            .sorted { $0.lastOpenedAt > $1.lastOpenedAt }

        var uniqueWorkspaces: [WorkspaceRecord] = []

        for workspace in normalized where seenPaths.insert(workspace.canonicalPath).inserted {
            uniqueWorkspaces.append(workspace)

            if uniqueWorkspaces.count == 20 {
                break
            }
        }

        return uniqueWorkspaces
    }

    private static func upsertingRecentWorkspace(
        _ workspace: WorkspaceRecord,
        into workspaces: [WorkspaceRecord]
    ) -> [WorkspaceRecord] {
        var updated = workspaces.filter { $0.canonicalPath != workspace.canonicalPath }
        updated.insert(workspace, at: 0)
        return Array(updated.prefix(20))
    }

    private static func workspaceExists(atPath path: String, fileManager: FileManager) -> Bool {
        var isDirectory = ObjCBool(false)
        let exists = fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    private static func codexOverrideDiagnostic(path: String, fileManager: FileManager) -> StartupDiagnostic {
        let canonicalPath = URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let exists = fileManager.fileExists(atPath: canonicalPath)
        return exists ? .codexOverridePresent(path: canonicalPath) : .codexOverrideMissing(path: canonicalPath)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private extension ConnectionStatus {
    var isRetryable: Bool {
        switch self {
        case .disconnected, .error:
            return true
        case .connecting, .ready, .streaming, .cancelling:
            return false
        }
    }
}
