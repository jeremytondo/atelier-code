import AppKit
import Foundation

enum WorkspaceBridgeRuntimeError: LocalizedError {
    case bridgeNotConnected
    case missingActiveThread
    case startupRecordNotFound
    case invalidSocketURL(host: String, port: Int)
    case unexpectedHandshakeMessage

    var errorDescription: String? {
        switch self {
        case .bridgeNotConnected:
            return "The embedded bridge is not connected."
        case .missingActiveThread:
            return "No active thread is selected for this workspace."
        case .startupRecordNotFound:
            return "The bridge did not emit a startup record before its stdout closed."
        case .invalidSocketURL(let host, let port):
            return "The bridge startup record contained an invalid WebSocket address (\(host):\(port))."
        case .unexpectedHandshakeMessage:
            return "The bridge did not respond to hello with a welcome payload."
        }
    }
}

protocol BridgeProcessHandle: AnyObject {
    var stdoutLines: AsyncThrowingStream<String, Error> { get }
    var onExit: (@Sendable (Int32?) -> Void)? { get set }
    func terminate()
}

protocol BridgeSocketClient: AnyObject {
    func connect() async throws
    func send(text: String) async throws
    func receiveText() async throws -> String
    func close()
}

@MainActor
final class WorkspaceBridgeRuntime: WorkspaceConversationRuntime {
    typealias ProcessLauncher = (URL) throws -> any BridgeProcessHandle
    typealias SocketFactory = (URL) -> any BridgeSocketClient
    typealias OpenURLAction = (URL) -> Void

    private enum PendingCommand {
        case threadStart
        case threadResume
        case threadList
        case turnStart(prompt: String)
        case turnCancel
        case approvalResolve(id: String)
        case accountRead
        case accountLogin
        case accountLogout
    }

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()
    private static let clientName = "AtelierCode"
    private static let provider = "codex"

    let controller: WorkspaceController

    private let executableLocator: BridgeExecutableLocator
    private let processLauncher: ProcessLauncher
    private let socketFactory: SocketFactory
    private let openURLAction: OpenURLAction
    private let appVersion: String

    private var processHandle: (any BridgeProcessHandle)?
    private var socketClient: (any BridgeSocketClient)?
    private var receiveTask: Task<Void, Never>?
    private var pendingCommands: [String: PendingCommand] = [:]
    private var pendingThreadStarts: [String: CheckedContinuation<ThreadSession, Error>] = [:]
    private var pendingApprovalResolutions: [String: CheckedContinuation<Void, Error>] = [:]
    private var abandonedThreadRequestIDs: Set<String> = []
    private var requestCounter = 0
    private var currentTurnID: String?
    private var isStopping = false

    init(
        controller: WorkspaceController,
        executableLocator: BridgeExecutableLocator? = nil,
        processLauncher: ProcessLauncher? = nil,
        socketFactory: SocketFactory? = nil,
        openURLAction: OpenURLAction? = nil,
        appVersion: String? = nil
    ) {
        let resolvedExecutableLocator = executableLocator ?? BridgeExecutableLocator()
        let resolvedProcessLauncher = processLauncher ?? { try DefaultBridgeProcessHandle(executableURL: $0) }
        let resolvedSocketFactory = socketFactory ?? { URLSessionBridgeSocketClient(url: $0) }
        let resolvedOpenURLAction = openURLAction ?? { NSWorkspace.shared.open($0) }
        let resolvedAppVersion = appVersion
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0")

        self.controller = controller
        self.executableLocator = resolvedExecutableLocator
        self.processLauncher = resolvedProcessLauncher
        self.socketFactory = resolvedSocketFactory
        self.openURLAction = resolvedOpenURLAction
        self.appVersion = resolvedAppVersion
    }

    func start() async throws {
        guard socketClient == nil, processHandle == nil else {
            return
        }

        controller.setBridgeLifecycleState(.starting)
        controller.setConnectionStatus(.connecting)

        do {
            let executableURL = try executableLocator.embeddedBridgeURL()
            let processHandle = try processLauncher(executableURL)
            self.processHandle = processHandle

            processHandle.onExit = { [weak self] exitCode in
                Task { @MainActor [weak self] in
                    self?.handleBridgeExit(exitCode: exitCode)
                }
            }

            let startupRecord = try await readStartupRecord(from: processHandle.stdoutLines)
            let socketURL = try socketURL(for: startupRecord)
            let socketClient = socketFactory(socketURL)
            self.socketClient = socketClient

            try await socketClient.connect()
            try await sendHello()

            let handshakeMessage = try await receiveInboundMessage()
            guard case .welcome = handshakeMessage else {
                throw WorkspaceBridgeRuntimeError.unexpectedHandshakeMessage
            }

            controller.setBridgeLifecycleState(.idle)
            controller.setConnectionStatus(.ready)

            receiveTask = Task { [weak self] in
                await self?.runReceiveLoop()
            }

            try await refreshAccount()
            try await listThreads()
        } catch {
            handleBridgeFailure(message: error.localizedDescription)
            throw error
        }
    }

    func stop() async {
        isStopping = true
        controller.setBridgeLifecycleState(.stopping)

        receiveTask?.cancel()
        receiveTask = nil
        socketClient?.close()
        socketClient = nil
        processHandle?.onExit = nil
        processHandle?.terminate()
        processHandle = nil
        pendingCommands.removeAll()
        let pendingThreadStarts = self.pendingThreadStarts
        self.pendingThreadStarts.removeAll()
        let pendingApprovalResolutions = self.pendingApprovalResolutions
        self.pendingApprovalResolutions.removeAll()
        abandonedThreadRequestIDs.removeAll()
        currentTurnID = nil
        controller.setAwaitingTurnStart(false)

        for continuation in pendingThreadStarts.values {
            continuation.resume(throwing: CancellationError())
        }

        for continuation in pendingApprovalResolutions.values {
            continuation.resume(throwing: CancellationError())
        }

        controller.setBridgeLifecycleState(.idle)
        controller.setConnectionStatus(.disconnected)
        isStopping = false
    }

    func listThreads(limit: Int? = nil) async throws {
        let requestID = nextRequestID(prefix: "thread-list")
        pendingCommands[requestID] = .threadList
        try await sendCommand(
            id: requestID,
            type: .threadList,
            payload: BridgeThreadListPayload(
                workspacePath: controller.workspace.canonicalPath,
                cursor: nil,
                limit: limit,
                archived: .exclude
            )
        )
    }

    func refreshAccount(forceRefresh: Bool = false) async throws {
        let requestID = nextRequestID(prefix: "account-read")
        pendingCommands[requestID] = .accountRead
        try await sendCommand(
            id: requestID,
            type: .accountRead,
            payload: BridgeAccountReadPayload(forceRefresh: forceRefresh ? true : nil)
        )
    }

    func login(method: BridgeLoginMethod = .chatgpt, credentials: [String: String]? = nil) async throws {
        let requestID = nextRequestID(prefix: "account-login")
        pendingCommands[requestID] = .accountLogin
        try await sendCommand(
            id: requestID,
            type: .accountLogin,
            payload: BridgeAccountLoginPayload(method: method, credentials: credentials)
        )
    }

    func logout(scope: String? = nil) async throws {
        let requestID = nextRequestID(prefix: "account-logout")
        pendingCommands[requestID] = .accountLogout
        try await sendCommand(
            id: requestID,
            type: .accountLogout,
            payload: BridgeAccountLogoutPayload(scope: scope)
        )
    }

    func startThread(title: String? = nil) async throws {
        let requestID = nextRequestID(prefix: "thread-start")
        pendingCommands[requestID] = .threadStart
        try await sendCommand(
            id: requestID,
            type: .threadStart,
            payload: BridgeThreadStartPayload(
                workspacePath: controller.workspace.canonicalPath,
                title: title
            )
        )
    }

    func startThreadAndWait(title: String? = nil) async throws -> ThreadSession {
        let requestID = nextRequestID(prefix: "thread-start")
        pendingCommands[requestID] = .threadStart

        return try await awaitThreadSession(requestID: requestID) { [weak self] in
            guard let self else {
                throw CancellationError()
            }

            try await self.sendCommand(
                id: requestID,
                type: .threadStart,
                payload: BridgeThreadStartPayload(
                    workspacePath: self.controller.workspace.canonicalPath,
                    title: title
                )
            )
        }
    }

    func resumeThreadAndWait(id: String) async throws -> ThreadSession {
        let requestID = nextRequestID(prefix: "thread-resume")
        pendingCommands[requestID] = .threadResume

        return try await awaitThreadSession(requestID: requestID) { [weak self] in
            guard let self else {
                throw CancellationError()
            }

            try await self.sendCommand(
                id: requestID,
                type: .threadResume,
                threadID: id,
                payload: BridgeThreadResumePayload(workspacePath: self.controller.workspace.canonicalPath)
            )
        }
    }

    func resumeThread(id: String) async throws {
        let requestID = nextRequestID(prefix: "thread-resume")
        pendingCommands[requestID] = .threadResume
        try await sendCommand(
            id: requestID,
            type: .threadResume,
            threadID: id,
            payload: BridgeThreadResumePayload(workspacePath: controller.workspace.canonicalPath)
        )
    }

    func startTurn(prompt: String, configuration: BridgeTurnStartConfiguration? = nil) async throws {
        guard let session = controller.activeThreadSession else {
            throw WorkspaceBridgeRuntimeError.missingActiveThread
        }

        let requestID = nextRequestID(prefix: "turn-start")
        pendingCommands[requestID] = .turnStart(prompt: prompt)
        controller.setAwaitingTurnStart(true)
        try await sendCommand(
            id: requestID,
            type: .turnStart,
            threadID: session.threadID,
            payload: BridgeTurnStartPayload(prompt: prompt, configuration: configuration)
        )
    }

    func cancelTurn(reason: String? = nil) async throws {
        guard let session = controller.activeThreadSession,
              let currentTurnID else {
            throw WorkspaceBridgeRuntimeError.missingActiveThread
        }

        let requestID = nextRequestID(prefix: "turn-cancel")
        pendingCommands[requestID] = .turnCancel
        controller.setConnectionStatus(.cancelling)
        try await sendCommand(
            id: requestID,
            type: .turnCancel,
            threadID: session.threadID,
            turnID: currentTurnID,
            payload: BridgeTurnCancelPayload(reason: reason)
        )
    }

    func resolveApproval(id: String, resolution: ApprovalResolution) async throws {
        try await resolveApproval(id: id, resolution: resolution, rememberDecision: false)
    }

    func resolveApproval(id: String, resolution: ApprovalResolution, rememberDecision: Bool = false) async throws {
        guard let session = controller.activeThreadSession else {
            throw WorkspaceBridgeRuntimeError.missingActiveThread
        }

        let requestID = nextRequestID(prefix: "approval-resolve")
        pendingCommands[requestID] = .approvalResolve(id: id)

        try await withCheckedThrowingContinuation { continuation in
            pendingApprovalResolutions[requestID] = continuation

            Task { @MainActor [weak self] in
                guard let self else {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                do {
                    try await self.sendCommand(
                        id: requestID,
                        type: .approvalResolve,
                        threadID: session.threadID,
                        turnID: currentTurnID,
                        payload: BridgeApprovalResolvePayload(
                            approvalID: id,
                            resolution: resolution.bridgeValue,
                            rememberDecision: rememberDecision ? true : nil
                        )
                    )
                } catch {
                    self.pendingCommands.removeValue(forKey: requestID)
                    self.pendingApprovalResolutions.removeValue(forKey: requestID)?.resume(throwing: error)
                }
            }
        }
    }

    private func runReceiveLoop() async {
        do {
            while Task.isCancelled == false {
                let inboundMessage = try await receiveInboundMessage()
                switch inboundMessage {
                case .welcome:
                    continue
                case .event(let event):
                    handleEvent(event)
                }
            }
        } catch is CancellationError {
            return
        } catch {
            guard isStopping == false else {
                return
            }

            handleBridgeFailure(message: error.localizedDescription)
        }
    }

    private func handleEvent(_ event: BridgeEventEnvelope) {
        switch event.payload {
        case .threadStarted(let payload):
            handleThreadStarted(payload, requestID: event.requestID)
        case .turnStarted:
            handleTurnStarted(event)
        case .messageDelta(let payload):
            guard let session = session(for: event.threadID) else {
                return
            }

            session.appendAssistantTextDelta(payload.delta)
        case .thinkingDelta(let payload):
            guard let session = session(for: event.threadID) else {
                return
            }

            session.appendThinkingDelta(payload.delta)
        case .toolStarted(let payload):
            guard let session = session(for: event.threadID) else {
                return
            }

            session.startActivity(
                id: event.activityID ?? UUID().uuidString,
                kind: .tool,
                title: payload.title,
                detail: payload.detail,
                command: payload.command,
                workingDirectory: payload.workingDirectory
            )
        case .toolOutput(let payload):
            guard let session = session(for: event.threadID),
                  let activityID = event.activityID else {
                return
            }

            session.appendActivityOutput(id: activityID, delta: payload.delta)
        case .toolCompleted(let payload):
            guard let session = session(for: event.threadID),
                  let activityID = event.activityID else {
                return
            }

            session.completeActivity(
                id: activityID,
                status: payload.status.activityStatus,
                detail: payload.detail,
                exitCode: payload.exitCode
            )
        case .fileChangeStarted(let payload):
            guard let session = session(for: event.threadID) else {
                return
            }

            session.startActivity(
                id: event.activityID ?? UUID().uuidString,
                kind: .fileChange,
                title: payload.title,
                detail: payload.detail,
                files: payload.files.map { $0.toDiffFileChange() }
            )
        case .fileChangeCompleted(let payload):
            guard let session = session(for: event.threadID),
                  let activityID = event.activityID else {
                return
            }

            session.completeActivity(
                id: activityID,
                status: payload.status.activityStatus,
                detail: payload.detail,
                files: payload.files.map { $0.toDiffFileChange() }
            )
        case .approvalRequested(let payload):
            guard let session = session(for: event.threadID) else {
                return
            }

            session.enqueueApprovalRequest(payload.toApprovalRequest())
        case .approvalResolved(let payload):
            if let requestID = event.requestID {
                pendingCommands.removeValue(forKey: requestID)
                pendingApprovalResolutions.removeValue(forKey: requestID)?.resume()
            }

            guard let session = session(for: event.threadID) else {
                return
            }

            session.resolveApprovalRequest(
                id: payload.approvalID,
                resolution: payload.resolution.approvalResolution
            )
        case .diffUpdated(let payload):
            guard let session = session(for: event.threadID) else {
                return
            }

            session.replaceAggregatedDiff(
                AggregatedDiff(
                    summary: payload.summary,
                    files: payload.files.map { $0.toDiffFileChange() }
                )
            )
        case .planUpdated(let payload):
            guard let session = session(for: event.threadID) else {
                return
            }

            session.replacePlanState(
                PlanState(
                    summary: payload.summary,
                    steps: payload.steps.map { $0.toPlanStep() }
                )
            )
        case .turnCompleted(let payload):
            handleTurnCompleted(payload, event: event)
        case .threadListResult(let payload):
            if let requestID = event.requestID {
                pendingCommands.removeValue(forKey: requestID)
            }

            controller.replaceThreadList(payload.threads.map { $0.toThreadSummary() })
        case .accountLoginResult(let payload):
            if let requestID = event.requestID {
                pendingCommands.removeValue(forKey: requestID)
            }

            handleAccountLoginResult(payload)
        case .authChanged(let payload):
            handleAuthChanged(payload, requestID: event.requestID)
        case .rateLimitUpdated(let payload):
            controller.setRateLimitState(
                RateLimitState(
                    accountID: payload.accountID,
                    buckets: payload.buckets.map { $0.toRateLimitBucketState() }
                )
            )
        case .error(let payload):
            handleBridgeError(payload, requestID: event.requestID)
        case .providerStatus(let payload):
            handleProviderStatus(payload)
        }
    }

    private func handleThreadStarted(_ payload: BridgeThreadStartedPayload, requestID: String?) {
        let summary = payload.thread.toThreadSummary()
        controller.upsertThreadSummary(summary)

        if let requestID, abandonedThreadRequestIDs.remove(requestID) != nil {
            pendingCommands.removeValue(forKey: requestID)
            pendingThreadStarts.removeValue(forKey: requestID)
            return
        }

        if let requestID,
           let pendingCommand = pendingCommands.removeValue(forKey: requestID) {
            let session: ThreadSession
            switch pendingCommand {
            case .threadResume:
                session = controller.resumeThread(id: summary.id, title: summary.title)
            case .threadStart:
                session = controller.openThread(id: summary.id, title: summary.title)
            default:
                session = controller.ensureActiveThreadSession(id: summary.id, title: summary.title)
            }

            if let continuation = pendingThreadStarts.removeValue(forKey: requestID) {
                continuation.resume(returning: session)
            }
            return
        }

        controller.ensureActiveThreadSession(id: summary.id, title: summary.title)
    }

    private func handleTurnStarted(_ event: BridgeEventEnvelope) {
        guard let threadID = event.threadID else {
            return
        }

        let title = controller.threadSummaries.first(where: { $0.id == threadID })?.title
            ?? controller.activeThreadSession?.title
            ?? "Thread"
        let session = controller.ensureActiveThreadSession(id: threadID, title: title)

        if let requestID = event.requestID,
           let pendingCommand = pendingCommands.removeValue(forKey: requestID),
           case .turnStart(let prompt) = pendingCommand,
           session.turnState.phase != .inProgress {
            session.beginTurn(userPrompt: prompt)
        } else if session.turnState.phase != .inProgress {
            session.beginTurn()
        }

        currentTurnID = event.turnID
        controller.setAwaitingTurnStart(false)
        controller.setConnectionStatus(.streaming)
    }

    private func handleTurnCompleted(_ payload: BridgeTurnCompletedPayload, event: BridgeEventEnvelope) {
        guard let session = session(for: event.threadID) else {
            return
        }

        if payload.status == .cancelled || payload.status == .interrupted {
            clearPendingCommands { command in
                if case .turnCancel = command {
                    return true
                }

                return false
            }
        }

        if currentTurnID == event.turnID {
            currentTurnID = nil
        }

        controller.setAwaitingTurnStart(false)

        switch payload.status {
        case .completed:
            session.completeTurn()
            controller.setConnectionStatus(.ready)
        case .cancelled, .interrupted:
            session.cancelTurn()
            controller.setConnectionStatus(.ready)
        case .failed:
            session.failTurn(payload.detail ?? "The bridge reported a failed turn.")
            controller.setConnectionStatus(.error(message: payload.detail ?? "The bridge reported a failed turn."))
        }
    }

    private func handleAccountLoginResult(_ payload: BridgeAccountLoginResultPayload) {
        guard let authURLString = payload.authURL,
              let authURL = URL(string: authURLString) else {
            controller.clearPendingLogin()
            return
        }

        controller.setPendingLogin(
            PendingLogin(
                method: payload.method.toAccountLoginMethod(),
                authURL: authURL,
                loginID: payload.loginID
            )
        )
        openURLAction(authURL)
    }

    private func handleAuthChanged(_ payload: BridgeAuthChangedPayload, requestID: String?) {
        if let requestID {
            pendingCommands.removeValue(forKey: requestID)
        }

        switch payload.state {
        case .unknown:
            controller.setAuthState(.unknown)
        case .signedOut:
            controller.setAuthState(.signedOut)
            controller.clearPendingLogin()
            controller.setRateLimitState(nil)
        case .signedIn:
            controller.setAuthState(.signedIn(accountDescription: payload.account?.displayName ?? "Signed In"))
            controller.clearPendingLogin()
        }
    }

    private func handleBridgeError(_ payload: BridgeErrorPayload, requestID: String?) {
        if let requestID,
           let pendingCommand = pendingCommands.removeValue(forKey: requestID) {
            switch pendingCommand {
            case .threadStart:
                pendingThreadStarts.removeValue(forKey: requestID)?.resume(throwing: RuntimeBridgeError.requestFailed(message: payload.message))
                controller.setAwaitingTurnStart(false)
            case .threadResume:
                pendingThreadStarts.removeValue(forKey: requestID)?.resume(throwing: RuntimeBridgeError.requestFailed(message: payload.message))
            case .turnStart:
                controller.setAwaitingTurnStart(false)
                controller.activeThreadSession?.failTurn(payload.message)
                currentTurnID = nil
            case .approvalResolve(let approvalID):
                controller.activeThreadSession?.clearApprovalResolution(id: approvalID)
                pendingApprovalResolutions.removeValue(forKey: requestID)?.resume(
                    throwing: RuntimeBridgeError.requestFailed(message: payload.message)
                )
            case .accountLogin:
                controller.clearPendingLogin()
            default:
                break
            }
        }

        controller.setConnectionStatus(.error(message: payload.message))
    }

    private func handleProviderStatus(_ payload: BridgeProviderStatusPayload) {
        switch payload.status {
        case .starting:
            controller.setConnectionStatus(.connecting)
        case .ready:
            let status: ConnectionStatus = currentTurnID == nil ? .ready : .streaming
            controller.setConnectionStatus(status)
        case .degraded, .error:
            controller.setAwaitingTurnStart(false)
            controller.setConnectionStatus(.error(message: payload.detail))
        case .disconnected:
            controller.setAwaitingTurnStart(false)
            controller.setConnectionStatus(.disconnected)
        }
    }

    private func session(for threadID: String?) -> ThreadSession? {
        guard let threadID else {
            return nil
        }

        let title = controller.threadSummaries.first(where: { $0.id == threadID })?.title
            ?? controller.activeThreadSession?.title
            ?? "Thread"
        return controller.ensureActiveThreadSession(id: threadID, title: title)
    }

    private func sendHello() async throws {
        guard let socketClient else {
            throw WorkspaceBridgeRuntimeError.bridgeNotConnected
        }

        let hello = BridgeHelloEnvelope(
            id: nextRequestID(prefix: "hello"),
            timestamp: Self.timestamp(),
            payload: BridgeHelloPayload(
                appVersion: appVersion,
                protocolVersion: BridgeProtocolVersion.current,
                supportedProtocolVersions: BridgeProtocolVersion.supported,
                clientName: Self.clientName,
                platform: "macOS",
                transport: "websocket"
            )
        )
        let data = try Self.encoder.encode(hello)
        try await socketClient.send(text: String(decoding: data, as: UTF8.self))
    }

    private func sendCommand<Payload: Encodable>(
        id: String,
        type: BridgeCommandType,
        threadID: String? = nil,
        turnID: String? = nil,
        payload: Payload
    ) async throws {
        guard let socketClient else {
            throw WorkspaceBridgeRuntimeError.bridgeNotConnected
        }

        let command = BridgeCommandEnvelope(
            id: id,
            type: type,
            timestamp: Self.timestamp(),
            provider: Self.provider,
            threadID: threadID,
            turnID: turnID,
            payload: payload
        )
        let data = try Self.encoder.encode(command)
        try await socketClient.send(text: String(decoding: data, as: UTF8.self))
    }

    private func receiveInboundMessage() async throws -> BridgeInboundMessage {
        guard let socketClient else {
            throw WorkspaceBridgeRuntimeError.bridgeNotConnected
        }

        let text = try await socketClient.receiveText()
        let data = Data(text.utf8)
        return try Self.decoder.decode(BridgeInboundMessage.self, from: data)
    }

    private func readStartupRecord(
        from stdoutLines: AsyncThrowingStream<String, Error>
    ) async throws -> BridgeStartupRecord {
        for try await line in stdoutLines {
            guard let data = line.data(using: .utf8) else {
                continue
            }

            if let record = try? Self.decoder.decode(BridgeStartupRecord.self, from: data),
               record.recordType == "bridge.startup" {
                return record
            }
        }

        throw WorkspaceBridgeRuntimeError.startupRecordNotFound
    }

    private func socketURL(for startupRecord: BridgeStartupRecord) throws -> URL {
        var components = URLComponents()
        components.scheme = "ws"
        components.host = startupRecord.host
        components.port = startupRecord.port

        guard let url = components.url else {
            throw WorkspaceBridgeRuntimeError.invalidSocketURL(
                host: startupRecord.host,
                port: startupRecord.port
            )
        }

        return url
    }

    private func handleBridgeExit(exitCode: Int32?) {
        processHandle = nil

        guard isStopping == false else {
            return
        }

        let message: String
        if let exitCode {
            message = "The embedded bridge exited unexpectedly with status \(exitCode)."
        } else {
            message = "The embedded bridge exited unexpectedly."
        }

        handleBridgeFailure(message: message)
    }

    private func handleBridgeFailure(message: String) {
        receiveTask?.cancel()
        receiveTask = nil
        socketClient?.close()
        socketClient = nil
        processHandle?.onExit = nil
        processHandle?.terminate()
        processHandle = nil
        pendingCommands.removeAll()
        let pendingThreadStarts = self.pendingThreadStarts
        self.pendingThreadStarts.removeAll()
        let pendingApprovalResolutions = self.pendingApprovalResolutions
        self.pendingApprovalResolutions.removeAll()
        abandonedThreadRequestIDs.removeAll()
        currentTurnID = nil
        controller.setBridgeLifecycleState(.idle)
        controller.setAwaitingTurnStart(false)
        controller.setConnectionStatus(.error(message: message))

        for continuation in pendingThreadStarts.values {
            continuation.resume(throwing: RuntimeBridgeError.requestFailed(message: message))
        }

        for continuation in pendingApprovalResolutions.values {
            continuation.resume(throwing: RuntimeBridgeError.requestFailed(message: message))
        }

        if controller.activeThreadSession?.turnState.phase == .inProgress {
            controller.activeThreadSession?.failTurn(message)
        }
    }

    private func nextRequestID(prefix: String) -> String {
        requestCounter += 1
        return "ateliercode-\(prefix)-\(requestCounter)"
    }

    private func awaitThreadSession(
        requestID: String,
        sendAction: @escaping @MainActor () async throws -> Void
    ) async throws -> ThreadSession {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                pendingThreadStarts[requestID] = continuation

                Task { @MainActor in
                    do {
                        try await sendAction()
                    } catch {
                        self.pendingCommands.removeValue(forKey: requestID)
                        self.pendingThreadStarts.removeValue(forKey: requestID)?.resume(throwing: error)
                    }
                }
            }
        }, onCancel: {
            Task { @MainActor [weak self] in
                self?.abandonThreadRequest(id: requestID)
            }
        })
    }

    private func abandonThreadRequest(id: String) {
        abandonedThreadRequestIDs.insert(id)
        pendingCommands.removeValue(forKey: id)
        pendingThreadStarts.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func clearPendingCommands(where shouldRemove: (PendingCommand) -> Bool) {
        pendingCommands = pendingCommands.filter { _, command in
            shouldRemove(command) == false
        }
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: .now)
    }
}

private enum RuntimeBridgeError: LocalizedError {
    case requestFailed(message: String)

    var errorDescription: String? {
        switch self {
        case .requestFailed(let message):
            return message
        }
    }
}

private final class DefaultBridgeProcessHandle: BridgeProcessHandle {
    var onExit: (@Sendable (Int32?) -> Void)?
    let stdoutLines: AsyncThrowingStream<String, Error>

    private let stdoutContinuation: AsyncThrowingStream<String, Error>.Continuation
    private let process: Process
    private let lock = NSLock()
    private var stdoutBuffer = Data()
    private var hasFinished = false

    init(executableURL: URL) throws {
        var continuation: AsyncThrowingStream<String, Error>.Continuation!
        stdoutLines = AsyncThrowingStream<String, Error> { continuation = $0 }
        stdoutContinuation = continuation

        let process = Process()
        self.process = process

        let stdoutPipe = Pipe()
        process.executableURL = executableURL
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(stdoutData: handle.availableData)
        }

        process.terminationHandler = { [weak self] finishedProcess in
            self?.finishStdoutStream()
            self?.onExit?(finishedProcess.terminationStatus)
        }

        try process.run()
    }

    func terminate() {
        if process.isRunning {
            process.terminate()
        }
    }

    private func consume(stdoutData: Data) {
        lock.lock()
        defer { lock.unlock() }

        guard hasFinished == false else {
            return
        }

        if stdoutData.isEmpty {
            finishLocked()
            return
        }

        stdoutBuffer.append(stdoutData)

        while let newlineIndex = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer.prefix(upTo: newlineIndex)
            stdoutBuffer.removeSubrange(...newlineIndex)
            stdoutContinuation.yield(String(decoding: lineData, as: UTF8.self))
        }
    }

    private func finishStdoutStream() {
        lock.lock()
        defer { lock.unlock() }
        finishLocked()
    }

    private func finishLocked() {
        guard hasFinished == false else {
            return
        }

        hasFinished = true

        if stdoutBuffer.isEmpty == false {
            stdoutContinuation.yield(String(decoding: stdoutBuffer, as: UTF8.self))
            stdoutBuffer.removeAll(keepingCapacity: false)
        }

        stdoutContinuation.finish()

        if let pipe = process.standardOutput as? Pipe {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
    }
}

private final class URLSessionBridgeSocketClient: BridgeSocketClient {
    private let url: URL
    private let session: URLSession
    private var task: URLSessionWebSocketTask?

    init(url: URL, session: URLSession = URLSession(configuration: .default)) {
        self.url = url
        self.session = session
    }

    func connect() async throws {
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
    }

    func send(text: String) async throws {
        guard let task else {
            throw WorkspaceBridgeRuntimeError.bridgeNotConnected
        }

        try await task.send(.string(text))
    }

    func receiveText() async throws -> String {
        guard let task else {
            throw WorkspaceBridgeRuntimeError.bridgeNotConnected
        }

        switch try await task.receive() {
        case .string(let text):
            return text
        case .data(let data):
            return String(decoding: data, as: UTF8.self)
        @unknown default:
            throw WorkspaceBridgeRuntimeError.unexpectedHandshakeMessage
        }
    }

    func close() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session.invalidateAndCancel()
    }
}

private extension ApprovalResolution {
    var bridgeValue: BridgeApprovalResolutionValue {
        switch self {
        case .approved:
            return .approved
        case .declined:
            return .declined
        case .cancelled:
            return .cancelled
        case .stale:
            return .stale
        }
    }
}

private extension BridgeActivityStatusValue {
    var activityStatus: ActivityStatus {
        switch self {
        case .running:
            return .running
        case .completed:
            return .completed
        case .failed:
            return .failed
        case .cancelled:
            return .cancelled
        }
    }
}
