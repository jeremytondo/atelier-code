import Foundation

@MainActor
protocol WorkspaceConversationRuntime: AnyObject {
    func start() async throws
    func stop() async
    func startThreadAndWait(title: String?) async throws -> ThreadSession
    func startTurn(prompt: String, configuration: BridgeTurnStartConfiguration?) async throws
    func cancelTurn(reason: String?) async throws
}
