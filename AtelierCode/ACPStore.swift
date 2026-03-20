//
//  ACPStore.swift
//  AtelierCode
//
//  Created by Codex on 3/14/26.
//

import Foundation
import Observation

nonisolated enum AppWorkingDirectory: Sendable {
    static func resolve(
        currentEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectoryPath: String = FileManager.default.currentDirectoryPath,
        userHomeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String {
        if let presentWorkingDirectory = sanitized(path: currentEnvironment["PWD"]) {
            return presentWorkingDirectory
        }

        if let currentDirectory = sanitized(path: currentDirectoryPath) {
            return currentDirectory
        }

        return userHomeDirectory
    }

    private static func sanitized(path: String?) -> String? {
        guard let path else { return nil }

        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty, trimmedPath != "/" else { return nil }
        return trimmedPath
    }
}

@MainActor
@Observable
final class ACPStore {
    var connectionState: ConnectionState = .disconnected
    var messages: [ConversationMessage] = []
    var activitiesByMessageID: [UUID: [ACPMessageActivity]] = [:]
    var terminalStates: [String: ACPTerminalState] = [:]
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
    @ObservationIgnored private var nextActivitySequence = 1
    @ObservationIgnored private var terminalMessageIDs: [String: UUID] = [:]
    @ObservationIgnored private var toolCallMessageIDs: [String: UUID] = [:]
    @ObservationIgnored private var terminalOutputSnapshots: [String: String] = [:]

    init(
        transport: AgentTransport = LocalACPTransport(),
        cwd: String = AppWorkingDirectory.resolve(),
        clientInfo: ACPImplementationInfo = .atelierCode,
        clientCapabilities: ACPClientCapabilities = .atelierCodeDefaults,
        mcpServers: [ACPMCPServer] = []
    ) {
        self.cwd = cwd
        self.clientInfo = clientInfo
        self.clientCapabilities = clientCapabilities
        self.mcpServers = mcpServers
        sessionClient = ACPSessionClient(transport: transport)
        sessionClient.onSessionUpdate = { [weak self] params in
            self?.handleSessionUpdate(params)
        }
        sessionClient.onPermissionDecision = { [weak self] decision in
            self?.handlePermissionDecision(decision)
        }
        sessionClient.onTerminalStateChange = { [weak self] state in
            self?.handleTerminalStateChange(state)
        }
        sessionClient.onTerminalStatesReset = { [weak self] in
            self?.terminalStates.removeAll()
            self?.terminalOutputSnapshots.removeAll()
            self?.terminalMessageIDs.removeAll()
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

        let assistantMessage = ConversationMessage(role: .assistant, text: "")
        messages.append(assistantMessage)
        currentAssistantMessageIndex = messages.indices.last
        activitiesByMessageID[assistantMessage.id] = []
        scrollTargetMessageID = assistantMessage.id

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

    private func handleSessionUpdate(_ params: ACPSessionUpdateNotificationParams) {
        switch params.update.kind {
        case .agentMessageChunk:
            if let text = params.update.agentMessageChunkText {
                appendAssistantChunk(text)
            }
        case .agentThoughtChunk:
            appendActivity(
                kind: .thinking,
                title: "Gemini is thinking",
                detail: params.update.summaryText,
                update: params.update
            )
        case .availableCommands:
            let commandNames = params.update.availableCommands?.map(\.name).joined(separator: ", ")
            appendActivity(
                kind: .availableCommands,
                title: "Available commands updated",
                detail: commandNames,
                update: params.update,
                commands: params.update.availableCommands ?? []
            )
        case .tool:
            let title = params.update.titleText.map { "Tool: \($0)" } ?? "Tool activity"
            appendActivity(
                kind: .tool,
                title: title,
                detail: params.update.summaryText,
                update: params.update
            )
        case .permission:
            appendActivity(
                kind: .permission,
                title: "Permission update",
                detail: params.update.summaryText,
                update: params.update
            )
        case .terminal:
            appendActivity(
                kind: .terminal,
                title: "Terminal update",
                detail: params.update.summaryText,
                update: params.update
            )
        case .other:
            break
        }
    }

    private func handlePermissionDecision(_ decision: ACPPermissionDecision) {
        let title: String
        let detail: String?

        switch decision.outcome {
        case .cancelled:
            title = "Permission denied"
            detail = decision.options.map(\.name).joined(separator: ", ")
        case .selected:
            let selectedName = decision.selectedOption?.name ?? "Allowed"
            title = "Permission granted"
            detail = selectedName
        }

        appendActivity(
            kind: .permission,
            title: title,
            detail: detail,
            toolCallId: decision.toolCallId
        )
    }

    private func handleTerminalStateChange(_ state: ACPTerminalState) {
        let previousState = terminalStates[state.id]
        terminalStates[state.id] = state

        let messageID = messageID(forTerminalID: state.id)
        terminalMessageIDs[state.id] = messageID

        let previousOutput = terminalOutputSnapshots[state.id] ?? previousState?.output ?? ""
        let outputDelta = deltaOutput(from: previousOutput, to: state.output)
        terminalOutputSnapshots[state.id] = state.output

        if previousState == nil {
            appendActivity(
                to: messageID,
                ACPMessageActivity(
                    sequence: nextSequence(),
                    kind: .terminal,
                    title: "Started terminal",
                    detail: "\(state.command) in \(state.cwd)",
                    terminal: ACPTerminalActivitySnapshot(
                        terminalId: state.id,
                        command: state.command,
                        cwd: state.cwd,
                        newOutput: nil,
                        fullOutput: state.output,
                        truncated: state.truncated,
                        exitStatus: state.exitStatus,
                        isReleased: state.isReleased
                    )
                )
            )
        }

        if let outputDelta, !outputDelta.isEmpty {
            appendActivity(
                to: messageID,
                ACPMessageActivity(
                    sequence: nextSequence(),
                    kind: .terminal,
                    title: "Terminal output",
                    detail: nil,
                    terminal: ACPTerminalActivitySnapshot(
                        terminalId: state.id,
                        command: state.command,
                        cwd: state.cwd,
                        newOutput: outputDelta,
                        fullOutput: state.output,
                        truncated: state.truncated,
                        exitStatus: state.exitStatus,
                        isReleased: state.isReleased
                    )
                )
            )
        }

        if previousState?.exitStatus != state.exitStatus, let exitStatus = state.exitStatus {
            appendActivity(
                to: messageID,
                ACPMessageActivity(
                    sequence: nextSequence(),
                    kind: .terminal,
                    title: "Terminal finished",
                    detail: terminalExitDescription(exitStatus),
                    terminal: ACPTerminalActivitySnapshot(
                        terminalId: state.id,
                        command: state.command,
                        cwd: state.cwd,
                        newOutput: nil,
                        fullOutput: state.output,
                        truncated: state.truncated,
                        exitStatus: exitStatus,
                        isReleased: state.isReleased
                    )
                )
            )
        }

        if previousState?.isReleased != state.isReleased, state.isReleased {
            appendActivity(
                to: messageID,
                ACPMessageActivity(
                    sequence: nextSequence(),
                    kind: .terminal,
                    title: "Terminal released",
                    detail: state.command,
                    terminal: ACPTerminalActivitySnapshot(
                        terminalId: state.id,
                        command: state.command,
                        cwd: state.cwd,
                        newOutput: nil,
                        fullOutput: state.output,
                        truncated: state.truncated,
                        exitStatus: state.exitStatus,
                        isReleased: state.isReleased
                    )
                )
            )
        }
    }

    private func finishStreaming() {
        currentAssistantMessageIndex = nil
        isSending = false
        isConnecting = false
        connectionState = hasActiveSession ? .ready : .disconnected
    }

    private func handleFailure(_ error: any Error) {
        sessionClient.reset()
        terminalStates.removeAll()
        terminalOutputSnapshots.removeAll()
        terminalMessageIDs.removeAll()
        toolCallMessageIDs.removeAll()
        lastErrorDescription = error.localizedDescription
        isConnecting = false
        isSending = false
        currentAssistantMessageIndex = nil
        connectionState = .disconnected
    }

    func activities(for messageID: UUID) -> [ACPMessageActivity] {
        activitiesByMessageID[messageID, default: []]
            .sorted { $0.sequence < $1.sequence }
    }

    private func appendActivity(
        kind: ACPMessageActivityKind,
        title: String,
        detail: String?,
        update: ACPSessionUpdate? = nil,
        toolCallId: String? = nil,
        commands: [ACPAvailableCommand] = []
    ) {
        let messageID = messageID(
            forToolCallID: toolCallId ?? update?.toolCallId,
            terminalID: update?.terminalId
        )

        appendActivity(
            to: messageID,
            ACPMessageActivity(
                sequence: nextSequence(),
                kind: kind,
                title: title,
                detail: detail,
                sessionUpdate: update?.sessionUpdate,
                toolCallId: toolCallId ?? update?.toolCallId,
                commands: commands
            )
        )
    }

    private func appendActivity(to messageID: UUID?, _ activity: ACPMessageActivity) {
        guard let messageID else { return }
        activitiesByMessageID[messageID, default: []].append(activity)
        scrollTargetMessageID = messageID
    }

    private func messageID(forToolCallID toolCallID: String?, terminalID: String?) -> UUID? {
        if let toolCallID, let messageID = toolCallMessageIDs[toolCallID] {
            return messageID
        }

        if let terminalID, let messageID = terminalMessageIDs[terminalID] {
            return messageID
        }

        guard let currentMessageID = currentAssistantMessageID else {
            return nil
        }

        if let toolCallID {
            toolCallMessageIDs[toolCallID] = currentMessageID
        }

        if let terminalID {
            terminalMessageIDs[terminalID] = currentMessageID
        }

        return currentMessageID
    }

    private func messageID(forTerminalID terminalID: String) -> UUID? {
        messageID(forToolCallID: nil, terminalID: terminalID)
    }

    private var currentAssistantMessageID: UUID? {
        guard let currentAssistantMessageIndex else { return nil }
        guard messages.indices.contains(currentAssistantMessageIndex) else { return nil }
        return messages[currentAssistantMessageIndex].id
    }

    private func nextSequence() -> Int {
        defer { nextActivitySequence += 1 }
        return nextActivitySequence
    }

    private func deltaOutput(from previous: String, to current: String) -> String? {
        guard current != previous else { return nil }

        if current.hasPrefix(previous) {
            return String(current.dropFirst(previous.count))
        }

        return current
    }

    private func terminalExitDescription(_ exitStatus: ACPTerminalExitStatus) -> String {
        if let exitCode = exitStatus.exitCode {
            return "Exit code \(exitCode)"
        }

        if let signal = exitStatus.signal {
            return signal
        }

        return "Finished"
    }
}
