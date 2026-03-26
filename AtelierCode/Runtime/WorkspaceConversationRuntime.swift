import Foundation

@MainActor
protocol WorkspaceConversationRuntime: AnyObject {
    func start() async throws
    func stop() async
    func listThreads(archived: Bool) async throws
    func startThreadAndWait(title: String?) async throws -> ThreadSession
    func resumeThreadAndWait(id: String) async throws -> ThreadSession
    func readThreadAndWait(id: String, includeTurns: Bool) async throws -> ThreadSession
    func forkThreadAndWait(id: String) async throws -> ThreadSession
    func renameThread(id: String, title: String) async throws
    func archiveThread(id: String) async throws
    func unarchiveThreadAndWait(id: String) async throws -> ThreadSession
    func rollbackThreadAndWait(id: String, numTurns: Int) async throws -> ThreadSession
    func startTurn(threadID: String, prompt: String, configuration: BridgeTurnStartConfiguration?) async throws
    func cancelTurn(threadID: String, reason: String?) async throws
    func resolveApproval(threadID: String, id: String, resolution: ApprovalResolution) async throws
}
