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
    case ready
    case streaming
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
