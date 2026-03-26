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

        #expect(controller.threadSummaries == threadSummaries)
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

        #expect(controller.threadSummaries.map(\.id) == ["thread-1", "thread-2"])
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
        #expect(controller.displayedThreadSummaries.map(\.id) == Array(threadSummaries.prefix(WorkspaceController.collapsedVisibleThreadLimit)).map(\.id))
        #expect(controller.canShowMoreVisibleThreads)
        #expect(controller.canShowLessVisibleThreads == false)

        controller.setShowingAllVisibleThreads(true)

        #expect(controller.displayedThreadSummaries.map(\.id) == threadSummaries.map(\.id))
        #expect(controller.canShowMoreVisibleThreads == false)
        #expect(controller.canShowLessVisibleThreads)

        controller.setShowingAllVisibleThreads(false)

        #expect(controller.displayedThreadSummaries.count == WorkspaceController.collapsedVisibleThreadLimit)
        #expect(controller.displayedThreadSummaries.map(\.id) == Array(threadSummaries.prefix(WorkspaceController.collapsedVisibleThreadLimit)).map(\.id))
    }
}
