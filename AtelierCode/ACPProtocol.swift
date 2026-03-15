//
//  ACPProtocol.swift
//  AtelierCode
//
//  Created by Codex on 3/14/26.
//

import Foundation

nonisolated enum ACPMethod: String, Sendable {
    case authenticate
    case initialize
    case sessionNew = "session/new"
    case sessionLoad = "session/load"
    case sessionPrompt = "session/prompt"
    case sessionCancel = "session/cancel"
    case sessionRequestPermission = "session/request_permission"
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

nonisolated enum ACPRequestID: Codable, Equatable, Sendable {
    case int(Int)
    case string(String)
    case null

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let intValue = try? container.decode(Int.self) {
            self = .int(intValue)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .int(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var intValue: Int? {
        guard case .int(let value) = self else { return nil }
        return value
    }
}

nonisolated struct ACPNotification<Params: Decodable & Sendable>: Decodable, Sendable {
    let jsonrpc: String?
    let method: String
    let params: Params
}

nonisolated struct ACPInboundRequest<Params: Decodable & Sendable>: Decodable, Sendable {
    let jsonrpc: String?
    let id: ACPRequestID?
    let method: String
    let params: Params
}

nonisolated struct ACPResponse<Result: Decodable & Sendable>: Decodable, Sendable {
    let jsonrpc: String?
    let id: ACPRequestID?
    let result: Result?
    let error: ACPError?
}

nonisolated struct ACPClientResponse<Result: Encodable & Sendable>: Encodable, Sendable {
    let jsonrpc = "2.0"
    let id: ACPRequestID?
    let result: Result
}

nonisolated struct ACPClientErrorResponse: Encodable, Sendable {
    let jsonrpc = "2.0"
    let id: ACPRequestID?
    let error: ACPClientError
}

nonisolated struct ACPClientError: Encodable, Sendable {
    let code: Int
    let message: String
}

nonisolated struct ACPError: Decodable, LocalizedError, Sendable {
    let code: Int
    let message: String

    var errorDescription: String? {
        message
    }
}

nonisolated struct ACPIncomingEnvelope: Decodable, Sendable {
    let id: ACPRequestID?
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

nonisolated struct ACPAuthMethod: Decodable, Equatable, Sendable {
    let id: String
    let name: String
    let description: String?
}

nonisolated struct ACPFileSystemCapabilities: Codable, Equatable, Sendable {
    let readTextFile: Bool?
    let writeTextFile: Bool?

    static let unsupported = ACPFileSystemCapabilities(
        readTextFile: false,
        writeTextFile: false
    )

    static let supported = ACPFileSystemCapabilities(
        readTextFile: true,
        writeTextFile: true
    )
}

nonisolated struct ACPPromptCapabilities: Decodable, Equatable, Sendable {
    let image: Bool?
    let audio: Bool?
    let embeddedContext: Bool?
}

nonisolated struct ACPMCPCapabilities: Decodable, Equatable, Sendable {
    let http: Bool?
    let sse: Bool?
}

nonisolated struct ACPAgentCapabilities: Decodable, Equatable, Sendable {
    let loadSession: Bool?
    let promptCapabilities: ACPPromptCapabilities?
    let mcp: ACPMCPCapabilities?

    private enum CodingKeys: String, CodingKey {
        case loadSession
        case promptCapabilities
        case mcp
        case mcpCapabilities
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        loadSession = try container.decodeIfPresent(Bool.self, forKey: .loadSession)
        promptCapabilities = try container.decodeIfPresent(
            ACPPromptCapabilities.self,
            forKey: .promptCapabilities
        )
        mcp =
            (try? container.decodeIfPresent(ACPMCPCapabilities.self, forKey: .mcp)) ??
            (try? container.decodeIfPresent(ACPMCPCapabilities.self, forKey: .mcpCapabilities))
    }
}

nonisolated struct ACPClientCapabilities: Codable, Equatable, Sendable {
    let fs: ACPFileSystemCapabilities?
    let terminal: Bool?
    let _meta: [String: Bool]?

    static let atelierCodeDefaults = ACPClientCapabilities(
        fs: ACPFileSystemCapabilities(readTextFile: true, writeTextFile: true),
        terminal: true,
        _meta: ["terminal_output": true, "terminal-auth": true]
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
    let agentCapabilities: ACPAgentCapabilities?
    let authMethods: [ACPAuthMethod]?
}

nonisolated struct ACPAuthenticateRequestParams: Codable, Equatable, Sendable {
    let methodId: String
}

nonisolated struct ACPAuthenticateResponse: Decodable, Equatable, Sendable {}

nonisolated struct ACPMCPServer: Codable, Equatable, Sendable {}

nonisolated struct ACPNewSessionRequestParams: Codable, Equatable, Sendable {
    let cwd: String
    let mcpServers: [ACPMCPServer]
}

nonisolated struct ACPNewSessionResponse: Decodable, Equatable, Sendable {
    let sessionId: String
}

nonisolated struct ACPCancelPromptRequestParams: Codable, Equatable, Sendable {
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

nonisolated struct ACPPermissionOption: Decodable, Equatable, Sendable {
    let kind: String
    let name: String
    let optionId: String
}

nonisolated struct ACPToolCallReference: Decodable, Equatable, Sendable {
    let toolCallId: String?
}

nonisolated struct ACPRequestPermissionRequest: Decodable, Equatable, Sendable {
    let options: [ACPPermissionOption]
    let sessionId: String
    let toolCall: ACPToolCallReference?
}

nonisolated struct ACPRequestPermissionResponse: Encodable, Equatable, Sendable {
    let outcome: ACPRequestPermissionOutcome
}

nonisolated enum ACPRequestPermissionOutcome: Encodable, Equatable, Sendable {
    case cancelled
    case selected(optionId: String)

    private enum CodingKeys: String, CodingKey {
        case outcome
        case optionId
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .cancelled:
            try container.encode("cancelled", forKey: .outcome)
        case .selected(let optionId):
            try container.encode("selected", forKey: .outcome)
            try container.encode(optionId, forKey: .optionId)
        }
    }
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
    let availableCommands: [ACPAvailableCommand]?

    private enum CodingKeys: String, CodingKey {
        case sessionUpdate
        case content
        case availableCommands
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionUpdate = try container.decode(String.self, forKey: .sessionUpdate)
        content = try? container.decode(ACPContentBlock.self, forKey: .content)
        availableCommands = try? container.decode([ACPAvailableCommand].self, forKey: .availableCommands)
    }

    var agentMessageChunkText: String? {
        guard sessionUpdate == "agent_message_chunk" else { return nil }
        return content?.textValue
    }
}

nonisolated struct ACPAvailableCommand: Decodable, Equatable, Sendable {
    let name: String
    let description: String?
}
