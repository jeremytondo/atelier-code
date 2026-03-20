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
    case fsReadTextFile = "fs/read_text_file"
    case fsWriteTextFile = "fs/write_text_file"
    case terminalCreate = "terminal/create"
    case terminalOutput = "terminal/output"
    case terminalWaitForExit = "terminal/wait_for_exit"
    case terminalKill = "terminal/kill"
    case terminalRelease = "terminal/release"
}

nonisolated enum ACPProtocolVersion {
    static let current = 1
    static let supported: Set<Int> = [current]

    static func isSupported(_ version: Int) -> Bool {
        supported.contains(version)
    }
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

nonisolated struct ACPClientError: Encodable, LocalizedError, Sendable {
    let code: Int
    let message: String
    let data: ACPJSONValue?

    init(code: Int, message: String, data: ACPJSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    var errorDescription: String? {
        message
    }
}

nonisolated enum ACPClientErrorCode {
    static let methodNotFound = -32601
    static let invalidParams = -32602
    static let internalError = -32603
    static let resourceNotFound = -32002
    static let permissionDenied = -32003
}

nonisolated enum ACPJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: ACPJSONValue])
    case array([ACPJSONValue])
    case null

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: ACPJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([ACPJSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported ACP JSON value."
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var compactText: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        guard
            let data = try? encoder.encode(self),
            let text = String(data: data, encoding: .utf8)
        else {
            return String(describing: self)
        }

        return text
    }

    var flattenedText: String {
        switch self {
        case .string(let value):
            return value
        case .int(let value):
            return String(value)
        case .double(let value):
            return String(value)
        case .bool(let value):
            return String(value)
        case .object(let value):
            return value
                .sorted { $0.key < $1.key }
                .map { "\($0.key) \($0.value.flattenedText)" }
                .joined(separator: " ")
        case .array(let value):
            return value.map(\.flattenedText).joined(separator: " ")
        case .null:
            return "null"
        }
    }
}

nonisolated struct ACPError: Decodable, LocalizedError, Sendable {
    let code: Int
    let message: String
    let data: ACPJSONValue?

    var errorDescription: String? {
        message
    }

    var contextDescription: String? {
        data?.compactText
    }

    var isAuthenticationRelated: Bool {
        let text = searchableText.lowercased()
        let markers = [
            "authrequired",
            "authenticate",
            "authentication",
            "oauth",
            "login",
            "log in",
            "sign in",
            "credential",
            "reauth",
            "re-auth",
            "token expired",
            "unauthorized",
            "forbidden",
        ]
        return markers.contains(where: text.contains)
    }

    var isModelRelated: Bool {
        let text = searchableText.lowercased()
        let directMarkers = [
            "modelnotfounderror",
            "model not found",
            "unknown model",
            "unsupported model",
            "invalid model",
            "requested entity was not found",
        ]

        if directMarkers.contains(where: text.contains) {
            return true
        }

        return (text.contains("404") || text.contains("not found")) && text.contains("model")
    }

    private var searchableText: String {
        [message, data?.flattenedText]
            .compactMap { $0 }
            .joined(separator: " ")
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

    static let readOnly = ACPFileSystemCapabilities(
        readTextFile: true,
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

// AtelierCode keeps capability advertisement truthful to the behavior it implements.
nonisolated enum ACPInterimCapabilityStrategy: String, CaseIterable, Sendable {
    case workspaceAndTerminalLifecycle

    var clientCapabilities: ACPClientCapabilities {
        switch self {
        case .workspaceAndTerminalLifecycle:
            return ACPClientCapabilities(
                fs: .readOnly,
                terminal: true,
                _meta: nil
            )
        }
    }

    var unimplementedClientMethods: Set<String> {
        switch self {
        case .workspaceAndTerminalLifecycle:
            return [
                ACPMethod.fsWriteTextFile.rawValue,
            ]
        }
    }

    func fallbackErrorMessage(for method: String) -> String? {
        guard unimplementedClientMethods.contains(method) else {
            return nil
        }

        let capabilityArea = method.hasPrefix("fs/") ? "file-system" : "terminal"
        return
            "AtelierCode does not support \(capabilityArea) client ACP method \(method) yet."
    }

    static let atelierCodeCurrent = ACPInterimCapabilityStrategy.workspaceAndTerminalLifecycle
}

nonisolated struct ACPClientCapabilities: Codable, Equatable, Sendable {
    let fs: ACPFileSystemCapabilities?
    let terminal: Bool?
    let _meta: [String: Bool]?

    static let atelierCodeDefaults = ACPInterimCapabilityStrategy.atelierCodeCurrent.clientCapabilities
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

nonisolated struct ACPReadTextFileRequest: Codable, Equatable, Sendable {
    let sessionId: String
    let path: String
    let line: Int?
    let limit: Int?
}

nonisolated struct ACPReadTextFileResponse: Codable, Equatable, Sendable {
    let content: String
}

nonisolated struct ACPEnvironmentVariable: Codable, Equatable, Sendable {
    let name: String
    let value: String
}

nonisolated struct ACPCreateTerminalRequest: Codable, Equatable, Sendable {
    let sessionId: String
    let command: String
    let args: [String]?
    let cwd: String?
    let env: [ACPEnvironmentVariable]?
    let outputByteLimit: Int?
}

nonisolated struct ACPCreateTerminalResponse: Codable, Equatable, Sendable {
    let terminalId: String
}

nonisolated struct ACPTerminalOutputRequest: Codable, Equatable, Sendable {
    let sessionId: String
    let terminalId: String
}

nonisolated struct ACPTerminalExitStatus: Codable, Equatable, Sendable {
    let exitCode: Int?
    let signal: String?
}

nonisolated struct ACPTerminalOutputResponse: Codable, Equatable, Sendable {
    let output: String
    let truncated: Bool
    let exitStatus: ACPTerminalExitStatus?
}

nonisolated struct ACPWaitForTerminalExitRequest: Codable, Equatable, Sendable {
    let sessionId: String
    let terminalId: String
}

nonisolated struct ACPWaitForTerminalExitResponse: Codable, Equatable, Sendable {
    let exitCode: Int?
    let signal: String?
}

nonisolated struct ACPReleaseTerminalRequest: Codable, Equatable, Sendable {
    let sessionId: String
    let terminalId: String
}

nonisolated struct ACPReleaseTerminalResponse: Codable, Equatable, Sendable {}

nonisolated struct ACPKillTerminalRequest: Codable, Equatable, Sendable {
    let sessionId: String
    let terminalId: String
}

nonisolated struct ACPKillTerminalResponse: Codable, Equatable, Sendable {}

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
