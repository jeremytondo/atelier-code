import Foundation
import Testing
@testable import AtelierCode

@MainActor
struct WorkspaceBridgeRuntimeTests {
    @Test func startupHandshakeBootstrapsWorkspaceState() async throws {
        let workspace = WorkspaceRecord(url: try temporaryDirectory(named: "runtime-bootstrap"), lastOpenedAt: .now)
        let controller = WorkspaceController(workspace: workspace)
        let bundle = try bridgeFixtureBundle()
        let processHandle = FakeBridgeProcessHandle(lines: [
            "bridge is warming up",
            startupRecordJSON(port: 4242)
        ])
        let socketClient = FakeBridgeSocketClient(messages: [
            welcomeJSON(requestID: "ateliercode-hello-1"),
            authChangedJSON(requestID: "ateliercode-account-read-2", state: "signed_in", displayName: "chatgpt (pro)"),
            rateLimitUpdatedJSON(requestID: "ateliercode-account-read-2"),
            threadListResultJSON(requestID: "ateliercode-thread-list-3", threadTitle: "Bootstrap Thread")
        ])
        let runtime = WorkspaceBridgeRuntime(
            controller: controller,
            executableLocator: BridgeExecutableLocator(bundle: bundle),
            processLauncher: { _ in processHandle },
            socketFactory: { _ in socketClient },
            openURLAction: { _ in }
        )

        try await runtime.start()
        await settle()

        #expect(controller.bridgeLifecycleState == .idle)
        #expect(controller.connectionStatus == .ready)
        #expect(controller.authState == .signedIn(accountDescription: "chatgpt (pro)"))
        #expect(controller.rateLimitState?.buckets.count == 1)
        #expect(controller.threadSummaries.map(\.title) == ["Bootstrap Thread"])
        #expect(sentMessageTypes(from: socketClient.sentTexts) == ["hello", "account.read", "thread.list"])
    }

    @Test func accountLoginResultOpensBrowserAndClearsPendingStateOnAuthChange() async throws {
        let workspace = WorkspaceRecord(url: try temporaryDirectory(named: "runtime-login"), lastOpenedAt: .now)
        let controller = WorkspaceController(workspace: workspace)
        let bundle = try bridgeFixtureBundle()
        let processHandle = FakeBridgeProcessHandle(lines: [startupRecordJSON(port: 4343)])
        let socketClient = FakeBridgeSocketClient(messages: [
            welcomeJSON(requestID: "ateliercode-hello-1"),
            authChangedJSON(requestID: "ateliercode-account-read-2", state: "signed_out", displayName: nil),
            threadListResultJSON(requestID: "ateliercode-thread-list-3", threadTitle: "Thread")
        ])
        var openedURLs: [URL] = []
        let runtime = WorkspaceBridgeRuntime(
            controller: controller,
            executableLocator: BridgeExecutableLocator(bundle: bundle),
            processLauncher: { _ in processHandle },
            socketFactory: { _ in socketClient },
            openURLAction: { openedURLs.append($0) }
        )

        try await runtime.start()
        try await runtime.login()
        socketClient.enqueue(
            accountLoginResultJSON(
                requestID: "ateliercode-account-login-4",
                authURL: "https://example.com/login",
                loginID: "login-42"
            )
        )
        await settle()

        #expect(openedURLs == [URL(string: "https://example.com/login")!])
        #expect(controller.pendingLogin == PendingLogin(
            method: .chatgpt,
            authURL: URL(string: "https://example.com/login")!,
            loginID: "login-42"
        ))

        socketClient.enqueue(authChangedJSON(requestID: nil, state: "signed_in", displayName: "chatgpt (pro)"))
        await settle()

        #expect(controller.pendingLogin == nil)
        #expect(controller.authState == .signedIn(accountDescription: "chatgpt (pro)"))
    }

    @Test func signedOutAuthClearsRateLimitsAndAccountCommandEntries() async throws {
        let workspace = WorkspaceRecord(url: try temporaryDirectory(named: "runtime-signed-out"), lastOpenedAt: .now)
        let controller = WorkspaceController(workspace: workspace)
        let bundle = try bridgeFixtureBundle()
        let processHandle = FakeBridgeProcessHandle(lines: [startupRecordJSON(port: 4545)])
        let socketClient = FakeBridgeSocketClient(messages: [
            welcomeJSON(requestID: "ateliercode-hello-1"),
            authChangedJSON(requestID: "ateliercode-account-read-2", state: "signed_in", displayName: "chatgpt (pro)"),
            rateLimitUpdatedJSON(requestID: "ateliercode-account-read-2"),
            threadListResultJSON(requestID: "ateliercode-thread-list-3", threadTitle: "Thread")
        ])
        let runtime = WorkspaceBridgeRuntime(
            controller: controller,
            executableLocator: BridgeExecutableLocator(bundle: bundle),
            processLauncher: { _ in processHandle },
            socketFactory: { _ in socketClient },
            openURLAction: { _ in }
        )

        try await runtime.start()
        await settle()

        #expect(controller.rateLimitState?.buckets.count == 1)
        #expect(pendingCommandCount(in: runtime) == 0)

        try await runtime.refreshAccount()
        #expect(pendingCommandCount(in: runtime) == 1)
        socketClient.enqueue(authChangedJSON(requestID: "ateliercode-account-read-4", state: "signed_out", displayName: nil))
        await settle()

        #expect(controller.authState == .signedOut)
        #expect(controller.rateLimitState == nil)
        #expect(pendingCommandCount(in: runtime) == 0)

        try await runtime.logout()
        #expect(pendingCommandCount(in: runtime) == 1)
        socketClient.enqueue(authChangedJSON(requestID: "ateliercode-account-logout-5", state: "signed_out", displayName: nil))
        await settle()

        #expect(controller.rateLimitState == nil)
        #expect(pendingCommandCount(in: runtime) == 0)
    }

    @Test func successfulCancelAndApprovalFlowsDrainPendingCommands() async throws {
        let workspace = WorkspaceRecord(url: try temporaryDirectory(named: "runtime-pending-cleanup"), lastOpenedAt: .now)
        let controller = WorkspaceController(workspace: workspace)
        let bundle = try bridgeFixtureBundle()
        let processHandle = FakeBridgeProcessHandle(lines: [startupRecordJSON(port: 4646)])
        let socketClient = FakeBridgeSocketClient(messages: [
            welcomeJSON(requestID: "ateliercode-hello-1"),
            authChangedJSON(requestID: "ateliercode-account-read-2", state: "signed_out", displayName: nil),
            threadListResultJSON(requestID: "ateliercode-thread-list-3", threadTitle: "Thread")
        ])
        let runtime = WorkspaceBridgeRuntime(
            controller: controller,
            executableLocator: BridgeExecutableLocator(bundle: bundle),
            processLauncher: { _ in processHandle },
            socketFactory: { _ in socketClient },
            openURLAction: { _ in }
        )

        try await runtime.start()
        await settle()

        let session = controller.openThread(id: "thread-1", title: "Thread")
        session.enqueueApprovalRequest(
            ApprovalRequest(
                id: "approval-1",
                kind: .generic,
                title: "Approve",
                detail: "Please approve"
            )
        )

        try await runtime.startTurn(prompt: "Ship it")
        #expect(pendingCommandCount(in: runtime) == 1)
        socketClient.enqueue(turnStartedJSON(requestID: "ateliercode-turn-start-4", threadID: "thread-1", turnID: "turn-1"))
        await settle()

        #expect(pendingCommandCount(in: runtime) == 0)

        try await runtime.cancelTurn()
        #expect(pendingCommandCount(in: runtime) == 1)
        socketClient.enqueue(turnCompletedJSON(threadID: "thread-1", turnID: "turn-1", status: "cancelled"))
        await settle()

        #expect(pendingCommandCount(in: runtime) == 0)

        try await runtime.resolveApproval(id: "approval-1", resolution: .approved)
        await settle()

        #expect(pendingCommandCount(in: runtime) == 0)
    }

    @Test func startThreadAndWaitReturnsCreatedSession() async throws {
        let workspace = WorkspaceRecord(url: try temporaryDirectory(named: "runtime-thread-start"), lastOpenedAt: .now)
        let controller = WorkspaceController(workspace: workspace)
        let bundle = try bridgeFixtureBundle()
        let processHandle = FakeBridgeProcessHandle(lines: [startupRecordJSON(port: 4747)])
        let socketClient = FakeBridgeSocketClient(messages: [
            welcomeJSON(requestID: "ateliercode-hello-1"),
            authChangedJSON(requestID: "ateliercode-account-read-2", state: "signed_out", displayName: nil),
            threadListResultJSON(requestID: "ateliercode-thread-list-3", threadTitle: "Thread")
        ])
        let runtime = WorkspaceBridgeRuntime(
            controller: controller,
            executableLocator: BridgeExecutableLocator(bundle: bundle),
            processLauncher: { _ in processHandle },
            socketFactory: { _ in socketClient },
            openURLAction: { _ in }
        )

        try await runtime.start()
        await settle()

        async let session = runtime.startThreadAndWait()
        await settle()

        socketClient.enqueue(threadStartedJSON(
            requestID: "ateliercode-thread-start-4",
            threadID: "thread-42",
            threadTitle: "Fresh Thread"
        ))

        let startedSession = try await session

        #expect(startedSession.threadID == "thread-42")
        #expect(startedSession.title == "Fresh Thread")
        #expect(controller.activeThreadSession?.threadID == "thread-42")
    }

    @Test func streamedMessageDeltasCollapseIntoSingleAssistantTranscriptMessage() async throws {
        let workspace = WorkspaceRecord(url: try temporaryDirectory(named: "runtime-stream"), lastOpenedAt: .now)
        let controller = WorkspaceController(workspace: workspace)
        let bundle = try bridgeFixtureBundle()
        let processHandle = FakeBridgeProcessHandle(lines: [startupRecordJSON(port: 4848)])
        let socketClient = FakeBridgeSocketClient(messages: [
            welcomeJSON(requestID: "ateliercode-hello-1"),
            authChangedJSON(requestID: "ateliercode-account-read-2", state: "signed_out", displayName: nil),
            threadListResultJSON(requestID: "ateliercode-thread-list-3", threadTitle: "Thread")
        ])
        let runtime = WorkspaceBridgeRuntime(
            controller: controller,
            executableLocator: BridgeExecutableLocator(bundle: bundle),
            processLauncher: { _ in processHandle },
            socketFactory: { _ in socketClient },
            openURLAction: { _ in }
        )

        try await runtime.start()
        await settle()

        let session = controller.openThread(id: "thread-1", title: "Thread")

        try await runtime.startTurn(prompt: "Show the transcript")
        socketClient.enqueue(turnStartedJSON(requestID: "ateliercode-turn-start-4", threadID: "thread-1", turnID: "turn-1"))
        socketClient.enqueue(messageDeltaJSON(threadID: "thread-1", turnID: "turn-1", delta: "First chunk"))
        socketClient.enqueue(messageDeltaJSON(threadID: "thread-1", turnID: "turn-1", delta: " and second chunk"))
        socketClient.enqueue(turnCompletedJSON(threadID: "thread-1", turnID: "turn-1", status: "completed"))
        await settle()

        #expect(session.messages.count == 2)
        #expect(session.messages[0].text == "Show the transcript")
        #expect(session.messages[1].text == "First chunk and second chunk")
        #expect(session.turnState.phase == .completed)
        #expect(controller.connectionStatus == .ready)
    }

    @Test func unexpectedBridgeExitMarksConnectionErrorAndFailsInFlightTurn() async throws {
        let workspace = WorkspaceRecord(url: try temporaryDirectory(named: "runtime-exit"), lastOpenedAt: .now)
        let controller = WorkspaceController(workspace: workspace)
        let bundle = try bridgeFixtureBundle()
        let processHandle = FakeBridgeProcessHandle(lines: [startupRecordJSON(port: 4444)])
        let socketClient = FakeBridgeSocketClient(messages: [
            welcomeJSON(requestID: "ateliercode-hello-1"),
            authChangedJSON(requestID: "ateliercode-account-read-2", state: "signed_out", displayName: nil),
            threadListResultJSON(requestID: "ateliercode-thread-list-3", threadTitle: "Thread")
        ])
        let runtime = WorkspaceBridgeRuntime(
            controller: controller,
            executableLocator: BridgeExecutableLocator(bundle: bundle),
            processLauncher: { _ in processHandle },
            socketFactory: { _ in socketClient },
            openURLAction: { _ in }
        )

        try await runtime.start()
        let session = controller.openThread(id: "thread-1", title: "Thread")
        session.beginTurn(userPrompt: "Keep going")
        controller.setConnectionStatus(.streaming)

        processHandle.exit(code: 9)
        await settle()

        #expect(controller.connectionStatus == .error(message: "The embedded bridge exited unexpectedly with status 9."))
        #expect(session.turnState.phase == .failed)
        #expect(session.turnState.failureDescription == "The embedded bridge exited unexpectedly with status 9.")
    }
}

private final class FakeBridgeProcessHandle: BridgeProcessHandle {
    var onExit: (@Sendable (Int32?) -> Void)?
    let stdoutLines: AsyncThrowingStream<String, Error>

    private let continuation: AsyncThrowingStream<String, Error>.Continuation

    init(lines: [String]) {
        var continuation: AsyncThrowingStream<String, Error>.Continuation!
        stdoutLines = AsyncThrowingStream<String, Error> { continuation = $0 }
        self.continuation = continuation

        for line in lines {
            continuation.yield(line)
        }
    }

    func terminate() {
        continuation.finish()
        onExit?(0)
    }

    func exit(code: Int32?) {
        continuation.finish()
        onExit?(code)
    }
}

private final class FakeBridgeSocketClient: BridgeSocketClient {
    private let stream: AsyncThrowingStream<String, Error>
    private let continuation: AsyncThrowingStream<String, Error>.Continuation
    private var iterator: AsyncThrowingStream<String, Error>.AsyncIterator

    private(set) var sentTexts: [String] = []

    init(messages: [String]) {
        var continuation: AsyncThrowingStream<String, Error>.Continuation!
        stream = AsyncThrowingStream<String, Error> { continuation = $0 }
        self.continuation = continuation
        iterator = stream.makeAsyncIterator()

        for message in messages {
            continuation.yield(message)
        }
    }

    func connect() async throws {}

    func send(text: String) async throws {
        sentTexts.append(text)
    }

    func receiveText() async throws -> String {
        guard let message = try await iterator.next() else {
            throw CancellationError()
        }

        return message
    }

    func close() {
        continuation.finish()
    }

    func enqueue(_ message: String) {
        continuation.yield(message)
    }
}

private func bridgeFixtureBundle() throws -> Bundle {
    let appBundleURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("Fixture.app", isDirectory: true)
    let executableURL = appBundleURL
        .appendingPathComponent("Contents", isDirectory: true)
        .appendingPathComponent("MacOS", isDirectory: true)
        .appendingPathComponent(BridgeExecutableLocator.executableName, isDirectory: false)

    try FileManager.default.createDirectory(
        at: executableURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    FileManager.default.createFile(atPath: executableURL.path, contents: Data())

    return try #require(Bundle(url: appBundleURL))
}

private func startupRecordJSON(port: Int) -> String {
    """
    {"recordType":"bridge.startup","bridgeVersion":"0.1.0","protocolVersion":1,"transport":"websocket","host":"127.0.0.1","port":\(port),"pid":999,"startedAt":"2026-03-24T10:00:00Z"}
    """
}

private func welcomeJSON(requestID: String) -> String {
    """
    {"type":"welcome","timestamp":"2026-03-24T10:00:01Z","requestID":"\(requestID)","payload":{"bridgeVersion":"0.1.0","protocolVersion":1,"supportedProtocolVersions":[1],"sessionID":"session-1","transport":"websocket","providers":[{"id":"codex","displayName":"Codex","status":"available"}]}}
    """
}

private func authChangedJSON(requestID: String?, state: String, displayName: String?) -> String {
    let requestFragment = requestID.map { "\"requestID\":\"\($0)\"," } ?? ""
    let accountFragment = displayName.map { "\"account\":{\"displayName\":\"\($0)\"}" } ?? "\"account\":null"
    return """
    {"type":"auth.changed","timestamp":"2026-03-24T10:00:02Z",\(requestFragment)"payload":{"state":"\(state)",\(accountFragment)}}
    """
}

private func rateLimitUpdatedJSON(requestID: String) -> String {
    """
    {"type":"rateLimit.updated","timestamp":"2026-03-24T10:00:03Z","requestID":"\(requestID)","payload":{"accountID":"account-1","buckets":[{"id":"requests:primary","kind":"requests","detail":"Requests: 10% used"}]}}
    """
}

private func threadListResultJSON(requestID: String, threadTitle: String) -> String {
    """
    {"type":"thread.list.result","timestamp":"2026-03-24T10:00:04Z","requestID":"\(requestID)","payload":{"threads":[{"id":"thread-1","title":"\(threadTitle)","previewText":"Preview","updatedAt":"2026-03-24T10:00:04Z"}],"nextCursor":null}}
    """
}

private func accountLoginResultJSON(requestID: String, authURL: String, loginID: String) -> String {
    """
    {"type":"account.login.result","timestamp":"2026-03-24T10:00:05Z","requestID":"\(requestID)","payload":{"method":"chatgpt","authURL":"\(authURL)","loginID":"\(loginID)"}}
    """
}

private func turnStartedJSON(requestID: String, threadID: String, turnID: String) -> String {
    """
    {"type":"turn.started","timestamp":"2026-03-24T10:00:06Z","requestID":"\(requestID)","threadID":"\(threadID)","turnID":"\(turnID)","payload":{"status":"in_progress"}}
    """
}

private func threadStartedJSON(requestID: String, threadID: String, threadTitle: String) -> String {
    """
    {"type":"thread.started","timestamp":"2026-03-24T10:00:05Z","requestID":"\(requestID)","threadID":"\(threadID)","payload":{"thread":{"id":"\(threadID)","title":"\(threadTitle)","previewText":"Preview","updatedAt":"2026-03-24T10:00:05Z"}}}
    """
}

private func messageDeltaJSON(threadID: String, turnID: String, delta: String) -> String {
    """
    {"type":"message.delta","timestamp":"2026-03-24T10:00:06Z","threadID":"\(threadID)","turnID":"\(turnID)","payload":{"messageID":"assistant-1","delta":"\(delta)"}}
    """
}

private func turnCompletedJSON(threadID: String, turnID: String, status: String) -> String {
    """
    {"type":"turn.completed","timestamp":"2026-03-24T10:00:07Z","threadID":"\(threadID)","turnID":"\(turnID)","payload":{"status":"\(status)","detail":null}}
    """
}

private func pendingCommandCount(in runtime: WorkspaceBridgeRuntime) -> Int {
    guard let pendingCommands = Mirror(reflecting: runtime).children.first(where: { $0.label == "pendingCommands" })?.value else {
        return 0
    }

    return Mirror(reflecting: pendingCommands).children.count
}

private func sentMessageTypes(from messages: [String]) -> [String] {
    messages.compactMap { message in
        guard let data = message.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return object["type"] as? String
    }
}

private func settle() async {
    for _ in 0..<10 {
        await Task.yield()
    }
}
