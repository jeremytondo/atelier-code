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

nonisolated struct ACPPersistedWorkspaceSession: Codable, Equatable, Sendable {
    let workspaceRoot: String
    let sessionId: String
    let updatedAt: Date
}

@MainActor
protocol ACPWorkspaceSessionPersisting: AnyObject {
    func sessionID(for workspaceRoot: String) -> String?
    func save(sessionID: String, for workspaceRoot: String)
    func removeSession(for workspaceRoot: String)
}

@MainActor
final class ACPWorkspaceSessionStore: ACPWorkspaceSessionPersisting {
    static let standard = ACPWorkspaceSessionStore()

    private let userDefaults: UserDefaults
    private let storageKey: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = "AtelierCode.ACPWorkspaceSessions"
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
    }

    func sessionID(for workspaceRoot: String) -> String? {
        storedSessions[Self.canonicalWorkspaceRoot(workspaceRoot)]?.sessionId
    }

    func save(sessionID: String, for workspaceRoot: String) {
        var sessions = storedSessions
        let canonicalWorkspaceRoot = Self.canonicalWorkspaceRoot(workspaceRoot)
        sessions[canonicalWorkspaceRoot] = ACPPersistedWorkspaceSession(
            workspaceRoot: canonicalWorkspaceRoot,
            sessionId: sessionID,
            updatedAt: Date()
        )
        persist(sessions)
    }

    func removeSession(for workspaceRoot: String) {
        var sessions = storedSessions
        sessions.removeValue(forKey: Self.canonicalWorkspaceRoot(workspaceRoot))
        persist(sessions)
    }

    private var storedSessions: [String: ACPPersistedWorkspaceSession] {
        guard let data = userDefaults.data(forKey: storageKey) else { return [:] }
        return (try? decoder.decode([String: ACPPersistedWorkspaceSession].self, from: data)) ?? [:]
    }

    private func persist(_ sessions: [String: ACPPersistedWorkspaceSession]) {
        guard let data = try? encoder.encode(sessions) else { return }
        userDefaults.set(data, forKey: storageKey)
    }

    private static func canonicalWorkspaceRoot(_ workspaceRoot: String) -> String {
        URL(fileURLWithPath: workspaceRoot)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }
}

nonisolated struct ACPPersistedWorkspacePermissionRules: Codable, Equatable, Sendable {
    let workspaceRoot: String
    var decisions: [ACPWorkspacePermissionScope: ACPWorkspacePermissionRuleDecision]
    let updatedAt: Date
}

@MainActor
protocol ACPWorkspacePermissionPersisting: AnyObject {
    func decision(
        for workspaceRoot: String,
        scope: ACPWorkspacePermissionScope
    ) -> ACPWorkspacePermissionRuleDecision?
    func save(
        decision: ACPWorkspacePermissionRuleDecision,
        for workspaceRoot: String,
        scope: ACPWorkspacePermissionScope
    )
    func removeDecision(for workspaceRoot: String, scope: ACPWorkspacePermissionScope)
    func removeAllDecisions(for workspaceRoot: String)
}

@MainActor
final class ACPWorkspacePermissionStore: ACPWorkspacePermissionPersisting {
    static let standard = ACPWorkspacePermissionStore()

    private let userDefaults: UserDefaults
    private let storageKey: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = "AtelierCode.ACPWorkspacePermissionRules"
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
    }

    func decision(
        for workspaceRoot: String,
        scope: ACPWorkspacePermissionScope
    ) -> ACPWorkspacePermissionRuleDecision? {
        storedRules[Self.canonicalWorkspaceRoot(workspaceRoot)]?.decisions[scope]
    }

    func save(
        decision: ACPWorkspacePermissionRuleDecision,
        for workspaceRoot: String,
        scope: ACPWorkspacePermissionScope
    ) {
        var rules = storedRules
        let canonicalWorkspaceRoot = Self.canonicalWorkspaceRoot(workspaceRoot)
        var decisions = rules[canonicalWorkspaceRoot]?.decisions ?? [:]
        decisions[scope] = decision
        rules[canonicalWorkspaceRoot] = ACPPersistedWorkspacePermissionRules(
            workspaceRoot: canonicalWorkspaceRoot,
            decisions: decisions,
            updatedAt: Date()
        )
        persist(rules)
    }

    func removeDecision(for workspaceRoot: String, scope: ACPWorkspacePermissionScope) {
        let canonicalWorkspaceRoot = Self.canonicalWorkspaceRoot(workspaceRoot)
        var rules = storedRules
        guard var entry = rules[canonicalWorkspaceRoot] else { return }
        entry.decisions.removeValue(forKey: scope)

        if entry.decisions.isEmpty {
            rules.removeValue(forKey: canonicalWorkspaceRoot)
        } else {
            rules[canonicalWorkspaceRoot] = ACPPersistedWorkspacePermissionRules(
                workspaceRoot: canonicalWorkspaceRoot,
                decisions: entry.decisions,
                updatedAt: Date()
            )
        }

        persist(rules)
    }

    func removeAllDecisions(for workspaceRoot: String) {
        var rules = storedRules
        rules.removeValue(forKey: Self.canonicalWorkspaceRoot(workspaceRoot))
        persist(rules)
    }

    private var storedRules: [String: ACPPersistedWorkspacePermissionRules] {
        guard let data = userDefaults.data(forKey: storageKey) else { return [:] }
        return (try? decoder.decode([String: ACPPersistedWorkspacePermissionRules].self, from: data)) ?? [:]
    }

    private func persist(_ rules: [String: ACPPersistedWorkspacePermissionRules]) {
        guard let data = try? encoder.encode(rules) else { return }
        userDefaults.set(data, forKey: storageKey)
    }

    private static func canonicalWorkspaceRoot(_ workspaceRoot: String) -> String {
        URL(fileURLWithPath: workspaceRoot)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }
}

nonisolated enum ACPRecoveryIssueKind: Equatable, Sendable {
    case missingExecutable
    case authenticationRequired
    case modelUnavailable
    case subprocessFailure
    case transportFailure
}

nonisolated struct ACPRecoveryIssue: Equatable, Sendable {
    let kind: ACPRecoveryIssueKind
    let title: String
    let detail: String
    let recoverySuggestion: String?
    let suggestedCommand: String?

    var setupState: AppBlockingSetupState {
        .message(
            title: title,
            detail: [detail, recoverySuggestion]
                .compactMap { $0 }
                .joined(separator: "\n\n")
        )
    }
}

@MainActor
@Observable
final class ACPStore {
    private struct PendingPermissionResolver {
        let prompt: ACPPermissionPrompt
        let resolve: (ACPPermissionPromptActionKind) -> Void
    }

    var connectionState: ConnectionState = .disconnected
    var messages: [ConversationMessage] = []
    var activitiesByMessageID: [UUID: [ACPMessageActivity]] = [:]
    var hostActivities: [ACPMessageActivity] = []
    var terminalStates: [String: ACPTerminalState] = [:]
    var pendingPermissionRequests: [ACPPermissionPrompt] = []
    var draftPrompt = ""
    var isConnecting = false
    var isSending = false
    var lastErrorDescription: String?
    var recoveryIssue: ACPRecoveryIssue?
    var currentAssistantMessageIndex: Int?
    var scrollTargetMessageID: UUID?

    @ObservationIgnored private let sessionClient: ACPSessionClient
    @ObservationIgnored private let cwd: String
    @ObservationIgnored private let geminiSettings: GeminiAppSettings
    @ObservationIgnored private let clientInfo: ACPImplementationInfo
    @ObservationIgnored private let clientCapabilities: ACPClientCapabilities
    @ObservationIgnored private let mcpServers: [ACPMCPServer]
    @ObservationIgnored private let sessionPersistence: ACPWorkspaceSessionPersisting
    @ObservationIgnored private let permissionPersistence: ACPWorkspacePermissionPersisting
    @ObservationIgnored private var nextActivitySequence = 1
    @ObservationIgnored private var terminalMessageIDs: [String: UUID] = [:]
    @ObservationIgnored private var toolCallMessageIDs: [String: UUID] = [:]
    @ObservationIgnored private var terminalOutputSnapshots: [String: String] = [:]
    @ObservationIgnored private var pendingPermissionResolvers: [UUID: PendingPermissionResolver] = [:]
    @ObservationIgnored private var latestTransportDiagnostic: String?

    init(
        transport: AgentTransport? = nil,
        cwd: String = AppWorkingDirectory.resolve(),
        geminiSettings: GeminiAppSettings = .default,
        clientInfo: ACPImplementationInfo = .atelierCode,
        clientCapabilities: ACPClientCapabilities = .atelierCodeDefaults,
        mcpServers: [ACPMCPServer] = [],
        sessionPersistence: ACPWorkspaceSessionPersisting = ACPWorkspaceSessionStore.standard,
        permissionPersistence: ACPWorkspacePermissionPersisting = ACPWorkspacePermissionStore.standard
    ) {
        let resolvedTransport = transport ?? LocalACPTransport(
            executableOverridePath: geminiSettings.executableOverridePath,
            model: geminiSettings.defaultModel
        )

        self.cwd = cwd
        self.geminiSettings = geminiSettings
        self.clientInfo = clientInfo
        self.clientCapabilities = clientCapabilities
        self.mcpServers = mcpServers
        self.sessionPersistence = sessionPersistence
        self.permissionPersistence = permissionPersistence
        sessionClient = ACPSessionClient(transport: resolvedTransport)
        sessionClient.permissionPolicy = ACPPermissionPolicy(
            resolveOutcome: { [weak self] request, context in
                await self?.resolveAgentPermissionRequest(request, context: context) ?? .cancelled
            },
            authorizeLocalAction: { [weak self] action, context in
                await self?.authorizeLocalAction(action, context: context)
                    ?? .deny(message: action.defaultDeniedMessage)
            }
        )
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

        if let localTransport = resolvedTransport as? LocalACPTransport {
            localTransport.onDiagnostic = { [weak self] diagnostic in
                self?.latestTransportDiagnostic = diagnostic
            }
        }
    }

    var canSendPrompt: Bool {
        guard !trimmedDraftPrompt.isEmpty else { return false }
        guard !isSending else { return false }
        return hasActiveSession
    }

    var workspacePath: String {
        cwd
    }

    var canCancelPrompt: Bool {
        isSending && connectionState != .cancelling
    }

    var recoverySetupState: AppBlockingSetupState? {
        recoveryIssue?.setupState
    }

    var visibleTerminalStates: [ACPTerminalState] {
        terminalStates.values.sorted { lhs, rhs in
            let lhsExitSequence = hostActivities.last(where: { $0.terminal?.terminalId == lhs.id })?.sequence ?? 0
            let rhsExitSequence = hostActivities.last(where: { $0.terminal?.terminalId == rhs.id })?.sequence ?? 0
            return lhsExitSequence > rhsExitSequence
        }
    }

    var statusText: String {
        if let recoveryIssue {
            return recoveryIssue.title
        }

        if let lastErrorDescription, !lastErrorDescription.isEmpty {
            return lastErrorDescription
        }

        switch connectionState {
        case .disconnected:
            return "Gemini offline"
        case .connecting:
            return "Starting Gemini ACP"
        case .resuming:
            return "Resuming ACP session"
        case .ready:
            return "ACP session ready"
        case .streaming:
            return "Streaming reply"
        case .cancelling:
            return "Cancelling reply"
        }
    }

    var isErrorVisible: Bool {
        recoveryIssue != nil || lastErrorDescription != nil
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

        recoveryIssue = nil
        lastErrorDescription = nil
        isConnecting = true
        let persistedSessionID = sessionPersistence.sessionID(for: cwd)

        if !isSending {
            connectionState = persistedSessionID == nil ? .connecting : .resuming
        }

        do {
            try await sessionClient.connect(
                cwd: cwd,
                clientInfo: clientInfo,
                clientCapabilities: clientCapabilities,
                resumeSessionID: persistedSessionID,
                mcpServers: mcpServers
            )
            if let sessionID = sessionClient.sessionID {
                sessionPersistence.save(sessionID: sessionID, for: cwd)
            }
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
            let response = try await sessionClient.sendPrompt(prompt)
            finishStreaming(stopReason: response.stopReason)
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

    func cancelPrompt() async {
        guard canCancelPrompt else { return }

        lastErrorDescription = nil
        connectionState = .cancelling

        do {
            try sessionClient.cancelPrompt()
        } catch {
            handleFailure(error)
        }
    }

    func teardown() {
        resolveAllPendingPermissionRequests(with: .deny)
        sessionClient.reset()
        connectionState = .disconnected
        messages = []
        activitiesByMessageID = [:]
        hostActivities = []
        terminalStates = [:]
        pendingPermissionRequests = []
        draftPrompt = ""
        isConnecting = false
        isSending = false
        lastErrorDescription = nil
        recoveryIssue = nil
        currentAssistantMessageIndex = nil
        scrollTargetMessageID = nil
        nextActivitySequence = 1
        terminalMessageIDs = [:]
        toolCallMessageIDs = [:]
        terminalOutputSnapshots = [:]
        pendingPermissionResolvers = [:]
        latestTransportDiagnostic = nil
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
        if connectionState != .cancelling {
            connectionState = .streaming
        }
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

    func resolvePermissionRequest(_ prompt: ACPPermissionPrompt, with action: ACPPermissionPromptAction) {
        guard let resolver = pendingPermissionResolvers.removeValue(forKey: prompt.id) else { return }
        pendingPermissionRequests.removeAll { $0.id == prompt.id }
        resolver.resolve(action.kind)
    }

    private func resolveAgentPermissionRequest(
        _ request: ACPRequestPermissionRequest,
        context: ACPPermissionContext
    ) async -> ACPRequestPermissionOutcome {
        let prompt = ACPPermissionPrompt(
            source: .agentTool,
            title: "Approve tool permission",
            detail: agentPermissionDetail(for: request, context: context),
            toolCallId: context.toolCallId,
            actions: request.options.map { option in
                ACPPermissionPromptAction(
                    id: option.optionId,
                    title: option.name,
                    role: option.kind.contains("reject") || option.kind.contains("deny") ? .destructive : .primary,
                    kind: .selectACPOption(optionId: option.optionId)
                )
            }
        )

        appendActivity(
            kind: .permission,
            title: prompt.title,
            detail: prompt.detail,
            toolCallId: context.toolCallId
        )

        let selection = await enqueuePermissionPrompt(prompt)
        if case .selectACPOption(let optionId) = selection {
            return .selected(optionId: optionId)
        }

        return .cancelled
    }

    private func authorizeLocalAction(
        _ action: ACPPermissionLocalAction,
        context: ACPPermissionContext
    ) async -> ACPPermissionAuthorization {
        if let savedDecision = savedDecision(for: action) {
            appendActivity(
                kind: .permission,
                title: savedDecision == .allow ? "Permission granted" : "Permission denied",
                detail: "\(permissionSubject(for: action)) \(savedDecision == .allow ? "allowed" : "denied") by saved workspace rule."
            )

            switch savedDecision {
            case .allow:
                return .allow
            case .deny:
                return .deny(message: action.defaultDeniedMessage)
            }
        }

        let prompt = prompt(for: action)
        appendActivity(
            kind: .permission,
            title: prompt.title,
            detail: prompt.detail,
            toolCallId: context.toolCallId
        )

        let selection = await enqueuePermissionPrompt(prompt)
        let authorization = localAuthorization(for: action, selection: selection)
        let isAllowed: Bool
        switch authorization {
        case .allow:
            isAllowed = true
        case .deny:
            isAllowed = false
        }

        appendActivity(
            kind: .permission,
            title: isAllowed ? "Permission granted" : "Permission denied",
            detail: localPermissionDecisionDetail(for: action, selection: selection)
        )

        if let scope = prompt.persistenceScope {
            switch selection {
            case .allowAlwaysForWorkspace:
                permissionPersistence.save(decision: .allow, for: cwd, scope: scope)
            case .deny:
                permissionPersistence.save(decision: .deny, for: cwd, scope: scope)
            case .allowOnce, .selectACPOption:
                break
            }
        }

        return authorization
    }

    private func handleTerminalStateChange(_ state: ACPTerminalState) {
        let previousState = terminalStates[state.id]
        terminalStates[state.id] = state

        let messageID = messageID(forTerminalID: state.id) ?? makeStandaloneActivityMessage()
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

    private func finishStreaming(stopReason: String) {
        if stopReason.caseInsensitiveCompare("cancelled") == .orderedSame {
            fillEmptyAssistantMessageIfNeeded(with: "Generation cancelled.")
        }

        currentAssistantMessageIndex = nil
        isSending = false
        isConnecting = false
        connectionState = hasActiveSession ? .ready : .disconnected
    }

    private func handleFailure(_ error: any Error) {
        resolveAllPendingPermissionRequests(with: .deny)
        sessionClient.reset()
        terminalStates.removeAll()
        terminalOutputSnapshots.removeAll()
        terminalMessageIDs.removeAll()
        toolCallMessageIDs.removeAll()
        pendingPermissionRequests.removeAll()
        lastErrorDescription = error.localizedDescription
        recoveryIssue = classifyRecoveryIssue(for: error)
        isConnecting = false
        isSending = false
        currentAssistantMessageIndex = nil
        connectionState = .disconnected
    }

    private func classifyRecoveryIssue(for error: any Error) -> ACPRecoveryIssue {
        if let error = error as? GeminiExecutableLocatorError {
            return ACPRecoveryIssue(
                kind: .missingExecutable,
                title: "Gemini executable not found",
                detail: error.localizedDescription,
                recoverySuggestion: "Set a valid Gemini executable override in Settings or install `gemini`, then reconnect.",
                suggestedCommand: nil
            )
        }

        if let error = error as? ACPSessionClientError {
            switch error {
            case .authenticationRequired:
                return ACPRecoveryIssue(
                    kind: .authenticationRequired,
                    title: "Gemini authentication required",
                    detail: error.localizedDescription,
                    recoverySuggestion: "Re-authenticate Gemini in Terminal, then reconnect from AtelierCode.",
                    suggestedCommand: "gemini"
                )
            case .modelUnavailable:
                return ACPRecoveryIssue(
                    kind: .modelUnavailable,
                    title: "Configured Gemini model unavailable",
                    detail: "Model: \(geminiSettings.defaultModel)\n\(error.localizedDescription)",
                    recoverySuggestion: "Choose an available model in Settings, then reconnect or reset the session.",
                    suggestedCommand: nil
                )
            default:
                break
            }
        }

        if let error = error as? LocalACPTransportError {
            let suggestion = latestTransportDiagnostic.map { "Last Gemini diagnostic: \($0)" }
            return ACPRecoveryIssue(
                kind: .subprocessFailure,
                title: "Gemini subprocess failed",
                detail: error.localizedDescription,
                recoverySuggestion: suggestion ?? "Reconnect to launch a fresh Gemini ACP subprocess.",
                suggestedCommand: nil
            )
        }

        return ACPRecoveryIssue(
            kind: .transportFailure,
            title: "Gemini connection failed",
            detail: error.localizedDescription,
            recoverySuggestion: "Reconnect to retry the ACP session, or reset the session if resume state may be stale.",
            suggestedCommand: nil
        )
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
        hostActivities.append(activity)

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

    private func makeStandaloneActivityMessage() -> UUID {
        let message = ConversationMessage(role: .assistant, text: "Gemini activity")
        messages.append(message)
        activitiesByMessageID[message.id] = activitiesByMessageID[message.id, default: []]
        scrollTargetMessageID = message.id
        return message.id
    }

    private func fillEmptyAssistantMessageIfNeeded(with text: String) {
        guard let currentAssistantMessageIndex else { return }
        guard messages.indices.contains(currentAssistantMessageIndex) else { return }

        let existingText = messages[currentAssistantMessageIndex].text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard existingText.isEmpty else { return }

        messages[currentAssistantMessageIndex].text = text
        scrollTargetMessageID = messages[currentAssistantMessageIndex].id
    }

    private func enqueuePermissionPrompt(_ prompt: ACPPermissionPrompt) async -> ACPPermissionPromptActionKind {
        await withCheckedContinuation { continuation in
            pendingPermissionRequests.append(prompt)
            pendingPermissionResolvers[prompt.id] = PendingPermissionResolver(
                prompt: prompt,
                resolve: { selection in
                    continuation.resume(returning: selection)
                }
            )
        }
    }

    private func resolveAllPendingPermissionRequests(with fallback: ACPPermissionPromptActionKind) {
        let resolvers = pendingPermissionResolvers.values
        pendingPermissionResolvers.removeAll()
        pendingPermissionRequests.removeAll()
        for resolver in resolvers {
            resolver.resolve(fallback)
        }
    }

    private func savedDecision(for action: ACPPermissionLocalAction) -> ACPWorkspacePermissionRuleDecision? {
        guard let scope = permissionScope(for: action) else { return nil }
        return permissionPersistence.decision(for: cwd, scope: scope)
    }

    private func permissionScope(for action: ACPPermissionLocalAction) -> ACPWorkspacePermissionScope? {
        switch action {
        case .fileRead:
            return .fileRead
        case .terminalCreate:
            return .terminalCreate
        case .terminalKill, .terminalRelease:
            return nil
        }
    }

    private func prompt(for action: ACPPermissionLocalAction) -> ACPPermissionPrompt {
        switch action {
        case .fileRead(let path):
            return ACPPermissionPrompt(
                source: .fileRead,
                title: "Read workspace file",
                detail: path,
                persistenceScope: .fileRead,
                actions: [
                    ACPPermissionPromptAction(
                        id: "allow_once",
                        title: "Allow once",
                        role: .primary,
                        kind: .allowOnce
                    ),
                    ACPPermissionPromptAction(
                        id: "allow_workspace",
                        title: "Always for this workspace",
                        role: .secondary,
                        kind: .allowAlwaysForWorkspace
                    ),
                    ACPPermissionPromptAction(
                        id: "deny",
                        title: "Deny",
                        role: .destructive,
                        kind: .deny
                    ),
                ]
            )
        case .terminalCreate(let command, let cwd):
            return ACPPermissionPrompt(
                source: .terminalCreate,
                title: "Create terminal",
                detail: "\(command)\nWorking directory: \(cwd)",
                persistenceScope: .terminalCreate,
                actions: [
                    ACPPermissionPromptAction(
                        id: "allow_once",
                        title: "Allow once",
                        role: .primary,
                        kind: .allowOnce
                    ),
                    ACPPermissionPromptAction(
                        id: "allow_workspace",
                        title: "Always for this workspace",
                        role: .secondary,
                        kind: .allowAlwaysForWorkspace
                    ),
                    ACPPermissionPromptAction(
                        id: "deny",
                        title: "Deny",
                        role: .destructive,
                        kind: .deny
                    ),
                ]
            )
        case .terminalKill(let terminalId):
            return ACPPermissionPrompt(
                source: .terminalKill,
                title: "Kill terminal",
                detail: "Terminal ID: \(terminalId)",
                actions: [
                    ACPPermissionPromptAction(
                        id: "allow_once",
                        title: "Allow once",
                        role: .primary,
                        kind: .allowOnce
                    ),
                    ACPPermissionPromptAction(
                        id: "deny",
                        title: "Deny",
                        role: .destructive,
                        kind: .deny
                    ),
                ]
            )
        case .terminalRelease(let terminalId):
            return ACPPermissionPrompt(
                source: .terminalRelease,
                title: "Release terminal",
                detail: "Terminal ID: \(terminalId)",
                actions: [
                    ACPPermissionPromptAction(
                        id: "allow_once",
                        title: "Allow once",
                        role: .primary,
                        kind: .allowOnce
                    ),
                    ACPPermissionPromptAction(
                        id: "deny",
                        title: "Deny",
                        role: .destructive,
                        kind: .deny
                    ),
                ]
            )
        }
    }

    private func localAuthorization(
        for action: ACPPermissionLocalAction,
        selection: ACPPermissionPromptActionKind
    ) -> ACPPermissionAuthorization {
        switch selection {
        case .allowOnce, .allowAlwaysForWorkspace:
            return .allow
        case .deny, .selectACPOption:
            return .deny(message: action.defaultDeniedMessage)
        }
    }

    private func localPermissionDecisionDetail(
        for action: ACPPermissionLocalAction,
        selection: ACPPermissionPromptActionKind
    ) -> String {
        switch selection {
        case .allowOnce:
            return "\(permissionSubject(for: action)) allowed once."
        case .allowAlwaysForWorkspace:
            return "\(permissionSubject(for: action)) allowed for this workspace."
        case .deny:
            if permissionScope(for: action) != nil {
                return "\(permissionSubject(for: action)) denied for this workspace."
            }
            return "\(permissionSubject(for: action)) denied."
        case .selectACPOption:
            return "\(permissionSubject(for: action)) denied."
        }
    }

    private func permissionSubject(for action: ACPPermissionLocalAction) -> String {
        switch action {
        case .fileRead:
            return "File reads"
        case .terminalCreate:
            return "Terminal creation"
        case .terminalKill:
            return "Terminal kill"
        case .terminalRelease:
            return "Terminal release"
        }
    }

    private func agentPermissionDetail(
        for request: ACPRequestPermissionRequest,
        context: ACPPermissionContext
    ) -> String {
        let optionSummary = request.options.map(\.name).joined(separator: ", ")
        if let toolCallId = context.toolCallId, !toolCallId.isEmpty {
            return "Tool call: \(toolCallId)\nOptions: \(optionSummary)"
        }

        return "Gemini requested approval to continue a tool action.\nOptions: \(optionSummary)"
    }
}
