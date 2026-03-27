import Foundation
import Observation

@MainActor
@Observable
final class WorkspaceController {
    static let collapsedVisibleThreadLimit = 5

    private(set) var workspace: WorkspaceRecord
    private(set) var bridgeLifecycleState: BridgeLifecycleState
    private(set) var connectionStatus: ConnectionStatus
    private(set) var threadSummaries: [ThreadSummary] {
        didSet {
            persistableStateDidChange?()
        }
    }
    private(set) var bridgeEnvironmentDiagnostics: WorkspaceBridgeEnvironmentDiagnostics?
    private(set) var providerExecutablePath: String?
    private(set) var threadListSyncState: ThreadListSyncState
    private(set) var lastSuccessfulThreadListAt: Date? {
        didSet {
            persistableStateDidChange?()
        }
    }
    private(set) var authState: AuthState
    private(set) var pendingLogin: PendingLogin?
    private(set) var rateLimitState: RateLimitState?
    private(set) var availableModels: [ComposerModelOption]
    private(set) var gitStatus: WorkspaceGitStatus
    private(set) var localGitBranches: [String]
    private(set) var threadSessionsByID: [String: ThreadSession]
    private(set) var lastActiveThreadID: String? {
        didSet {
            persistableStateDidChange?()
        }
    }
    private(set) var isShowingArchivedThreads: Bool
    private(set) var isExpanded: Bool {
        didSet {
            persistableStateDidChange?()
        }
    }
    private(set) var isShowingAllVisibleThreads: Bool {
        didSet {
            persistableStateDidChange?()
        }
    }

    @ObservationIgnored private let threadListRepository: WorkspaceThreadListRepository
    @ObservationIgnored private var awaitingTurnStartThreadIDs: Set<String>
    @ObservationIgnored private var currentTurnIDsByThreadID: [String: String]
    @ObservationIgnored var persistableStateDidChange: (() -> Void)?

    init(workspace: WorkspaceRecord) {
        self.workspace = workspace
        self.bridgeLifecycleState = .idle
        self.connectionStatus = .disconnected
        self.threadSummaries = []
        self.bridgeEnvironmentDiagnostics = nil
        self.providerExecutablePath = nil
        self.threadListSyncState = .idle
        self.lastSuccessfulThreadListAt = nil
        self.authState = .unknown
        self.pendingLogin = nil
        self.rateLimitState = nil
        self.availableModels = []
        self.gitStatus = .unavailable(.lookupFailed)
        self.localGitBranches = []
        self.threadSessionsByID = [:]
        self.lastActiveThreadID = nil
        self.isShowingArchivedThreads = false
        self.isExpanded = true
        self.isShowingAllVisibleThreads = false
        self.threadListRepository = WorkspaceThreadListRepository()
        self.awaitingTurnStartThreadIDs = []
        self.currentTurnIDsByThreadID = [:]
    }

    var activeThreadSession: ThreadSession? {
        guard let lastActiveThreadID else {
            return nil
        }

        return threadSessionsByID[lastActiveThreadID]
    }

    var isAwaitingTurnStart: Bool {
        guard let lastActiveThreadID else {
            return false
        }

        return awaitingTurnStartThreadIDs.contains(lastActiveThreadID)
    }

    var visibleThreadSummaries: [ThreadSummary] {
        threadSummaries.filter { summary in
            summary.isVisibleInSidebar && summary.isArchived == isShowingArchivedThreads
        }
    }

    var displayedThreadSummaries: [ThreadSummary] {
        guard isShowingAllVisibleThreads else {
            return Array(visibleThreadSummaries.prefix(Self.collapsedVisibleThreadLimit))
        }

        return visibleThreadSummaries
    }

    var canShowMoreVisibleThreads: Bool {
        visibleThreadSummaries.count > displayedThreadSummaries.count
    }

    var canShowLessVisibleThreads: Bool {
        isShowingAllVisibleThreads && visibleThreadSummaries.count > Self.collapsedVisibleThreadLimit
    }

    var hasRunningThreads: Bool {
        threadSummaries.contains(where: \.isRunning)
    }

    var bridgeEnvironmentWarningMessage: String? {
        bridgeEnvironmentDiagnostics?.warningMessage
    }

    var persistedState: PersistedWorkspaceState {
        PersistedWorkspaceState(
            workspacePath: workspace.canonicalPath,
            uiState: PersistedWorkspaceUIState(
                isExpanded: isExpanded,
                isShowingAllVisibleThreads: isShowingAllVisibleThreads,
                lastActiveThreadID: lastActiveThreadID
            ),
            cachedThreadList: threadListRepository.persistedState()
        )
    }

    func activate(workspace: WorkspaceRecord) {
        self.workspace = workspace
        gitStatus = .unavailable(.lookupFailed)
        resetWorkspace()
    }

    func resetWorkspace() {
        bridgeLifecycleState = .idle
        connectionStatus = .disconnected
        bridgeEnvironmentDiagnostics = nil
        providerExecutablePath = nil
        threadListRepository.reset()
        authState = .unknown
        pendingLogin = nil
        rateLimitState = nil
        availableModels = []
        gitStatus = .unavailable(.lookupFailed)
        localGitBranches = []
        threadSessionsByID.removeAll()
        lastActiveThreadID = nil
        isShowingArchivedThreads = false
        isExpanded = true
        isShowingAllVisibleThreads = false
        awaitingTurnStartThreadIDs.removeAll()
        currentTurnIDsByThreadID.removeAll()
        refreshThreadListProjection()
    }

    func setBridgeLifecycleState(_ state: BridgeLifecycleState) {
        bridgeLifecycleState = state
    }

    func setConnectionStatus(_ status: ConnectionStatus) {
        connectionStatus = status
    }

    func setBridgeEnvironmentDiagnostics(_ diagnostics: WorkspaceBridgeEnvironmentDiagnostics?) {
        bridgeEnvironmentDiagnostics = diagnostics
    }

    func setProviderExecutablePath(_ executablePath: String?) {
        providerExecutablePath = executablePath
    }

    func setAuthState(_ authState: AuthState) {
        self.authState = authState
    }

    func setPendingLogin(_ pendingLogin: PendingLogin?) {
        self.pendingLogin = pendingLogin
    }

    func clearPendingLogin() {
        pendingLogin = nil
    }

    func setRateLimitState(_ rateLimitState: RateLimitState?) {
        self.rateLimitState = rateLimitState
    }

    func setAvailableModels(_ availableModels: [ComposerModelOption]) {
        self.availableModels = availableModels
    }

    func setGitStatus(_ gitStatus: WorkspaceGitStatus) {
        self.gitStatus = gitStatus
    }

    func setLocalGitBranches(_ localGitBranches: [String]) {
        self.localGitBranches = localGitBranches
    }

    func setGitSnapshot(_ snapshot: WorkspaceGitSnapshot) {
        gitStatus = snapshot.status
        localGitBranches = snapshot.localBranches
    }

    func setShowingArchivedThreads(_ isShowingArchivedThreads: Bool) {
        self.isShowingArchivedThreads = isShowingArchivedThreads
        refreshThreadListProjection()
    }

    func setExpanded(_ isExpanded: Bool) {
        self.isExpanded = isExpanded
    }

    func setShowingAllVisibleThreads(_ isShowingAllVisibleThreads: Bool) {
        self.isShowingAllVisibleThreads = isShowingAllVisibleThreads
    }

    func restorePersistedState(_ persistedState: PersistedWorkspaceState) {
        threadListRepository.restorePersistedState(persistedState.cachedThreadList)
        refreshThreadListProjection()

        isExpanded = persistedState.uiState.isExpanded
        isShowingAllVisibleThreads = persistedState.uiState.isShowingAllVisibleThreads
        lastActiveThreadID = persistedState.uiState.lastActiveThreadID.flatMap { threadID in
            threadListRepository.threadSummary(id: threadID) != nil ? threadID : nil
        }
    }

    func beginThreadListSync(archived: Bool) {
        threadListRepository.setSyncing(archived: archived)
        refreshThreadListProjection()
    }

    func markThreadListSyncFailed(archived: Bool) {
        threadListRepository.setSyncFailed(archived: archived)
        refreshThreadListProjection()
    }

    func replaceThreadList(
        _ threadSummaries: [ThreadSummary],
        archived: Bool = false,
        listedAt: Date = .now
    ) {
        threadListRepository.replaceThreadList(
            threadSummaries,
            archived: archived,
            listedAt: listedAt,
            selectedThreadID: lastActiveThreadID,
            loadedThreadIDs: Set(threadSessionsByID.keys)
        )
        refreshThreadListProjection()
    }

    func upsertThreadSummary(_ threadSummary: ThreadSummary) {
        threadListRepository.upsertThreadSummary(threadSummary, clearsStale: true)
        refreshThreadListProjection()
    }

    func updateThreadSummary(id: String, clearsStale: Bool = false, mutate: (inout ThreadSummary) -> Void) {
        threadListRepository.updateThreadSummary(id: id, clearsStale: clearsStale, mutate: mutate)
        refreshThreadListProjection()
    }

    func threadSummary(id: String) -> ThreadSummary? {
        threadListRepository.threadSummary(id: id)
    }

    func markThreadSelected(_ id: String?) {
        lastActiveThreadID = id

        guard let id else {
            return
        }

        threadListRepository.updateThreadSummary(id: id) { summary in
            summary.hasUnreadActivity = false
        }
        refreshThreadListProjection()
    }

    func threadSession(id: String) -> ThreadSession? {
        threadSessionsByID[id]
    }

    @discardableResult
    func openThread(id: String, title: String, isVisibleInSidebar: Bool = true) -> ThreadSession {
        let existingSummary = threadSummary(id: id)
        let session = threadSessionsByID[id] ?? ThreadSession(threadID: id, title: title)
        session.startThread(id: id, title: title)
        threadSessionsByID[id] = session
        upsertThreadSummary(
            ThreadSummary(
                id: id,
                title: title,
                previewText: existingSummary?.previewText ?? "",
                updatedAt: existingSummary?.updatedAt ?? .now,
                isVisibleInSidebar: existingSummary?.isVisibleInSidebar ?? isVisibleInSidebar,
                isArchived: existingSummary?.isArchived ?? false,
                isRunning: existingSummary?.isRunning ?? false,
                hasUnreadActivity: false,
                lastErrorMessage: existingSummary?.lastErrorMessage
            )
        )
        markThreadSelected(id)
        return session
    }

    @discardableResult
    func resumeThread(
        id: String,
        title: String,
        messages: [ConversationMessage] = []
    ) -> ThreadSession {
        let existingSummary = threadSummary(id: id)
        let session = threadSessionsByID[id] ?? ThreadSession(threadID: id, title: title)
        session.resumeThread(id: id, title: title, messages: messages)
        threadSessionsByID[id] = session
        upsertThreadSummary(
            ThreadSummary(
                id: id,
                title: title,
                previewText: messages.last?.text ?? existingSummary?.previewText ?? "",
                updatedAt: existingSummary?.updatedAt ?? .now,
                isVisibleInSidebar: existingSummary?.isVisibleInSidebar ?? true,
                isArchived: existingSummary?.isArchived ?? false,
                isRunning: existingSummary?.isRunning ?? false,
                hasUnreadActivity: false,
                lastErrorMessage: existingSummary?.lastErrorMessage
            )
        )
        markThreadSelected(id)
        return session
    }

    @discardableResult
    func ensureThreadSession(id: String, title: String, markSelected: Bool = false) -> ThreadSession {
        if let session = threadSessionsByID[id] {
            session.updateThreadIdentity(id: id, title: title)
            if markSelected {
                markThreadSelected(id)
            }
            return session
        }

        let session = ThreadSession(threadID: id, title: title)
        threadSessionsByID[id] = session
        if markSelected {
            markThreadSelected(id)
        }
        return session
    }

    @discardableResult
    func ensureActiveThreadSession(id: String, title: String) -> ThreadSession {
        ensureThreadSession(id: id, title: title, markSelected: true)
    }

    func clearActiveThreadSession() {
        lastActiveThreadID = nil
    }

    func clearThreadSession(id: String) {
        threadSessionsByID.removeValue(forKey: id)
        awaitingTurnStartThreadIDs.remove(id)
        currentTurnIDsByThreadID.removeValue(forKey: id)

        if lastActiveThreadID == id {
            lastActiveThreadID = nil
        }
    }

    func setAwaitingTurnStart(_ isAwaitingTurnStart: Bool, for threadID: String? = nil) {
        let resolvedThreadID = threadID ?? lastActiveThreadID
        guard let resolvedThreadID else {
            return
        }

        if isAwaitingTurnStart {
            awaitingTurnStartThreadIDs.insert(resolvedThreadID)
        } else {
            awaitingTurnStartThreadIDs.remove(resolvedThreadID)
        }

        updateThreadSummary(id: resolvedThreadID) { summary in
            summary.isRunning = isAwaitingTurnStart || currentTurnIDsByThreadID[resolvedThreadID] != nil
            if isAwaitingTurnStart {
                summary.updatedAt = .now
            }
        }
    }

    func isAwaitingTurnStart(threadID: String) -> Bool {
        awaitingTurnStartThreadIDs.contains(threadID)
    }

    func setCurrentTurnID(_ turnID: String?, for threadID: String) {
        if let turnID {
            currentTurnIDsByThreadID[threadID] = turnID
        } else {
            currentTurnIDsByThreadID.removeValue(forKey: threadID)
        }

        updateThreadSummary(id: threadID) { summary in
            summary.isRunning = turnID != nil || awaitingTurnStartThreadIDs.contains(threadID)
            if turnID != nil {
                summary.updatedAt = .now
            }
        }
    }

    func currentTurnID(for threadID: String) -> String? {
        currentTurnIDsByThreadID[threadID]
    }

    func setThreadRunning(_ isRunning: Bool, for threadID: String, at date: Date = .now) {
        updateThreadSummary(id: threadID) { summary in
            summary.isRunning = isRunning
            summary.updatedAt = date
        }
    }

    func setThreadArchived(_ isArchived: Bool, for threadID: String) {
        updateThreadSummary(id: threadID, clearsStale: true) { summary in
            summary.isArchived = isArchived
            summary.updatedAt = .now
        }
    }

    func setThreadSidebarVisibility(_ isVisibleInSidebar: Bool, for threadID: String) {
        let fallbackTitle = threadSession(id: threadID)?.title ?? "New Conversation"
        let defaultSummary = isVisibleInSidebar
            ? ThreadSummary(
                id: threadID,
                title: fallbackTitle,
                previewText: "",
                updatedAt: .now,
                isVisibleInSidebar: true
            )
            : nil

        threadListRepository.updateThreadSummary(
            id: threadID,
            defaultSummary: defaultSummary,
            clearsStale: isVisibleInSidebar
        ) { summary in
            summary.isVisibleInSidebar = isVisibleInSidebar
        }
        refreshThreadListProjection()
    }

    func markThreadActivity(
        id: String,
        at date: Date = .now,
        previewText: String? = nil,
        isRunning: Bool? = nil,
        hasUnreadActivity: Bool? = nil,
        lastErrorMessage: String? = nil
    ) {
        updateThreadSummary(id: id, clearsStale: true) { summary in
            summary.updatedAt = date
            if let previewText, previewText.isEmpty == false {
                summary.previewText = previewText
            }
            if let isRunning {
                summary.isRunning = isRunning
            }
            if let hasUnreadActivity {
                summary.hasUnreadActivity = hasUnreadActivity
            }
            summary.lastErrorMessage = lastErrorMessage
        }
    }

    private func refreshThreadListProjection() {
        threadSummaries = threadListRepository.threadSummaries
        threadListSyncState = threadListRepository.syncState(for: isShowingArchivedThreads)
        lastSuccessfulThreadListAt = threadListRepository.lastSuccessfulListAt(for: isShowingArchivedThreads)
    }
}
