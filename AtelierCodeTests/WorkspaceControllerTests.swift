import Foundation
import Testing
@testable import AtelierCode

@MainActor
struct WorkspaceControllerTests {
    @Test func workspaceSwitchResetsVolatileState() async throws {
        let firstWorkspace = WorkspaceRecord(url: try temporaryDirectory(named: "workspace-one"), lastOpenedAt: .now)
        let secondWorkspace = WorkspaceRecord(url: try temporaryDirectory(named: "workspace-two"), lastOpenedAt: .now)
        let controller = WorkspaceController(workspace: firstWorkspace)

        controller.setBridgeLifecycleState(.starting)
        controller.setConnectionStatus(.ready)
        controller.setAuthState(.signedIn(accountDescription: "Preview"))
        controller.setPendingLogin(
            PendingLogin(
                method: .chatgpt,
                authURL: URL(string: "https://example.com/login")!,
                loginID: "login-1"
            )
        )
        controller.setRateLimitState(
            RateLimitState(
                accountID: "account-1",
                buckets: [
                    RateLimitBucketState(
                        id: "bucket-1",
                        kind: .requests,
                        limit: nil,
                        remaining: nil,
                        resetAt: nil,
                        detail: nil
                    )
                ]
            )
        )
        controller.replaceThreadList([
            ThreadSummary(id: "thread-1", title: "One", previewText: "Preview", updatedAt: .now)
        ])
        controller.openThread(id: "thread-1", title: "One")

        controller.activate(workspace: secondWorkspace)

        #expect(controller.workspace == secondWorkspace)
        #expect(controller.bridgeLifecycleState == .idle)
        #expect(controller.connectionStatus == .disconnected)
        #expect(controller.threadSummaries.isEmpty)
        #expect(controller.authState == .unknown)
        #expect(controller.pendingLogin == nil)
        #expect(controller.rateLimitState == nil)
        #expect(controller.activeThreadSession == nil)
    }

    @Test func threadListReplacementAndActiveThreadChangesAreDeterministic() async throws {
        let workspace = WorkspaceRecord(url: try temporaryDirectory(named: "workspace-threads"), lastOpenedAt: .now)
        let controller = WorkspaceController(workspace: workspace)
        let threadSummaries = [
            ThreadSummary(id: "thread-1", title: "First", previewText: "One", updatedAt: .now),
            ThreadSummary(id: "thread-2", title: "Second", previewText: "Two", updatedAt: .now)
        ]

        controller.replaceThreadList(threadSummaries)
        let session = controller.openThread(id: "thread-2", title: "Second")
        controller.clearActiveThreadSession()

        #expect(Set(controller.threadSummaries.map(\.conversationID)) == Set(threadSummaries.map(\.conversationID)))
        #expect(session.threadID == "thread-2")
        #expect(controller.activeThreadSession == nil)
    }

    @Test func authAndConnectionMutationsUpdateExpectedState() async throws {
        let workspace = WorkspaceRecord(url: try temporaryDirectory(named: "workspace-auth"), lastOpenedAt: .now)
        let controller = WorkspaceController(workspace: workspace)

        controller.setConnectionStatus(.streaming)
        controller.setAuthState(.signedOut)

        #expect(controller.connectionStatus == .streaming)
        #expect(controller.authState == .signedOut)
    }

    @Test func upsertingThreadSummaryKeepsNewestThreadsSorted() async throws {
        let workspace = WorkspaceRecord(url: try temporaryDirectory(named: "workspace-sort"), lastOpenedAt: .now)
        let controller = WorkspaceController(workspace: workspace)
        let older = ThreadSummary(id: "thread-1", title: "Older", previewText: "One", updatedAt: .distantPast)
        let newer = ThreadSummary(id: "thread-2", title: "Newer", previewText: "Two", updatedAt: .now)

        controller.upsertThreadSummary(older)
        controller.upsertThreadSummary(newer)
        controller.upsertThreadSummary(
            ThreadSummary(id: "thread-1", title: "Updated", previewText: "Latest", updatedAt: .now.addingTimeInterval(10))
        )

        #expect(controller.threadSummaries.map(\.threadID) == ["thread-1", "thread-2"])
        #expect(controller.threadSummaries.first?.title == "Updated")
    }

    @Test func displayedThreadSummariesDefaultToFiveAndCanExpandAndCollapse() async throws {
        let workspace = WorkspaceRecord(url: try temporaryDirectory(named: "workspace-display-limit"), lastOpenedAt: .now)
        let controller = WorkspaceController(workspace: workspace)
        let threadSummaries = (0..<7).map { index in
            ThreadSummary(
                id: "thread-\(index)",
                title: "Thread \(index)",
                previewText: "Preview \(index)",
                updatedAt: .now.addingTimeInterval(TimeInterval(-index))
            )
        }

        controller.replaceThreadList(threadSummaries)

        #expect(controller.displayedThreadSummaries.count == WorkspaceController.collapsedVisibleThreadLimit)
        #expect(controller.displayedThreadSummaries.map(\.threadID) == Array(threadSummaries.prefix(WorkspaceController.collapsedVisibleThreadLimit)).map(\.threadID))
        #expect(controller.canShowMoreVisibleThreads)
        #expect(controller.canShowLessVisibleThreads == false)

        controller.setShowingAllVisibleThreads(true)

        #expect(controller.displayedThreadSummaries.map(\.threadID) == threadSummaries.map(\.threadID))
        #expect(controller.canShowMoreVisibleThreads == false)
        #expect(controller.canShowLessVisibleThreads)

        controller.setShowingAllVisibleThreads(false)

        #expect(controller.displayedThreadSummaries.count == WorkspaceController.collapsedVisibleThreadLimit)
        #expect(controller.displayedThreadSummaries.map(\.threadID) == Array(threadSummaries.prefix(WorkspaceController.collapsedVisibleThreadLimit)).map(\.threadID))
    }

    @Test func locallyPromotedThreadsSurviveListRefreshWithoutBecomingStale() async throws {
        let workspace = WorkspaceRecord(url: try temporaryDirectory(named: "workspace-draft-thread"), lastOpenedAt: .now)
        let controller = WorkspaceController(workspace: workspace)

        controller.openThread(id: "draft-thread", title: "Draft", isVisibleInSidebar: false)

        #expect(controller.threadSummary(id: "draft-thread")?.isVisibleInSidebar == false)
        #expect(controller.visibleThreadSummaries.isEmpty)

        controller.setThreadSidebarVisibility(true, for: "draft-thread")
        controller.replaceThreadList([])

        #expect(controller.threadSummary(id: "draft-thread")?.isVisibleInSidebar == true)
        #expect(controller.visibleThreadSummaries.map(\.threadID) == ["draft-thread"])
        #expect(controller.threadSummary(id: "draft-thread")?.isLocalOnly == true)
        #expect(controller.threadSummary(id: "draft-thread")?.isStale == false)
    }

    @Test func refreshKeepsExistingHumanTitleWhenIncomingTitleFallsBackToThreadID() async throws {
        let workspace = WorkspaceRecord(url: try temporaryDirectory(named: "workspace-refresh-title"), lastOpenedAt: .now)
        let controller = WorkspaceController(workspace: workspace)

        controller.openThread(id: "thread-123", title: "Start the real conversation.", isVisibleInSidebar: true)
        controller.replaceThreadList([
            ThreadSummary(id: "thread-123", title: "thread-123", previewText: "Preview", updatedAt: .now)
        ])

        #expect(controller.threadSummary(id: "thread-123")?.title == "Start the real conversation.")
        #expect(controller.visibleThreadSummaries.map(\.threadID) == ["thread-123"])
    }

    @Test func locallyCreatedSidebarThreadSurvivesRefreshEvenIfSessionIsCleared() async throws {
        let workspace = WorkspaceRecord(url: try temporaryDirectory(named: "workspace-local-thread"), lastOpenedAt: .now)
        let controller = WorkspaceController(workspace: workspace)

        controller.openThread(id: "thread-keep", title: "Keep Me", isVisibleInSidebar: true)
        controller.setThreadSidebarVisibility(true, for: "thread-keep")
        controller.clearThreadSession(id: "thread-keep")
        controller.replaceThreadList([])

        #expect(controller.threadSummary(id: "thread-keep")?.title == "Keep Me")
        #expect(controller.visibleThreadSummaries.map(\.threadID) == ["thread-keep"])
        #expect(controller.threadSummary(id: "thread-keep")?.isLocalOnly == true)
        #expect(controller.threadSummary(id: "thread-keep")?.isStale == false)
    }

    @Test func selectedThreadSurvivesRefreshWhenBridgeOmitsItAndBecomesStale() async throws {
        let workspace = WorkspaceRecord(url: try temporaryDirectory(named: "workspace-selected-thread"), lastOpenedAt: .now)
        let controller = WorkspaceController(workspace: workspace)

        controller.replaceThreadList([
            ThreadSummary(id: "thread-active", title: "Active", previewText: "Current", updatedAt: .now),
            ThreadSummary(id: "thread-other", title: "Other", previewText: "Other", updatedAt: .distantPast)
        ])
        controller.markThreadSelected("thread-active")
        controller.replaceThreadList([])

        #expect(controller.threadSummary(id: "thread-active")?.title == "Active")
        #expect(controller.visibleThreadSummaries.map(\.threadID) == ["thread-active"])
        #expect(controller.threadSummary(id: "thread-active")?.isStale == true)
    }

    @Test func staleRefreshKeepsNewestLocalActivityVisible() async throws {
        let workspace = WorkspaceRecord(url: try temporaryDirectory(named: "workspace-stale-refresh"), lastOpenedAt: .now)
        let controller = WorkspaceController(workspace: workspace)
        let baseline = Date(timeIntervalSince1970: 1_710_000_000)
        let promotedDate = baseline.addingTimeInterval(120)

        controller.replaceThreadList((0..<6).map { index in
            ThreadSummary(
                id: "thread-\(index)",
                title: "Thread \(index)",
                previewText: "Preview \(index)",
                updatedAt: baseline.addingTimeInterval(TimeInterval(-index))
            )
        }, listedAt: baseline)
        controller.markThreadActivity(id: "thread-5", at: promotedDate, previewText: "Fresh local work")

        controller.replaceThreadList((0..<6).map { index in
            ThreadSummary(
                id: "thread-\(index)",
                title: "Thread \(index)",
                previewText: index == 5 ? "Stale bridge preview" : "Preview \(index)",
                updatedAt: baseline.addingTimeInterval(TimeInterval(-index))
            )
        }, listedAt: baseline.addingTimeInterval(180))

        #expect(controller.displayedThreadSummaries.first?.threadID == "thread-5")
        #expect(controller.threadSummary(id: "thread-5")?.previewText == "Fresh local work")
        #expect(controller.threadSummary(id: "thread-5")?.updatedAt == promotedDate)
    }

    @Test func sameThreadIDCanCoexistAcrossProvidersInSessionsAndSelection() async throws {
        let workspace = WorkspaceRecord(url: try temporaryDirectory(named: "workspace-provider-collision"), lastOpenedAt: .now)
        let controller = WorkspaceController(workspace: workspace)

        let codexSession = controller.openThread(
            id: "thread-shared",
            providerID: BridgeProviderIdentifier.codex,
            title: "Codex Thread"
        )
        let geminiSession = controller.openThread(
            id: "thread-shared",
            providerID: "gemini",
            title: "Gemini Thread"
        )

        #expect(controller.threadSessionsByID.count == 2)
        #expect(controller.threadSummary(
            for: ConversationIdentity(providerID: BridgeProviderIdentifier.codex, threadID: "thread-shared")
        )?.title == "Codex Thread")
        #expect(controller.threadSummary(
            for: ConversationIdentity(providerID: "gemini", threadID: "thread-shared")
        )?.title == "Gemini Thread")

        controller.markThreadSelected(codexSession.conversationID)
        #expect(controller.activeThreadSession === codexSession)

        controller.markThreadSelected(geminiSession.conversationID)
        #expect(controller.activeThreadSession === geminiSession)
        #expect(controller.lastActiveConversationID == geminiSession.conversationID)
    }
}
