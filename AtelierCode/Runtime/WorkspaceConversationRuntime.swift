import Foundation

@MainActor
protocol WorkspaceConversationRuntime: AnyObject {
    func start() async throws
    func stop() async
    func startThreadAndWait(title: String?) async throws -> ThreadSession
    func resumeThreadAndWait(id: String) async throws -> ThreadSession
    func startTurn(prompt: String, configuration: BridgeTurnStartConfiguration?) async throws
    func cancelTurn(reason: String?) async throws
    func resolveApproval(id: String, resolution: ApprovalResolution) async throws
}
