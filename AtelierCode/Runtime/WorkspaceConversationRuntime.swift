import Foundation

@MainActor
protocol WorkspaceConversationRuntime: AnyObject {
    func start() async throws
    func stop() async
    func refreshModels() async throws
    func listThreads(archived: Bool) async throws
    func startThreadAndWait(title: String?, configuration: BridgeConversationConfiguration?) async throws -> ThreadSession
    func resumeThreadAndWait(conversationID: ConversationIdentity) async throws -> ThreadSession
    func readThreadAndWait(conversationID: ConversationIdentity, includeTurns: Bool) async throws -> ThreadSession
    func forkThreadAndWait(conversationID: ConversationIdentity) async throws -> ThreadSession
    func renameThread(conversationID: ConversationIdentity, title: String) async throws
    func archiveThread(conversationID: ConversationIdentity) async throws
    func unarchiveThreadAndWait(conversationID: ConversationIdentity) async throws -> ThreadSession
    func rollbackThreadAndWait(conversationID: ConversationIdentity, numTurns: Int) async throws -> ThreadSession
    func startTurn(threadID: String, prompt: String, configuration: BridgeTurnStartConfiguration?) async throws
    func cancelTurn(threadID: String, reason: String?) async throws
    func resolveApproval(threadID: String, id: String, resolution: ApprovalResolution) async throws
}

extension WorkspaceConversationRuntime {
    func startThreadAndWait(title: String?) async throws -> ThreadSession {
        try await startThreadAndWait(title: title, configuration: nil)
    }
}
