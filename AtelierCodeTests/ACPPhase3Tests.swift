//
//  ACPPhase3Tests.swift
//  AtelierCodeTests
//
//  Created by Codex on 3/14/26.
//

import Foundation
import Testing
@testable import AtelierCode

@MainActor
struct ACPPhase3Tests {

    @Test func connectCreatesSessionAndTransitionsToReady() async {
        let transport = FakeACPStoreTransport()
        let store = ACPStore(transport: transport, cwd: "/tmp/atelier")
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

            default:
                Issue.record("Unexpected method \(method)")
            }
        }

        await store.connect()

        #expect(transport.startCallCount == 1)
        #expect(sentMethods == ["initialize", "session/new"])
        #expect(store.connectionState == .ready)
        #expect(store.isConnecting == false)
        #expect(store.isSending == false)
        #expect(store.statusText == "Ready")
        #expect(store.isErrorVisible == false)
    }

    @Test func sendMessageAppendsRowsAndStreamsChunksIntoAssistantMessage() async {
        let transport = FakeACPStoreTransport()
        let store = ACPStore(transport: transport, cwd: "/tmp/atelier")

        transport.onSend = { data in
            let envelope = try JSONDecoder().decode(ACPIncomingEnvelope.self, from: data)
            let method = try #require(envelope.method)
            let requestID = try #require(envelope.id)

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
                        "text": "Hello"
                      }
                    }
                  }
                }
                """)

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
                        "text": " back"
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

        await store.sendMessage("Hi Gemini")

        #expect(store.messages.count == 2)
        #expect(store.messages[0].role == .user)
        #expect(store.messages[0].text == "Hi Gemini")
        #expect(store.messages[1].role == .assistant)
        #expect(store.messages[1].text == "Hello back")
        #expect(store.currentAssistantMessageIndex == nil)
        #expect(store.connectionState == .ready)
        #expect(store.isSending == false)
        #expect(store.scrollTargetMessageID == store.messages[1].id)
    }

    @Test func unsupportedNotificationsAreIgnored() async {
        let transport = FakeACPStoreTransport()
        let store = ACPStore(transport: transport, cwd: "/tmp/atelier")

        transport.onSend = { data in
            let envelope = try JSONDecoder().decode(ACPIncomingEnvelope.self, from: data)
            let method = try #require(envelope.method)
            let requestID = try #require(envelope.id)

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

        await store.connect()

        transport.deliver("""
        {
          "jsonrpc": "2.0",
          "method": "session/update",
          "params": {
            "sessionId": "session_123",
            "update": {
              "sessionUpdate": "tool_call",
              "content": {
                "type": "text",
                "text": "ignored"
              }
            }
          }
        }
        """)

        transport.deliver("""
        {
          "jsonrpc": "2.0",
          "method": "custom/notification",
          "params": {
            "value": "ignored"
          }
        }
        """)

        #expect(store.messages.isEmpty)
        #expect(store.connectionState == .ready)
        #expect(store.currentAssistantMessageIndex == nil)
    }

    @Test func transportFailureResetsSendabilityAndSurfacesError() async {
        let transport = FakeACPStoreTransport()
        let store = ACPStore(transport: transport, cwd: "/tmp/atelier")

        transport.onSend = { data in
            let envelope = try JSONDecoder().decode(ACPIncomingEnvelope.self, from: data)
            let method = try #require(envelope.method)
            let requestID = try #require(envelope.id)

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

        await store.connect()
        store.draftPrompt = "Retry me"

        transport.fail(FakeACPStoreTransportError.transportStopped)

        #expect(store.connectionState == .disconnected)
        #expect(store.isSending == false)
        #expect(store.isConnecting == false)
        #expect(store.currentAssistantMessageIndex == nil)
        #expect(store.isErrorVisible == true)
        #expect(store.statusText == FakeACPStoreTransportError.transportStopped.localizedDescription)
        #expect(store.canSendPrompt == false)
    }
}

@MainActor
private final class FakeACPStoreTransport: AgentTransport {
    var onReceive: ((Result<Data, any Error>) -> Void)?
    var onSend: ((Data) throws -> Void)?

    private(set) var startCallCount = 0

    func start() throws {
        startCallCount += 1
    }

    func send(message: Data) throws {
        try onSend?(message)
    }

    func deliver(_ json: String) {
        onReceive?(.success(Data(json.utf8)))
    }

    func fail(_ error: any Error) {
        onReceive?(.failure(error))
    }
}

private enum FakeACPStoreTransportError: LocalizedError {
    case transportStopped

    var errorDescription: String? {
        switch self {
        case .transportStopped:
            return "The fake ACP transport stopped."
        }
    }
}
