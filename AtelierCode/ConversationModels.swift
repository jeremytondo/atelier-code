//
//  ConversationModels.swift
//  AtelierCode
//
//  Created by Codex on 3/14/26.
//

import Foundation

nonisolated enum ConnectionState: String, Sendable {
    case disconnected
    case connecting
    case resuming
    case ready
    case streaming
    case cancelling
}

nonisolated enum ConversationRole: String, Codable, Sendable {
    case user
    case assistant
    case system
}

nonisolated struct ConversationMessage: Identifiable, Equatable, Sendable {
    let id: UUID
    let role: ConversationRole
    var text: String

    init(id: UUID = UUID(), role: ConversationRole, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

nonisolated struct ACPTerminalState: Identifiable, Equatable, Sendable {
    let id: String
    var command: String
    var cwd: String
    var output: String
    var truncated: Bool
    var exitStatus: ACPTerminalExitStatus?
    var isReleased: Bool
}

nonisolated enum ACPWorkspacePermissionScope: String, Codable, CaseIterable, Equatable, Sendable {
    case fileRead
    case terminalCreate
}

nonisolated enum ACPWorkspacePermissionRuleDecision: String, Codable, Equatable, Sendable {
    case allow
    case deny
}

nonisolated enum ACPPermissionPromptSource: String, Equatable, Sendable {
    case agentTool
    case fileRead
    case terminalCreate
    case terminalKill
    case terminalRelease
}

nonisolated enum ACPPermissionPromptActionRole: String, Equatable, Sendable {
    case primary
    case secondary
    case destructive
}

nonisolated enum ACPPermissionPromptActionKind: Equatable, Sendable {
    case selectACPOption(optionId: String)
    case allowOnce
    case allowAlwaysForWorkspace
    case deny
}

nonisolated struct ACPPermissionPromptAction: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let role: ACPPermissionPromptActionRole
    let kind: ACPPermissionPromptActionKind
}

nonisolated struct ACPPermissionPrompt: Identifiable, Equatable, Sendable {
    let id: UUID
    let source: ACPPermissionPromptSource
    let title: String
    let detail: String
    let toolCallId: String?
    let persistenceScope: ACPWorkspacePermissionScope?
    let actions: [ACPPermissionPromptAction]

    init(
        id: UUID = UUID(),
        source: ACPPermissionPromptSource,
        title: String,
        detail: String,
        toolCallId: String? = nil,
        persistenceScope: ACPWorkspacePermissionScope? = nil,
        actions: [ACPPermissionPromptAction]
    ) {
        self.id = id
        self.source = source
        self.title = title
        self.detail = detail
        self.toolCallId = toolCallId
        self.persistenceScope = persistenceScope
        self.actions = actions
    }
}

nonisolated enum ACPMessageActivityKind: String, Equatable, Sendable {
    case thinking
    case tool
    case availableCommands
    case permission
    case terminal
}

nonisolated struct ACPTerminalActivitySnapshot: Equatable, Sendable {
    let terminalId: String
    let command: String
    let cwd: String
    let newOutput: String?
    let fullOutput: String
    let truncated: Bool
    let exitStatus: ACPTerminalExitStatus?
    let isReleased: Bool
}

nonisolated struct ACPMessageActivity: Identifiable, Equatable, Sendable {
    let id: UUID
    let sequence: Int
    let kind: ACPMessageActivityKind
    let title: String
    let detail: String?
    let sessionUpdate: String?
    let toolCallId: String?
    let commands: [ACPAvailableCommand]
    let terminal: ACPTerminalActivitySnapshot?

    init(
        id: UUID = UUID(),
        sequence: Int,
        kind: ACPMessageActivityKind,
        title: String,
        detail: String? = nil,
        sessionUpdate: String? = nil,
        toolCallId: String? = nil,
        commands: [ACPAvailableCommand] = [],
        terminal: ACPTerminalActivitySnapshot? = nil
    ) {
        self.id = id
        self.sequence = sequence
        self.kind = kind
        self.title = title
        self.detail = detail
        self.sessionUpdate = sessionUpdate
        self.toolCallId = toolCallId
        self.commands = commands
        self.terminal = terminal
    }
}

nonisolated struct ACPPermissionDecision: Equatable, Sendable {
    let sessionId: String
    let toolCallId: String?
    let options: [ACPPermissionOption]
    let outcome: ACPRequestPermissionOutcome

    var selectedOption: ACPPermissionOption? {
        guard case .selected(let optionId) = outcome else { return nil }
        return options.first(where: { $0.optionId == optionId })
    }
}
