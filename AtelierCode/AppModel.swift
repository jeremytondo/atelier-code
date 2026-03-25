import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class AppModel {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AtelierCode", category: "AppModel")

    private(set) var recentWorkspaces: [WorkspaceRecord]
    private(set) var lastSelectedWorkspacePath: String?
    private(set) var codexPathOverride: String?
    private(set) var startupDiagnostics: [StartupDiagnostic]
    private(set) var activeWorkspaceController: WorkspaceController?

    @ObservationIgnored private let preferencesStore: any AppPreferencesStore
    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let bridgeDiagnosticProvider: () -> StartupDiagnostic
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let runtimeFactory: @MainActor (WorkspaceController) -> any WorkspaceConversationRuntime
    @ObservationIgnored private var activeWorkspaceRuntime: (any WorkspaceConversationRuntime)?
    @ObservationIgnored private var runtimeLifecycleTask: Task<Void, Never>?

    init(
        preferencesStore: (any AppPreferencesStore)? = nil,
        fileManager: FileManager = .default,
        bridgeDiagnosticProvider: (() -> StartupDiagnostic)? = nil,
        now: @escaping () -> Date = Date.init,
        runtimeFactory: (@MainActor (WorkspaceController) -> any WorkspaceConversationRuntime)? = nil
    ) {
        let resolvedPreferencesStore = preferencesStore ?? UserDefaultsAppPreferencesStore()
        let resolvedBridgeDiagnosticProvider = bridgeDiagnosticProvider ?? { StartupDiagnostic.defaultBridgeDiagnostic() }
        let resolvedRuntimeFactory = runtimeFactory ?? { WorkspaceBridgeRuntime(controller: $0) }

        self.preferencesStore = resolvedPreferencesStore
        self.fileManager = fileManager
        self.bridgeDiagnosticProvider = resolvedBridgeDiagnosticProvider
        self.now = now
        self.runtimeFactory = resolvedRuntimeFactory

        let loadedSnapshot = try? resolvedPreferencesStore.loadSnapshot()
        let normalizedRecentWorkspaces = Self.normalizeRecentWorkspaces(loadedSnapshot?.recentWorkspaces ?? [])
        let selectedPath = loadedSnapshot?.lastSelectedWorkspacePath.map(WorkspaceRecord.canonicalizedPath(for:))
        let codexOverridePath = loadedSnapshot?.codexPathOverride

        recentWorkspaces = normalizedRecentWorkspaces
        lastSelectedWorkspacePath = selectedPath
        codexPathOverride = codexOverridePath
        startupDiagnostics = []
        activeWorkspaceController = nil

        if let codexOverridePath {
            appendStartupDiagnostic(Self.codexOverrideDiagnostic(path: codexOverridePath, fileManager: fileManager))
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
                activeWorkspaceRuntime = resolvedRuntimeFactory(controller)
                appendStartupDiagnostic(.restoredWorkspacePresent(restoredWorkspace))
            } else {
                lastSelectedWorkspacePath = nil
                appendStartupDiagnostic(.restoredWorkspaceMissing(path: selectedPath))
            }
        }

        appendStartupDiagnostic(resolvedBridgeDiagnosticProvider())

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
            codexPathOverride: codexPathOverride
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
        runtimeLifecycleTask?.cancel()
        activeWorkspaceRuntime = nil
        activeWorkspaceController = nil
        lastSelectedWorkspacePath = nil
        persistPreferences()

        scheduleRuntimeLifecycle(previousRuntime: previousRuntime, nextRuntime: nil)
    }

    func setCodexPathOverride(_ path: String?) {
        codexPathOverride = path?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        persistPreferences()
    }

    func retryActiveWorkspaceConnection() {
        guard let controller = activeWorkspaceController else {
            return
        }

        let previousRuntime = activeWorkspaceRuntime
        let runtime = runtimeFactory(controller)
        activeWorkspaceRuntime = runtime

        scheduleRuntimeLifecycle(previousRuntime: previousRuntime, nextRuntime: runtime)
    }

    func canSendPrompt(_ prompt: String) -> Bool {
        guard let controller = activeWorkspaceController else {
            return false
        }

        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return canSendNormalizedPrompt(trimmedPrompt, with: controller)
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
        guard let controller = activeWorkspaceController,
              canSendNormalizedPrompt(trimmedPrompt, with: controller),
              let runtime = activeWorkspaceRuntime else {
            return false
        }

        controller.setAwaitingTurnStart(true)

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
            controller.setAwaitingTurnStart(false)
            return false
        } catch {
            controller.setAwaitingTurnStart(false)
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

    @discardableResult
    func resolveApproval(id: String, resolution: ApprovalResolution) async -> Bool {
        guard let controller = activeWorkspaceController,
              let session = controller.activeThreadSession,
              session.beginApprovalResolution(id: id, resolution: resolution),
              let runtime = activeWorkspaceRuntime else {
            return false
        }

        do {
            try await runtime.resolveApproval(id: id, resolution: resolution)
            return true
        } catch is CancellationError {
            session.clearApprovalResolution(id: id)
            return false
        } catch {
            session.clearApprovalResolution(id: id)
            controller.setConnectionStatus(.error(message: error.localizedDescription))
            if controller.activeThreadSession?.turnState.phase == .inProgress {
                controller.activeThreadSession?.failTurn(error.localizedDescription)
            }
            return false
        }
    }

    private func persistPreferences() {
        try? preferencesStore.saveSnapshot(snapshot)
    }

    private func appendStartupDiagnostic(_ diagnostic: StartupDiagnostic) {
        guard diagnostic.severity != .info else {
            return
        }

        startupDiagnostics.append(diagnostic)
    }

    private func replaceActiveWorkspace(with workspace: WorkspaceRecord) {
        let previousRuntime = activeWorkspaceRuntime
        let controller = WorkspaceController(workspace: workspace)
        let runtime = runtimeFactory(controller)

        activeWorkspaceController = controller
        activeWorkspaceRuntime = runtime

        scheduleRuntimeLifecycle(previousRuntime: previousRuntime, nextRuntime: runtime)
    }

    private func startActiveWorkspaceRuntime() {
        guard let runtime = activeWorkspaceRuntime else {
            return
        }

        scheduleRuntimeLifecycle(previousRuntime: nil, nextRuntime: runtime)
    }

    private func startRuntime(_ runtime: any WorkspaceConversationRuntime) async {
        guard isActiveRuntime(runtime) else {
            await runtime.stop()
            return
        }

        do {
            try await runtime.start()
        } catch is CancellationError {
            return
        } catch {
            Self.logger.error("Workspace runtime start failed: \(error.localizedDescription, privacy: .public)")
        }

        guard isActiveRuntime(runtime) else {
            await runtime.stop()
            return
        }
    }

    private func defaultTurnConfiguration(for controller: WorkspaceController) -> BridgeTurnStartConfiguration {
        BridgeTurnStartConfiguration(
            cwd: controller.workspace.canonicalPath,
            model: nil,
            reasoningEffort: nil,
            sandboxPolicy: SandboxPolicy.workspaceWrite.rawValue,
            approvalPolicy: ApprovalPolicy.onRequest.rawValue,
            summaryMode: SummaryMode.concise.rawValue,
            environment: nil
        )
    }

    private func canSendNormalizedPrompt(_ prompt: String, with controller: WorkspaceController) -> Bool {
        guard prompt.isEmpty == false else {
            return false
        }

        guard controller.bridgeLifecycleState == .idle else {
            return false
        }

        guard controller.connectionStatus == .ready else {
            return false
        }

        guard controller.isAwaitingTurnStart == false else {
            return false
        }

        return controller.activeThreadSession?.turnState.phase != .inProgress
    }

    private func scheduleRuntimeLifecycle(
        previousRuntime: (any WorkspaceConversationRuntime)?,
        nextRuntime: (any WorkspaceConversationRuntime)?
    ) {
        runtimeLifecycleTask?.cancel()
        runtimeLifecycleTask = Task { [weak self] in
            await previousRuntime?.stop()

            guard let self, Task.isCancelled == false else {
                return
            }

            guard let nextRuntime else {
                return
            }

            await self.startRuntime(nextRuntime)
        }
    }

    private func isActiveRuntime(_ runtime: any WorkspaceConversationRuntime) -> Bool {
        guard let activeWorkspaceRuntime else {
            return false
        }

        return ObjectIdentifier(activeWorkspaceRuntime as AnyObject) == ObjectIdentifier(runtime as AnyObject)
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

private enum SandboxPolicy: String {
    case workspaceWrite = "workspace-write"
}

private enum ApprovalPolicy: String {
    case onRequest = "on-request"
}

private enum SummaryMode: String {
    case concise
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
