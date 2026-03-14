//
//  ACPStore.swift
//  AtelierCode
//
//  Created by Codex on 3/14/26.
//

import Foundation
import Observation

@MainActor
@Observable
final class ACPStore {
    var connectionState: ConnectionState = .disconnected
    var messages: [ConversationMessage] = []
    var draftPrompt = ""
    var isConnecting = false
    var isSending = false
    var lastErrorDescription: String?
    var currentAssistantMessageIndex: Int?
    var scrollTargetMessageID: UUID?

    @ObservationIgnored private let sessionClient: ACPSessionClient
    @ObservationIgnored private let cwd: String
    @ObservationIgnored private let clientInfo: ACPImplementationInfo
    @ObservationIgnored private let clientCapabilities: ACPClientCapabilities
    @ObservationIgnored private let mcpServers: [ACPMCPServer]

    init(
        transport: AgentTransport = LocalACPTransport(),
        cwd: String = FileManager.default.currentDirectoryPath,
        clientInfo: ACPImplementationInfo = .atelierCode,
        clientCapabilities: ACPClientCapabilities = .atelierCodeDefaults,
        mcpServers: [ACPMCPServer] = []
    ) {
        self.cwd = cwd
        self.clientInfo = clientInfo
        self.clientCapabilities = clientCapabilities
        self.mcpServers = mcpServers
        sessionClient = ACPSessionClient(transport: transport)
        sessionClient.onAgentMessageChunk = { [weak self] text in
            self?.appendAssistantChunk(text)
        }
        sessionClient.onTransportError = { [weak self] error in
            self?.handleFailure(error)
        }
    }

    var canSendPrompt: Bool {
        guard !trimmedDraftPrompt.isEmpty else { return false }
        guard !isSending else { return false }
        return hasActiveSession
    }

    var statusText: String {
        if let lastErrorDescription, !lastErrorDescription.isEmpty {
            return lastErrorDescription
        }

        switch connectionState {
        case .disconnected:
            return "Gemini offline"
        case .connecting:
            return "Starting Gemini ACP"
        case .ready:
            return "ACP session ready"
        case .streaming:
            return "Streaming reply"
        }
    }

    var isErrorVisible: Bool {
        lastErrorDescription != nil
    }

    private var trimmedDraftPrompt: String {
        draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasActiveSession: Bool {
        sessionClient.sessionID != nil
    }

    func connect() async {
        guard !isConnecting else { return }

        if hasActiveSession {
            if !isSending {
                connectionState = .ready
            }
            return
        }

        lastErrorDescription = nil
        isConnecting = true

        if !isSending {
            connectionState = .connecting
        }

        do {
            try await sessionClient.connect(
                cwd: cwd,
                clientInfo: clientInfo,
                clientCapabilities: clientCapabilities,
                mcpServers: mcpServers
            )
            isConnecting = false
            connectionState = isSending ? .streaming : .ready
        } catch {
            handleFailure(error)
        }
    }

    func connectIfNeeded() async {
        guard !hasActiveSession else { return }
        await connect()
    }

    func sendMessage(_ text: String) async {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !prompt.isEmpty else { return }
        guard !isSending else { return }

        if !hasActiveSession {
            await connect()
        }

        guard hasActiveSession else { return }

        prepareForPrompt(prompt)

        do {
            _ = try await sessionClient.sendPrompt(prompt)
            finishStreaming()
        } catch {
            handleFailure(error)
        }
    }

    func sendPrompt() async {
        let prompt = trimmedDraftPrompt
        guard !prompt.isEmpty else { return }

        draftPrompt = ""
        await sendMessage(prompt)
    }

    private func prepareForPrompt(_ prompt: String) {
        messages.append(ConversationMessage(role: .user, text: prompt))
        scrollTargetMessageID = messages.last?.id

        messages.append(ConversationMessage(role: .assistant, text: ""))
        currentAssistantMessageIndex = messages.indices.last
        scrollTargetMessageID = messages.last?.id

        lastErrorDescription = nil
        isSending = true
        connectionState = .streaming
    }

    private func appendAssistantChunk(_ text: String) {
        guard !text.isEmpty else { return }
        guard isSending || currentAssistantMessageIndex != nil else { return }

        if currentAssistantMessageIndex == nil {
            messages.append(ConversationMessage(role: .assistant, text: ""))
            currentAssistantMessageIndex = messages.indices.last
        }

        guard let currentAssistantMessageIndex else { return }

        messages[currentAssistantMessageIndex].text += text
        scrollTargetMessageID = messages[currentAssistantMessageIndex].id
        connectionState = .streaming
        isSending = true
    }

    private func finishStreaming() {
        currentAssistantMessageIndex = nil
        isSending = false
        isConnecting = false
        connectionState = hasActiveSession ? .ready : .disconnected
    }

    private func handleFailure(_ error: any Error) {
        sessionClient.reset()
        lastErrorDescription = error.localizedDescription
        isConnecting = false
        isSending = false
        currentAssistantMessageIndex = nil
        connectionState = .disconnected
    }
}
