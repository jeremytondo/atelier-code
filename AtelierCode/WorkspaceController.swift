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
    private(set) var availableProviders: [ProviderSummaryState]
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
    private(set) var threadSessionsByID: [ConversationIdentity: ThreadSession]
    private(set) var lastActiveConversationID: ConversationIdentity? {
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
    @ObservationIgnored private var awaitingTurnStartThreadIDs: Set<ConversationIdentity>
    @ObservationIgnored private var currentTurnIDsByThreadID: [ConversationIdentity: String]
    @ObservationIgnored var persistableStateDidChange: (() -> Void)?

    init(workspace: WorkspaceRecord) {
        self.workspace = workspace
        self.bridgeLifecycleState = .idle
        self.connectionStatus = .disconnected
        self.threadSummaries = []
        self.bridgeEnvironmentDiagnostics = nil
        self.providerExecutablePath = nil
        self.availableProviders = []
        self.threadListSyncState = .idle
        self.lastSuccessfulThreadListAt = nil
        self.authState = .unknown
        self.pendingLogin = nil
        self.rateLimitState = nil
        self.availableModels = []
        self.gitStatus = .unavailable(.lookupFailed)
        self.localGitBranches = []
        self.threadSessionsByID = [:]
        self.lastActiveConversationID = nil
        self.isShowingArchivedThreads = false
        self.isExpanded = true
        self.isShowingAllVisibleThreads = false
        self.threadListRepository = WorkspaceThreadListRepository()
        self.awaitingTurnStartThreadIDs = []
        self.currentTurnIDsByThreadID = [:]
    }

    var lastActiveProviderID: String? {
        lastActiveConversationID?.providerID
    }

    var lastActiveThreadID: String? {
        lastActiveConversationID?.threadID
    }

    var activeThreadSession: ThreadSession? {
        guard let lastActiveConversationID else {
            return nil
        }

        return threadSessionsByID[lastActiveConversationID]
    }

    var isAwaitingTurnStart: Bool {
        guard let lastActiveConversationID else {
            return false
        }

        return awaitingTurnStartThreadIDs.contains(lastActiveConversationID)
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
                lastActiveConversationID: lastActiveConversationID
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
        availableProviders = []
        threadListRepository.reset()
        authState = .unknown
        pendingLogin = nil
        rateLimitState = nil
        availableModels = []
        gitStatus = .unavailable(.lookupFailed)
        localGitBranches = []
        threadSessionsByID.removeAll()
        lastActiveConversationID = nil
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

    func setAvailableProviders(_ availableProviders: [ProviderSummaryState]) {
        self.availableProviders = availableProviders
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
        lastActiveConversationID = persistedState.uiState.lastActiveConversationID.flatMap { conversationID in
            threadListRepository.threadSummary(for: conversationID) != nil ? conversationID : nil
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

    func completeThreadListSync(archived: Bool, listedAt: Date = .now) {
        threadListRepository.markListSuccessful(archived: archived, listedAt: listedAt)
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
            selectedConversationID: lastActiveConversationID,
            loadedConversationIDs: Set(threadSessionsByID.keys)
        )
        refreshThreadListProjection()
    }

    func upsertThreadSummary(_ threadSummary: ThreadSummary) {
        threadListRepository.upsertThreadSummary(threadSummary, clearsStale: true)
        refreshThreadListProjection()
    }

    func updateThreadSummary(
        id: String,
        providerID: String = BridgeProviderIdentifier.codex,
        clearsStale: Bool = false,
        mutate: (inout ThreadSummary) -> Void
    ) {
        threadListRepository.updateThreadSummary(
            id: id,
            providerID: providerID,
            clearsStale: clearsStale,
            mutate: mutate
        )
        refreshThreadListProjection()
    }

    func updateThreadSummary(
        for identity: ConversationIdentity,
        clearsStale: Bool = false,
        mutate: (inout ThreadSummary) -> Void
    ) {
        threadListRepository.updateThreadSummary(
            for: identity,
            clearsStale: clearsStale,
            mutate: mutate
        )
        refreshThreadListProjection()
    }

    func threadSummary(id: String, providerID: String = BridgeProviderIdentifier.codex) -> ThreadSummary? {
        threadListRepository.threadSummary(id: id, providerID: providerID)
    }

    func threadSummary(for identity: ConversationIdentity) -> ThreadSummary? {
        threadListRepository.threadSummary(for: identity)
    }

    func markThreadSelected(_ id: String?, providerID: String = BridgeProviderIdentifier.codex) {
        markThreadSelected(id.map { ConversationIdentity(providerID: providerID, threadID: $0) })
    }

    func markThreadSelected(_ identity: ConversationIdentity?) {
        lastActiveConversationID = identity

        guard let identity else {
            return
        }

        threadListRepository.updateThreadSummary(for: identity) { summary in
            summary.hasUnreadActivity = false
        }
        refreshThreadListProjection()
    }

    func threadSession(id: String, providerID: String = BridgeProviderIdentifier.codex) -> ThreadSession? {
        threadSession(for: ConversationIdentity(providerID: providerID, threadID: id))
    }

    func threadSession(for identity: ConversationIdentity) -> ThreadSession? {
        threadSessionsByID[identity]
    }

    @discardableResult
    func openThread(
        id: String,
        providerID: String = BridgeProviderIdentifier.codex,
        title: String,
        isVisibleInSidebar: Bool = true
    ) -> ThreadSession {
        let identity = ConversationIdentity(providerID: providerID, threadID: id)
        let existingSummary = threadSummary(for: identity)
        let session = threadSessionsByID[identity] ?? ThreadSession(providerID: providerID, threadID: id, title: title)
        session.startThread(providerID: providerID, id: id, title: title)
        threadSessionsByID[identity] = session
        upsertThreadSummary(
            ThreadSummary(
                id: id,
                providerID: providerID,
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
        markThreadSelected(identity)
        return session
    }

    @discardableResult
    func resumeThread(
        id: String,
        providerID: String = BridgeProviderIdentifier.codex,
        title: String,
        messages: [ConversationMessage] = []
    ) -> ThreadSession {
        let identity = ConversationIdentity(providerID: providerID, threadID: id)
        let existingSummary = threadSummary(for: identity)
        let session = threadSessionsByID[identity] ?? ThreadSession(providerID: providerID, threadID: id, title: title)
        session.resumeThread(providerID: providerID, id: id, title: title, messages: messages)
        threadSessionsByID[identity] = session
        upsertThreadSummary(
            ThreadSummary(
                id: id,
                providerID: providerID,
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
        markThreadSelected(identity)
        return session
    }

    @discardableResult
    func ensureThreadSession(
        id: String,
        providerID: String = BridgeProviderIdentifier.codex,
        title: String,
        markSelected: Bool = false
    ) -> ThreadSession {
        let identity = ConversationIdentity(providerID: providerID, threadID: id)
        if let session = threadSessionsByID[identity] {
            session.updateThreadIdentity(providerID: providerID, id: id, title: title)
            if markSelected {
                markThreadSelected(identity)
            }
            return session
        }

        let session = ThreadSession(providerID: providerID, threadID: id, title: title)
        threadSessionsByID[identity] = session
        if markSelected {
            markThreadSelected(identity)
        }
        return session
    }

    @discardableResult
    func ensureActiveThreadSession(id: String, providerID: String = BridgeProviderIdentifier.codex, title: String) -> ThreadSession {
        ensureThreadSession(id: id, providerID: providerID, title: title, markSelected: true)
    }

    func clearActiveThreadSession() {
        lastActiveConversationID = nil
    }

    func clearThreadSession(id: String, providerID: String = BridgeProviderIdentifier.codex) {
        clearThreadSession(for: ConversationIdentity(providerID: providerID, threadID: id))
    }

    func clearThreadSession(for identity: ConversationIdentity) {
        threadSessionsByID.removeValue(forKey: identity)
        awaitingTurnStartThreadIDs.remove(identity)
        currentTurnIDsByThreadID.removeValue(forKey: identity)

        if lastActiveConversationID == identity {
            lastActiveConversationID = nil
        }
    }

    func removeThread(id: String, providerID: String = BridgeProviderIdentifier.codex) {
        removeThread(for: ConversationIdentity(providerID: providerID, threadID: id))
    }

    func removeThread(for identity: ConversationIdentity) {
        clearThreadSession(for: identity)
        threadListRepository.removeThreadSummary(for: identity)
        refreshThreadListProjection()
    }

    func setAwaitingTurnStart(
        _ isAwaitingTurnStart: Bool,
        for threadID: String? = nil,
        providerID: String = BridgeProviderIdentifier.codex
    ) {
        let resolvedConversationID = threadID.map {
            ConversationIdentity(providerID: providerID, threadID: $0)
        } ?? lastActiveConversationID
        guard let resolvedConversationID else {
            return
        }

        if isAwaitingTurnStart {
            awaitingTurnStartThreadIDs.insert(resolvedConversationID)
        } else {
            awaitingTurnStartThreadIDs.remove(resolvedConversationID)
        }

        updateThreadSummary(for: resolvedConversationID) { summary in
            summary.isRunning = isAwaitingTurnStart || currentTurnIDsByThreadID[resolvedConversationID] != nil
            if isAwaitingTurnStart {
                summary.updatedAt = .now
            }
        }
    }

    func isAwaitingTurnStart(threadID: String, providerID: String = BridgeProviderIdentifier.codex) -> Bool {
        awaitingTurnStartThreadIDs.contains(ConversationIdentity(providerID: providerID, threadID: threadID))
    }

    func setCurrentTurnID(
        _ turnID: String?,
        for threadID: String,
        providerID: String = BridgeProviderIdentifier.codex
    ) {
        let identity = ConversationIdentity(providerID: providerID, threadID: threadID)
        if let turnID {
            currentTurnIDsByThreadID[identity] = turnID
        } else {
            currentTurnIDsByThreadID.removeValue(forKey: identity)
        }

        updateThreadSummary(for: identity) { summary in
            summary.isRunning = turnID != nil || awaitingTurnStartThreadIDs.contains(identity)
            if turnID != nil {
                summary.updatedAt = .now
            }
        }
    }

    func currentTurnID(for threadID: String, providerID: String = BridgeProviderIdentifier.codex) -> String? {
        currentTurnIDsByThreadID[ConversationIdentity(providerID: providerID, threadID: threadID)]
    }

    func setThreadRunning(
        _ isRunning: Bool,
        for threadID: String,
        providerID: String = BridgeProviderIdentifier.codex,
        at date: Date = .now
    ) {
        updateThreadSummary(id: threadID, providerID: providerID) { summary in
            summary.isRunning = isRunning
            summary.updatedAt = date
        }
    }

    func setThreadArchived(
        _ isArchived: Bool,
        for threadID: String,
        providerID: String = BridgeProviderIdentifier.codex
    ) {
        updateThreadSummary(id: threadID, providerID: providerID, clearsStale: true) { summary in
            summary.isArchived = isArchived
            summary.updatedAt = .now
        }
    }

    func setThreadSidebarVisibility(
        _ isVisibleInSidebar: Bool,
        for threadID: String,
        providerID: String = BridgeProviderIdentifier.codex
    ) {
        let identity = ConversationIdentity(providerID: providerID, threadID: threadID)
        let fallbackTitle = threadSession(for: identity)?.title ?? "New Conversation"
        let defaultSummary = isVisibleInSidebar
            ? ThreadSummary(
                id: threadID,
                providerID: providerID,
                title: fallbackTitle,
                previewText: "",
                updatedAt: .now,
                isVisibleInSidebar: true
            )
            : nil

        threadListRepository.updateThreadSummary(
            for: identity,
            defaultSummary: defaultSummary,
            clearsStale: isVisibleInSidebar
        ) { summary in
            summary.isVisibleInSidebar = isVisibleInSidebar
        }
        refreshThreadListProjection()
    }

    func markThreadActivity(
        id: String,
        providerID: String = BridgeProviderIdentifier.codex,
        at date: Date = .now,
        previewText: String? = nil,
        isRunning: Bool? = nil,
        hasUnreadActivity: Bool? = nil,
        lastErrorMessage: String? = nil
    ) {
        updateThreadSummary(id: id, providerID: providerID, clearsStale: true) { summary in
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
