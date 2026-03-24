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
    private(set) var activeThreadSession: ThreadSession?

    init(workspace: WorkspaceRecord) {
        self.workspace = workspace
        self.bridgeLifecycleState = .idle
        self.connectionStatus = .disconnected
        self.threadSummaries = []
        self.authState = .unknown
        self.pendingLogin = nil
        self.rateLimitState = nil
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
        pendingLogin = nil
        rateLimitState = nil
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

    func setPendingLogin(_ pendingLogin: PendingLogin?) {
        self.pendingLogin = pendingLogin
    }

    func clearPendingLogin() {
        pendingLogin = nil
    }

    func setRateLimitState(_ rateLimitState: RateLimitState?) {
        self.rateLimitState = rateLimitState
    }

    func replaceThreadList(_ threadSummaries: [ThreadSummary]) {
        self.threadSummaries = threadSummaries
    }

    func upsertThreadSummary(_ threadSummary: ThreadSummary) {
        if let index = threadSummaries.firstIndex(where: { $0.id == threadSummary.id }) {
            threadSummaries[index] = threadSummary
        } else {
            threadSummaries.append(threadSummary)
        }

        threadSummaries.sort { $0.updatedAt > $1.updatedAt }
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

    @discardableResult
    func ensureActiveThreadSession(id: String, title: String) -> ThreadSession {
        if let activeThreadSession, activeThreadSession.threadID == id {
            activeThreadSession.updateThreadIdentity(id: id, title: title)
            return activeThreadSession
        }

        return resumeThread(id: id, title: title)
    }

    func clearActiveThreadSession() {
        activeThreadSession = nil
    }
}
