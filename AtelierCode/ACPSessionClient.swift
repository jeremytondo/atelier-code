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

@MainActor
final class ACPSessionClient {
    var onAgentMessageChunk: ((String) -> Void)?
    var onTransportError: ((any Error) -> Void)?

    private let transport: AgentTransport
    private let requestTimeouts: ACPSessionClientTimeouts
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private struct PendingResponse {
        let timeoutTask: Task<Void, Never>?
        let complete: (Result<Data, any Error>) -> Void
    }

    private var nextRequestID = 1
    private var isTransportStarted = false
    private var pendingResponses: [Int: PendingResponse] = [:]

    private(set) var negotiatedProtocolVersion: Int?
    private(set) var sessionID: String?
    private(set) var agentCapabilities: ACPAgentCapabilities?
    private(set) var authMethods: [ACPAuthMethod] = []

    init(
        transport: AgentTransport,
        requestTimeouts: ACPSessionClientTimeouts = .atelierCodeDefault
    ) {
        self.transport = transport
        self.requestTimeouts = requestTimeouts
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
        default:
            let errorMessage =
                ACPInterimCapabilityStrategy.atelierCodeCurrent.fallbackErrorMessage(for: method)
                ?? "AtelierCode does not support client ACP method \(method)."
            sendClientErrorResponse(
                id: id,
                code: -32601,
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
                code: -32602,
                message: "AtelierCode could not decode the permission request."
            )
            return
        }

        let preferredOption =
            request.params.options.first(where: { $0.kind == "allow_once" }) ??
            request.params.options.first(where: { $0.kind == "allow_always" }) ??
            request.params.options.first

        let outcome = preferredOption.map { ACPRequestPermissionOutcome.selected(optionId: $0.optionId) }
            ?? .cancelled

        sendClientResponse(
            ACPClientResponse(
                id: request.id,
                result: ACPRequestPermissionResponse(outcome: outcome)
            )
        )
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
        do {
            try transport.send(
                message: encoder.encode(
                    ACPClientErrorResponse(
                        id: id,
                        error: ACPClientError(code: code, message: message)
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
