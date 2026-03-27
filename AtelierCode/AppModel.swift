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
    private(set) var appearancePreference: AppAppearancePreference
    private(set) var composerModelID: String?
    private(set) var composerReasoningEffort: ComposerReasoningEffort
    private(set) var startupDiagnostics: [StartupDiagnostic]
    private(set) var workspaceControllers: [WorkspaceController]
    private(set) var selectedRoute: WorkspaceThreadRoute?
    private(set) var primaryView: AppPrimaryView
    private(set) var selectedSettingsSection: SettingsSection

    @ObservationIgnored private let preferencesStore: any AppPreferencesStore
    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let bridgeDiagnosticProvider: () -> StartupDiagnostic
    @ObservationIgnored private let gitStatusProvider: any WorkspaceGitStatusProviding
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let runtimeFactory: @MainActor (WorkspaceController) -> any WorkspaceConversationRuntime
    @ObservationIgnored private var workspaceRuntimes: [String: any WorkspaceConversationRuntime]
    @ObservationIgnored private var runtimeLifecycleTasks: [String: Task<Void, Never>]
    @ObservationIgnored private var gitStatusRefreshTasks: [String: Task<Void, Never>]

    init(
        preferencesStore: (any AppPreferencesStore)? = nil,
        fileManager: FileManager = .default,
        bridgeDiagnosticProvider: (() -> StartupDiagnostic)? = nil,
        gitStatusProvider: (any WorkspaceGitStatusProviding)? = nil,
        now: @escaping () -> Date = Date.init,
        runtimeFactory: (@MainActor (WorkspaceController) -> any WorkspaceConversationRuntime)? = nil
    ) {
        let resolvedPreferencesStore = preferencesStore ?? UserDefaultsAppPreferencesStore()
        let resolvedBridgeDiagnosticProvider = bridgeDiagnosticProvider ?? { StartupDiagnostic.defaultBridgeDiagnostic() }
        let resolvedGitStatusProvider = gitStatusProvider ?? WorkspaceGitStatusProvider()
        let resolvedRuntimeFactory = runtimeFactory ?? { WorkspaceBridgeRuntime(controller: $0) }

        self.preferencesStore = resolvedPreferencesStore
        self.fileManager = fileManager
        self.bridgeDiagnosticProvider = resolvedBridgeDiagnosticProvider
        self.gitStatusProvider = resolvedGitStatusProvider
        self.now = now
        self.runtimeFactory = resolvedRuntimeFactory
        self.workspaceRuntimes = [:]
        self.runtimeLifecycleTasks = [:]
        self.gitStatusRefreshTasks = [:]

        let loadedSnapshot = try? resolvedPreferencesStore.loadSnapshot()
        let normalizedRecentWorkspaces = Self.normalizeRecentWorkspaces(loadedSnapshot?.recentWorkspaces ?? [])
        let normalizedWorkspaceStatesByPath = Self.normalizeWorkspaceStates(loadedSnapshot?.workspaceStates ?? [])
        let selectedPath = loadedSnapshot?.lastSelectedWorkspacePath.map(WorkspaceRecord.canonicalizedPath(for:))
        let codexOverridePath = loadedSnapshot?.codexPathOverride
        let appearancePreference = loadedSnapshot?.appearancePreference ?? .system
        let composerModelID = loadedSnapshot?.composerModelID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let composerReasoningEffort = ComposerReasoningEffort(storedValue: loadedSnapshot?.composerReasoningEffort.rawValue)

        recentWorkspaces = []
        lastSelectedWorkspacePath = nil
        codexPathOverride = codexOverridePath
        self.appearancePreference = appearancePreference
        self.composerModelID = composerModelID
        self.composerReasoningEffort = composerReasoningEffort
        startupDiagnostics = []
        workspaceControllers = []
        selectedRoute = nil
        primaryView = .conversations
        selectedSettingsSection = .general

        if let codexOverridePath {
            appendStartupDiagnostic(Self.codexOverrideDiagnostic(path: codexOverridePath, fileManager: fileManager))
        }

        for workspace in normalizedRecentWorkspaces {
            guard Self.workspaceExists(atPath: workspace.canonicalPath, fileManager: fileManager) else {
                appendStartupDiagnostic(.restoredWorkspaceMissing(path: workspace.canonicalPath))
                continue
            }

            let controller = WorkspaceController(workspace: workspace)
            if let persistedState = normalizedWorkspaceStatesByPath[workspace.canonicalPath] {
                controller.restorePersistedState(persistedState)
            }
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
            controllers: workspaceControllers,
            preferExistingThreadSelection: false
        )

        appendStartupDiagnostic(resolvedBridgeDiagnosticProvider())
        installWorkspacePersistenceHandlers()

        if let loadedSnapshot, loadedSnapshot != snapshot {
            persistPreferences()
        }

        startInitiallySelectedWorkspaceRuntime()
        preloadInitiallyExpandedWorkspaceThreadLists()
        refreshSelectedWorkspaceGitStatus()
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
            codexPathOverride: codexPathOverride,
            appearancePreference: appearancePreference,
            composerModelID: composerModelID,
            composerReasoningEffort: composerReasoningEffort,
            workspaceStates: workspaceControllers.map(\.persistedState)
        )
    }

    var availableComposerModels: [ComposerModelOption] {
        selectedWorkspaceController?.availableModels ?? []
    }

    var defaultComposerModelOption: ComposerModelOption? {
        availableComposerModels.first(where: \.isDefault) ?? availableComposerModels.first
    }

    var effectiveComposerModelID: String? {
        explicitComposerModelOption?.id
    }

    var effectiveComposerReasoningEffort: ComposerReasoningEffort {
        guard composerReasoningEffort != .appDefault else {
            return .appDefault
        }

        guard let selectedComposerModelOption,
              selectedComposerModelOption.supportedReasoningEfforts.contains(composerReasoningEffort) else {
            return .appDefault
        }

        return composerReasoningEffort
    }

    private var explicitComposerModelOption: ComposerModelOption? {
        guard let composerModelID else {
            return nil
        }

        return availableComposerModels.first(where: { $0.id == composerModelID })
    }

    var selectedComposerModelOption: ComposerModelOption? {
        explicitComposerModelOption ?? defaultComposerModelOption
    }

    var composerModelTitle: String {
        selectedComposerModelOption?.title ?? "Default Model"
    }

    var availableComposerReasoningEfforts: [ComposerReasoningEffort] {
        guard let selectedComposerModelOption else {
            return [.appDefault]
        }

        return [.appDefault] + selectedComposerModelOption.supportedReasoningEfforts
    }

    var composerReasoningEffortTitle: String {
        if effectiveComposerReasoningEffort == .appDefault {
            return selectedComposerModelOption?.defaultReasoningEffort?.title ?? composerReasoningEffort.title
        }

        return effectiveComposerReasoningEffort.title
    }

    var detailStatusItems: [DetailStatusItem] {
        [
            DetailStatusItem(
                id: "git-reference",
                systemImage: "arrow.triangle.branch",
                text: selectedWorkspaceGitStatusText,
                isPlaceholder: selectedWorkspaceGitStatusIsPlaceholder
            )
        ]
    }

    func activateWorkspace(at url: URL) {
        let workspace = WorkspaceRecord(url: url, lastOpenedAt: now())
        showConversations()

        if let controller = workspaceController(for: workspace.canonicalPath) {
            updateWorkspaceRecord(workspace)
            controller.markThreadSelected(controller.lastActiveThreadID)
            selectWorkspace(path: workspace.canonicalPath)
            persistPreferences()
            return
        }

        let controller = WorkspaceController(workspace: workspace)
        configurePersistenceHandler(for: controller)
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
        showConversations()
        selectedRoute = nil
        lastSelectedWorkspacePath = nil
        persistPreferences()
    }

    func removeWorkspace(path: String) {
        let canonicalPath = WorkspaceRecord.canonicalizedPath(for: path)
        let previousRuntime = workspaceRuntimes.removeValue(forKey: canonicalPath)

        gitStatusRefreshTasks[canonicalPath]?.cancel()
        gitStatusRefreshTasks.removeValue(forKey: canonicalPath)
        runtimeLifecycleTasks[canonicalPath]?.cancel()
        runtimeLifecycleTasks.removeValue(forKey: canonicalPath)
        workspaceControllers.removeAll { $0.workspace.canonicalPath == canonicalPath }
        recentWorkspaces.removeAll { $0.canonicalPath == canonicalPath }

        if selectedRoute?.workspacePath == canonicalPath {
            let nextWorkspacePath = recentWorkspaces.first?.canonicalPath
            selectedRoute = Self.initialRoute(
                selectedWorkspacePath: nextWorkspacePath,
                controllers: workspaceControllers,
                preferExistingThreadSelection: true
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

    func setAppearancePreference(_ preference: AppAppearancePreference) {
        guard appearancePreference != preference else {
            return
        }

        appearancePreference = preference
        persistPreferences()
    }

    func setComposerModelID(_ modelID: String?) {
        let normalizedModelID = modelID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        guard composerModelID != normalizedModelID else {
            return
        }

        composerModelID = normalizedModelID
        persistPreferences()
    }

    func setComposerReasoningEffort(_ effort: ComposerReasoningEffort) {
        guard composerReasoningEffort != effort else {
            return
        }

        composerReasoningEffort = effort
        persistPreferences()
    }

    func showSettings(section: SettingsSection = .general) {
        selectedSettingsSection = section
        primaryView = .settings
    }

    func applicationDidBecomeActive() {
        refreshSelectedWorkspaceGitStatus()
    }

    func selectSettingsSection(_ section: SettingsSection) {
        selectedSettingsSection = section
        primaryView = .settings
    }

    func showConversations() {
        primaryView = .conversations
    }

    func selectWorkspace(path: String) {
        let canonicalPath = WorkspaceRecord.canonicalizedPath(for: path)
        guard let controller = workspaceController(for: canonicalPath) else {
            return
        }

        showConversations()
        let threadID = preferredThreadID(for: controller)
        controller.markThreadSelected(threadID)
        selectedRoute = WorkspaceThreadRoute(
            workspacePath: canonicalPath,
            threadID: threadID
        )
        lastSelectedWorkspacePath = canonicalPath
        startWorkspaceRuntimeIfNeeded(for: canonicalPath)
        refreshGitStatus(for: controller.workspace)
        persistPreferences()
    }

    func selectWorkspaceForNewThread(path: String) {
        let canonicalPath = WorkspaceRecord.canonicalizedPath(for: path)
        guard let controller = workspaceController(for: canonicalPath) else {
            return
        }

        showConversations()
        selectedRoute = WorkspaceThreadRoute(
            workspacePath: canonicalPath,
            threadID: nil
        )
        lastSelectedWorkspacePath = canonicalPath
        startWorkspaceRuntimeIfNeeded(for: canonicalPath)
        refreshGitStatus(for: controller.workspace)
        persistPreferences()
    }

    @discardableResult
    func prepareWorkspaceForBrowsing(path: String) async -> Bool {
        let canonicalPath = WorkspaceRecord.canonicalizedPath(for: path)
        guard let controller = workspaceController(for: canonicalPath),
              await ensureRuntimeReady(for: canonicalPath),
              let runtime = runtime(for: canonicalPath) else {
            return false
        }

        do {
            try await runtime.listThreads(archived: controller.isShowingArchivedThreads)
            return true
        } catch is CancellationError {
            return false
        } catch {
            controller.setConnectionStatus(.error(message: error.localizedDescription))
            return false
        }
    }

    @discardableResult
    func openThread(workspacePath: String, threadID: String) async -> Bool {
        let canonicalPath = WorkspaceRecord.canonicalizedPath(for: workspacePath)
        guard let controller = workspaceController(for: canonicalPath),
              let summary = controller.threadSummary(id: threadID) else {
            return false
        }

        do {
            showConversations()
            if controller.threadSession(id: threadID) == nil {
                guard await ensureRuntimeReady(for: canonicalPath),
                      let runtime = runtime(for: canonicalPath) else {
                    return false
                }

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
        guard let controller = selectedWorkspaceController else {
            return false
        }

        showConversations()
        controller.clearActiveThreadSession()
        selectedRoute = WorkspaceThreadRoute(
            workspacePath: controller.workspace.canonicalPath,
            threadID: nil
        )
        lastSelectedWorkspacePath = controller.workspace.canonicalPath
        startWorkspaceRuntimeIfNeeded(for: controller.workspace.canonicalPath)
        persistPreferences()
        return true
    }

    @discardableResult
    func forkSelectedThread() async -> Bool {
        guard let controller = selectedWorkspaceController,
              let selectedRoute,
              let threadID = selectedRoute.threadID else {
            return false
        }

        return await forkThread(workspacePath: controller.workspace.canonicalPath, threadID: threadID)
    }

    @discardableResult
    func forkThread(workspacePath: String, threadID: String) async -> Bool {
        let canonicalPath = WorkspaceRecord.canonicalizedPath(for: workspacePath)
        guard let controller = workspaceController(for: canonicalPath),
              let runtime = runtime(for: canonicalPath) else {
            return false
        }

        do {
            let session = try await runtime.forkThreadAndWait(id: threadID)
            controller.markThreadSelected(session.threadID)
            self.selectedRoute = WorkspaceThreadRoute(
                workspacePath: canonicalPath,
                threadID: session.threadID
            )
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
    func archiveSelectedThread() async -> Bool {
        guard let controller = selectedWorkspaceController,
              let selectedRoute,
              let threadID = selectedRoute.threadID else {
            return false
        }

        return await archiveThread(workspacePath: controller.workspace.canonicalPath, threadID: threadID)
    }

    @discardableResult
    func archiveThread(workspacePath: String, threadID: String) async -> Bool {
        let canonicalPath = WorkspaceRecord.canonicalizedPath(for: workspacePath)
        guard let controller = workspaceController(for: canonicalPath),
              let runtime = runtime(for: canonicalPath) else {
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
            if selectedRoute?.workspacePath == canonicalPath, selectedRoute?.threadID == threadID, controller.isShowingArchivedThreads {
                controller.markThreadSelected(threadID)
            } else if selectedRoute?.workspacePath == canonicalPath, selectedRoute?.threadID == threadID {
                selectWorkspace(path: canonicalPath)
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
              let threadID = selectedRoute.threadID else {
            return false
        }

        return await unarchiveThread(workspacePath: controller.workspace.canonicalPath, threadID: threadID)
    }

    @discardableResult
    func unarchiveThread(workspacePath: String, threadID: String) async -> Bool {
        let canonicalPath = WorkspaceRecord.canonicalizedPath(for: workspacePath)
        guard let controller = workspaceController(for: canonicalPath),
              let runtime = runtime(for: canonicalPath) else {
            return false
        }

        do {
            let session = try await runtime.unarchiveThreadAndWait(id: threadID)
            controller.markThreadSelected(session.threadID)
            self.selectedRoute = WorkspaceThreadRoute(
                workspacePath: canonicalPath,
                threadID: session.threadID
            )
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
    func renameThread(workspacePath: String, threadID: String, title: String) async -> Bool {
        let canonicalPath = WorkspaceRecord.canonicalizedPath(for: workspacePath)
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let resolvedTitle = trimmedTitle.nilIfEmpty,
              let controller = workspaceController(for: canonicalPath),
              let runtime = runtime(for: canonicalPath) else {
            return false
        }

        do {
            try await runtime.renameThread(id: threadID, title: resolvedTitle)
            controller.updateThreadSummary(id: threadID) { summary in
                summary.title = resolvedTitle
            }
            controller.threadSession(id: threadID)?.updateThreadIdentity(id: threadID, title: resolvedTitle)
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

            controller.setThreadSidebarVisibility(true, for: threadID)
            controller.markThreadActivity(
                id: threadID,
                at: now(),
                previewText: trimmedPrompt,
                hasUnreadActivity: false,
                lastErrorMessage: nil
            )
            controller.updateThreadSummary(id: threadID) { summary in
                let trimmedTitle = summary.title.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmedTitle.isEmpty || trimmedTitle == summary.id || trimmedTitle == "New Conversation" || trimmedTitle == "Thread" {
                    summary.title = Self.defaultDraftThreadTitle(from: trimmedPrompt)
                }
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

    private var selectedWorkspaceGitStatusText: String {
        guard let controller = selectedWorkspaceController else {
            return "No workspace selected"
        }

        switch controller.gitStatus {
        case .branch(let branchName):
            return branchName
        case .detachedHead(let commitSHA):
            return commitSHA
        case .unavailable:
            return "No Git branch"
        }
    }

    private var selectedWorkspaceGitStatusIsPlaceholder: Bool {
        guard let controller = selectedWorkspaceController else {
            return true
        }

        if case .unavailable = controller.gitStatus {
            return true
        }

        return false
    }

    private func installWorkspacePersistenceHandlers() {
        for controller in workspaceControllers {
            configurePersistenceHandler(for: controller)
        }
    }

    private func configurePersistenceHandler(for controller: WorkspaceController) {
        controller.persistableStateDidChange = { [weak self] in
            self?.persistPreferences()
        }
    }

    private func appendStartupDiagnostic(_ diagnostic: StartupDiagnostic) {
        guard diagnostic.severity != .info else {
            return
        }

        startupDiagnostics.append(diagnostic)
    }

    private func startInitiallySelectedWorkspaceRuntime() {
        guard let workspacePath = selectedRoute?.workspacePath ?? lastSelectedWorkspacePath else {
            return
        }

        startWorkspaceRuntimeIfNeeded(for: workspacePath)
    }

    private func preloadInitiallyExpandedWorkspaceThreadLists() {
        let selectedWorkspacePath = selectedRoute?.workspacePath ?? lastSelectedWorkspacePath
        let workspacePathsToPreload = workspaceControllers
            .filter { controller in
                controller.isExpanded &&
                controller.workspace.canonicalPath != selectedWorkspacePath
            }
            .map(\.workspace.canonicalPath)

        for workspacePath in workspacePathsToPreload {
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                _ = await prepareWorkspaceForBrowsing(path: workspacePath)
            }
        }
    }

    private func refreshSelectedWorkspaceGitStatus() {
        guard let workspace = selectedWorkspaceController?.workspace else {
            return
        }

        refreshGitStatus(for: workspace)
    }

    private func refreshGitStatus(for workspace: WorkspaceRecord) {
        let workspacePath = workspace.canonicalPath
        gitStatusRefreshTasks[workspacePath]?.cancel()

        gitStatusRefreshTasks[workspacePath] = Task { [weak self] in
            guard let self else {
                return
            }

            let gitStatus = await gitStatusProvider.gitStatus(for: workspacePath)
            guard Task.isCancelled == false,
                  let controller = workspaceController(for: workspacePath) else {
                return
            }

            controller.setGitStatus(gitStatus)
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
            model: effectiveComposerModelID,
            reasoningEffort: effectiveComposerReasoningEffort.bridgeValue,
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

    private func startWorkspaceRuntimeIfNeeded(for workspacePath: String) {
        guard let controller = workspaceController(for: workspacePath),
              let runtime = runtime(for: workspacePath) else {
            return
        }

        guard controller.connectionStatus == .disconnected else {
            return
        }

        scheduleRuntimeLifecycle(
            workspacePath: workspacePath,
            previousRuntime: nil,
            nextRuntime: runtime
        )
    }

    private func ensureRuntimeReady(for workspacePath: String) async -> Bool {
        guard let controller = workspaceController(for: workspacePath) else {
            return false
        }

        switch controller.connectionStatus {
        case .ready, .streaming, .cancelling:
            return true
        case .error:
            return false
        case .disconnected:
            startWorkspaceRuntimeIfNeeded(for: workspacePath)
            await runtimeLifecycleTasks[workspacePath]?.value
        case .connecting:
            await runtimeLifecycleTasks[workspacePath]?.value
        }

        switch controller.connectionStatus {
        case .ready, .streaming, .cancelling:
            return true
        case .connecting, .disconnected, .error:
            return false
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
        Self.preferredThreadID(for: controller)
    }

    private static func preferredThreadID(for controller: WorkspaceController) -> String? {
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
        controllers: [WorkspaceController],
        preferExistingThreadSelection: Bool
    ) -> WorkspaceThreadRoute? {
        let workspacePath = selectedWorkspacePath
            ?? controllers.first?.workspace.canonicalPath
        guard let workspacePath,
              let controller = controllers.first(where: { $0.workspace.canonicalPath == workspacePath }) else {
            return nil
        }

        return WorkspaceThreadRoute(
            workspacePath: workspacePath,
            threadID: preferExistingThreadSelection ? preferredThreadID(for: controller) : nil
        )
    }

    private static func defaultDraftThreadTitle(from prompt: String) -> String {
        let firstLine = prompt
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return firstLine?.isEmpty == false ? firstLine! : "New Conversation"
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

    private static func normalizeWorkspaceStates(
        _ workspaceStates: [PersistedWorkspaceState]
    ) -> [String: PersistedWorkspaceState] {
        var normalizedStates: [String: PersistedWorkspaceState] = [:]

        for workspaceState in workspaceStates {
            let canonicalPath = WorkspaceRecord.canonicalizedPath(for: workspaceState.workspacePath)
            let normalizedThreadSummaries = workspaceState.threadSummaries.reduce(into: [String: PersistedThreadSummary]()) {
                partialResult,
                summary in
                partialResult[summary.id] = summary
            }
            let normalizedPinnedThreadIDs = Array(Set(workspaceState.pinnedThreadIDs)).sorted()
            let normalizedLastActiveThreadID = workspaceState.lastActiveThreadID?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedLastActiveThreadID = normalizedLastActiveThreadID?.isEmpty == false
                ? normalizedLastActiveThreadID
                : nil

            normalizedStates[canonicalPath] = PersistedWorkspaceState(
                workspacePath: canonicalPath,
                isExpanded: workspaceState.isExpanded,
                isShowingAllVisibleThreads: workspaceState.isShowingAllVisibleThreads,
                lastActiveThreadID: resolvedLastActiveThreadID,
                pinnedThreadIDs: normalizedPinnedThreadIDs,
                threadSummaries: normalizedThreadSummaries.values.sorted { lhs, rhs in
                    if lhs.updatedAt == rhs.updatedAt {
                        return lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
                    }

                    return lhs.updatedAt > rhs.updatedAt
                },
                lastSuccessfulActiveListAt: workspaceState.cachedThreadList.lastSuccessfulActiveListAt,
                lastSuccessfulArchivedListAt: workspaceState.cachedThreadList.lastSuccessfulArchivedListAt
            )
        }

        return normalizedStates
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

struct DetailStatusItem: Identifiable, Equatable, Sendable {
    let id: String
    let systemImage: String
    let text: String
    let isPlaceholder: Bool
}
