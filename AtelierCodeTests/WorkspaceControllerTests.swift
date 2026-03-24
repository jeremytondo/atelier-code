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
}
