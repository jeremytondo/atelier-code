import Foundation
import Observation

@MainActor
@Observable
final class WorkspaceController {
    private(set) var workspace: WorkspaceRecord
    private(set) var bridgeLifecycleState: BridgeLifecycleState
    private(set) var connectionStatus: ConnectionStatus
    private(set) var threadSummaries: [ThreadSummary]
    private(set) var authState: AuthState
    private(set) var pendingLogin: PendingLogin?
    private(set) var rateLimitState: RateLimitState?
    private(set) var threadSessionsByID: [String: ThreadSession]
    private(set) var lastActiveThreadID: String?
    private(set) var isShowingArchivedThreads: Bool
    private(set) var isExpanded: Bool

    @ObservationIgnored private var awaitingTurnStartThreadIDs: Set<String>
    @ObservationIgnored private var currentTurnIDsByThreadID: [String: String]

    init(workspace: WorkspaceRecord) {
        self.workspace = workspace
        self.bridgeLifecycleState = .idle
        self.connectionStatus = .disconnected
        self.threadSummaries = []
        self.authState = .unknown
        self.pendingLogin = nil
        self.rateLimitState = nil
        self.threadSessionsByID = [:]
        self.lastActiveThreadID = nil
        self.isShowingArchivedThreads = false
        self.isExpanded = true
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
            isShowingArchivedThreads || summary.isArchived == false
        }
    }

    var hasRunningThreads: Bool {
        threadSummaries.contains(where: \.isRunning)
    }

    func activate(workspace: WorkspaceRecord) {
        self.workspace = workspace
        resetWorkspace()
    }

    func resetWorkspace() {
        bridgeLifecycleState = .idle
        connectionStatus = .disconnected
        threadSummaries.removeAll()
        authState = .unknown
        pendingLogin = nil
        rateLimitState = nil
        threadSessionsByID.removeAll()
        lastActiveThreadID = nil
        isShowingArchivedThreads = false
        isExpanded = true
        awaitingTurnStartThreadIDs.removeAll()
        currentTurnIDsByThreadID.removeAll()
    }

    func setBridgeLifecycleState(_ state: BridgeLifecycleState) {
        bridgeLifecycleState = state
    }

    func setConnectionStatus(_ status: ConnectionStatus) {
        connectionStatus = status
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

    func setShowingArchivedThreads(_ isShowingArchivedThreads: Bool) {
        self.isShowingArchivedThreads = isShowingArchivedThreads
    }

    func setExpanded(_ isExpanded: Bool) {
        self.isExpanded = isExpanded
    }

    func replaceThreadList(_ threadSummaries: [ThreadSummary], archived: Bool = false) {
        let existingByID = Dictionary(uniqueKeysWithValues: self.threadSummaries.map { ($0.id, $0) })
        var merged = self.threadSummaries.filter { $0.isArchived != archived }

        for summary in threadSummaries {
            let existing = existingByID[summary.id]
            merged.append(
                ThreadSummary(
                    id: summary.id,
                    title: summary.title,
                    previewText: summary.previewText,
                    updatedAt: summary.updatedAt,
                    isArchived: archived,
                    isRunning: summary.isRunning || existing?.isRunning == true,
                    hasUnreadActivity: existing?.hasUnreadActivity ?? false,
                    lastErrorMessage: summary.lastErrorMessage ?? existing?.lastErrorMessage
                )
            )
        }

        self.threadSummaries = Self.sortedThreadSummaries(merged)
    }

    func upsertThreadSummary(_ threadSummary: ThreadSummary) {
        if let index = threadSummaries.firstIndex(where: { $0.id == threadSummary.id }) {
            threadSummaries[index] = Self.mergeThreadSummary(threadSummary, existing: threadSummaries[index])
        } else {
            threadSummaries.append(threadSummary)
        }

        threadSummaries = Self.sortedThreadSummaries(threadSummaries)
    }

    func updateThreadSummary(id: String, mutate: (inout ThreadSummary) -> Void) {
        guard let index = threadSummaries.firstIndex(where: { $0.id == id }) else {
            return
        }

        mutate(&threadSummaries[index])
        threadSummaries = Self.sortedThreadSummaries(threadSummaries)
    }

    func threadSummary(id: String) -> ThreadSummary? {
        threadSummaries.first(where: { $0.id == id })
    }

    func markThreadSelected(_ id: String?) {
        lastActiveThreadID = id

        guard let id else {
            return
        }

        updateThreadSummary(id: id) { summary in
            summary.hasUnreadActivity = false
        }
    }

    func threadSession(id: String) -> ThreadSession? {
        threadSessionsByID[id]
    }

    @discardableResult
    func openThread(id: String, title: String) -> ThreadSession {
        let existingSummary = threadSummary(id: id)
        let session = threadSessionsByID[id] ?? ThreadSession(threadID: id, title: title)
        session.startThread(id: id, title: title)
        threadSessionsByID[id] = session
        markThreadSelected(id)
        upsertThreadSummary(
            ThreadSummary(
                id: id,
                title: title,
                previewText: existingSummary?.previewText ?? "",
                updatedAt: existingSummary?.updatedAt ?? .now,
                isArchived: existingSummary?.isArchived ?? false,
                isRunning: existingSummary?.isRunning ?? false,
                hasUnreadActivity: false,
                lastErrorMessage: existingSummary?.lastErrorMessage
            )
        )
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
        markThreadSelected(id)
        upsertThreadSummary(
            ThreadSummary(
                id: id,
                title: title,
                previewText: messages.last?.text ?? existingSummary?.previewText ?? "",
                updatedAt: existingSummary?.updatedAt ?? .now,
                isArchived: existingSummary?.isArchived ?? false,
                isRunning: existingSummary?.isRunning ?? false,
                hasUnreadActivity: false,
                lastErrorMessage: existingSummary?.lastErrorMessage
            )
        )
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
        updateThreadSummary(id: threadID) { summary in
            summary.isArchived = isArchived
            summary.updatedAt = .now
        }
    }

    func markThreadActivity(
        id: String,
        at date: Date = .now,
        previewText: String? = nil,
        isRunning: Bool? = nil,
        hasUnreadActivity: Bool? = nil,
        lastErrorMessage: String? = nil
    ) {
        updateThreadSummary(id: id) { summary in
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

    private static func sortedThreadSummaries(_ threadSummaries: [ThreadSummary]) -> [ThreadSummary] {
        threadSummaries.sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }

            return lhs.updatedAt > rhs.updatedAt
        }
    }

    private static func mergeThreadSummary(_ incoming: ThreadSummary, existing: ThreadSummary) -> ThreadSummary {
        ThreadSummary(
            id: incoming.id,
            title: incoming.title,
            previewText: incoming.previewText,
            updatedAt: incoming.updatedAt,
            isArchived: incoming.isArchived,
            isRunning: incoming.isRunning || existing.isRunning,
            hasUnreadActivity: incoming.hasUnreadActivity || existing.hasUnreadActivity,
            lastErrorMessage: incoming.lastErrorMessage ?? existing.lastErrorMessage
        )
    }
}
