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
    typealias SleepAction = @Sendable (TimeInterval) async -> Void

    private enum PendingCommand {
        case threadStart
        case threadResume
        case threadRead
        case threadFork
        case threadRename(threadID: String)
        case threadArchive(threadID: String)
        case threadUnarchive
        case threadRollback
        case threadList(archived: Bool)
        case turnStart(threadID: String, prompt: String)
        case turnCancel(threadID: String)
        case approvalResolve(threadID: String, id: String)
        case accountRead
        case accountLogin
        case accountLogout
    }

    private struct PendingThreadListRequest {
        let archived: Bool
        var summariesByID: [String: ThreadSummary]
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
    private let minimumVisibleRunningActivityDuration: TimeInterval
    private let now: () -> Date
    private let sleep: SleepAction

    private var processHandle: (any BridgeProcessHandle)?
    private var socketClient: (any BridgeSocketClient)?
    private var receiveTask: Task<Void, Never>?
    private var pendingCommands: [String: PendingCommand] = [:]
    private var pendingThreadSessions: [String: CheckedContinuation<ThreadSession, Error>] = [:]
    private var pendingVoidResponses: [String: CheckedContinuation<Void, Error>] = [:]
    private var pendingApprovalResolutions: [String: CheckedContinuation<Void, Error>] = [:]
    private var pendingThreadListsByRequestID: [String: PendingThreadListRequest] = [:]
    private var abandonedThreadRequestIDs: Set<String> = []
    private var requestCounter = 0
    private var runningActivityStartedAt: [String: Date] = [:]
    private var pendingActivityCompletions: [String: Task<Void, Never>] = [:]
    private var isStopping = false

    init(
        controller: WorkspaceController,
        executableLocator: BridgeExecutableLocator? = nil,
        processLauncher: ProcessLauncher? = nil,
        socketFactory: SocketFactory? = nil,
        openURLAction: OpenURLAction? = nil,
        appVersion: String? = nil,
        minimumVisibleRunningActivityDuration: TimeInterval = 0.2,
        now: @escaping () -> Date = Date.init,
        sleep: SleepAction? = nil
    ) {
        let resolvedExecutableLocator = executableLocator ?? BridgeExecutableLocator()
        let resolvedProcessLauncher = processLauncher ?? { try DefaultBridgeProcessHandle(executableURL: $0) }
        let resolvedSocketFactory = socketFactory ?? { URLSessionBridgeSocketClient(url: $0) }
        let resolvedOpenURLAction = openURLAction ?? { NSWorkspace.shared.open($0) }
        let resolvedAppVersion = appVersion
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0")
        let resolvedSleep = sleep ?? { duration in
            let nanoseconds = UInt64(max(0, duration) * 1_000_000_000)
            guard nanoseconds > 0 else {
                return
            }

            try? await Task.sleep(nanoseconds: nanoseconds)
        }

        self.controller = controller
        self.executableLocator = resolvedExecutableLocator
        self.processLauncher = resolvedProcessLauncher
        self.socketFactory = resolvedSocketFactory
        self.openURLAction = resolvedOpenURLAction
        self.appVersion = resolvedAppVersion
        self.minimumVisibleRunningActivityDuration = max(0, minimumVisibleRunningActivityDuration)
        self.now = now
        self.sleep = resolvedSleep
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
            guard case .welcome(let welcomeEnvelope) = handshakeMessage else {
                throw WorkspaceBridgeRuntimeError.unexpectedHandshakeMessage
            }

            controller.setBridgeEnvironmentDiagnostics(
                welcomeEnvelope.payload.environment?.toWorkspaceBridgeEnvironmentDiagnostics()
            )

            controller.setBridgeLifecycleState(.idle)
            controller.setConnectionStatus(.ready)

            receiveTask = Task { [weak self] in
                await self?.runReceiveLoop()
            }

            try await refreshAccount()
            try await listThreads(archived: false)
        } catch {
            handleBridgeFailure(message: error.localizedDescription)
            throw error
        }
    }

    func stop() async {
        isStopping = true
        controller.setBridgeLifecycleState(.stopping)

        cancelPendingActivityCompletions()
        receiveTask?.cancel()
        receiveTask = nil
        socketClient?.close()
        socketClient = nil
        processHandle?.onExit = nil
        processHandle?.terminate()
        processHandle = nil
        pendingCommands.removeAll()
        let pendingThreadSessions = self.pendingThreadSessions
        self.pendingThreadSessions.removeAll()
        let pendingVoidResponses = self.pendingVoidResponses
        self.pendingVoidResponses.removeAll()
        let pendingApprovalResolutions = self.pendingApprovalResolutions
        self.pendingApprovalResolutions.removeAll()
        pendingThreadListsByRequestID.removeAll()
        abandonedThreadRequestIDs.removeAll()
        for summary in controller.threadSummaries {
            controller.setCurrentTurnID(nil, for: summary.id)
            controller.setAwaitingTurnStart(false, for: summary.id)
        }

        for continuation in pendingThreadSessions.values {
            continuation.resume(throwing: CancellationError())
        }

        for continuation in pendingVoidResponses.values {
            continuation.resume(throwing: CancellationError())
        }

        for continuation in pendingApprovalResolutions.values {
            continuation.resume(throwing: CancellationError())
        }

        controller.setBridgeLifecycleState(.idle)
        controller.setConnectionStatus(.disconnected)
        isStopping = false
    }

    func listThreads(archived: Bool) async throws {
        controller.beginThreadListSync(archived: archived)

        do {
            try await sendThreadListRequest(
                archived: archived,
                cursor: nil,
                accumulatedSummariesByID: [:]
            )
        } catch {
            controller.markThreadListSyncFailed(archived: archived)
            throw error
        }
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

    func readThreadAndWait(id: String, includeTurns: Bool = true) async throws -> ThreadSession {
        let requestID = nextRequestID(prefix: "thread-read")
        pendingCommands[requestID] = .threadRead

        return try await awaitThreadSession(requestID: requestID) { [weak self] in
            guard let self else {
                throw CancellationError()
            }

            try await self.sendCommand(
                id: requestID,
                type: .threadRead,
                threadID: id,
                payload: BridgeThreadReadPayload(includeTurns: includeTurns ? true : nil)
            )
        }
    }

    func forkThreadAndWait(id: String) async throws -> ThreadSession {
        let requestID = nextRequestID(prefix: "thread-fork")
        pendingCommands[requestID] = .threadFork

        return try await awaitThreadSession(requestID: requestID) { [weak self] in
            guard let self else {
                throw CancellationError()
            }

            try await self.sendCommand(
                id: requestID,
                type: .threadFork,
                threadID: id,
                payload: BridgeThreadForkPayload(workspacePath: self.controller.workspace.canonicalPath)
            )
        }
    }

    func renameThread(id: String, title: String) async throws {
        let requestID = nextRequestID(prefix: "thread-rename")
        pendingCommands[requestID] = .threadRename(threadID: id)

        try await awaitVoidResponse(requestID: requestID) { [weak self] in
            guard let self else {
                throw CancellationError()
            }

            try await self.sendCommand(
                id: requestID,
                type: .threadRename,
                threadID: id,
                payload: BridgeThreadRenamePayload(title: title)
            )
        }
    }

    func archiveThread(id: String) async throws {
        if shouldArchiveThreadLocally(id: id) {
            applyLocalThreadArchive(threadID: id)
            return
        }

        let requestID = nextRequestID(prefix: "thread-archive")
        pendingCommands[requestID] = .threadArchive(threadID: id)

        try await awaitVoidResponse(requestID: requestID) { [weak self] in
            guard let self else {
                throw CancellationError()
            }

            try await self.sendCommand(
                id: requestID,
                type: .threadArchive,
                threadID: id,
                payload: BridgeThreadArchivePayload()
            )
        }
    }

    func unarchiveThreadAndWait(id: String) async throws -> ThreadSession {
        if shouldArchiveThreadLocally(id: id) {
            applyLocalThreadUnarchive(threadID: id)
            return controller.ensureThreadSession(
                id: id,
                title: controller.threadSummary(id: id)?.title ?? "Recovered Conversation",
                markSelected: false
            )
        }

        let requestID = nextRequestID(prefix: "thread-unarchive")
        pendingCommands[requestID] = .threadUnarchive

        return try await awaitThreadSession(requestID: requestID) { [weak self] in
            guard let self else {
                throw CancellationError()
            }

            try await self.sendCommand(
                id: requestID,
                type: .threadUnarchive,
                threadID: id,
                payload: BridgeThreadUnarchivePayload()
            )
        }
    }

    func rollbackThreadAndWait(id: String, numTurns: Int) async throws -> ThreadSession {
        let requestID = nextRequestID(prefix: "thread-rollback")
        pendingCommands[requestID] = .threadRollback

        return try await awaitThreadSession(requestID: requestID) { [weak self] in
            guard let self else {
                throw CancellationError()
            }

            try await self.sendCommand(
                id: requestID,
                type: .threadRollback,
                threadID: id,
                payload: BridgeThreadRollbackPayload(numTurns: numTurns)
            )
        }
    }

    func startTurn(prompt: String, configuration: BridgeTurnStartConfiguration? = nil) async throws {
        guard let threadID = controller.lastActiveThreadID else {
            throw WorkspaceBridgeRuntimeError.missingActiveThread
        }

        try await startTurn(threadID: threadID, prompt: prompt, configuration: configuration)
    }

    func startTurn(threadID: String, prompt: String, configuration: BridgeTurnStartConfiguration? = nil) async throws {
        let title = controller.threadSummary(id: threadID)?.title ?? controller.threadSession(id: threadID)?.title ?? "Thread"
        let session = controller.ensureThreadSession(id: threadID, title: title, markSelected: false)

        if session.turnState.phase != .inProgress {
            session.beginTurn(userPrompt: prompt)
        }

        controller.markThreadActivity(
            id: threadID,
            at: now(),
            previewText: prompt,
            isRunning: true,
            hasUnreadActivity: controller.lastActiveThreadID == threadID ? false : true
        )

        let requestID = nextRequestID(prefix: "turn-start")
        pendingCommands[requestID] = .turnStart(threadID: threadID, prompt: prompt)
        controller.setAwaitingTurnStart(true, for: threadID)
        try await sendCommand(
            id: requestID,
            type: .turnStart,
            threadID: threadID,
            payload: BridgeTurnStartPayload(prompt: prompt, configuration: configuration)
        )
    }

    func cancelTurn(reason: String? = nil) async throws {
        guard let threadID = controller.lastActiveThreadID else {
            throw WorkspaceBridgeRuntimeError.missingActiveThread
        }

        try await cancelTurn(threadID: threadID, reason: reason)
    }

    func cancelTurn(threadID: String, reason: String? = nil) async throws {
        guard let currentTurnID = controller.currentTurnID(for: threadID) else {
            throw WorkspaceBridgeRuntimeError.missingActiveThread
        }

        let requestID = nextRequestID(prefix: "turn-cancel")
        pendingCommands[requestID] = .turnCancel(threadID: threadID)
        controller.setConnectionStatus(.cancelling)
        try await sendCommand(
            id: requestID,
            type: .turnCancel,
            threadID: threadID,
            turnID: currentTurnID,
            payload: BridgeTurnCancelPayload(reason: reason)
        )
    }

    func resolveApproval(id: String, resolution: ApprovalResolution) async throws {
        guard let threadID = controller.lastActiveThreadID else {
            throw WorkspaceBridgeRuntimeError.missingActiveThread
        }

        try await resolveApproval(threadID: threadID, id: id, resolution: resolution)
    }

    func resolveApproval(threadID: String, id: String, resolution: ApprovalResolution) async throws {
        try await resolveApproval(threadID: threadID, id: id, resolution: resolution, rememberDecision: false)
    }

    func resolveApproval(
        threadID: String,
        id: String,
        resolution: ApprovalResolution,
        rememberDecision: Bool = false
    ) async throws {
        guard controller.threadSession(id: threadID) != nil else {
            throw WorkspaceBridgeRuntimeError.missingActiveThread
        }

        let requestID = nextRequestID(prefix: "approval-resolve")
        pendingCommands[requestID] = .approvalResolve(threadID: threadID, id: id)

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
                        threadID: threadID,
                        turnID: self.controller.currentTurnID(for: threadID),
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
                    await handleEvent(event)
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

    private func handleEvent(_ event: BridgeEventEnvelope) async {
        adoptTurnContextIfNeeded(from: event)

        switch event.payload {
        case .threadStarted(let payload):
            handleThreadStarted(payload, requestID: event.requestID)
        case .threadArchived(let payload):
            handleThreadArchived(payload, requestID: event.requestID)
        case .threadUnarchived(let payload):
            handleThreadUnarchived(payload, requestID: event.requestID)
        case .turnStarted:
            handleTurnStarted(event)
        case .messageDelta(let payload):
            guard let threadID = event.threadID,
                  let session = session(for: threadID) else {
                return
            }

            session.appendAssistantTextDelta(
                payload.delta,
                itemID: event.itemID ?? payload.messageID
            )
            controller.markThreadActivity(
                id: threadID,
                at: bridgeDate(from: event.timestamp) ?? now(),
                previewText: payload.delta,
                isRunning: true,
                hasUnreadActivity: controller.lastActiveThreadID == threadID ? false : true
            )
        case .thinkingDelta(let payload):
            guard let threadID = event.threadID,
                  let session = session(for: threadID) else {
                return
            }

            session.appendThinkingDelta(
                payload.delta,
                itemID: event.itemID ?? "reasoning-\(event.turnID ?? "active")"
            )
            controller.markThreadActivity(
                id: threadID,
                at: bridgeDate(from: event.timestamp) ?? now(),
                isRunning: true,
                hasUnreadActivity: controller.lastActiveThreadID == threadID ? false : true
            )
        case .toolStarted(let payload):
            guard let threadID = event.threadID,
                  let session = session(for: threadID) else {
                return
            }

            if let activityID = event.activityID {
                markActivityStarted(id: activityID)
            }

            session.startActivity(
                id: event.activityID ?? UUID().uuidString,
                kind: .tool,
                title: payload.title,
                detail: payload.detail,
                command: payload.command,
                workingDirectory: payload.workingDirectory
            )
            controller.markThreadActivity(
                id: threadID,
                at: bridgeDate(from: event.timestamp) ?? now(),
                previewText: payload.title,
                isRunning: true,
                hasUnreadActivity: controller.lastActiveThreadID == threadID ? false : true
            )
        case .toolOutput(let payload):
            guard let threadID = event.threadID,
                  let session = session(for: threadID),
                  let activityID = event.activityID else {
                return
            }

            if session.hasTurnItem(id: activityID) == false {
                markActivityStarted(id: activityID)
                session.startActivity(
                    id: activityID,
                    kind: .tool,
                    title: "Tool Call",
                    detail: "Running"
                )
            }

            session.appendActivityOutput(id: activityID, delta: payload.delta)
            controller.markThreadActivity(
                id: threadID,
                at: bridgeDate(from: event.timestamp) ?? now(),
                isRunning: true,
                hasUnreadActivity: controller.lastActiveThreadID == threadID ? false : true
            )
        case .toolCompleted(let payload):
            guard let threadID = event.threadID,
                  let session = session(for: threadID),
                  let activityID = event.activityID else {
                return
            }

            if session.hasTurnItem(id: activityID) == false {
                markActivityStarted(id: activityID)
                session.startActivity(
                    id: activityID,
                    kind: .tool,
                    title: "Tool Call",
                    detail: "Running"
                )
            }

            completeActivityWhenVisible(threadID: event.threadID, activityID: activityID) { session in
                session.completeActivity(
                    id: activityID,
                    status: payload.status.activityStatus,
                    detail: payload.detail,
                    exitCode: payload.exitCode
                )
            }
            controller.markThreadActivity(
                id: threadID,
                at: bridgeDate(from: event.timestamp) ?? now(),
                isRunning: true,
                hasUnreadActivity: controller.lastActiveThreadID == threadID ? false : true
            )
        case .fileChangeStarted(let payload):
            guard let threadID = event.threadID,
                  let session = session(for: threadID) else {
                return
            }

            if let activityID = event.activityID {
                markActivityStarted(id: activityID)
            }

            session.startActivity(
                id: event.activityID ?? UUID().uuidString,
                kind: .fileChange,
                title: payload.title,
                detail: payload.detail,
                files: payload.files.map { $0.toDiffFileChange() }
            )
            controller.markThreadActivity(
                id: threadID,
                at: bridgeDate(from: event.timestamp) ?? now(),
                previewText: payload.title,
                isRunning: true,
                hasUnreadActivity: controller.lastActiveThreadID == threadID ? false : true
            )
        case .fileChangeCompleted(let payload):
            guard let threadID = event.threadID,
                  let session = session(for: threadID),
                  let activityID = event.activityID else {
                return
            }

            if session.hasTurnItem(id: activityID) == false {
                markActivityStarted(id: activityID)
                session.startActivity(
                    id: activityID,
                    kind: .fileChange,
                    title: payload.detail ?? "File Change",
                    detail: "Running",
                    files: payload.files.map { $0.toDiffFileChange() }
                )
            }

            completeActivityWhenVisible(threadID: event.threadID, activityID: activityID) { session in
                session.completeActivity(
                    id: activityID,
                    status: payload.status.activityStatus,
                    detail: payload.detail,
                    files: payload.files.map { $0.toDiffFileChange() }
                )
            }
            controller.markThreadActivity(
                id: threadID,
                at: bridgeDate(from: event.timestamp) ?? now(),
                isRunning: true,
                hasUnreadActivity: controller.lastActiveThreadID == threadID ? false : true
            )
        case .approvalRequested(let payload):
            guard let threadID = event.threadID,
                  let session = session(for: threadID) else {
                return
            }

            session.enqueueApprovalRequest(payload.toApprovalRequest())
            controller.markThreadActivity(
                id: threadID,
                at: bridgeDate(from: event.timestamp) ?? now(),
                isRunning: true,
                hasUnreadActivity: controller.lastActiveThreadID == threadID ? false : true
            )
        case .approvalResolved(let payload):
            if let requestID = event.requestID {
                pendingCommands.removeValue(forKey: requestID)
                pendingApprovalResolutions.removeValue(forKey: requestID)?.resume()
            }

            guard let threadID = event.threadID,
                  let session = session(for: threadID) else {
                return
            }

            session.resolveApprovalRequest(
                id: payload.approvalID,
                resolution: payload.resolution.approvalResolution
            )
            controller.markThreadActivity(
                id: threadID,
                at: bridgeDate(from: event.timestamp) ?? now(),
                isRunning: true,
                hasUnreadActivity: controller.lastActiveThreadID == threadID ? false : true
            )
        case .diffUpdated(let payload):
            guard let threadID = event.threadID,
                  let session = session(for: threadID) else {
                return
            }

            session.replaceAggregatedDiff(
                AggregatedDiff(
                    summary: payload.summary,
                    files: payload.files.map { $0.toDiffFileChange() }
                )
            )
            controller.markThreadActivity(
                id: threadID,
                at: bridgeDate(from: event.timestamp) ?? now(),
                isRunning: true,
                hasUnreadActivity: controller.lastActiveThreadID == threadID ? false : true
            )
        case .planUpdated(let payload):
            guard let threadID = event.threadID,
                  let session = session(for: threadID) else {
                return
            }

            session.replacePlanState(
                PlanState(
                    summary: payload.summary,
                    steps: payload.steps.map { $0.toPlanStep() }
                )
            )
            controller.markThreadActivity(
                id: threadID,
                at: bridgeDate(from: event.timestamp) ?? now(),
                isRunning: true,
                hasUnreadActivity: controller.lastActiveThreadID == threadID ? false : true
            )
        case .turnCompleted(let payload):
            handleTurnCompleted(payload, event: event)
        case .threadListResult(let payload):
            await handleThreadListResult(
                payload,
                requestID: event.requestID,
                listedAt: bridgeDate(from: event.timestamp) ?? now()
            )
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
        let pendingCommand = requestID.flatMap { pendingCommands[$0] }
        var summary = payload.thread.toThreadSummary()

        if case .threadStart? = pendingCommand,
           payload.thread.messages?.isEmpty != false {
            summary.isVisibleInSidebar = controller.threadSummary(id: summary.id)?.isVisibleInSidebar ?? false
        }

        controller.upsertThreadSummary(summary)

        if let requestID, abandonedThreadRequestIDs.remove(requestID) != nil {
            pendingCommands.removeValue(forKey: requestID)
            pendingThreadSessions.removeValue(forKey: requestID)
            return
        }

        if let requestID,
           let pendingCommand = pendingCommands.removeValue(forKey: requestID) {
            let session: ThreadSession
            switch pendingCommand {
            case .threadResume, .threadRead, .threadFork, .threadRollback, .threadUnarchive:
                session = controller.resumeThread(
                    id: summary.id,
                    title: summary.title,
                    messages: payload.thread.messages?.map { $0.toConversationMessage() } ?? []
                )
            case .threadStart:
                if let messages = payload.thread.messages, messages.isEmpty == false {
                    session = controller.resumeThread(
                        id: summary.id,
                        title: summary.title,
                        messages: messages.map { $0.toConversationMessage() }
                    )
                } else {
                    session = controller.openThread(
                        id: summary.id,
                        title: summary.title,
                        isVisibleInSidebar: summary.isVisibleInSidebar
                    )
                }
            case .threadRename(let threadID):
                if let session = controller.threadSession(id: threadID) {
                    session.updateThreadIdentity(id: summary.id, title: summary.title)
                }
                pendingVoidResponses.removeValue(forKey: requestID)?.resume()
                return
            default:
                session = controller.ensureThreadSession(id: summary.id, title: summary.title, markSelected: false)
            }

            if let continuation = pendingThreadSessions.removeValue(forKey: requestID) {
                continuation.resume(returning: session)
            }
            return
        }

        _ = controller.ensureThreadSession(id: summary.id, title: summary.title, markSelected: false)
    }

    private func handleThreadListResult(
        _ payload: BridgeThreadListResultPayload,
        requestID: String?,
        listedAt: Date
    ) async {
        let archived: Bool
        let requestState: PendingThreadListRequest?

        if let requestID,
           let pendingCommand = pendingCommands.removeValue(forKey: requestID),
           case .threadList(let requestArchived) = pendingCommand {
            archived = requestArchived
            requestState = pendingThreadListsByRequestID.removeValue(forKey: requestID)
        } else {
            archived = false
            requestState = requestID.flatMap { pendingThreadListsByRequestID.removeValue(forKey: $0) }
        }

        var accumulatedSummariesByID = requestState?.summariesByID ?? [:]
        for summary in payload.threads.map({ $0.toThreadSummary() }) {
            accumulatedSummariesByID[summary.id] = summary
        }

        if let nextCursor = payload.nextCursor,
           nextCursor.isEmpty == false {
            do {
                try await sendThreadListRequest(
                    archived: archived,
                    cursor: nextCursor,
                    accumulatedSummariesByID: accumulatedSummariesByID
                )
            } catch {
                handleBridgeFailure(message: error.localizedDescription)
            }
            return
        }

        controller.replaceThreadList(
            Array(accumulatedSummariesByID.values),
            archived: archived,
            listedAt: listedAt
        )
    }

    private func handleThreadArchived(_ payload: BridgeThreadArchivedPayload, requestID: String?) {
        if let requestID,
           let pendingCommand = pendingCommands.removeValue(forKey: requestID),
           case .threadArchive(let threadID) = pendingCommand,
           threadID == payload.threadID {
            pendingVoidResponses.removeValue(forKey: requestID)?.resume()
        }

        controller.setThreadArchived(true, for: payload.threadID)
        controller.setThreadRunning(false, for: payload.threadID, at: now())
        controller.markThreadActivity(
            id: payload.threadID,
            at: now(),
            hasUnreadActivity: controller.lastActiveThreadID == payload.threadID ? false : true
        )
        refreshWorkspaceConnectionStatus()
    }

    private func handleThreadUnarchived(_ payload: BridgeThreadUnarchivedPayload, requestID: String?) {
        controller.setThreadArchived(false, for: payload.threadID)
        controller.markThreadActivity(
            id: payload.threadID,
            at: now(),
            hasUnreadActivity: controller.lastActiveThreadID == payload.threadID ? false : true
        )
        refreshWorkspaceConnectionStatus()
    }

    private func handleTurnStarted(_ event: BridgeEventEnvelope) {
        guard let threadID = event.threadID else {
            return
        }

        let title = controller.threadSummaries.first(where: { $0.id == threadID })?.title
            ?? controller.threadSession(id: threadID)?.title
            ?? "Thread"
        let session = controller.ensureThreadSession(id: threadID, title: title, markSelected: false)

        if let requestID = event.requestID,
           let pendingCommand = pendingCommands.removeValue(forKey: requestID),
           case .turnStart(_, let prompt) = pendingCommand,
           session.turnState.phase != .inProgress {
            session.beginTurn(userPrompt: prompt)
        } else if session.turnState.phase != .inProgress {
            session.beginTurn()
        }

        controller.setCurrentTurnID(event.turnID, for: threadID)
        controller.setAwaitingTurnStart(false, for: threadID)
        controller.setThreadSidebarVisibility(true, for: threadID)
        controller.markThreadActivity(
            id: threadID,
            at: bridgeDate(from: event.timestamp) ?? now(),
            isRunning: true,
            hasUnreadActivity: controller.lastActiveThreadID == threadID ? false : true
        )
        refreshWorkspaceConnectionStatus()
    }

    private func handleTurnCompleted(_ payload: BridgeTurnCompletedPayload, event: BridgeEventEnvelope) {
        guard let threadID = event.threadID,
              let session = session(for: threadID) else {
            return
        }

        if payload.status == .cancelled || payload.status == .interrupted {
            clearPendingCommands { command in
                if case .turnCancel(let commandThreadID) = command {
                    return commandThreadID == threadID
                }

                return false
            }
        }

        controller.setCurrentTurnID(nil, for: threadID)

        cancelPendingActivityCompletions()
        controller.setAwaitingTurnStart(false, for: threadID)

        switch payload.status {
        case .completed:
            session.completeTurn()
            controller.markThreadActivity(
                id: threadID,
                at: bridgeDate(from: event.timestamp) ?? now(),
                previewText: session.messages.last?.text ?? controller.threadSummary(id: threadID)?.previewText,
                isRunning: false,
                hasUnreadActivity: controller.lastActiveThreadID == threadID ? false : true,
                lastErrorMessage: nil
            )
            refreshWorkspaceConnectionStatus()
        case .cancelled, .interrupted:
            session.cancelTurn()
            controller.markThreadActivity(
                id: threadID,
                at: bridgeDate(from: event.timestamp) ?? now(),
                isRunning: false,
                hasUnreadActivity: controller.lastActiveThreadID == threadID ? false : true,
                lastErrorMessage: nil
            )
            refreshWorkspaceConnectionStatus()
        case .failed:
            let message = payload.detail ?? "The bridge reported a failed turn."
            session.failTurn(message)
            controller.markThreadActivity(
                id: threadID,
                at: bridgeDate(from: event.timestamp) ?? now(),
                previewText: message,
                isRunning: false,
                hasUnreadActivity: controller.lastActiveThreadID == threadID ? false : true,
                lastErrorMessage: message
            )
            refreshWorkspaceConnectionStatus()
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
            case .threadStart, .threadResume, .threadRead, .threadFork, .threadUnarchive, .threadRollback:
                pendingThreadSessions.removeValue(forKey: requestID)?.resume(
                    throwing: RuntimeBridgeError.requestFailed(message: payload.message)
                )
            case .threadList:
                pendingThreadListsByRequestID.removeValue(forKey: requestID)
            case .threadRename:
                pendingVoidResponses.removeValue(forKey: requestID)?.resume(
                    throwing: RuntimeBridgeError.requestFailed(message: payload.message)
                )
            case .threadArchive(let threadID):
                if shouldTreatArchiveErrorAsLocalSuccess(message: payload.message, threadID: threadID) {
                    pendingVoidResponses.removeValue(forKey: requestID)?.resume()
                    applyLocalThreadArchive(threadID: threadID)
                    refreshWorkspaceConnectionStatus()
                    return
                }

                pendingVoidResponses.removeValue(forKey: requestID)?.resume(
                    throwing: RuntimeBridgeError.requestFailed(message: payload.message)
                )
            case .turnStart(let threadID, _):
                controller.setAwaitingTurnStart(false, for: threadID)
                controller.setCurrentTurnID(nil, for: threadID)
                controller.threadSession(id: threadID)?.failTurn(payload.message)
            case .approvalResolve(let threadID, let approvalID):
                controller.threadSession(id: threadID)?.clearApprovalResolution(id: approvalID)
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
        if let environment = payload.environment?.toWorkspaceBridgeEnvironmentDiagnostics() {
            controller.setBridgeEnvironmentDiagnostics(environment)
        }

        if let executablePath = payload.executablePath {
            controller.setProviderExecutablePath(executablePath)
        }

        switch payload.status {
        case .starting:
            controller.setConnectionStatus(.connecting)
        case .ready:
            let status: ConnectionStatus = controller.threadSummaries.contains(where: \.isRunning) ? .streaming : .ready
            controller.setConnectionStatus(status)
        case .degraded, .error:
            for summary in controller.threadSummaries {
                controller.setAwaitingTurnStart(false, for: summary.id)
            }
            controller.setConnectionStatus(.error(message: payload.detail))
        case .disconnected:
            for summary in controller.threadSummaries {
                controller.setAwaitingTurnStart(false, for: summary.id)
            }
            controller.setConnectionStatus(.disconnected)
        }
    }

    private func adoptTurnContextIfNeeded(from event: BridgeEventEnvelope) {
        guard let turnID = event.turnID,
              let threadID = event.threadID,
              controller.currentTurnID(for: threadID) == nil,
              controller.isAwaitingTurnStart(threadID: threadID) else {
            return
        }

        controller.setCurrentTurnID(turnID, for: threadID)
        controller.setAwaitingTurnStart(false, for: threadID)
        controller.setThreadSidebarVisibility(true, for: threadID)
        controller.markThreadActivity(
            id: threadID,
            at: bridgeDate(from: event.timestamp) ?? now(),
            isRunning: true,
            hasUnreadActivity: controller.lastActiveThreadID == threadID ? false : true
        )
        refreshWorkspaceConnectionStatus()
    }

    private func session(for threadID: String) -> ThreadSession? {
        let title = controller.threadSummary(id: threadID)?.title
            ?? controller.threadSession(id: threadID)?.title
            ?? "Thread"
        if controller.threadSummary(id: threadID) == nil {
            controller.upsertThreadSummary(
                ThreadSummary(
                    id: threadID,
                    title: title,
                    previewText: "",
                    updatedAt: now()
                )
            )
        }
        return controller.ensureThreadSession(id: threadID, title: title, markSelected: false)
    }

    private func markActivityStarted(id: String) {
        pendingActivityCompletions[id]?.cancel()
        pendingActivityCompletions.removeValue(forKey: id)
        runningActivityStartedAt[id] = now()
    }

    private func completeActivityWhenVisible(
        threadID: String?,
        activityID: String,
        applyCompletion: @escaping @MainActor (ThreadSession) -> Void
    ) {
        let elapsed = runningActivityStartedAt[activityID].map { now().timeIntervalSince($0) }
            ?? minimumVisibleRunningActivityDuration
        let remaining = max(0, minimumVisibleRunningActivityDuration - elapsed)

        guard remaining > 0 else {
            if let threadID,
               let session = session(for: threadID) {
                applyCompletion(session)
            }

            clearActivityTracking(id: activityID)
            return
        }

        pendingActivityCompletions[activityID]?.cancel()
        pendingActivityCompletions[activityID] = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            await self.sleep(remaining)

            guard Task.isCancelled == false else {
                return
            }

            if let threadID,
               let session = self.session(for: threadID) {
                applyCompletion(session)
            }

            self.clearActivityTracking(id: activityID)
        }
    }

    private func clearActivityTracking(id: String) {
        pendingActivityCompletions[id]?.cancel()
        pendingActivityCompletions.removeValue(forKey: id)
        runningActivityStartedAt.removeValue(forKey: id)
    }

    private func cancelPendingActivityCompletions() {
        pendingActivityCompletions.values.forEach { $0.cancel() }
        pendingActivityCompletions.removeAll()
        runningActivityStartedAt.removeAll()
    }

    private func sendThreadListRequest(
        archived: Bool,
        cursor: String?,
        accumulatedSummariesByID: [String: ThreadSummary]
    ) async throws {
        let requestID = nextRequestID(prefix: archived ? "thread-list-archived" : "thread-list")
        pendingCommands[requestID] = .threadList(archived: archived)
        pendingThreadListsByRequestID[requestID] = PendingThreadListRequest(
            archived: archived,
            summariesByID: accumulatedSummariesByID
        )
        try await sendCommand(
            id: requestID,
            type: .threadList,
            payload: BridgeThreadListPayload(
                workspacePath: controller.workspace.canonicalPath,
                cursor: cursor,
                limit: nil,
                archived: archived ? .only : .exclude
            )
        )
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
        cancelPendingActivityCompletions()
        receiveTask?.cancel()
        receiveTask = nil
        socketClient?.close()
        socketClient = nil
        processHandle?.onExit = nil
        processHandle?.terminate()
        processHandle = nil
        let failingThreadListScopes = Set(pendingThreadListsByRequestID.values.map(\.archived))
        pendingCommands.removeAll()
        let pendingThreadSessions = self.pendingThreadSessions
        self.pendingThreadSessions.removeAll()
        let pendingVoidResponses = self.pendingVoidResponses
        self.pendingVoidResponses.removeAll()
        let pendingApprovalResolutions = self.pendingApprovalResolutions
        self.pendingApprovalResolutions.removeAll()
        pendingThreadListsByRequestID.removeAll()
        abandonedThreadRequestIDs.removeAll()
        controller.setBridgeLifecycleState(.idle)

        for archived in failingThreadListScopes {
            controller.markThreadListSyncFailed(archived: archived)
        }

        for summary in controller.threadSummaries {
            controller.setCurrentTurnID(nil, for: summary.id)
            controller.setAwaitingTurnStart(false, for: summary.id)
            controller.setThreadRunning(false, for: summary.id)
        }

        controller.setConnectionStatus(.error(message: message))

        for continuation in pendingThreadSessions.values {
            continuation.resume(throwing: RuntimeBridgeError.requestFailed(message: message))
        }

        for continuation in pendingVoidResponses.values {
            continuation.resume(throwing: RuntimeBridgeError.requestFailed(message: message))
        }

        for continuation in pendingApprovalResolutions.values {
            continuation.resume(throwing: RuntimeBridgeError.requestFailed(message: message))
        }

        for summary in controller.threadSummaries {
            if controller.threadSession(id: summary.id)?.turnState.phase == .inProgress {
                controller.threadSession(id: summary.id)?.failTurn(message)
            }
        }
    }

    private func nextRequestID(prefix: String) -> String {
        requestCounter += 1
        return "ateliercode-\(prefix)-\(requestCounter)"
    }

    private func shouldArchiveThreadLocally(id: String) -> Bool {
        guard let session = controller.threadSession(id: id) else {
            return false
        }

        return session.messages.isEmpty &&
            session.turnState.phase == .idle &&
            session.turnItems.isEmpty &&
            session.pendingApprovals.isEmpty &&
            session.planState == nil &&
            session.aggregatedDiff == nil
    }

    private func shouldTreatArchiveErrorAsLocalSuccess(message: String, threadID: String) -> Bool {
        shouldArchiveThreadLocally(id: threadID) &&
            message.localizedCaseInsensitiveContains("no rollout found")
    }

    private func applyLocalThreadArchive(threadID: String) {
        controller.setThreadArchived(true, for: threadID)
        controller.setThreadRunning(false, for: threadID, at: now())
        controller.markThreadActivity(
            id: threadID,
            at: now(),
            hasUnreadActivity: controller.lastActiveThreadID == threadID ? false : true
        )
        refreshWorkspaceConnectionStatus()
    }

    private func applyLocalThreadUnarchive(threadID: String) {
        controller.setThreadArchived(false, for: threadID)
        controller.markThreadActivity(
            id: threadID,
            at: now(),
            hasUnreadActivity: controller.lastActiveThreadID == threadID ? false : true
        )
        refreshWorkspaceConnectionStatus()
    }

    private func awaitThreadSession(
        requestID: String,
        sendAction: @escaping @MainActor () async throws -> Void
    ) async throws -> ThreadSession {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                pendingThreadSessions[requestID] = continuation

                Task { @MainActor in
                    do {
                        try await sendAction()
                    } catch {
                        self.pendingCommands.removeValue(forKey: requestID)
                        self.pendingThreadSessions.removeValue(forKey: requestID)?.resume(throwing: error)
                    }
                }
            }
        }, onCancel: {
            Task { @MainActor [weak self] in
                self?.abandonThreadRequest(id: requestID)
            }
        })
    }

    private func awaitVoidResponse(
        requestID: String,
        sendAction: @escaping @MainActor () async throws -> Void
    ) async throws {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                pendingVoidResponses[requestID] = continuation

                Task { @MainActor in
                    do {
                        try await sendAction()
                    } catch {
                        self.pendingCommands.removeValue(forKey: requestID)
                        self.pendingVoidResponses.removeValue(forKey: requestID)?.resume(throwing: error)
                    }
                }
            }
        }, onCancel: {
            Task { @MainActor [weak self] in
                self?.abandonVoidRequest(id: requestID)
            }
        })
    }

    private func abandonThreadRequest(id: String) {
        abandonedThreadRequestIDs.insert(id)
        pendingCommands.removeValue(forKey: id)
        pendingThreadSessions.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func abandonVoidRequest(id: String) {
        abandonedThreadRequestIDs.insert(id)
        pendingCommands.removeValue(forKey: id)
        pendingVoidResponses.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func clearPendingCommands(where shouldRemove: (PendingCommand) -> Bool) {
        pendingCommands = pendingCommands.filter { _, command in
            shouldRemove(command) == false
        }
    }

    private func refreshWorkspaceConnectionStatus() {
        let status: ConnectionStatus = controller.hasRunningThreads ? .streaming : .ready
        controller.setConnectionStatus(status)
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
