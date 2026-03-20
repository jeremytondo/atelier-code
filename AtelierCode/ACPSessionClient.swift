//
//  ACPSessionClient.swift
//  AtelierCode
//
//  Created by Codex on 3/14/26.
//

import Foundation

nonisolated struct ACPSessionClientTimeouts: Sendable {
    let initialize: TimeInterval
    let sessionNew: TimeInterval
    let sessionPrompt: TimeInterval

    static let atelierCodeDefault = ACPSessionClientTimeouts(
        initialize: 10,
        sessionNew: 15,
        sessionPrompt: 60
    )

    func timeout(for method: ACPMethod) -> TimeInterval? {
        switch method {
        case .initialize:
            return initialize
        case .sessionNew:
            return sessionNew
        case .sessionPrompt:
            return sessionPrompt
        default:
            return nil
        }
    }
}

nonisolated enum ACPSessionClientError: LocalizedError {
    case sessionNotCreated
    case requestTimedOut(method: String, timeout: TimeInterval)
    case invalidResponse(method: String)
    case missingResult(method: String)
    case serverError(method: String, error: ACPError)
    case authenticationRequired(method: String, error: ACPError)
    case modelUnavailable(method: String, error: ACPError)
    case unsupportedProtocolVersion(received: Int, supported: [Int])

    var errorDescription: String? {
        switch self {
        case .sessionNotCreated:
            return "The ACP session has not been created yet."
        case .requestTimedOut(let method, let timeout):
            return "The ACP request \(method) timed out after \(Self.formattedTimeout(timeout))."
        case .invalidResponse(let method):
            return "The ACP response for \(method) could not be decoded."
        case .missingResult(let method):
            return "The ACP response for \(method) did not include a result."
        case .serverError(let method, let error):
            return Self.structuredFailureDescription(
                prefix: "The ACP request \(method) failed",
                error: error
            )
        case .authenticationRequired(let method, let error):
            return Self.structuredFailureDescription(
                prefix: "The ACP request \(method) needs Gemini authentication",
                error: error,
                guidance: "Re-authenticate in a terminal and try again."
            )
        case .modelUnavailable(let method, let error):
            return Self.structuredFailureDescription(
                prefix: "The ACP request \(method) failed because the configured Gemini model is unavailable",
                error: error,
                guidance: "Check the explicit Gemini model and try again."
            )
        case .unsupportedProtocolVersion(let received, let supported):
            let supportedList = supported.map(String.init).joined(separator: ", ")
            return "The ACP initialize response negotiated unsupported protocol version \(received). AtelierCode supports: \(supportedList)."
        }
    }

    private static func formattedTimeout(_ timeout: TimeInterval) -> String {
        if timeout.rounded(.towardZero) == timeout {
            return "\(Int(timeout))s"
        }

        return String(format: "%.2fs", timeout)
    }

    private static func structuredFailureDescription(
        prefix: String,
        error: ACPError,
        guidance: String? = nil
    ) -> String {
        var segments = ["\(prefix) (code \(error.code))."]

        if let guidance {
            segments.append(guidance)
        }

        segments.append("Server message: \(error.message)")

        if let context = error.contextDescription {
            segments.append("Context: \(context)")
        }

        return segments.joined(separator: " ")
    }
}

nonisolated enum ACPPermissionCategory: String, Sendable {
    case agentTool
    case fileRead
    case fileWrite
    case terminal
}

nonisolated struct ACPPermissionContext: Sendable {
    let category: ACPPermissionCategory
    let sessionId: String
    let toolCallId: String?
}

nonisolated struct ACPPermissionPolicy: Sendable {
    private let resolveOutcome: @Sendable (ACPRequestPermissionRequest, ACPPermissionContext) -> ACPRequestPermissionOutcome

    init(
        resolveOutcome: @escaping @Sendable (ACPRequestPermissionRequest, ACPPermissionContext) -> ACPRequestPermissionOutcome
    ) {
        self.resolveOutcome = resolveOutcome
    }

    func outcome(
        for request: ACPRequestPermissionRequest,
        context: ACPPermissionContext
    ) -> ACPRequestPermissionOutcome {
        resolveOutcome(request, context)
    }

    static let autoApproveCompatible = ACPPermissionPolicy { request, _ in
        let preferredOption =
            request.options.first(where: { $0.kind == "allow_once" }) ??
            request.options.first(where: { $0.kind == "allow_always" }) ??
            request.options.first

        return preferredOption.map { ACPRequestPermissionOutcome.selected(optionId: $0.optionId) }
            ?? .cancelled
    }
}

nonisolated struct ACPWorkspaceAccessPolicy: Sendable {
    let workspaceRoot: String

    init(workspaceRoot: String) {
        self.workspaceRoot = Self.canonicalPath(for: workspaceRoot)
    }

    func readTextFile(request: ACPReadTextFileRequest) throws -> ACPReadTextFileResponse {
        let authorizedRead = try authorizeRead(request: request)
        let content = try Self.readTextContent(
            at: authorizedRead.resolvedPath,
            startLine: authorizedRead.startLine,
            lineLimit: authorizedRead.lineLimit
        )
        return ACPReadTextFileResponse(content: content)
    }

    private func authorizeRead(request: ACPReadTextFileRequest) throws -> AuthorizedWorkspaceRead {
        guard request.limit == nil || request.limit.map({ $0 >= 0 }) == true else {
            throw ACPWorkspaceAccessError.invalidReadRange(
                line: request.line,
                limit: request.limit
            )
        }

        guard request.line == nil || request.line.map({ $0 >= 0 }) == true else {
            throw ACPWorkspaceAccessError.invalidReadRange(
                line: request.line,
                limit: request.limit
            )
        }

        let trimmedPath = request.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            throw ACPWorkspaceAccessError.invalidPath(request.path)
        }

        let baseURL = URL(fileURLWithPath: workspaceRoot, isDirectory: true)
        let candidateURL: URL
        if trimmedPath.hasPrefix("/") {
            candidateURL = URL(fileURLWithPath: trimmedPath)
        } else {
            candidateURL = baseURL.appendingPathComponent(trimmedPath)
        }

        let standardizedPath = Self.canonicalPath(for: candidateURL.path)
        guard Self.isWithinWorkspace(standardizedPath, workspaceRoot: workspaceRoot) else {
            throw ACPWorkspaceAccessError.pathOutsideWorkspace(
                requestedPath: request.path,
                resolvedPath: standardizedPath,
                workspaceRoot: workspaceRoot
            )
        }

        var isDirectory = ObjCBool(false)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: standardizedPath, isDirectory: &isDirectory) else {
            throw ACPWorkspaceAccessError.fileMissing(path: standardizedPath)
        }

        guard !isDirectory.boolValue else {
            throw ACPWorkspaceAccessError.notAFile(path: standardizedPath)
        }

        return AuthorizedWorkspaceRead(
            resolvedPath: standardizedPath,
            startLine: max(request.line ?? 1, 1),
            lineLimit: request.limit
        )
    }

    private static func readTextContent(
        at path: String,
        startLine: Int,
        lineLimit: Int?
    ) throws -> String {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let rawText = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            return slice(text: rawText, startLine: startLine, lineLimit: lineLimit)
        } catch {
            throw ACPWorkspaceAccessError.readFailed(path: path)
        }
    }

    private static func slice(text: String, startLine: Int, lineLimit: Int?) -> String {
        guard !text.isEmpty else { return "" }
        guard lineLimit != .some(0) else { return "" }

        let normalizedText = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalizedText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let startIndex = max(startLine - 1, 0)

        guard startIndex < lines.count else { return "" }

        let endIndex = lineLimit.map { min(startIndex + $0, lines.count) } ?? lines.count
        return Array(lines[startIndex..<endIndex]).joined(separator: "\n")
    }

    private static func isWithinWorkspace(_ path: String, workspaceRoot: String) -> Bool {
        path == workspaceRoot || path.hasPrefix(workspaceRoot + "/")
    }

    private static func canonicalPath(for path: String) -> String {
        let fileManager = FileManager.default
        var existingURL = URL(fileURLWithPath: path).standardizedFileURL
        var missingPathComponents: [String] = []

        while existingURL.path != "/", !fileManager.fileExists(atPath: existingURL.path) {
            missingPathComponents.insert(existingURL.lastPathComponent, at: 0)
            existingURL.deleteLastPathComponent()
        }

        return missingPathComponents
            .reduce(existingURL.resolvingSymlinksInPath()) { partialURL, component in
                partialURL.appendingPathComponent(component)
            }
            .path
    }

    private struct AuthorizedWorkspaceRead: Sendable {
        let resolvedPath: String
        let startLine: Int
        let lineLimit: Int?
    }
}

nonisolated enum ACPWorkspaceAccessError: LocalizedError, Sendable {
    case invalidPath(String)
    case invalidReadRange(line: Int?, limit: Int?)
    case pathOutsideWorkspace(requestedPath: String, resolvedPath: String, workspaceRoot: String)
    case fileMissing(path: String)
    case notAFile(path: String)
    case readFailed(path: String)

    var errorDescription: String? {
        switch self {
        case .invalidPath(let path):
            return "AtelierCode could not resolve the requested file path \(path)."
        case .invalidReadRange(let line, let limit):
            return "AtelierCode received an invalid file read range (line: \(line.map(String.init) ?? "nil"), limit: \(limit.map(String.init) ?? "nil"))."
        case .pathOutsideWorkspace(_, let resolvedPath, let workspaceRoot):
            return "AtelierCode denied file access to \(resolvedPath) because it is outside the active workspace root \(workspaceRoot)."
        case .fileMissing(let path):
            return "AtelierCode could not read \(path) because the file does not exist."
        case .notAFile(let path):
            return "AtelierCode can only read text files, but \(path) is not a regular file."
        case .readFailed(let path):
            return "AtelierCode could not read the requested file at \(path)."
        }
    }

    var clientError: ACPClientError {
        switch self {
        case .invalidPath(let path):
            return ACPClientError(
                code: ACPClientErrorCode.invalidParams,
                message: errorDescription ?? "Invalid file path.",
                data: .object([
                    "reason": .string("invalid_path"),
                    "path": .string(path),
                ])
            )
        case .invalidReadRange(let line, let limit):
            return ACPClientError(
                code: ACPClientErrorCode.invalidParams,
                message: errorDescription ?? "Invalid file read range.",
                data: .object([
                    "reason": .string("invalid_read_range"),
                    "line": line.map(ACPJSONValue.int) ?? .null,
                    "limit": limit.map(ACPJSONValue.int) ?? .null,
                ])
            )
        case .pathOutsideWorkspace(let requestedPath, let resolvedPath, let workspaceRoot):
            return ACPClientError(
                code: ACPClientErrorCode.permissionDenied,
                message: errorDescription ?? "Path is outside the active workspace.",
                data: .object([
                    "reason": .string("path_outside_workspace"),
                    "requestedPath": .string(requestedPath),
                    "resolvedPath": .string(resolvedPath),
                    "workspaceRoot": .string(workspaceRoot),
                ])
            )
        case .fileMissing(let path):
            return ACPClientError(
                code: ACPClientErrorCode.resourceNotFound,
                message: errorDescription ?? "File not found.",
                data: .object([
                    "reason": .string("not_found"),
                    "path": .string(path),
                ])
            )
        case .notAFile(let path):
            return ACPClientError(
                code: ACPClientErrorCode.invalidParams,
                message: errorDescription ?? "Requested path is not a regular file.",
                data: .object([
                    "reason": .string("not_a_file"),
                    "path": .string(path),
                ])
            )
        case .readFailed(let path):
            return ACPClientError(
                code: ACPClientErrorCode.internalError,
                message: errorDescription ?? "The requested file could not be read.",
                data: .object([
                    "reason": .string("read_failed"),
                    "path": .string(path),
                ])
            )
        }
    }
}

@MainActor
final class ACPSessionClient {
    var onAgentMessageChunk: ((String) -> Void)?
    var onTransportError: ((any Error) -> Void)?

    private let transport: AgentTransport
    private let requestTimeouts: ACPSessionClientTimeouts
    private let permissionPolicy: ACPPermissionPolicy
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private struct PendingResponse {
        let timeoutTask: Task<Void, Never>?
        let complete: (Result<Data, any Error>) -> Void
    }

    private var nextRequestID = 1
    private var isTransportStarted = false
    private var pendingResponses: [Int: PendingResponse] = [:]
    private var workspaceAccessPolicy: ACPWorkspaceAccessPolicy?

    private(set) var negotiatedProtocolVersion: Int?
    private(set) var sessionID: String?
    private(set) var agentCapabilities: ACPAgentCapabilities?
    private(set) var authMethods: [ACPAuthMethod] = []

    init(
        transport: AgentTransport,
        requestTimeouts: ACPSessionClientTimeouts = .atelierCodeDefault,
        permissionPolicy: ACPPermissionPolicy = .autoApproveCompatible
    ) {
        self.transport = transport
        self.requestTimeouts = requestTimeouts
        self.permissionPolicy = permissionPolicy
        transport.onReceive = { [weak self] result in
            self?.handleTransportMessage(result)
        }
    }

    func connect(
        cwd: String = FileManager.default.currentDirectoryPath,
        clientInfo: ACPImplementationInfo = .atelierCode,
        clientCapabilities: ACPClientCapabilities = .atelierCodeDefaults,
        mcpServers: [ACPMCPServer] = []
    ) async throws {
        guard sessionID == nil else { return }

        try startTransportIfNeeded()

        let initializeResponse: ACPInitializeResponse = try await sendRequest(
            method: .initialize,
            params: ACPInitializeRequestParams(
                protocolVersion: ACPProtocolVersion.current,
                clientCapabilities: clientCapabilities,
                clientInfo: clientInfo
            )
        )

        guard ACPProtocolVersion.isSupported(initializeResponse.protocolVersion) else {
            throw ACPSessionClientError.unsupportedProtocolVersion(
                received: initializeResponse.protocolVersion,
                supported: ACPProtocolVersion.supported.sorted()
            )
        }

        negotiatedProtocolVersion = initializeResponse.protocolVersion
        agentCapabilities = initializeResponse.agentCapabilities
        authMethods = initializeResponse.authMethods ?? []

        let newSessionResponse: ACPNewSessionResponse = try await sendRequest(
            method: .sessionNew,
            params: ACPNewSessionRequestParams(
                cwd: cwd,
                mcpServers: mcpServers
            )
        )
        sessionID = newSessionResponse.sessionId
        workspaceAccessPolicy = ACPWorkspaceAccessPolicy(workspaceRoot: cwd)
    }

    func sendPrompt(_ text: String) async throws -> ACPPromptResponse {
        guard let sessionID else {
            throw ACPSessionClientError.sessionNotCreated
        }

        return try await sendRequest(
            method: .sessionPrompt,
            params: ACPPromptRequestParams(
                sessionId: sessionID,
                prompt: [.text(text)]
            )
        )
    }

    func reset() {
        transport.stop()
        cancelPendingResponses()
        nextRequestID = 1
        isTransportStarted = false
        negotiatedProtocolVersion = nil
        sessionID = nil
        agentCapabilities = nil
        authMethods = []
        workspaceAccessPolicy = nil
    }

    private func startTransportIfNeeded() throws {
        guard !isTransportStarted else { return }
        try transport.start()
        isTransportStarted = true
    }

    private func makeRequestID() -> Int {
        defer { nextRequestID += 1 }
        return nextRequestID
    }

    private func sendRequest<Params: Encodable & Sendable, Result: Decodable & Sendable>(
        method: ACPMethod,
        params: Params
    ) async throws -> Result {
        let requestID = makeRequestID()
        let request = ACPRequest(id: requestID, method: method.rawValue, params: params)
        let payload = try encoder.encode(request)
        let timeout = requestTimeouts.timeout(for: method)

        return try await withCheckedThrowingContinuation { continuation in
            pendingResponses[requestID] = PendingResponse(
                timeoutTask: timeout.map { makeTimeoutTask(for: requestID, method: method, timeout: $0) }
            ) { [decoder] result in
                switch result {
                case .success(let data):
                    do {
                        let response = try decoder.decode(ACPResponse<Result>.self, from: data)

                        if let error = response.error {
                            continuation.resume(throwing: Self.classify(error: error, for: method))
                            return
                        }

                        guard let result = response.result else {
                            continuation.resume(
                                throwing: ACPSessionClientError.missingResult(method: method.rawValue)
                            )
                            return
                        }

                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(
                            throwing: ACPSessionClientError.invalidResponse(method: method.rawValue)
                        )
                    }

                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            do {
                try transport.send(message: payload)
            } catch {
                resolvePendingResponse(requestID: requestID, with: .failure(error))
            }
        }
    }

    private func handleTransportMessage(_ result: Result<Data, any Error>) {
        switch result {
        case .success(let data):
            handleIncomingData(data)
        case .failure(let error):
            failPendingResponses(with: error)
            reset()
            onTransportError?(error)
        }
    }

    private func handleIncomingData(_ data: Data) {
        guard let envelope = try? decoder.decode(ACPIncomingEnvelope.self, from: data) else {
            return
        }

        if let method = envelope.method {
            if envelope.id != nil {
                handleRequest(method: method, id: envelope.id, data: data)
            } else {
                handleNotification(method: method, data: data)
            }
            return
        }

        if let id = envelope.id?.intValue {
            resolvePendingResponse(requestID: id, with: .success(data))
        }
    }

    private func handleRequest(method: String, id: ACPRequestID?, data: Data) {
        switch method {
        case ACPMethod.sessionRequestPermission.rawValue:
            handlePermissionRequest(id: id, data: data)
        case ACPMethod.fsReadTextFile.rawValue:
            handleReadTextFileRequest(id: id, data: data)
        default:
            let errorMessage =
                ACPInterimCapabilityStrategy.atelierCodeCurrent.fallbackErrorMessage(for: method)
                ?? "AtelierCode does not support client ACP method \(method)."
            sendClientErrorResponse(
                id: id,
                code: ACPClientErrorCode.methodNotFound,
                message: errorMessage
            )
        }
    }

    private func handleNotification(method: String, data: Data) {
        guard method == ACPMethod.sessionUpdate.rawValue else {
            return
        }

        guard
            let notification = try? decoder.decode(
                ACPNotification<ACPSessionUpdateNotificationParams>.self,
                from: data
            ),
            let text = notification.params.agentMessageChunkText
        else {
            return
        }

        onAgentMessageChunk?(text)
    }

    private func handlePermissionRequest(id: ACPRequestID?, data: Data) {
        guard
            let request = try? decoder.decode(
                ACPInboundRequest<ACPRequestPermissionRequest>.self,
                from: data
            )
        else {
            sendClientErrorResponse(
                id: id,
                code: ACPClientErrorCode.invalidParams,
                message: "AtelierCode could not decode the permission request."
            )
            return
        }

        let outcome = permissionPolicy.outcome(
            for: request.params,
            context: ACPPermissionContext(
                category: .agentTool,
                sessionId: request.params.sessionId,
                toolCallId: request.params.toolCall?.toolCallId
            )
        )

        sendClientResponse(
            ACPClientResponse(
                id: request.id,
                result: ACPRequestPermissionResponse(outcome: outcome)
            )
        )
    }

    private func handleReadTextFileRequest(id: ACPRequestID?, data: Data) {
        guard
            let request = try? decoder.decode(
                ACPInboundRequest<ACPReadTextFileRequest>.self,
                from: data
            )
        else {
            sendClientErrorResponse(
                id: id,
                code: ACPClientErrorCode.invalidParams,
                message: "AtelierCode could not decode the file read request."
            )
            return
        }

        guard let sessionID else {
            sendClientErrorResponse(
                id: request.id,
                code: ACPClientErrorCode.invalidParams,
                message: "AtelierCode cannot read files before a session is created."
            )
            return
        }

        guard request.params.sessionId == sessionID else {
            sendClientErrorResponse(
                id: request.id,
                error: ACPClientError(
                    code: ACPClientErrorCode.invalidParams,
                    message: "AtelierCode received a file read request for an unknown ACP session.",
                    data: .object([
                        "reason": .string("unknown_session"),
                        "sessionId": .string(request.params.sessionId),
                        "expectedSessionId": .string(sessionID),
                    ])
                )
            )
            return
        }

        guard let workspaceAccessPolicy else {
            sendClientErrorResponse(
                id: request.id,
                code: ACPClientErrorCode.internalError,
                message: "AtelierCode does not have an active workspace policy for this session."
            )
            return
        }

        do {
            let response = try workspaceAccessPolicy.readTextFile(request: request.params)
            sendClientResponse(
                ACPClientResponse(
                    id: request.id,
                    result: response
                )
            )
        } catch let error as ACPWorkspaceAccessError {
            sendClientErrorResponse(id: request.id, error: error.clientError)
        } catch {
            sendClientErrorResponse(
                id: request.id,
                error: ACPClientError(
                    code: ACPClientErrorCode.internalError,
                    message: "AtelierCode hit an unexpected error while reading a workspace file.",
                    data: .object([
                        "reason": .string("unexpected_read_failure"),
                        "path": .string(request.params.path),
                    ])
                )
            )
        }
    }

    private func sendClientResponse<Result: Encodable & Sendable>(_ response: ACPClientResponse<Result>) {
        do {
            try transport.send(message: encoder.encode(response))
        } catch {
            failPendingResponses(with: error)
            reset()
            onTransportError?(error)
        }
    }

    private func sendClientErrorResponse(id: ACPRequestID?, code: Int, message: String) {
        sendClientErrorResponse(
            id: id,
            error: ACPClientError(code: code, message: message)
        )
    }

    private func sendClientErrorResponse(id: ACPRequestID?, error: ACPClientError) {
        do {
            try transport.send(
                message: encoder.encode(
                    ACPClientErrorResponse(
                        id: id,
                        error: error
                    )
                )
            )
        } catch {
            failPendingResponses(with: error)
            reset()
            onTransportError?(error)
        }
    }

    private func failPendingResponses(with error: any Error) {
        let responses = Array(pendingResponses.values)
        pendingResponses.removeAll()

        for response in responses {
            response.timeoutTask?.cancel()
            response.complete(.failure(error))
        }
    }

    private func resolvePendingResponse(requestID: Int, with result: Result<Data, any Error>) {
        guard let pendingResponse = pendingResponses.removeValue(forKey: requestID) else {
            return
        }

        pendingResponse.timeoutTask?.cancel()
        pendingResponse.complete(result)
    }

    private func cancelPendingResponses() {
        let responses = Array(pendingResponses.values)
        pendingResponses.removeAll()

        for response in responses {
            response.timeoutTask?.cancel()
        }
    }

    private func makeTimeoutTask(for requestID: Int, method: ACPMethod, timeout: TimeInterval) -> Task<Void, Never> {
        Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.nanoseconds(for: timeout))
            } catch {
                return
            }

            await MainActor.run {
                self?.resolvePendingResponse(
                    requestID: requestID,
                    with: .failure(
                        ACPSessionClientError.requestTimedOut(
                            method: method.rawValue,
                            timeout: timeout
                        )
                    )
                )
            }
        }
    }

    private static func classify(error: ACPError, for method: ACPMethod) -> ACPSessionClientError {
        if error.isAuthenticationRelated {
            return .authenticationRequired(method: method.rawValue, error: error)
        }

        if error.isModelRelated {
            return .modelUnavailable(method: method.rawValue, error: error)
        }

        return .serverError(method: method.rawValue, error: error)
    }

    private static func nanoseconds(for timeout: TimeInterval) -> UInt64 {
        let seconds = max(timeout, 0)
        return UInt64(seconds * 1_000_000_000)
    }
}
