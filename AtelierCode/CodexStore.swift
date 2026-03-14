//
//  CodexStore.swift
//  AtelierCode
//
//  Created by Codex on 3/13/26.
//

import Foundation
import Observation

nonisolated struct JSONRPCRequest<Params: Encodable & Sendable>: Encodable, Sendable {
    let jsonrpc = "2.0"
    let id: Int?
    let method: String
    let params: Params?
}

nonisolated struct JSONRPCNotification<Params: Decodable & Sendable>: Decodable, Sendable {
    let jsonrpc: String?
    let method: String
    let params: Params
}

nonisolated struct JSONRPCResponse<Result: Decodable & Sendable>: Decodable, Sendable {
    let jsonrpc: String?
    let id: Int
    let result: Result?
    let error: JSONRPCError?
}

nonisolated struct JSONRPCError: Decodable, Sendable {
    let code: Int
    let message: String
}

nonisolated struct IncomingEnvelope: Decodable, Sendable {
    let id: Int?
    let method: String?
}

nonisolated struct EmptyParams: Codable, Sendable {}

nonisolated struct InitializeParams: Encodable, Sendable {
    let clientInfo: ClientInfo
}

nonisolated struct ClientInfo: Encodable, Sendable {
    let name: String
    let version: String
}

nonisolated struct ThreadStartResult: Decodable, Sendable {
    let thread: ThreadReference
}

nonisolated struct ThreadReference: Decodable, Sendable {
    let id: String
}

nonisolated struct TurnStartParams: Encodable, Sendable {
    let threadId: String
    let input: [TurnInputItem]
}

nonisolated struct TurnInputItem: Encodable, Sendable {
    let type: String
    let text: String

    init(text: String) {
        self.type = "text"
        self.text = text
    }
}

nonisolated struct AgentMessageDeltaParams: Decodable, Sendable {
    let threadId: String?
    let turnId: String?
    let itemId: String?
    let delta: String
}

nonisolated struct ItemCompletedParams: Decodable, Sendable {
    let threadId: String
    let turnId: String
    let item: CompletedThreadItem
}

nonisolated enum CompletedThreadItem: Decodable, Sendable {
    case agentMessage(CompletedAgentMessageItem)
    case other

    private enum CodingKeys: String, CodingKey {
        case type
    }

    private enum ItemType: String, Decodable {
        case agentMessage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decodeIfPresent(ItemType.self, forKey: .type)

        switch type {
        case .agentMessage:
            self = .agentMessage(try CompletedAgentMessageItem(from: decoder))
        case .none:
            self = .other
        }
    }
}

nonisolated struct CompletedAgentMessageItem: Decodable, Sendable {
    let id: String
    let text: String
}

nonisolated enum CodexStoreError: LocalizedError {
    case missingSocket
    case failedToEncodeMessage

    var errorDescription: String? {
        switch self {
        case .missingSocket:
            return "The WebSocket connection is not available."
        case .failedToEncodeMessage:
            return "The WebSocket request could not be encoded."
        }
    }
}

@MainActor
@Observable
final class CodexStore {
    var connectionState: ConnectionState = .disconnected
    var threadID: String?
    var messages: [ConversationMessage] = []
    var draftPrompt = ""
    var isConnecting = false
    var isSending = false
    var lastErrorDescription: String?
    var currentAssistantMessageIndex: Int?
    var nextRequestID = 1
    var scrollTargetMessageID: UUID?

    @ObservationIgnored private var webSocketTask: URLSessionWebSocketTask?
    @ObservationIgnored private var receiveLoopTask: Task<Void, Never>?
    @ObservationIgnored private var pendingThreadStartRequestID: Int?
    @ObservationIgnored private var pendingTurnStartRequestID: Int?
    @ObservationIgnored private let urlSession = URLSession(configuration: .default)
    @ObservationIgnored private let encoder = JSONEncoder()
    @ObservationIgnored private let decoder = JSONDecoder()

    var canSendPrompt: Bool {
        guard !trimmedDraftPrompt.isEmpty else { return false }
        guard !isSending else { return false }
        return threadID != nil
    }

    var statusText: String {
        if let lastErrorDescription, !lastErrorDescription.isEmpty {
            return lastErrorDescription
        }

        switch connectionState {
        case .disconnected:
            return "Disconnected"
        case .connecting:
            return "Connecting"
        case .ready:
            return "Ready"
        case .streaming:
            return "Streaming"
        }
    }

    var isErrorVisible: Bool {
        lastErrorDescription != nil
    }

    private var trimmedDraftPrompt: String {
        draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func connectIfNeeded() async {
        if webSocketTask != nil {
            return
        }

        guard let socketURL = URL(string: "ws://127.0.0.1:4500") else {
            updateFailureState(message: "The local Codex server URL is invalid.")
            return
        }

        lastErrorDescription = nil
        isConnecting = true
        connectionState = .connecting

        let socketTask = urlSession.webSocketTask(with: socketURL)
        webSocketTask = socketTask
        socketTask.resume()

        receiveLoopTask = Task { [weak self] in
            await self?.receiveLoop()
        }

        do {
            let initializeRequest = JSONRPCRequest(
                id: makeRequestID(),
                method: "initialize",
                params: InitializeParams(
                    clientInfo: ClientInfo(name: "AtelierCode", version: "0.1.0")
                )
            )
            try await send(initializeRequest)

            let initializedNotification: JSONRPCRequest<EmptyParams> = .init(
                id: nil,
                method: "initialized",
                params: EmptyParams()
            )
            try await send(initializedNotification)

            let threadStartRequestID = makeRequestID()
            pendingThreadStartRequestID = threadStartRequestID

            let threadStartRequest = JSONRPCRequest(
                id: threadStartRequestID,
                method: "thread/start",
                params: EmptyParams()
            )
            try await send(threadStartRequest)
        } catch {
            updateFailureState(message: error.localizedDescription)
            disconnect()
        }
    }

    func sendPrompt() async {
        let prompt = trimmedDraftPrompt

        guard !prompt.isEmpty else { return }
        guard let threadID else { return }
        guard !isSending else { return }

        if webSocketTask == nil {
            await connectIfNeeded()
        }

        guard webSocketTask != nil else { return }

        messages.append(ConversationMessage(role: .user, text: prompt))
        scrollTargetMessageID = messages.last?.id

        messages.append(ConversationMessage(role: .assistant, text: ""))
        currentAssistantMessageIndex = messages.indices.last
        scrollTargetMessageID = messages.last?.id

        draftPrompt = ""
        lastErrorDescription = nil
        isSending = true
        connectionState = .streaming

        let turnStartRequestID = makeRequestID()
        pendingTurnStartRequestID = turnStartRequestID

        let request = JSONRPCRequest(
            id: turnStartRequestID,
            method: "turn/start",
            params: TurnStartParams(
                threadId: threadID,
                input: [TurnInputItem(text: prompt)]
            )
        )

        do {
            try await send(request)
        } catch {
            updateFailureState(message: error.localizedDescription)
            disconnect()
        }
    }

    func disconnect() {
        receiveLoopTask?.cancel()
        receiveLoopTask = nil

        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil

        pendingThreadStartRequestID = nil
        pendingTurnStartRequestID = nil
        threadID = nil
        currentAssistantMessageIndex = nil
        isConnecting = false
        isSending = false
        connectionState = .disconnected
    }

    private func receiveLoop() async {
        guard let webSocketTask else { return }

        do {
            while !Task.isCancelled {
                let message = try await webSocketTask.receive()

                switch message {
                case .string(let text):
                    handleIncomingTextFrame(text)
                case .data:
                    continue
                @unknown default:
                    continue
                }
            }
        } catch {
            if Task.isCancelled {
                return
            }

            updateFailureState(message: error.localizedDescription)
            disconnect()
        }
    }

    private func handleIncomingTextFrame(_ text: String) {
        let data = Data(text.utf8)

        guard let envelope = try? decoder.decode(IncomingEnvelope.self, from: data) else {
            return
        }

        if let method = envelope.method {
            handleNotification(method: method, data: data)
            return
        }

        if let responseID = envelope.id {
            handleResponse(id: responseID, data: data)
        }
    }

    private func handleNotification(method: String, data: Data) {
        switch method {
        case "item/agentMessage/delta":
            guard
                let notification = try? decoder.decode(JSONRPCNotification<AgentMessageDeltaParams>.self, from: data),
                !notification.params.delta.isEmpty
            else {
                return
            }

            if currentAssistantMessageIndex == nil {
                messages.append(ConversationMessage(role: .assistant, text: ""))
                currentAssistantMessageIndex = messages.indices.last
            }

            guard let currentAssistantMessageIndex else { return }

            messages[currentAssistantMessageIndex].text += notification.params.delta
            scrollTargetMessageID = messages[currentAssistantMessageIndex].id
            connectionState = .streaming
            isSending = true

        case "item/completed":
            guard
                let notification = try? decoder.decode(JSONRPCNotification<ItemCompletedParams>.self, from: data)
            else {
                return
            }

            guard case .agentMessage(let item) = notification.params.item else {
                return
            }

            if currentAssistantMessageIndex == nil {
                messages.append(ConversationMessage(role: .assistant, text: item.text))
                scrollTargetMessageID = messages.last?.id
                return
            }

            guard let currentAssistantMessageIndex else { return }

            messages[currentAssistantMessageIndex].text = item.text
            scrollTargetMessageID = messages[currentAssistantMessageIndex].id

        case "turn/complete", "turn/completed", "turn/end", "turn/finished", "item/agentMessage/complete", "item/agentMessage/completed":
            finishStreaming()

        default:
            break
        }
    }

    private func handleResponse(id: Int, data: Data) {
        if id == pendingThreadStartRequestID {
            pendingThreadStartRequestID = nil

            guard let response = try? decoder.decode(JSONRPCResponse<ThreadStartResult>.self, from: data) else {
                updateFailureState(message: "The thread/start response could not be decoded.")
                return
            }

            if let error = response.error {
                updateFailureState(message: error.message)
                return
            }

            threadID = response.result?.thread.id
            isConnecting = false

            if isSending {
                connectionState = .streaming
            } else {
                connectionState = .ready
            }

            return
        }

        if id == pendingTurnStartRequestID {
            pendingTurnStartRequestID = nil

            guard let response = try? decoder.decode(JSONRPCResponse<EmptyParams>.self, from: data) else {
                return
            }

            if let error = response.error {
                updateFailureState(message: error.message)
                disconnect()
                return
            }

            if response.result == nil {
                updateFailureState(message: "The turn/start response did not include a result.")
                disconnect()
            }
        }
    }

    private func finishStreaming() {
        currentAssistantMessageIndex = nil
        isSending = false

        if threadID == nil {
            connectionState = .connecting
        } else {
            connectionState = .ready
        }
    }

    private func updateFailureState(message: String) {
        lastErrorDescription = message
        isConnecting = false
        isSending = false
        currentAssistantMessageIndex = nil
        connectionState = .disconnected
    }

    private func makeRequestID() -> Int {
        defer { nextRequestID += 1 }
        return nextRequestID
    }

    private func send<Request: Encodable & Sendable>(_ request: Request) async throws {
        guard let webSocketTask else {
            throw CodexStoreError.missingSocket
        }

        let data = try encoder.encode(request)

        guard let payload = String(data: data, encoding: .utf8) else {
            throw CodexStoreError.failedToEncodeMessage
        }

        try await webSocketTask.send(.string(payload))
    }
}
