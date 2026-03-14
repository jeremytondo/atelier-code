//
//  ACPPhase2Tests.swift
//  AtelierCodeTests
//
//  Created by Codex on 3/14/26.
//

import Foundation
import Testing
@testable import AtelierCode

@MainActor
struct ACPPhase2Tests {

    @Test func initializeRequestEncodesExpectedShape() throws {
        let request = ACPRequest(
            id: 1,
            method: ACPMethod.initialize.rawValue,
            params: ACPInitializeRequestParams(
                protocolVersion: ACPProtocolVersion.current,
                clientCapabilities: .atelierCodeDefaults,
                clientInfo: .atelierCode
            )
        )

        let data = try JSONEncoder().encode(request)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let params = try #require(object["params"] as? [String: Any])
        let clientInfo = try #require(params["clientInfo"] as? [String: Any])
        let capabilities = try #require(params["clientCapabilities"] as? [String: Any])
        let fileSystem = try #require(capabilities["fs"] as? [String: Any])

        #expect(object["method"] as? String == "initialize")
        #expect(params["protocolVersion"] as? Int == 1)
        #expect(clientInfo["name"] as? String == "AtelierCode")
        #expect(clientInfo["version"] as? String == "0.1.0")
        #expect(capabilities["terminal"] as? Bool == false)
        #expect(fileSystem["readTextFile"] as? Bool == false)
        #expect(fileSystem["writeTextFile"] as? Bool == false)
    }

    @Test func sessionNewResponseDecodesSessionID() throws {
        let payload = """
        {
          "jsonrpc": "2.0",
          "id": 2,
          "result": {
            "sessionId": "session_123"
          }
        }
        """

        let response = try JSONDecoder().decode(
            ACPResponse<ACPNewSessionResponse>.self,
            from: Data(payload.utf8)
        )

        #expect(response.id == 2)
        #expect(response.result?.sessionId == "session_123")
    }

    @Test func sessionPromptRequestEncodesExpectedShape() throws {
        let request = ACPRequest(
            id: 7,
            method: ACPMethod.sessionPrompt.rawValue,
            params: ACPPromptRequestParams(
                sessionId: "session_123",
                prompt: [.text("Write a haiku")]
            )
        )

        let data = try JSONEncoder().encode(request)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let params = try #require(object["params"] as? [String: Any])
        let prompt = try #require(params["prompt"] as? [[String: Any]])
        let firstBlock = try #require(prompt.first)

        #expect(object["method"] as? String == "session/prompt")
        #expect(params["sessionId"] as? String == "session_123")
        #expect(firstBlock["type"] as? String == "text")
        #expect(firstBlock["text"] as? String == "Write a haiku")
    }

    @Test func sessionUpdateExtractsAgentMessageChunkText() throws {
        let payload = """
        {
          "jsonrpc": "2.0",
          "method": "session/update",
          "params": {
            "sessionId": "session_123",
            "update": {
              "sessionUpdate": "agent_message_chunk",
              "content": {
                "type": "text",
                "text": "Hello from Gemini"
              }
            }
          }
        }
        """

        let notification = try JSONDecoder().decode(
            ACPNotification<ACPSessionUpdateNotificationParams>.self,
            from: Data(payload.utf8)
        )

        #expect(notification.method == "session/update")
        #expect(notification.params.sessionId == "session_123")
        #expect(notification.params.agentMessageChunkText == "Hello from Gemini")
    }

    @Test func sessionUpdateIgnoresUnsupportedContentBlocks() throws {
        let payload = """
        {
          "jsonrpc": "2.0",
          "method": "session/update",
          "params": {
            "sessionId": "session_123",
            "update": {
              "sessionUpdate": "agent_message_chunk",
              "content": {
                "type": "image",
                "url": "file:///tmp/output.png"
              }
            }
          }
        }
        """

        let notification = try JSONDecoder().decode(
            ACPNotification<ACPSessionUpdateNotificationParams>.self,
            from: Data(payload.utf8)
        )

        #expect(notification.params.sessionId == "session_123")
        #expect(notification.params.agentMessageChunkText == nil)
    }

    @Test func sessionClientRequiresSessionBeforePrompt() async {
        let client = ACPSessionClient(transport: FakeAgentTransport())

        do {
            _ = try await client.sendPrompt("Hello")
            #expect(Bool(false))
        } catch let error as ACPSessionClientError {
            switch error {
            case .sessionNotCreated:
                #expect(Bool(true))
            default:
                Issue.record("Unexpected ACP error: \(error.localizedDescription)")
            }
        } catch {
            #expect(Bool(false))
        }
    }

    @Test func sessionClientRunsInitializeSessionAndPromptFlow() async throws {
        let transport = FakeAgentTransport()
        let client = ACPSessionClient(transport: transport)
        var streamedChunks: [String] = []
        var sentMethods: [String] = []

        client.onAgentMessageChunk = { streamedChunks.append($0) }

        transport.onSend = { data in
            let envelope = try JSONDecoder().decode(ACPIncomingEnvelope.self, from: data)
            let method = try #require(envelope.method)
            let requestID = try #require(envelope.id)
            sentMethods.append(method)

            switch method {
            case ACPMethod.initialize.rawValue:
                transport.deliver("""
                {
                  "jsonrpc": "2.0",
                  "id": \(requestID),
                  "result": {
                    "protocolVersion": 1,
                    "agentInfo": {
                      "name": "Gemini",
                      "version": "0.1.0"
                    }
                  }
                }
                """)

            case ACPMethod.sessionNew.rawValue:
                transport.deliver("""
                {
                  "jsonrpc": "2.0",
                  "id": \(requestID),
                  "result": {
                    "sessionId": "session_123"
                  }
                }
                """)

            case ACPMethod.sessionPrompt.rawValue:
                transport.deliver("""
                {
                  "jsonrpc": "2.0",
                  "method": "session/update",
                  "params": {
                    "sessionId": "session_123",
                    "update": {
                      "sessionUpdate": "agent_message_chunk",
                      "content": {
                        "type": "text",
                        "text": "Streaming reply"
                      }
                    }
                  }
                }
                """)

                transport.deliver("""
                {
                  "jsonrpc": "2.0",
                  "id": \(requestID),
                  "result": {
                    "stopReason": "end_turn"
                  }
                }
                """)

            default:
                Issue.record("Unexpected method \(method)")
            }
        }

        try await client.connect(cwd: "/tmp/atelier")
        let promptResponse = try await client.sendPrompt("Hello, Gemini")

        #expect(transport.startCallCount == 1)
        #expect(sentMethods == ["initialize", "session/new", "session/prompt"])
        #expect(client.negotiatedProtocolVersion == 1)
        #expect(client.sessionID == "session_123")
        #expect(streamedChunks == ["Streaming reply"])
        #expect(promptResponse.stopReason == "end_turn")
    }

    @Test func connectReusesExistingSessionWithoutRestartingTransport() async throws {
        let transport = FakeAgentTransport()
        let client = ACPSessionClient(transport: transport)
        var sentMethods: [String] = []

        transport.onSend = { data in
            let envelope = try JSONDecoder().decode(ACPIncomingEnvelope.self, from: data)
            let method = try #require(envelope.method)
            let requestID = try #require(envelope.id)
            sentMethods.append(method)

            switch method {
            case ACPMethod.initialize.rawValue:
                transport.deliver("""
                {
                  "jsonrpc": "2.0",
                  "id": \(requestID),
                  "result": {
                    "protocolVersion": 1
                  }
                }
                """)

            case ACPMethod.sessionNew.rawValue:
                transport.deliver("""
                {
                  "jsonrpc": "2.0",
                  "id": \(requestID),
                  "result": {
                    "sessionId": "session_123"
                  }
                }
                """)

            default:
                Issue.record("Unexpected method \(method)")
            }
        }

        try await client.connect(cwd: "/tmp/atelier")
        try await client.connect(cwd: "/tmp/atelier")

        #expect(transport.startCallCount == 1)
        #expect(sentMethods == ["initialize", "session/new"])
        #expect(client.sessionID == "session_123")
    }
}

@MainActor
private final class FakeAgentTransport: AgentTransport {
    var onReceive: ((Result<Data, any Error>) -> Void)?
    var onSend: ((Data) throws -> Void)?

    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0

    func start() throws {
        startCallCount += 1
    }

    func stop() {
        stopCallCount += 1
    }

    func send(message: Data) throws {
        try onSend?(message)
    }

    func deliver(_ json: String) {
        onReceive?(.success(Data(json.utf8)))
    }
}
