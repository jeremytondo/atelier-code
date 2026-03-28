import Foundation

enum ThreadListSyncState: String, Equatable, Sendable {
    case idle
    case syncing
    case failed
}

@MainActor
final class WorkspaceThreadListRepository {
    private var threadSummariesByID: [ConversationIdentity: ThreadSummary]
    private var syncStatesByArchived: [Bool: ThreadListSyncState]
    private var lastSuccessfulListAtByArchived: [Bool: Date]

    init() {
        threadSummariesByID = [:]
        syncStatesByArchived = [false: .idle, true: .idle]
        lastSuccessfulListAtByArchived = [:]
    }

    var threadSummaries: [ThreadSummary] {
        Self.sortedThreadSummaries(Array(threadSummariesByID.values))
    }

    func threadSummary(id: String, providerID: String = BridgeProviderIdentifier.codex) -> ThreadSummary? {
        threadSummary(for: ConversationIdentity(providerID: providerID, threadID: id))
    }

    func threadSummary(for identity: ConversationIdentity) -> ThreadSummary? {
        threadSummariesByID[identity]
    }

    func persistedState() -> PersistedCachedThreadListState {
        PersistedCachedThreadListState(
            threadSummaries: threadSummaries.map(\.persistedSummary),
            lastSuccessfulActiveListAt: lastSuccessfulListAtByArchived[false],
            lastSuccessfulArchivedListAt: lastSuccessfulListAtByArchived[true]
        )
    }

    func restorePersistedState(_ persistedState: PersistedCachedThreadListState) {
        threadSummariesByID = Dictionary(
            uniqueKeysWithValues: Self.sortedThreadSummaries(
                persistedState.threadSummaries.map(ThreadSummary.init(persistedSummary:))
            ).map { ($0.conversationID, $0) }
        )
        lastSuccessfulListAtByArchived = [:]
        if let lastSuccessfulActiveListAt = persistedState.lastSuccessfulActiveListAt {
            lastSuccessfulListAtByArchived[false] = lastSuccessfulActiveListAt
        }
        if let lastSuccessfulArchivedListAt = persistedState.lastSuccessfulArchivedListAt {
            lastSuccessfulListAtByArchived[true] = lastSuccessfulArchivedListAt
        }
        syncStatesByArchived = [false: .idle, true: .idle]
    }

    func reset() {
        threadSummariesByID.removeAll()
        syncStatesByArchived = [false: .idle, true: .idle]
        lastSuccessfulListAtByArchived.removeAll()
    }

    func removeThreadSummary(id: String, providerID: String = BridgeProviderIdentifier.codex) {
        removeThreadSummary(for: ConversationIdentity(providerID: providerID, threadID: id))
    }

    func removeThreadSummary(for identity: ConversationIdentity) {
        threadSummariesByID.removeValue(forKey: identity)
    }

    func syncState(for archived: Bool) -> ThreadListSyncState {
        syncStatesByArchived[archived] ?? .idle
    }

    func lastSuccessfulListAt(for archived: Bool) -> Date? {
        lastSuccessfulListAtByArchived[archived]
    }

    func setSyncing(archived: Bool) {
        syncStatesByArchived[archived] = .syncing
    }

    func setSyncFailed(archived: Bool) {
        syncStatesByArchived[archived] = .failed
    }

    func markListSuccessful(archived: Bool, listedAt: Date) {
        syncStatesByArchived[archived] = .idle
        lastSuccessfulListAtByArchived[archived] = listedAt
    }

    func replaceThreadList(
        _ incoming: [ThreadSummary],
        archived: Bool,
        listedAt: Date,
        selectedThreadID: String?,
        loadedThreadIDs: Set<String>
    ) {
        replaceThreadList(
            incoming,
            archived: archived,
            listedAt: listedAt,
            selectedConversationID: selectedThreadID.map { ConversationIdentity(threadID: $0) },
            loadedConversationIDs: Set(loadedThreadIDs.map { ConversationIdentity(threadID: $0) })
        )
    }

    func replaceThreadList(
        _ incoming: [ThreadSummary],
        archived: Bool,
        listedAt: Date,
        selectedConversationID: ConversationIdentity?,
        loadedConversationIDs: Set<ConversationIdentity>
    ) {
        let previousSuccessfulListAt = lastSuccessfulListAtByArchived[archived]
        let existingInArchivedScope = threadSummaries.filter { $0.isArchived == archived }
        let incomingIDs = Set(incoming.map(\.conversationID))

        syncStatesByArchived[archived] = .idle
        lastSuccessfulListAtByArchived[archived] = listedAt

        for summary in incoming {
            threadSummariesByID[summary.conversationID] = Self.mergeRefreshedThreadSummary(
                summary,
                existing: threadSummariesByID[summary.conversationID],
                archived: archived
            )
        }

        for summary in existingInArchivedScope where incomingIDs.contains(summary.conversationID) == false {
            if shouldRetainOmittedSummary(
                summary,
                previousSuccessfulListAt: previousSuccessfulListAt,
                selectedConversationID: selectedConversationID,
                loadedConversationIDs: loadedConversationIDs
            ) {
                var retained = summary
                retained.isStale = retained.isLocalOnly == false
                threadSummariesByID[summary.conversationID] = retained
            } else {
                threadSummariesByID.removeValue(forKey: summary.conversationID)
            }
        }
    }

    func upsertThreadSummary(_ incoming: ThreadSummary, clearsStale: Bool = true) {
        var merged = Self.mergeThreadSummary(incoming, existing: threadSummariesByID[incoming.conversationID])
        if clearsStale {
            merged.isStale = false
        }
        threadSummariesByID[incoming.conversationID] = merged
    }

    func updateThreadSummary(
        id: String,
        providerID: String = BridgeProviderIdentifier.codex,
        defaultSummary: ThreadSummary? = nil,
        clearsStale: Bool = false,
        mutate: (inout ThreadSummary) -> Void
    ) {
        updateThreadSummary(
            for: ConversationIdentity(providerID: providerID, threadID: id),
            defaultSummary: defaultSummary,
            clearsStale: clearsStale,
            mutate: mutate
        )
    }

    func updateThreadSummary(
        for identity: ConversationIdentity,
        defaultSummary: ThreadSummary? = nil,
        clearsStale: Bool = false,
        mutate: (inout ThreadSummary) -> Void
    ) {
        let isNew = threadSummariesByID[identity] == nil
        guard var summary = threadSummariesByID[identity] ?? defaultSummary else {
            return
        }

        mutate(&summary)

        if isNew {
            summary.isLocalOnly = true
        }
        if clearsStale {
            summary.isStale = false
        }

        threadSummariesByID[identity] = summary
    }

    private func shouldRetainOmittedSummary(
        _ summary: ThreadSummary,
        previousSuccessfulListAt: Date?,
        selectedConversationID: ConversationIdentity?,
        loadedConversationIDs: Set<ConversationIdentity>
    ) -> Bool {
        if summary.isLocalOnly {
            return true
        }

        if summary.conversationID == selectedConversationID {
            return true
        }

        if loadedConversationIDs.contains(summary.conversationID) {
            return true
        }

        if summary.isRunning || summary.hasUnreadActivity || summary.lastErrorMessage != nil {
            return true
        }

        guard let previousSuccessfulListAt else {
            return false
        }

        return summary.updatedAt > previousSuccessfulListAt
    }

    private static func sortedThreadSummaries(_ threadSummaries: [ThreadSummary]) -> [ThreadSummary] {
        threadSummaries.sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
            }

            return lhs.updatedAt > rhs.updatedAt
        }
    }

    private static func mergeThreadSummary(_ incoming: ThreadSummary, existing: ThreadSummary?) -> ThreadSummary {
        guard let existing else {
            var summary = incoming
            summary.isLocalOnly = true
            summary.isStale = false
            return summary
        }

        return ThreadSummary(
            id: incoming.threadID,
            providerID: incoming.providerID,
            title: preferredThreadTitle(incoming: incoming.title, existing: existing.title, threadID: incoming.threadID),
            previewText: preferredThreadPreview(
                incoming: incoming.previewText,
                existing: existing.previewText,
                preferExisting: incoming.updatedAt < existing.updatedAt
            ),
            updatedAt: preferredThreadUpdatedAt(incoming: incoming.updatedAt, existing: existing.updatedAt),
            isVisibleInSidebar: incoming.isVisibleInSidebar || existing.isVisibleInSidebar,
            isArchived: incoming.isArchived,
            isRunning: incoming.isRunning || existing.isRunning,
            hasUnreadActivity: incoming.hasUnreadActivity || existing.hasUnreadActivity,
            lastErrorMessage: incoming.lastErrorMessage ?? existing.lastErrorMessage,
            isLocalOnly: existing.isLocalOnly,
            isStale: false
        )
    }

    private static func mergeRefreshedThreadSummary(
        _ incoming: ThreadSummary,
        existing: ThreadSummary?,
        archived: Bool
    ) -> ThreadSummary {
        let shouldPreferExistingActivity = existing.map { $0.updatedAt > incoming.updatedAt } ?? false

        return ThreadSummary(
            id: incoming.threadID,
            providerID: incoming.providerID,
            title: preferredThreadTitle(incoming: incoming.title, existing: existing?.title, threadID: incoming.threadID),
            previewText: preferredThreadPreview(
                incoming: incoming.previewText,
                existing: existing?.previewText,
                preferExisting: shouldPreferExistingActivity
            ),
            updatedAt: preferredThreadUpdatedAt(incoming: incoming.updatedAt, existing: existing?.updatedAt),
            isVisibleInSidebar: incoming.isVisibleInSidebar || existing?.isVisibleInSidebar == true,
            isArchived: archived,
            isRunning: incoming.isRunning || existing?.isRunning == true,
            hasUnreadActivity: existing?.hasUnreadActivity ?? false,
            lastErrorMessage: incoming.lastErrorMessage ?? existing?.lastErrorMessage,
            isLocalOnly: false,
            isStale: false
        )
    }

    private static func preferredThreadTitle(incoming: String, existing: String?, threadID: String) -> String {
        guard let existing else {
            return incoming
        }

        let normalizedIncoming = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedExisting = existing.trimmingCharacters(in: .whitespacesAndNewlines)

        guard normalizedExisting.isEmpty == false else {
            return incoming
        }

        if isPlaceholderThreadTitle(normalizedIncoming, threadID: threadID) &&
            isPlaceholderThreadTitle(normalizedExisting, threadID: threadID) == false {
            return existing
        }

        return incoming
    }

    private static func preferredThreadPreview(incoming: String, existing: String?, preferExisting: Bool) -> String {
        guard let existing else {
            return incoming
        }

        let normalizedIncoming = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedExisting = existing.trimmingCharacters(in: .whitespacesAndNewlines)

        if preferExisting, normalizedExisting.isEmpty == false {
            return existing
        }

        if normalizedIncoming.isEmpty, normalizedExisting.isEmpty == false {
            return existing
        }

        return incoming
    }

    private static func preferredThreadUpdatedAt(incoming: Date, existing: Date?) -> Date {
        guard let existing else {
            return incoming
        }

        return max(incoming, existing)
    }

    private static func isPlaceholderThreadTitle(_ title: String, threadID: String) -> Bool {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty || normalized == threadID || normalized == "Thread" || normalized == "New Conversation"
    }
}
