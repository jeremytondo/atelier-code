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
    private(set) var workspaceControllers: [WorkspaceController]
    private(set) var selectedRoute: WorkspaceThreadRoute?

    @ObservationIgnored private let preferencesStore: any AppPreferencesStore
    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let bridgeDiagnosticProvider: () -> StartupDiagnostic
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let runtimeFactory: @MainActor (WorkspaceController) -> any WorkspaceConversationRuntime
    @ObservationIgnored private var workspaceRuntimes: [String: any WorkspaceConversationRuntime]
    @ObservationIgnored private var runtimeLifecycleTasks: [String: Task<Void, Never>]

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
        self.workspaceRuntimes = [:]
        self.runtimeLifecycleTasks = [:]

        let loadedSnapshot = try? resolvedPreferencesStore.loadSnapshot()
        let normalizedRecentWorkspaces = Self.normalizeRecentWorkspaces(loadedSnapshot?.recentWorkspaces ?? [])
        let selectedPath = loadedSnapshot?.lastSelectedWorkspacePath.map(WorkspaceRecord.canonicalizedPath(for:))
        let codexOverridePath = loadedSnapshot?.codexPathOverride

        recentWorkspaces = []
        lastSelectedWorkspacePath = nil
        codexPathOverride = codexOverridePath
        startupDiagnostics = []
        workspaceControllers = []
        selectedRoute = nil

        if let codexOverridePath {
            appendStartupDiagnostic(Self.codexOverrideDiagnostic(path: codexOverridePath, fileManager: fileManager))
        }

        for workspace in normalizedRecentWorkspaces {
            guard Self.workspaceExists(atPath: workspace.canonicalPath, fileManager: fileManager) else {
                appendStartupDiagnostic(.restoredWorkspaceMissing(path: workspace.canonicalPath))
                continue
            }

            let controller = WorkspaceController(workspace: workspace)
            workspaceControllers.append(controller)
            workspaceRuntimes[workspace.canonicalPath] = resolvedRuntimeFactory(controller)
        }

        if let selectedPath,
           workspaceControllers.contains(where: { $0.workspace.canonicalPath == selectedPath }) == false,
           startupDiagnostics.contains(where: { $0.message == StartupDiagnostic.restoredWorkspaceMissing(path: selectedPath).message }) == false {
            appendStartupDiagnostic(.restoredWorkspaceMissing(path: selectedPath))
        }

        recentWorkspaces = workspaceControllers.map(\.workspace)
        lastSelectedWorkspacePath = selectedPath.flatMap { path in
            workspaceControllers.contains(where: { $0.workspace.canonicalPath == path }) ? path : nil
        } ?? workspaceControllers.first?.workspace.canonicalPath
        selectedRoute = Self.initialRoute(
            selectedWorkspacePath: lastSelectedWorkspacePath,
            controllers: workspaceControllers
        )

        appendStartupDiagnostic(resolvedBridgeDiagnosticProvider())

        if let loadedSnapshot, loadedSnapshot != snapshot {
            persistPreferences()
        }

        startAllWorkspaceRuntimes()
    }

    var activeWorkspaceController: WorkspaceController? {
        selectedWorkspaceController
    }

    var selectedWorkspaceController: WorkspaceController? {
        guard let workspacePath = selectedRoute?.workspacePath ?? lastSelectedWorkspacePath else {
            return nil
        }

        return workspaceControllers.first(where: { $0.workspace.canonicalPath == workspacePath })
    }

    var selectedThreadSession: ThreadSession? {
        guard let selectedRoute,
              let threadID = selectedRoute.threadID else {
            return nil
        }

        return selectedWorkspaceController?.threadSession(id: threadID)
    }

    var selectedThreadSummary: ThreadSummary? {
        guard let selectedRoute,
              let threadID = selectedRoute.threadID else {
            return nil
        }

        return selectedWorkspaceController?.threadSummary(id: threadID)
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

        if let controller = workspaceController(for: workspace.canonicalPath) {
            updateWorkspaceRecord(workspace)
            controller.markThreadSelected(controller.lastActiveThreadID)
            selectWorkspace(path: workspace.canonicalPath)
            persistPreferences()
            return
        }

        let controller = WorkspaceController(workspace: workspace)
        workspaceControllers.append(controller)
        updateWorkspaceRecord(workspace)

        let runtime = runtimeFactory(controller)
        workspaceRuntimes[workspace.canonicalPath] = runtime
        selectWorkspace(path: workspace.canonicalPath)
        persistPreferences()
        scheduleRuntimeLifecycle(
            workspacePath: workspace.canonicalPath,
            previousRuntime: nil,
            nextRuntime: runtime
        )
    }

    func reopenWorkspace(_ workspace: WorkspaceRecord) {
        activateWorkspace(at: workspace.url)
    }

    func clearSelectedWorkspace() {
        selectedRoute = nil
        lastSelectedWorkspacePath = nil
        persistPreferences()
    }

    func removeWorkspace(path: String) {
        let canonicalPath = WorkspaceRecord.canonicalizedPath(for: path)
        let previousRuntime = workspaceRuntimes.removeValue(forKey: canonicalPath)

        runtimeLifecycleTasks[canonicalPath]?.cancel()
        runtimeLifecycleTasks.removeValue(forKey: canonicalPath)
        workspaceControllers.removeAll { $0.workspace.canonicalPath == canonicalPath }
        recentWorkspaces.removeAll { $0.canonicalPath == canonicalPath }

        if selectedRoute?.workspacePath == canonicalPath {
            let nextWorkspacePath = recentWorkspaces.first?.canonicalPath
            selectedRoute = Self.initialRoute(
                selectedWorkspacePath: nextWorkspacePath,
                controllers: workspaceControllers
            )
            lastSelectedWorkspacePath = selectedRoute?.workspacePath
        }

        persistPreferences()
        scheduleRuntimeLifecycle(
            workspacePath: canonicalPath,
            previousRuntime: previousRuntime,
            nextRuntime: nil
        )
    }

    func setCodexPathOverride(_ path: String?) {
        codexPathOverride = path?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        persistPreferences()
    }

    func selectWorkspace(path: String) {
        let canonicalPath = WorkspaceRecord.canonicalizedPath(for: path)
        guard let controller = workspaceController(for: canonicalPath) else {
            return
        }

        let threadID = preferredThreadID(for: controller)
        controller.markThreadSelected(threadID)
        selectedRoute = WorkspaceThreadRoute(
            workspacePath: canonicalPath,
            threadID: threadID
        )
        lastSelectedWorkspacePath = canonicalPath
        persistPreferences()
    }

    @discardableResult
    func openThread(workspacePath: String, threadID: String) async -> Bool {
        let canonicalPath = WorkspaceRecord.canonicalizedPath(for: workspacePath)
        guard let controller = workspaceController(for: canonicalPath),
              let runtime = runtime(for: canonicalPath),
              let summary = controller.threadSummary(id: threadID) else {
            return false
        }

        do {
            if controller.threadSession(id: threadID) == nil {
                if summary.isArchived {
                    _ = try await runtime.readThreadAndWait(id: threadID, includeTurns: true)
                } else {
                    _ = try await runtime.resumeThreadAndWait(id: threadID)
                }
            }

            controller.markThreadSelected(threadID)
            selectedRoute = WorkspaceThreadRoute(workspacePath: canonicalPath, threadID: threadID)
            lastSelectedWorkspacePath = canonicalPath
            persistPreferences()
            return true
        } catch is CancellationError {
            return false
        } catch {
            controller.setConnectionStatus(.error(message: error.localizedDescription))
            return false
        }
    }

    @discardableResult
    func createThread() async -> Bool {
        guard let controller = selectedWorkspaceController,
              let runtime = runtime(for: controller.workspace.canonicalPath) else {
            return false
        }

        do {
            let session = try await runtime.startThreadAndWait(title: nil)
            controller.markThreadSelected(session.threadID)
            selectedRoute = WorkspaceThreadRoute(
                workspacePath: controller.workspace.canonicalPath,
                threadID: session.threadID
            )
            lastSelectedWorkspacePath = controller.workspace.canonicalPath
            persistPreferences()
            return true
        } catch is CancellationError {
            return false
        } catch {
            controller.setConnectionStatus(.error(message: error.localizedDescription))
            return false
        }
    }

    @discardableResult
    func forkSelectedThread() async -> Bool {
        guard let controller = selectedWorkspaceController,
              let selectedRoute,
              let threadID = selectedRoute.threadID,
              let runtime = runtime(for: controller.workspace.canonicalPath) else {
            return false
        }

        do {
            let session = try await runtime.forkThreadAndWait(id: threadID)
            controller.markThreadSelected(session.threadID)
            self.selectedRoute = WorkspaceThreadRoute(
                workspacePath: controller.workspace.canonicalPath,
                threadID: session.threadID
            )
            persistPreferences()
            return true
        } catch is CancellationError {
            return false
        } catch {
            controller.setConnectionStatus(.error(message: error.localizedDescription))
            return false
        }
    }

    @discardableResult
    func archiveSelectedThread() async -> Bool {
        guard let controller = selectedWorkspaceController,
              let selectedRoute,
              let threadID = selectedRoute.threadID,
              let runtime = runtime(for: controller.workspace.canonicalPath) else {
            return false
        }

        do {
            try await runtime.archiveThread(id: threadID)
            controller.setThreadArchived(true, for: threadID)
            controller.markThreadActivity(
                id: threadID,
                at: now(),
                isRunning: false,
                hasUnreadActivity: false
            )
            if controller.isShowingArchivedThreads {
                controller.markThreadSelected(threadID)
            } else {
                selectWorkspace(path: controller.workspace.canonicalPath)
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            controller.setConnectionStatus(.error(message: error.localizedDescription))
            return false
        }
    }

    @discardableResult
    func unarchiveSelectedThread() async -> Bool {
        guard let controller = selectedWorkspaceController,
              let selectedRoute,
              let threadID = selectedRoute.threadID,
              let runtime = runtime(for: controller.workspace.canonicalPath) else {
            return false
        }

        do {
            let session = try await runtime.unarchiveThreadAndWait(id: threadID)
            controller.markThreadSelected(session.threadID)
            self.selectedRoute = WorkspaceThreadRoute(
                workspacePath: controller.workspace.canonicalPath,
                threadID: session.threadID
            )
            persistPreferences()
            return true
        } catch is CancellationError {
            return false
        } catch {
            controller.setConnectionStatus(.error(message: error.localizedDescription))
            return false
        }
    }

    @discardableResult
    func rollbackSelectedThread() async -> Bool {
        guard let controller = selectedWorkspaceController,
              let selectedRoute,
              let threadID = selectedRoute.threadID,
              let runtime = runtime(for: controller.workspace.canonicalPath) else {
            return false
        }

        do {
            let session = try await runtime.rollbackThreadAndWait(id: threadID, numTurns: 1)
            controller.markThreadSelected(session.threadID)
            self.selectedRoute = WorkspaceThreadRoute(
                workspacePath: controller.workspace.canonicalPath,
                threadID: session.threadID
            )
            persistPreferences()
            return true
        } catch is CancellationError {
            return false
        } catch {
            controller.setConnectionStatus(.error(message: error.localizedDescription))
            return false
        }
    }

    func toggleArchivedThreads(for workspacePath: String) async {
        let canonicalPath = WorkspaceRecord.canonicalizedPath(for: workspacePath)
        guard let controller = workspaceController(for: canonicalPath) else {
            return
        }

        let nextValue = controller.isShowingArchivedThreads == false
        controller.setShowingArchivedThreads(nextValue)

        guard nextValue,
              let runtime = runtime(for: canonicalPath) else {
            if let selectedRoute,
               selectedRoute.workspacePath == canonicalPath,
               let threadID = selectedRoute.threadID,
               controller.threadSummary(id: threadID)?.isArchived == true {
                selectWorkspace(path: canonicalPath)
            }
            return
        }

        do {
            try await runtime.listThreads(archived: true)
        } catch is CancellationError {
            return
        } catch {
            controller.setConnectionStatus(.error(message: error.localizedDescription))
        }
    }

    func retryActiveWorkspaceConnection() {
        guard let controller = selectedWorkspaceController else {
            return
        }

        let workspacePath = controller.workspace.canonicalPath
        let previousRuntime = workspaceRuntimes[workspacePath]
        let runtime = runtimeFactory(controller)
        workspaceRuntimes[workspacePath] = runtime

        scheduleRuntimeLifecycle(
            workspacePath: workspacePath,
            previousRuntime: previousRuntime,
            nextRuntime: runtime
        )
    }

    func canSendPrompt(_ prompt: String) -> Bool {
        guard let controller = selectedWorkspaceController else {
            return false
        }

        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return canSendNormalizedPrompt(trimmedPrompt, with: controller)
    }

    var canCancelTurn: Bool {
        guard let controller = selectedWorkspaceController,
              let selectedRoute,
              let threadID = selectedRoute.threadID,
              let session = selectedThreadSession,
              session.turnState.phase == .inProgress,
              controller.currentTurnID(for: threadID) != nil else {
            return false
        }

        switch controller.connectionStatus {
        case .ready, .streaming:
            return true
        case .connecting, .disconnected, .cancelling, .error:
            return false
        }
    }

    var canRetryActiveWorkspace: Bool {
        guard let controller = selectedWorkspaceController else {
            return false
        }

        return controller.connectionStatus.isRetryable
    }

    @discardableResult
    func sendPrompt(_ prompt: String) async -> Bool {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let controller = selectedWorkspaceController,
              canSendNormalizedPrompt(trimmedPrompt, with: controller),
              let runtime = runtime(for: controller.workspace.canonicalPath) else {
            return false
        }

        do {
            let threadID: String

            if let existingThreadID = selectedRoute?.threadID {
                if selectedThreadSummary?.isArchived == true {
                    return false
                }

                if controller.threadSession(id: existingThreadID) == nil {
                    _ = try await runtime.resumeThreadAndWait(id: existingThreadID)
                }

                threadID = existingThreadID
            } else {
                let session = try await runtime.startThreadAndWait(title: nil)
                threadID = session.threadID
                controller.markThreadSelected(threadID)
                selectedRoute = WorkspaceThreadRoute(
                    workspacePath: controller.workspace.canonicalPath,
                    threadID: threadID
                )
                persistPreferences()
            }

            controller.setAwaitingTurnStart(true, for: threadID)
            try await runtime.startTurn(
                threadID: threadID,
                prompt: trimmedPrompt,
                configuration: defaultTurnConfiguration(for: controller)
            )
            return true
        } catch is CancellationError {
            if let threadID = selectedRoute?.threadID {
                controller.setAwaitingTurnStart(false, for: threadID)
            }
            return false
        } catch {
            if let threadID = selectedRoute?.threadID {
                controller.setAwaitingTurnStart(false, for: threadID)
                controller.setCurrentTurnID(nil, for: threadID)
                controller.threadSession(id: threadID)?.failTurn(error.localizedDescription)
            }
            controller.setConnectionStatus(.error(message: error.localizedDescription))
            return false
        }
    }

    func cancelActiveTurn() async {
        guard canCancelTurn,
              let controller = selectedWorkspaceController,
              let threadID = selectedRoute?.threadID,
              let runtime = runtime(for: controller.workspace.canonicalPath) else {
            return
        }

        do {
            try await runtime.cancelTurn(threadID: threadID, reason: "User cancelled the current turn.")
        } catch is CancellationError {
            return
        } catch {
            controller.setConnectionStatus(.error(message: error.localizedDescription))
            controller.threadSession(id: threadID)?.failTurn(error.localizedDescription)
        }
    }

    @discardableResult
    func resolveApproval(id: String, resolution: ApprovalResolution) async -> Bool {
        guard let controller = selectedWorkspaceController,
              let threadID = selectedRoute?.threadID,
              let session = controller.threadSession(id: threadID),
              session.beginApprovalResolution(id: id, resolution: resolution),
              let runtime = runtime(for: controller.workspace.canonicalPath) else {
            return false
        }

        do {
            try await runtime.resolveApproval(threadID: threadID, id: id, resolution: resolution)
            return true
        } catch is CancellationError {
            session.clearApprovalResolution(id: id)
            return false
        } catch {
            session.clearApprovalResolution(id: id)
            controller.setConnectionStatus(.error(message: error.localizedDescription))
            if session.turnState.phase == .inProgress {
                session.failTurn(error.localizedDescription)
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

    private func startAllWorkspaceRuntimes() {
        for controller in workspaceControllers {
            guard let runtime = workspaceRuntimes[controller.workspace.canonicalPath] else {
                continue
            }

            scheduleRuntimeLifecycle(
                workspacePath: controller.workspace.canonicalPath,
                previousRuntime: nil,
                nextRuntime: runtime
            )
        }
    }

    private func startRuntime(_ runtime: any WorkspaceConversationRuntime, workspacePath: String) async {
        guard isActiveRuntime(runtime, for: workspacePath) else {
            await runtime.stop()
            return
        }

        do {
            try await runtime.start()
        } catch is CancellationError {
            return
        } catch {
            Self.logger.error("Workspace runtime start failed for \(workspacePath, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        guard isActiveRuntime(runtime, for: workspacePath) else {
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

        switch controller.connectionStatus {
        case .ready, .streaming:
            break
        case .connecting, .disconnected, .cancelling, .error:
            return false
        }

        if let threadID = selectedRoute?.threadID,
           selectedRoute?.workspacePath == controller.workspace.canonicalPath,
           controller.isAwaitingTurnStart(threadID: threadID) {
            return false
        }

        if let selectedThreadSummary,
           selectedThreadSummary.isArchived {
            return false
        }

        return selectedThreadSession?.turnState.phase != .inProgress
    }

    private func scheduleRuntimeLifecycle(
        workspacePath: String,
        previousRuntime: (any WorkspaceConversationRuntime)?,
        nextRuntime: (any WorkspaceConversationRuntime)?
    ) {
        runtimeLifecycleTasks[workspacePath]?.cancel()
        runtimeLifecycleTasks[workspacePath] = Task { [weak self] in
            await previousRuntime?.stop()

            guard let self, Task.isCancelled == false else {
                return
            }

            guard let nextRuntime else {
                return
            }

            await self.startRuntime(nextRuntime, workspacePath: workspacePath)
        }
    }

    private func isActiveRuntime(_ runtime: any WorkspaceConversationRuntime, for workspacePath: String) -> Bool {
        guard let activeRuntime = workspaceRuntimes[workspacePath] else {
            return false
        }

        return ObjectIdentifier(activeRuntime as AnyObject) == ObjectIdentifier(runtime as AnyObject)
    }

    private func runtime(for workspacePath: String) -> (any WorkspaceConversationRuntime)? {
        workspaceRuntimes[workspacePath]
    }

    private func workspaceController(for path: String) -> WorkspaceController? {
        workspaceControllers.first(where: { $0.workspace.canonicalPath == path })
    }

    private func preferredThreadID(for controller: WorkspaceController) -> String? {
        if let lastActiveThreadID = controller.lastActiveThreadID,
           controller.visibleThreadSummaries.contains(where: { $0.id == lastActiveThreadID }) {
            return lastActiveThreadID
        }

        return controller.visibleThreadSummaries.first?.id
    }

    private func updateWorkspaceRecord(_ workspace: WorkspaceRecord) {
        recentWorkspaces = Self.upsertingRecentWorkspace(workspace, into: recentWorkspaces)
        workspaceControllers.sort { lhs, rhs in
            let lhsIndex = recentWorkspaces.firstIndex(where: { $0.canonicalPath == lhs.workspace.canonicalPath }) ?? Int.max
            let rhsIndex = recentWorkspaces.firstIndex(where: { $0.canonicalPath == rhs.workspace.canonicalPath }) ?? Int.max
            return lhsIndex < rhsIndex
        }
    }

    private static func initialRoute(
        selectedWorkspacePath: String?,
        controllers: [WorkspaceController]
    ) -> WorkspaceThreadRoute? {
        let workspacePath = selectedWorkspacePath
            ?? controllers.first?.workspace.canonicalPath
        guard let workspacePath,
              let controller = controllers.first(where: { $0.workspace.canonicalPath == workspacePath }) else {
            return nil
        }

        return WorkspaceThreadRoute(
            workspacePath: workspacePath,
            threadID: controller.visibleThreadSummaries.first?.id
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
