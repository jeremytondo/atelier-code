//
//  ACPSessionClient.swift
//  AtelierCode
//
//  Created by Codex on 3/14/26.
//

import Foundation

nonisolated enum ACPSessionClientError: LocalizedError {
    case sessionNotCreated
    case invalidResponse(method: String)
    case missingResult(method: String)
    case serverError(method: String, message: String)
    case unsupportedProtocolVersion(received: Int, supported: [Int])

    var errorDescription: String? {
        switch self {
        case .sessionNotCreated:
            return "The ACP session has not been created yet."
        case .invalidResponse(let method):
            return "The ACP response for \(method) could not be decoded."
        case .missingResult(let method):
            return "The ACP response for \(method) did not include a result."
        case .serverError(let method, let message):
            return "The ACP request \(method) failed: \(message)"
        case .unsupportedProtocolVersion(let received, let supported):
            let supportedList = supported.map(String.init).joined(separator: ", ")
            return "The ACP initialize response negotiated unsupported protocol version \(received). AtelierCode supports: \(supportedList)."
        }
    }
}

@MainActor
final class ACPSessionClient {
    var onAgentMessageChunk: ((String) -> Void)?
    var onTransportError: ((any Error) -> Void)?

    private let transport: AgentTransport
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var nextRequestID = 1
    private var isTransportStarted = false
    private var pendingResponses: [Int: (Result<Data, any Error>) -> Void] = [:]

    private(set) var negotiatedProtocolVersion: Int?
    private(set) var sessionID: String?
    private(set) var agentCapabilities: ACPAgentCapabilities?
    private(set) var authMethods: [ACPAuthMethod] = []

    init(transport: AgentTransport) {
        self.transport = transport
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
        pendingResponses.removeAll()
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

        return try await withCheckedThrowingContinuation { continuation in
            pendingResponses[requestID] = { [decoder] result in
                switch result {
                case .success(let data):
                    do {
                        let response = try decoder.decode(ACPResponse<Result>.self, from: data)

                        if let error = response.error {
                            continuation.resume(
                                throwing: ACPSessionClientError.serverError(
                                    method: method.rawValue,
                                    message: error.message
                                )
                            )
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
                pendingResponses.removeValue(forKey: requestID)
                continuation.resume(throwing: error)
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
            pendingResponses.removeValue(forKey: id)?(.success(data))
        }
    }

    private func handleRequest(method: String, id: ACPRequestID?, data: Data) {
        switch method {
        case ACPMethod.sessionRequestPermission.rawValue:
            handlePermissionRequest(id: id, data: data)
        default:
            sendClientErrorResponse(
                id: id,
                code: -32601,
                message: "AtelierCode does not support client ACP method \(method)."
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
        let responses = pendingResponses.values
        pendingResponses.removeAll()

        for resume in responses {
            resume(.failure(error))
        }
    }
}
