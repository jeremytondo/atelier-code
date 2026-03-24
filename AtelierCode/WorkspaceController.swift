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
    private(set) var activeThreadSession: ThreadSession?

    init(workspace: WorkspaceRecord) {
        self.workspace = workspace
        self.bridgeLifecycleState = .idle
        self.connectionStatus = .disconnected
        self.threadSummaries = []
        self.authState = .unknown
        self.activeThreadSession = nil
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
        activeThreadSession = nil
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

    func replaceThreadList(_ threadSummaries: [ThreadSummary]) {
        self.threadSummaries = threadSummaries
    }

    @discardableResult
    func openThread(id: String, title: String) -> ThreadSession {
        let session = ThreadSession(threadID: id, title: title)
        session.startThread(id: id, title: title)
        activeThreadSession = session
        return session
    }

    @discardableResult
    func resumeThread(
        id: String,
        title: String,
        messages: [ConversationMessage] = []
    ) -> ThreadSession {
        let session = ThreadSession(threadID: id, title: title)
        session.resumeThread(id: id, title: title, messages: messages)
        activeThreadSession = session
        return session
    }

    func clearActiveThreadSession() {
        activeThreadSession = nil
    }
}
