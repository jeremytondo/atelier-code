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
    private(set) var branchPickerState: WorkspaceBranchPickerState?

    @ObservationIgnored private let preferencesStore: any AppPreferencesStore
    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let bridgeDiagnosticProvider: () -> StartupDiagnostic
    @ObservationIgnored private let gitService: any WorkspaceGitServing
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let runtimeFactory: @MainActor (WorkspaceController) -> any WorkspaceConversationRuntime
    @ObservationIgnored private var workspaceRuntimes: [String: any WorkspaceConversationRuntime]
    @ObservationIgnored private var runtimeLifecycleTasks: [String: Task<Void, Never>]
    @ObservationIgnored private var gitStatusRefreshTasks: [String: Task<Void, Never>]
    @ObservationIgnored private var branchPickerRefreshTask: Task<Void, Never>?

    init(
        preferencesStore: (any AppPreferencesStore)? = nil,
        fileManager: FileManager = .default,
        bridgeDiagnosticProvider: (() -> StartupDiagnostic)? = nil,
        gitService: (any WorkspaceGitServing)? = nil,
        now: @escaping () -> Date = Date.init,
        runtimeFactory: (@MainActor (WorkspaceController) -> any WorkspaceConversationRuntime)? = nil
    ) {
        let resolvedPreferencesStore = preferencesStore ?? UserDefaultsAppPreferencesStore()
        let resolvedBridgeDiagnosticProvider = bridgeDiagnosticProvider ?? { StartupDiagnostic.defaultBridgeDiagnostic() }
        let resolvedGitService = gitService ?? WorkspaceGitService()
        let resolvedRuntimeFactory = runtimeFactory ?? { WorkspaceBridgeRuntime(controller: $0) }

        self.preferencesStore = resolvedPreferencesStore
        self.fileManager = fileManager
        self.bridgeDiagnosticProvider = resolvedBridgeDiagnosticProvider
        self.gitService = resolvedGitService
        self.now = now
        self.runtimeFactory = resolvedRuntimeFactory
        self.workspaceRuntimes = [:]
        self.runtimeLifecycleTasks = [:]
        self.gitStatusRefreshTasks = [:]
        self.branchPickerRefreshTask = nil
        self.branchPickerState = nil

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
        branchPickerState = nil

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
              let conversationID = selectedRoute.conversationID else {
            return nil
        }

        return selectedWorkspaceController?.threadSession(for: conversationID)
    }

    var selectedThreadSummary: ThreadSummary? {
        guard let selectedRoute,
              let conversationID = selectedRoute.conversationID else {
            return nil
        }

        return selectedWorkspaceController?.threadSummary(for: conversationID)
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
                isPlaceholder: selectedWorkspaceGitStatusIsPlaceholder,
                isInteractive: selectedWorkspaceGitStatusIsInteractive
            )
        ]
    }

    var isSelectedWorkspaceBranchPickerPresented: Bool {
        guard let workspacePath = selectedWorkspaceController?.workspace.canonicalPath else {
            return false
        }

        return branchPickerState?.workspacePath == workspacePath
    }

    var selectedWorkspaceBranchPickerFilterText: String {
        guard isSelectedWorkspaceBranchPickerPresented else {
            return ""
        }

        return branchPickerState?.filterText ?? ""
    }

    var selectedWorkspaceBranchPickerFilteredBranches: [String] {
        guard isSelectedWorkspaceBranchPickerPresented else {
            return []
        }

        return branchPickerState?.filteredBranches ?? []
    }

    var selectedWorkspaceBranchPickerItems: [WorkspaceBranchPickerItem] {
        guard isSelectedWorkspaceBranchPickerPresented else {
            return []
        }

        return branchPickerState?.items ?? []
    }

    var selectedWorkspaceBranchPickerSelectedItemID: WorkspaceBranchPickerItem.ID? {
        guard isSelectedWorkspaceBranchPickerPresented else {
            return nil
        }

        return branchPickerState?.selectedItemID
    }

    var selectedWorkspaceBranchPickerCurrentBranchName: String? {
        return branchPickerState?.currentBranchName
    }

    var selectedWorkspaceBranchPickerErrorMessage: String? {
        guard isSelectedWorkspaceBranchPickerPresented else {
            return nil
        }

        return branchPickerState?.errorMessage
    }

    var isSelectedWorkspaceBranchPickerLoading: Bool {
        guard isSelectedWorkspaceBranchPickerPresented else {
            return false
        }

        return branchPickerState?.isLoading ?? false
    }

    var isSelectedWorkspaceBranchPickerPerformingAction: Bool {
        guard isSelectedWorkspaceBranchPickerPresented else {
            return false
        }

        return branchPickerState?.isPerformingAction ?? false
    }

    var canCreateSelectedWorkspaceBranchFromPicker: Bool {
        guard isSelectedWorkspaceBranchPickerPresented else {
            return false
        }

        guard let branchPickerState else {
            return false
        }

        return branchPickerState.canCreateBranch
    }

    func showSelectedWorkspaceBranchPicker() {
        guard selectedWorkspaceGitStatusIsInteractive else {
            return
        }

        guard isSelectedWorkspaceBranchPickerPresented == false else {
            return
        }

        presentSelectedWorkspaceBranchPicker()
    }

    func toggleSelectedWorkspaceBranchPicker() {
        if isSelectedWorkspaceBranchPickerPresented {
            dismissSelectedWorkspaceBranchPicker()
            return
        }

        showSelectedWorkspaceBranchPicker()
    }

    func dismissSelectedWorkspaceBranchPicker() {
        branchPickerRefreshTask?.cancel()
        branchPickerRefreshTask = nil
        branchPickerState = nil
    }

    func setSelectedWorkspaceBranchPickerFilterText(_ filterText: String) {
        guard isSelectedWorkspaceBranchPickerPresented else {
            return
        }

        guard var branchPickerState else {
            return
        }

        branchPickerState.setFilterText(filterText)
        self.branchPickerState = branchPickerState
    }

    func moveSelectedWorkspaceBranchPickerSelection(_ direction: WorkspaceBranchPickerSelectionDirection) {
        guard isSelectedWorkspaceBranchPickerPresented,
              var branchPickerState else {
            return
        }

        branchPickerState.moveSelection(direction)
        self.branchPickerState = branchPickerState
    }

    func selectBranchFromPicker(_ branchName: String) async {
        guard let branchPickerState,
              isSelectedWorkspaceBranchPickerPresented,
              branchPickerState.isLoading == false,
              branchPickerState.isPerformingAction == false else {
            return
        }

        if selectedWorkspaceBranchPickerCurrentBranchName == branchName {
            dismissSelectedWorkspaceBranchPicker()
            return
        }

        await performBranchPickerAction(named: branchName, createIfNeeded: false)
    }

    func submitSelectedWorkspaceBranchPicker() async {
        guard let selectedItem = branchPickerState?.selectedItem else {
            return
        }

        switch selectedItem {
        case .branch(let branchName):
            await selectBranchFromPicker(branchName)
        case .create(let branchName):
            await performBranchPickerAction(named: branchName, createIfNeeded: true)
        }
    }

    func createSelectedWorkspaceBranchFromPicker() async {
        guard let branchPickerState else {
            return
        }

        let branchName = branchPickerState.submittedBranchName
        guard branchName.isEmpty == false else {
            return
        }

        guard branchPickerState.exactMatchName == nil else {
            return
        }

        await performBranchPickerAction(named: branchName, createIfNeeded: true)
    }

    func activateWorkspace(at url: URL) {
        let workspace = WorkspaceRecord(url: url, lastOpenedAt: now())
        showConversations()

        if let controller = workspaceController(for: workspace.canonicalPath) {
            updateWorkspaceRecord(workspace)
            controller.markThreadSelected(controller.lastActiveConversationID)
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
        dismissSelectedWorkspaceBranchPicker()
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

        if branchPickerState?.workspacePath == canonicalPath {
            resetBranchPickerState(for: selectedRoute?.workspacePath)
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

    func applicationWindowDidBecomeKey() {
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
        let conversationID = preferredConversationID(for: controller)
        controller.markThreadSelected(conversationID)
        updateSelectedRoute(workspacePath: canonicalPath, conversationID: conversationID)
        startWorkspaceRuntimeIfNeeded(for: canonicalPath)
        persistPreferences()
    }

    func selectWorkspaceForNewThread(path: String) {
        let canonicalPath = WorkspaceRecord.canonicalizedPath(for: path)
        guard workspaceController(for: canonicalPath) != nil else {
            return
        }

        showConversations()
        updateSelectedRoute(workspacePath: canonicalPath, conversationID: nil)
        startWorkspaceRuntimeIfNeeded(for: canonicalPath)
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
        await openThread(
            workspacePath: workspacePath,
            conversationID: ConversationIdentity(threadID: threadID)
        )
    }

    @discardableResult
    func openThread(workspacePath: String, conversationID: ConversationIdentity) async -> Bool {
        let canonicalPath = WorkspaceRecord.canonicalizedPath(for: workspacePath)
        guard let controller = workspaceController(for: canonicalPath),
              let summary = controller.threadSummary(for: conversationID) else {
            return false
        }

        if controller.threadSession(for: conversationID) == nil, summary.isLocalOnly {
            removeCachedThread(workspacePath: canonicalPath, conversationID: conversationID)
            return false
        }

        do {
            showConversations()
            if controller.threadSession(for: conversationID) == nil {
                guard await ensureRuntimeReady(for: canonicalPath),
                      let runtime = runtime(for: canonicalPath) else {
                    return false
                }

                if summary.isArchived {
                    _ = try await runtime.readThreadAndWait(id: conversationID.threadID, includeTurns: true)
                } else {
                    _ = try await runtime.resumeThreadAndWait(id: conversationID.threadID)
                }
            }

            controller.markThreadSelected(conversationID)
            updateSelectedRoute(workspacePath: canonicalPath, conversationID: conversationID)
            persistPreferences()
            return true
        } catch is CancellationError {
            return false
        } catch {
            handleThreadOpenFailure(
                error,
                workspacePath: canonicalPath,
                conversationID: conversationID
            )
            return false
        }
    }

    @discardableResult
    func removeCachedThread(workspacePath: String, threadID: String) -> Bool {
        removeCachedThread(
            workspacePath: workspacePath,
            conversationID: ConversationIdentity(threadID: threadID)
        )
    }

    @discardableResult
    func removeCachedThread(workspacePath: String, conversationID: ConversationIdentity) -> Bool {
        let canonicalPath = WorkspaceRecord.canonicalizedPath(for: workspacePath)
        guard let controller = workspaceController(for: canonicalPath),
              controller.threadSummary(for: conversationID) != nil else {
            return false
        }

        controller.removeThread(for: conversationID)

        if selectedRoute?.workspacePath == canonicalPath,
           selectedRoute?.conversationID == conversationID {
            let nextConversationID = preferredConversationID(for: controller)
            controller.markThreadSelected(nextConversationID)
            updateSelectedRoute(workspacePath: canonicalPath, conversationID: nextConversationID)
        }

        persistPreferences()
        return true
    }

    @discardableResult
    func createThread() async -> Bool {
        guard let controller = selectedWorkspaceController else {
            return false
        }

        showConversations()
        controller.clearActiveThreadSession()
        updateSelectedRoute(workspacePath: controller.workspace.canonicalPath, conversationID: nil)
        startWorkspaceRuntimeIfNeeded(for: controller.workspace.canonicalPath)
        persistPreferences()
        return true
    }

    @discardableResult
    func forkSelectedThread() async -> Bool {
        guard let controller = selectedWorkspaceController,
              let selectedRoute,
              let conversationID = selectedRoute.conversationID else {
            return false
        }

        return await forkThread(workspacePath: controller.workspace.canonicalPath, conversationID: conversationID)
    }

    @discardableResult
    func forkThread(workspacePath: String, threadID: String) async -> Bool {
        await forkThread(
            workspacePath: workspacePath,
            conversationID: ConversationIdentity(threadID: threadID)
        )
    }

    @discardableResult
    func forkThread(workspacePath: String, conversationID: ConversationIdentity) async -> Bool {
        let canonicalPath = WorkspaceRecord.canonicalizedPath(for: workspacePath)
        guard let controller = workspaceController(for: canonicalPath),
              let runtime = runtime(for: canonicalPath) else {
            return false
        }

        do {
            let session = try await runtime.forkThreadAndWait(id: conversationID.threadID)
            controller.markThreadSelected(session.conversationID)
            updateSelectedRoute(workspacePath: canonicalPath, conversationID: session.conversationID)
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
              let conversationID = selectedRoute.conversationID else {
            return false
        }

        return await archiveThread(workspacePath: controller.workspace.canonicalPath, conversationID: conversationID)
    }

    @discardableResult
    func archiveThread(workspacePath: String, threadID: String) async -> Bool {
        await archiveThread(
            workspacePath: workspacePath,
            conversationID: ConversationIdentity(threadID: threadID)
        )
    }

    @discardableResult
    func archiveThread(workspacePath: String, conversationID: ConversationIdentity) async -> Bool {
        let canonicalPath = WorkspaceRecord.canonicalizedPath(for: workspacePath)
        guard let controller = workspaceController(for: canonicalPath),
              let runtime = runtime(for: canonicalPath) else {
            return false
        }

        do {
            try await runtime.archiveThread(id: conversationID.threadID)
            controller.setThreadArchived(true, for: conversationID.threadID, providerID: conversationID.providerID)
            controller.markThreadActivity(
                id: conversationID.threadID,
                providerID: conversationID.providerID,
                at: now(),
                isRunning: false,
                hasUnreadActivity: false
            )
            if selectedRoute?.workspacePath == canonicalPath, selectedRoute?.conversationID == conversationID, controller.isShowingArchivedThreads {
                controller.markThreadSelected(conversationID)
            } else if selectedRoute?.workspacePath == canonicalPath, selectedRoute?.conversationID == conversationID {
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
              let conversationID = selectedRoute.conversationID else {
            return false
        }

        return await unarchiveThread(workspacePath: controller.workspace.canonicalPath, conversationID: conversationID)
    }

    @discardableResult
    func unarchiveThread(workspacePath: String, threadID: String) async -> Bool {
        await unarchiveThread(
            workspacePath: workspacePath,
            conversationID: ConversationIdentity(threadID: threadID)
        )
    }

    @discardableResult
    func unarchiveThread(workspacePath: String, conversationID: ConversationIdentity) async -> Bool {
        let canonicalPath = WorkspaceRecord.canonicalizedPath(for: workspacePath)
        guard let controller = workspaceController(for: canonicalPath),
              let runtime = runtime(for: canonicalPath) else {
            return false
        }

        do {
            let session = try await runtime.unarchiveThreadAndWait(id: conversationID.threadID)
            controller.markThreadSelected(session.conversationID)
            updateSelectedRoute(workspacePath: canonicalPath, conversationID: session.conversationID)
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
        await renameThread(
            workspacePath: workspacePath,
            conversationID: ConversationIdentity(threadID: threadID),
            title: title
        )
    }

    @discardableResult
    func renameThread(workspacePath: String, conversationID: ConversationIdentity, title: String) async -> Bool {
        let canonicalPath = WorkspaceRecord.canonicalizedPath(for: workspacePath)
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let resolvedTitle = trimmedTitle.nilIfEmpty,
              let controller = workspaceController(for: canonicalPath),
              let runtime = runtime(for: canonicalPath) else {
            return false
        }

        do {
            try await runtime.renameThread(id: conversationID.threadID, title: resolvedTitle)
            controller.updateThreadSummary(for: conversationID) { summary in
                summary.title = resolvedTitle
            }
            controller.threadSession(for: conversationID)?.updateThreadIdentity(
                providerID: conversationID.providerID,
                id: conversationID.threadID,
                title: resolvedTitle
            )
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
              let conversationID = selectedRoute.conversationID,
              let runtime = runtime(for: controller.workspace.canonicalPath) else {
            return false
        }

        do {
            let session = try await runtime.rollbackThreadAndWait(id: conversationID.threadID, numTurns: 1)
            controller.markThreadSelected(session.conversationID)
            updateSelectedRoute(workspacePath: controller.workspace.canonicalPath, conversationID: session.conversationID)
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
               let conversationID = selectedRoute.conversationID,
               controller.threadSummary(for: conversationID)?.isArchived == true {
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
              let conversationID = selectedRoute.conversationID,
              let session = selectedThreadSession,
              session.turnState.phase == .inProgress,
              controller.currentTurnID(
                  for: conversationID.threadID,
                  providerID: conversationID.providerID
              ) != nil else {
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
            let conversationID: ConversationIdentity

            if let existingConversationID = selectedRoute?.conversationID {
                if selectedThreadSummary?.isArchived == true {
                    return false
                }

                if controller.threadSession(for: existingConversationID) == nil {
                    _ = try await runtime.resumeThreadAndWait(id: existingConversationID.threadID)
                }

                conversationID = existingConversationID
            } else {
                let session = try await runtime.startThreadAndWait(
                    title: nil,
                    configuration: defaultThreadConfiguration(for: controller)
                )
                conversationID = session.conversationID
                controller.markThreadSelected(conversationID)
                updateSelectedRoute(
                    workspacePath: controller.workspace.canonicalPath,
                    conversationID: conversationID
                )
                persistPreferences()
            }

            controller.setThreadSidebarVisibility(
                true,
                for: conversationID.threadID,
                providerID: conversationID.providerID
            )
            controller.markThreadActivity(
                id: conversationID.threadID,
                providerID: conversationID.providerID,
                at: now(),
                previewText: trimmedPrompt,
                hasUnreadActivity: false,
                lastErrorMessage: nil
            )
            controller.updateThreadSummary(for: conversationID) { summary in
                let trimmedTitle = summary.title.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmedTitle.isEmpty || trimmedTitle == summary.threadID || trimmedTitle == "New Conversation" || trimmedTitle == "Thread" {
                    summary.title = Self.defaultDraftThreadTitle(from: trimmedPrompt)
                }
            }
            controller.setAwaitingTurnStart(
                true,
                for: conversationID.threadID,
                providerID: conversationID.providerID
            )
            try await runtime.startTurn(
                threadID: conversationID.threadID,
                prompt: trimmedPrompt,
                configuration: defaultTurnConfiguration(for: controller)
            )
            return true
        } catch is CancellationError {
            if let conversationID = selectedRoute?.conversationID {
                controller.setAwaitingTurnStart(
                    false,
                    for: conversationID.threadID,
                    providerID: conversationID.providerID
                )
            }
            return false
        } catch {
            if let conversationID = selectedRoute?.conversationID {
                controller.setAwaitingTurnStart(
                    false,
                    for: conversationID.threadID,
                    providerID: conversationID.providerID
                )
                controller.setCurrentTurnID(
                    nil,
                    for: conversationID.threadID,
                    providerID: conversationID.providerID
                )
                controller.threadSession(for: conversationID)?.failTurn(error.localizedDescription)
            }
            controller.setConnectionStatus(.error(message: error.localizedDescription))
            return false
        }
    }

    func cancelActiveTurn() async {
        guard canCancelTurn,
              let controller = selectedWorkspaceController,
              let conversationID = selectedRoute?.conversationID,
              let runtime = runtime(for: controller.workspace.canonicalPath) else {
            return
        }

        do {
            try await runtime.cancelTurn(
                threadID: conversationID.threadID,
                reason: "User cancelled the current turn."
            )
        } catch is CancellationError {
            return
        } catch {
            controller.setConnectionStatus(.error(message: error.localizedDescription))
            controller.threadSession(for: conversationID)?.failTurn(error.localizedDescription)
        }
    }

    @discardableResult
    func resolveApproval(id: String, resolution: ApprovalResolution) async -> Bool {
        guard let controller = selectedWorkspaceController,
              let conversationID = selectedRoute?.conversationID,
              let session = controller.threadSession(for: conversationID),
              session.beginApprovalResolution(id: id, resolution: resolution),
              let runtime = runtime(for: controller.workspace.canonicalPath) else {
            return false
        }

        do {
            try await runtime.resolveApproval(
                threadID: conversationID.threadID,
                id: id,
                resolution: resolution
            )
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

    private var selectedWorkspaceGitStatusIsInteractive: Bool {
        guard let controller = selectedWorkspaceController else {
            return false
        }

        switch controller.gitStatus {
        case .branch, .detachedHead:
            return true
        case .unavailable:
            return false
        }
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

        refreshGitSnapshot(for: workspace)
    }

    private func updateSelectedRoute(
        workspacePath: String,
        conversationID: ConversationIdentity? = nil,
        providerID: String? = nil,
        threadID: String? = nil
    ) {
        resetBranchPickerState(for: workspacePath)
        let resolvedConversationID = conversationID
            ?? threadID.map { threadID in
                let resolvedProviderID = providerID
                    ?? workspaceController(for: workspacePath)?.threadSummaries.first(where: { $0.threadID == threadID })?.providerID
                    ?? workspaceController(for: workspacePath)?.threadSessionsByID.keys.first(where: { $0.threadID == threadID })?.providerID
                    ?? BridgeProviderIdentifier.codex
                return ConversationIdentity(providerID: resolvedProviderID, threadID: threadID)
            }
        selectedRoute = WorkspaceThreadRoute(
            workspacePath: workspacePath,
            conversationID: resolvedConversationID
        )
        lastSelectedWorkspacePath = workspacePath

        guard let controller = workspaceController(for: workspacePath) else {
            return
        }

        refreshGitSnapshot(for: controller.workspace)
    }

    private func refreshGitSnapshot(for workspace: WorkspaceRecord) {
        let workspacePath = workspace.canonicalPath
        gitStatusRefreshTasks[workspacePath]?.cancel()

        gitStatusRefreshTasks[workspacePath] = Task { [weak self] in
            guard let self else {
                return
            }

            let snapshot = await gitService.snapshot(for: workspacePath)
            guard Task.isCancelled == false,
                  let controller = workspaceController(for: workspacePath) else {
                return
            }

            controller.setGitSnapshot(snapshot)

        if case .unavailable = snapshot.status,
               branchPickerState?.workspacePath == workspacePath {
                dismissSelectedWorkspaceBranchPicker()
            }
        }
    }

    private func presentSelectedWorkspaceBranchPicker() {
        guard let controller = selectedWorkspaceController,
              selectedWorkspaceGitStatusIsInteractive else {
            return
        }

        let workspacePath = controller.workspace.canonicalPath
        let currentBranchName = Self.currentBranchName(from: controller.gitStatus)
        branchPickerState = WorkspaceBranchPickerState(
            workspacePath: workspacePath,
            sessionID: UUID(),
            branchNames: Self.normalizedBranchNames(
                controller.localGitBranches,
                currentBranchName: currentBranchName
            ),
            currentBranchName: currentBranchName,
            filterText: "",
            selectedItemID: nil,
            errorMessage: nil,
            isLoading: controller.localGitBranches.isEmpty,
            isPerformingAction: false
        )

        branchPickerState?.selectDefaultItem()

        reloadSelectedWorkspaceBranchPicker()
    }

    private func reloadSelectedWorkspaceBranchPicker() {
        guard let branchPickerState else {
            return
        }

        let workspacePath = branchPickerState.workspacePath
        let sessionID = branchPickerState.sessionID

        branchPickerRefreshTask?.cancel()
        branchPickerRefreshTask = Task { [weak self] in
            guard let self else {
                return
            }

            let snapshot = await gitService.snapshot(for: workspacePath)
            guard Task.isCancelled == false,
                  let controller = workspaceController(for: workspacePath),
                  var currentBranchPickerState = self.branchPickerState,
                  currentBranchPickerState.sessionID == sessionID,
                  currentBranchPickerState.workspacePath == workspacePath else {
                return
            }

            controller.setGitSnapshot(snapshot)

            if case .unavailable = snapshot.status {
                dismissSelectedWorkspaceBranchPicker()
                return
            }

            currentBranchPickerState.branchNames = Self.normalizedBranchNames(
                snapshot.localBranches,
                currentBranchName: Self.currentBranchName(from: snapshot.status)
            )
            currentBranchPickerState.currentBranchName = Self.currentBranchName(from: snapshot.status)
            currentBranchPickerState.isLoading = false
            currentBranchPickerState.syncSelection()
            self.branchPickerState = currentBranchPickerState
        }
    }

    private func performBranchPickerAction(named branchName: String, createIfNeeded: Bool) async {
        guard let controller = selectedWorkspaceController,
              var currentBranchPickerState = branchPickerState,
              currentBranchPickerState.workspacePath == controller.workspace.canonicalPath,
              currentBranchPickerState.isLoading == false,
              currentBranchPickerState.isPerformingAction == false else {
            return
        }

        let workspacePath = currentBranchPickerState.workspacePath
        let sessionID = currentBranchPickerState.sessionID
        currentBranchPickerState.errorMessage = nil
        currentBranchPickerState.isPerformingAction = true
        self.branchPickerState = currentBranchPickerState

        do {
            let snapshot: WorkspaceGitSnapshot
            if createIfNeeded {
                snapshot = try await gitService.createAndSwitchToBranch(named: branchName, for: workspacePath)
            } else {
                snapshot = try await gitService.switchToBranch(named: branchName, for: workspacePath)
            }

            guard let refreshedController = workspaceController(for: workspacePath),
                  var currentBranchPickerState = self.branchPickerState,
                  currentBranchPickerState.sessionID == sessionID,
                  currentBranchPickerState.workspacePath == workspacePath else {
                dismissSelectedWorkspaceBranchPicker()
                return
            }

            refreshedController.setGitSnapshot(snapshot)
            currentBranchPickerState.branchNames = Self.normalizedBranchNames(
                snapshot.localBranches,
                currentBranchName: Self.currentBranchName(from: snapshot.status)
            )
            currentBranchPickerState.currentBranchName = Self.currentBranchName(from: snapshot.status)
            currentBranchPickerState.isPerformingAction = false
            self.branchPickerState = currentBranchPickerState
            dismissSelectedWorkspaceBranchPicker()
            refreshGitSnapshot(for: refreshedController.workspace)
        } catch let error as WorkspaceGitBranchManagerError {
            guard var currentBranchPickerState = self.branchPickerState,
                  currentBranchPickerState.sessionID == sessionID,
                  currentBranchPickerState.workspacePath == workspacePath else {
                return
            }

            currentBranchPickerState.isPerformingAction = false
            currentBranchPickerState.errorMessage = error.message
            self.branchPickerState = currentBranchPickerState
        } catch {
            guard var currentBranchPickerState = self.branchPickerState,
                  currentBranchPickerState.sessionID == sessionID,
                  currentBranchPickerState.workspacePath == workspacePath else {
                return
            }

            currentBranchPickerState.isPerformingAction = false
            currentBranchPickerState.errorMessage = error.localizedDescription
            self.branchPickerState = currentBranchPickerState
        }
    }

    private func resetBranchPickerState(for workspacePath: String?) {
        guard branchPickerState?.workspacePath != workspacePath else {
            return
        }

        dismissSelectedWorkspaceBranchPicker()
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

    private func defaultThreadConfiguration(for controller: WorkspaceController) -> BridgeConversationConfiguration {
        BridgeConversationConfiguration(
            cwd: controller.workspace.canonicalPath,
            model: effectiveComposerModelID,
            reasoningEffort: effectiveComposerReasoningEffort.bridgeValue,
            sandboxPolicy: SandboxPolicy.workspaceWrite.rawValue,
            approvalPolicy: ApprovalPolicy.onRequest.rawValue
        )
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

        if let conversationID = selectedRoute?.conversationID,
           selectedRoute?.workspacePath == controller.workspace.canonicalPath,
           controller.isAwaitingTurnStart(
               threadID: conversationID.threadID,
               providerID: conversationID.providerID
           ) {
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

    private func handleThreadOpenFailure(
        _ error: Error,
        workspacePath: String,
        conversationID: ConversationIdentity
    ) {
        guard let controller = workspaceController(for: workspacePath) else {
            return
        }

        controller.updateThreadSummary(for: conversationID) { summary in
            summary.isRunning = false
            summary.hasUnreadActivity = false
            summary.lastErrorMessage = error.localizedDescription
            summary.isStale = true
        }

        if selectedRoute?.workspacePath == workspacePath,
           selectedRoute?.conversationID == conversationID {
            let nextConversationID = controller.visibleThreadSummaries
                .first(where: { $0.conversationID != conversationID })?
                .conversationID
            controller.markThreadSelected(nextConversationID)
            updateSelectedRoute(workspacePath: workspacePath, conversationID: nextConversationID)
            persistPreferences()
        }

        recoverWorkspaceConnectionStatusIfNeeded(for: controller)
    }

    private func recoverWorkspaceConnectionStatusIfNeeded(for controller: WorkspaceController) {
        guard case .error = controller.connectionStatus else {
            return
        }

        let status: ConnectionStatus = controller.hasRunningThreads ? .streaming : .ready
        controller.setConnectionStatus(status)
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

    private func preferredConversationID(for controller: WorkspaceController) -> ConversationIdentity? {
        Self.preferredConversationID(for: controller)
    }

    private static func preferredConversationID(for controller: WorkspaceController) -> ConversationIdentity? {
        if let lastActiveConversationID = controller.lastActiveConversationID,
           controller.visibleThreadSummaries.contains(where: { $0.conversationID == lastActiveConversationID }) {
            return lastActiveConversationID
        }

        return controller.visibleThreadSummaries.first?.conversationID
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
            conversationID: preferExistingThreadSelection ? preferredConversationID(for: controller) : nil
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

    private static func normalizedBranchNames(_ branchNames: [String], currentBranchName: String?) -> [String] {
        var seenBranchNames = Set<String>()
        var normalizedBranchNames = branchNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
            .filter { seenBranchNames.insert($0).inserted }

        if let currentBranchName = currentBranchName?.trimmingCharacters(in: .whitespacesAndNewlines),
           currentBranchName.isEmpty == false,
           seenBranchNames.insert(currentBranchName).inserted {
            normalizedBranchNames.append(currentBranchName)
        }

        normalizedBranchNames.sort { lhs, rhs in
            lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }

        return normalizedBranchNames
    }

    private static func currentBranchName(from status: WorkspaceGitStatus) -> String? {
        guard case .branch(let branchName) = status else {
            return nil
        }

        return branchName
    }

    private static func normalizeWorkspaceStates(
        _ workspaceStates: [PersistedWorkspaceState]
    ) -> [String: PersistedWorkspaceState] {
        var normalizedStates: [String: PersistedWorkspaceState] = [:]

        for workspaceState in workspaceStates {
            let canonicalPath = WorkspaceRecord.canonicalizedPath(for: workspaceState.workspacePath)
            let normalizedThreadSummaries = workspaceState.threadSummaries.reduce(into: [ConversationIdentity: PersistedThreadSummary]()) {
                partialResult,
                summary in
                partialResult[summary.conversationID] = summary
            }
            let normalizedPinnedThreadIDs = Array(Set(workspaceState.pinnedThreadIDs)).sorted()
            let normalizedLastActiveConversationID: ConversationIdentity?
            if let conversationID = workspaceState.lastActiveConversationID {
                let normalizedThreadID = conversationID.threadID
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                normalizedLastActiveConversationID = normalizedThreadID.isEmpty
                    ? nil
                    : ConversationIdentity(
                        providerID: conversationID.providerID,
                        threadID: normalizedThreadID
                    )
            } else {
                normalizedLastActiveConversationID = nil
            }

            normalizedStates[canonicalPath] = PersistedWorkspaceState(
                workspacePath: canonicalPath,
                isExpanded: workspaceState.isExpanded,
                isShowingAllVisibleThreads: workspaceState.isShowingAllVisibleThreads,
                lastActiveConversationID: normalizedLastActiveConversationID,
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

struct WorkspaceBranchPickerState: Equatable, Sendable {
    let workspacePath: String
    let sessionID: UUID
    var branchNames: [String]
    var currentBranchName: String?
    var filterText: String
    var selectedItemID: WorkspaceBranchPickerItem.ID?
    var errorMessage: String?
    var isLoading: Bool
    var isPerformingAction: Bool

    var normalizedFilterText: String {
        filterText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var submittedBranchName: String {
        normalizedFilterText
    }

    var exactMatchName: String? {
        let branchName = normalizedFilterText
        guard branchName.isEmpty == false else {
            return nil
        }

        return branchNames.first { candidate in
            candidate == branchName
        }
    }

    var filteredBranches: [String] {
        let filterText = normalizedFilterText
        guard filterText.isEmpty == false else {
            return branchNames
        }

        return branchNames.filter { branchName in
            branchName.localizedCaseInsensitiveContains(filterText)
        }
    }

    var canCreateBranch: Bool {
        isLoading == false &&
        isPerformingAction == false &&
        submittedBranchName.isEmpty == false &&
        exactMatchName == nil
    }

    var items: [WorkspaceBranchPickerItem] {
        var items = filteredBranches.map(WorkspaceBranchPickerItem.branch)

        if canCreateBranch {
            items.append(.create(submittedBranchName))
        }

        return items
    }

    var selectedItem: WorkspaceBranchPickerItem? {
        guard let selectedItemID else {
            return items.first(where: { $0.id == defaultSelectedItemID })
        }

        return items.first(where: { $0.id == selectedItemID })
    }

    mutating func setFilterText(_ filterText: String) {
        self.filterText = filterText
        errorMessage = nil
        selectDefaultItem()
    }

    mutating func moveSelection(_ direction: WorkspaceBranchPickerSelectionDirection) {
        let items = items
        guard items.isEmpty == false else {
            selectedItemID = nil
            return
        }

        guard let selectedItemID,
              let selectedIndex = items.firstIndex(where: { $0.id == selectedItemID }) else {
            self.selectedItemID = defaultSelectedItemID
            return
        }

        let nextIndex: Int
        switch direction {
        case .up:
            nextIndex = max(selectedIndex - 1, 0)
        case .down:
            nextIndex = min(selectedIndex + 1, items.count - 1)
        }

        self.selectedItemID = items[nextIndex].id
    }

    mutating func selectDefaultItem() {
        selectedItemID = defaultSelectedItemID
    }

    mutating func syncSelection() {
        let items = items
        guard items.isEmpty == false else {
            selectedItemID = nil
            return
        }

        guard let selectedItemID,
              items.contains(where: { $0.id == selectedItemID }) else {
            self.selectedItemID = defaultSelectedItemID
            return
        }
    }

    private var defaultSelectedItemID: WorkspaceBranchPickerItem.ID? {
        let items = items
        guard items.isEmpty == false else {
            return nil
        }

        if normalizedFilterText.isEmpty,
           let currentBranchName,
           let currentBranchItem = items.first(where: {
               if case .branch(let branchName) = $0 {
                   return branchName == currentBranchName
               }

               return false
           }) {
            return currentBranchItem.id
        }

        return items.first?.id
    }
}

enum WorkspaceBranchPickerSelectionDirection: Sendable {
    case up
    case down
}

enum WorkspaceBranchPickerItem: Identifiable, Equatable, Sendable {
    case branch(String)
    case create(String)

    var id: String {
        switch self {
        case .branch(let branchName):
            return "branch:\(branchName)"
        case .create(let branchName):
            return "create:\(branchName)"
        }
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
    let isInteractive: Bool
}
