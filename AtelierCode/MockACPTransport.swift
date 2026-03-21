//
//  MockACPTransport.swift
//  AtelierCode
//
//  Created by Codex on 3/21/26.
//

import Foundation

@MainActor
final class MockACPTransport: AgentTransport {
    enum Scenario: Sendable {
        case ready
        case activity
    }

    var onReceive: ((Result<Data, any Error>) -> Void)?

    private let scenario: Scenario
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let sessionID = "mock_session_1"

    init(scenario: Scenario) {
        self.scenario = scenario
    }

    func start() throws {}

    func stop() {}

    func send(message: Data) throws {
        let envelope = try decoder.decode(ACPIncomingEnvelope.self, from: message)
        guard let method = envelope.method else { return }

        switch method {
        case ACPMethod.initialize.rawValue:
            try deliverInitializeResponse(requestID: envelope.id?.intValue)
        case ACPMethod.sessionNew.rawValue:
            try deliverNewSessionResponse(requestID: envelope.id?.intValue)
        case ACPMethod.sessionLoad.rawValue:
            try deliverLoadSessionResponse(requestID: envelope.id?.intValue)
        case ACPMethod.sessionPrompt.rawValue:
            try deliverPromptResponse(requestID: envelope.id?.intValue)
        case ACPMethod.sessionCancel.rawValue:
            break
        default:
            break
        }
    }

    private func deliverInitializeResponse(requestID: Int?) throws {
        guard let requestID else { return }

        try deliverJSON([
            "jsonrpc": .string("2.0"),
            "id": .int(requestID),
            "result": .object([
                "protocolVersion": .int(ACPProtocolVersion.current),
                "agentInfo": .object([
                    "name": .string("Mock Gemini"),
                    "version": .string("phase1"),
                ]),
                "agentCapabilities": .object([
                    "loadSession": .bool(true),
                ]),
            ]),
        ])
    }

    private func deliverNewSessionResponse(requestID: Int?) throws {
        guard let requestID else { return }

        try deliverJSON([
            "jsonrpc": .string("2.0"),
            "id": .int(requestID),
            "result": .object([
                "sessionId": .string(sessionID),
            ]),
        ])
    }

    private func deliverLoadSessionResponse(requestID: Int?) throws {
        guard let requestID else { return }

        try deliverJSON([
            "jsonrpc": .string("2.0"),
            "id": .int(requestID),
            "result": .object([:]),
        ])
    }

    private func deliverPromptResponse(requestID: Int?) throws {
        guard let requestID else { return }

        switch scenario {
        case .ready:
            try deliverSessionUpdate([
                "sessionUpdate": .string("agent_message_chunk"),
                "content": .object([
                    "type": .string("text"),
                    "text": .string("This mock session is ready."),
                ]),
            ])
        case .activity:
            try deliverSessionUpdate([
                "sessionUpdate": .string("available_commands_update"),
                "availableCommands": .array([
                    .object([
                        "name": .string("read_file"),
                        "description": .string("Read a workspace file."),
                    ]),
                    .object([
                        "name": .string("run_tests"),
                        "description": .string("Run the test suite."),
                    ]),
                ]),
            ])

            try deliverSessionUpdate([
                "sessionUpdate": .string("agent_thought_chunk"),
                "content": .object([
                    "type": .string("text"),
                    "text": .string("Inspecting the launch shell."),
                ]),
            ])

            try deliverSessionUpdate([
                "sessionUpdate": .string("tool_call_update"),
                "toolCallId": .string("tool_mock_read"),
                "title": .string("Read workspace"),
                "content": .object([
                    "type": .string("text"),
                    "text": .string("Scanning project files."),
                ]),
            ])

            try deliverSessionUpdate([
                "sessionUpdate": .string("agent_message_chunk"),
                "content": .object([
                    "type": .string("text"),
                    "text": .string("The mock activity scenario streamed a deterministic answer."),
                ]),
            ])
        }

        try deliverJSON([
            "jsonrpc": .string("2.0"),
            "id": .int(requestID),
            "result": .object([
                "stopReason": .string("end_turn"),
            ]),
        ])
    }

    private func deliverSessionUpdate(_ update: [String: ACPJSONValue]) throws {
        try deliverJSON([
            "jsonrpc": .string("2.0"),
            "method": .string(ACPMethod.sessionUpdate.rawValue),
            "params": .object([
                "sessionId": .string(sessionID),
                "update": .object(update),
            ]),
        ])
    }

    private func deliverJSON(_ payload: [String: ACPJSONValue]) throws {
        onReceive?(.success(try encoder.encode(payload)))
    }
}
