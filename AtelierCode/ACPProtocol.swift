//
//  ACPProtocol.swift
//  AtelierCode
//
//  Created by Codex on 3/14/26.
//

import Foundation

nonisolated enum ACPMethod: String, Sendable {
    case initialize
    case sessionNew = "session/new"
    case sessionPrompt = "session/prompt"
    case sessionUpdate = "session/update"
}

nonisolated enum ACPProtocolVersion {
    static let current = 1
}

nonisolated struct ACPRequest<Params: Encodable & Sendable>: Encodable, Sendable {
    let jsonrpc = "2.0"
    let id: Int
    let method: String
    let params: Params
}

nonisolated struct ACPNotification<Params: Decodable & Sendable>: Decodable, Sendable {
    let jsonrpc: String?
    let method: String
    let params: Params
}

nonisolated struct ACPResponse<Result: Decodable & Sendable>: Decodable, Sendable {
    let jsonrpc: String?
    let id: Int
    let result: Result?
    let error: ACPError?
}

nonisolated struct ACPError: Decodable, LocalizedError, Sendable {
    let code: Int
    let message: String

    var errorDescription: String? {
        message
    }
}

nonisolated struct ACPIncomingEnvelope: Decodable, Sendable {
    let id: Int?
    let method: String?
}

nonisolated struct ACPImplementationInfo: Codable, Equatable, Sendable {
    let name: String
    let title: String?
    let version: String

    static let atelierCode = ACPImplementationInfo(
        name: "AtelierCode",
        title: "AtelierCode",
        version: "0.1.0"
    )
}

nonisolated struct ACPFileSystemCapabilities: Codable, Equatable, Sendable {
    let readTextFile: Bool?
    let writeTextFile: Bool?

    static let unsupported = ACPFileSystemCapabilities(
        readTextFile: false,
        writeTextFile: false
    )
}

nonisolated struct ACPClientCapabilities: Codable, Equatable, Sendable {
    let fs: ACPFileSystemCapabilities?
    let terminal: Bool?

    static let atelierCodeDefaults = ACPClientCapabilities(
        fs: .unsupported,
        terminal: false
    )
}

nonisolated struct ACPInitializeRequestParams: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let clientCapabilities: ACPClientCapabilities?
    let clientInfo: ACPImplementationInfo?
}

nonisolated struct ACPInitializeResponse: Decodable, Equatable, Sendable {
    let protocolVersion: Int
    let agentInfo: ACPImplementationInfo?
}

nonisolated struct ACPMCPServer: Codable, Equatable, Sendable {}

nonisolated struct ACPNewSessionRequestParams: Codable, Equatable, Sendable {
    let cwd: String
    let mcpServers: [ACPMCPServer]
}

nonisolated struct ACPNewSessionResponse: Decodable, Equatable, Sendable {
    let sessionId: String
}

nonisolated enum ACPContentBlock: Codable, Equatable, Sendable {
    case text(String)
    case unsupported(type: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "text":
            self = .text(try container.decode(String.self, forKey: .text))
        default:
            self = .unsupported(type: type)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .unsupported(let type):
            try container.encode(type, forKey: .type)
        }
    }

    var textValue: String? {
        guard case .text(let text) = self else { return nil }
        return text
    }
}

nonisolated struct ACPPromptRequestParams: Codable, Equatable, Sendable {
    let sessionId: String
    let prompt: [ACPContentBlock]
}

nonisolated struct ACPPromptResponse: Decodable, Equatable, Sendable {
    let stopReason: String
}

nonisolated struct ACPSessionUpdateNotificationParams: Decodable, Equatable, Sendable {
    let sessionId: String
    let update: ACPSessionUpdate

    var agentMessageChunkText: String? {
        update.agentMessageChunkText
    }
}

nonisolated struct ACPSessionUpdate: Decodable, Equatable, Sendable {
    let sessionUpdate: String
    let content: ACPContentBlock?

    var agentMessageChunkText: String? {
        guard sessionUpdate == "agent_message_chunk" else { return nil }
        return content?.textValue
    }
}
