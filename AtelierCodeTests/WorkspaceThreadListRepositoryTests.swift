import Foundation
import Testing
@testable import AtelierCode

@MainActor
struct WorkspaceThreadListRepositoryTests {
    @Test func restoreRestoresCachedRowsAndListMetadata() async throws {
        let repository = WorkspaceThreadListRepository()
        let activeListDate = Date(timeIntervalSince1970: 1_710_000_000)
        let archivedListDate = activeListDate.addingTimeInterval(600)

        repository.restorePersistedState(
            PersistedCachedThreadListState(
                threadSummaries: [
                    PersistedThreadSummary(
                        id: "thread-1",
                        title: "Cached",
                        previewText: "Preview",
                        updatedAt: activeListDate,
                        isVisibleInSidebar: true,
                        isArchived: false,
                        isLocalOnly: true,
                        isStale: false
                    ),
                    PersistedThreadSummary(
                        id: "thread-2",
                        title: "Archived",
                        previewText: "Older",
                        updatedAt: archivedListDate,
                        isVisibleInSidebar: true,
                        isArchived: true,
                        isLocalOnly: false,
                        isStale: true
                    )
                ],
                lastSuccessfulActiveListAt: activeListDate,
                lastSuccessfulArchivedListAt: archivedListDate
            )
        )

        #expect(repository.threadSummaries.map(\.id) == ["thread-2", "thread-1"])
        #expect(repository.threadSummary(id: "thread-1")?.isLocalOnly == true)
        #expect(repository.threadSummary(id: "thread-2")?.isStale == true)
        #expect(repository.lastSuccessfulListAt(for: false) == activeListDate)
        #expect(repository.lastSuccessfulListAt(for: true) == archivedListDate)
        #expect(repository.syncState(for: false) == .idle)
    }

    @Test func selectedOmissionMarksThreadStaleInsteadOfDroppingIt() async throws {
        let repository = WorkspaceThreadListRepository()
        let baseline = Date(timeIntervalSince1970: 1_710_000_000)

        repository.replaceThreadList(
            [
                ThreadSummary(id: "thread-active", title: "Active", previewText: "Preview", updatedAt: baseline),
                ThreadSummary(id: "thread-other", title: "Other", previewText: "Preview", updatedAt: baseline.addingTimeInterval(-60))
            ],
            archived: false,
            listedAt: baseline,
            selectedThreadID: nil,
            loadedThreadIDs: []
        )

        repository.replaceThreadList(
            [],
            archived: false,
            listedAt: baseline.addingTimeInterval(120),
            selectedThreadID: "thread-active",
            loadedThreadIDs: []
        )

        #expect(repository.threadSummary(id: "thread-active")?.isStale == true)
        #expect(repository.threadSummary(id: "thread-other") == nil)
    }

    @Test func recentlyActiveThreadSurvivesOneOmissionThenFallsOut() async throws {
        let repository = WorkspaceThreadListRepository()
        let baseline = Date(timeIntervalSince1970: 1_710_000_000)

        repository.replaceThreadList(
            [ThreadSummary(id: "thread-1", title: "First", previewText: "Preview", updatedAt: baseline)],
            archived: false,
            listedAt: baseline,
            selectedThreadID: nil,
            loadedThreadIDs: []
        )

        repository.updateThreadSummary(id: "thread-1", clearsStale: true) { summary in
            summary.updatedAt = baseline.addingTimeInterval(30)
            summary.previewText = "Fresh local work"
        }

        repository.replaceThreadList(
            [],
            archived: false,
            listedAt: baseline.addingTimeInterval(90),
            selectedThreadID: nil,
            loadedThreadIDs: []
        )

        #expect(repository.threadSummary(id: "thread-1")?.isStale == true)

        repository.replaceThreadList(
            [],
            archived: false,
            listedAt: baseline.addingTimeInterval(180),
            selectedThreadID: nil,
            loadedThreadIDs: []
        )

        #expect(repository.threadSummary(id: "thread-1") == nil)
    }

    @Test func directThreadUpsertStartsLocalOnlyAndListConfirmationClearsIt() async throws {
        let repository = WorkspaceThreadListRepository()
        let baseline = Date(timeIntervalSince1970: 1_710_000_000)

        repository.upsertThreadSummary(
            ThreadSummary(
                id: "thread-local",
                title: "Draft",
                previewText: "Preview",
                updatedAt: baseline,
                isVisibleInSidebar: true
            )
        )

        #expect(repository.threadSummary(id: "thread-local")?.isLocalOnly == true)
        #expect(repository.threadSummary(id: "thread-local")?.isStale == false)

        repository.replaceThreadList(
            [
                ThreadSummary(
                    id: "thread-local",
                    title: "Draft",
                    previewText: "Preview",
                    updatedAt: baseline.addingTimeInterval(60),
                    isVisibleInSidebar: true
                )
            ],
            archived: false,
            listedAt: baseline.addingTimeInterval(60),
            selectedThreadID: nil,
            loadedThreadIDs: []
        )

        #expect(repository.threadSummary(id: "thread-local")?.isLocalOnly == false)
        #expect(repository.threadSummary(id: "thread-local")?.isStale == false)
    }

    @Test func equalActivityDatesDoNotResortWhenOnlyTitleChanges() async throws {
        let repository = WorkspaceThreadListRepository()
        let baseline = Date(timeIntervalSince1970: 1_710_000_000)

        repository.replaceThreadList(
            [
                ThreadSummary(id: "thread-1", title: "Beta", previewText: "Preview", updatedAt: baseline),
                ThreadSummary(id: "thread-2", title: "Alpha", previewText: "Preview", updatedAt: baseline)
            ],
            archived: false,
            listedAt: baseline,
            selectedThreadID: nil,
            loadedThreadIDs: []
        )

        #expect(repository.threadSummaries.map(\.id) == ["thread-1", "thread-2"])

        repository.updateThreadSummary(id: "thread-2") { summary in
            summary.title = "Zulu"
        }

        #expect(repository.threadSummaries.map(\.id) == ["thread-1", "thread-2"])
    }
}
