//
//  ACPStoreTests.swift
//  AtelierCodeTests
//
//  Created by Codex on 3/14/26.
//

import Foundation
import Testing
@testable import AtelierCode

@MainActor
struct ACPStoreTests {

    @Test func connectCreatesSessionAndTransitionsToReady() async {
        let transport = FakeACPStoreTransport()
        let store = ACPStore(transport: transport, cwd: "/tmp/atelier")
        var sentMethods: [String] = []

        transport.onSend = { data in
            let envelope = try JSONDecoder().decode(ACPIncomingEnvelope.self, from: data)
            let method = try #require(envelope.method)
            let requestID = try #require(envelope.id?.intValue)
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
        #expect(store.statusText == "ACP session ready")
        #expect(store.isErrorVisible == false)
    }

    @Test func appWorkingDirectoryAvoidsFilesystemRootFallback() {
        #expect(
            AppWorkingDirectory.resolve(
                currentEnvironment: ["PWD": "/Users/jeremytondo/Projects/AtelierCode"],
                currentDirectoryPath: "/",
                userHomeDirectory: "/Users/jeremytondo"
            ) == "/Users/jeremytondo/Projects/AtelierCode"
        )

        #expect(
            AppWorkingDirectory.resolve(
                currentEnvironment: [:],
                currentDirectoryPath: "/",
                userHomeDirectory: "/Users/jeremytondo"
            ) == "/Users/jeremytondo"
        )
    }

    @Test func sendMessageAppendsRowsAndStreamsChunksIntoAssistantMessage() async {
        let transport = FakeACPStoreTransport()
        let store = ACPStore(transport: transport, cwd: "/tmp/atelier")

        transport.onSend = { data in
            let envelope = try JSONDecoder().decode(ACPIncomingEnvelope.self, from: data)
            let method = try #require(envelope.method)
            let requestID = try #require(envelope.id?.intValue)

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
            let requestID = try #require(envelope.id?.intValue)

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

    @Test func terminalLifecycleUpdatesStoreState() async throws {
        let fileManager = FileManager.default
        let workspaceURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: workspaceURL)
        }

        let transport = FakeACPStoreTransport()
        let store = ACPStore(transport: transport, cwd: workspaceURL.path)
        var outboundResponses: [String: [String: Any]] = [:]

        transport.onSend = { data in
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

            if let method = object["method"] as? String {
                let requestID = try #require(object["id"] as? Int)

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
            } else if let responseID = object["id"] as? String {
                outboundResponses[responseID] = object
            }
        }

        await store.connect()

        transport.deliver("""
        {
          "jsonrpc": "2.0",
          "id": "terminal_create_store",
          "method": "terminal/create",
          "params": {
            "sessionId": "session_123",
            "command": "/bin/sh",
            "args": ["-lc", "printf 'store terminal'"],
            "cwd": "."
          }
        }
        """)

        let created = await waitUntil {
            outboundResponses["terminal_create_store"] != nil
        }
        #expect(created)

        let createResponse = try #require(outboundResponses["terminal_create_store"])
        let result = try #require(createResponse["result"] as? [String: Any])
        let terminalID = try #require(result["terminalId"] as? String)

        let updated = await waitUntil {
            store.terminalStates[terminalID]?.output.contains("store terminal") == true
        }
        #expect(updated)
    }

    @Test func transportFailureResetsSendabilityAndSurfacesError() async {
        let transport = FakeACPStoreTransport()
        let store = ACPStore(transport: transport, cwd: "/tmp/atelier")

        transport.onSend = { data in
            let envelope = try JSONDecoder().decode(ACPIncomingEnvelope.self, from: data)
            let method = try #require(envelope.method)
            let requestID = try #require(envelope.id?.intValue)

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

    @Test func promptFailureStopsTransportAndAllowsReconnect() async {
        let transport = FakeACPStoreTransport()
        let store = ACPStore(transport: transport, cwd: "/tmp/atelier")
        var sessionCounter = 0

        transport.onSend = { data in
            let envelope = try JSONDecoder().decode(ACPIncomingEnvelope.self, from: data)
            let method = try #require(envelope.method)
            let requestID = try #require(envelope.id?.intValue)

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
                sessionCounter += 1
                transport.deliver("""
                {
                  "jsonrpc": "2.0",
                  "id": \(requestID),
                  "result": {
                    "sessionId": "session_\(sessionCounter)"
                  }
                }
                """)

            case ACPMethod.sessionPrompt.rawValue:
                transport.deliver("""
                {
                  "jsonrpc": "2.0",
                  "id": \(requestID),
                  "error": {
                    "code": -32000,
                    "message": "Prompt failed"
                  }
                }
                """)

            default:
                Issue.record("Unexpected method \(method)")
            }
        }

        await store.connect()
        await store.sendMessage("Trigger failure")

        #expect(store.connectionState == .disconnected)
        #expect(store.isSending == false)
        #expect(store.isErrorVisible == true)
        #expect(store.statusText.contains("Prompt failed"))
        #expect(transport.stopCallCount == 1)

        await store.connect()

        #expect(store.connectionState == .ready)
        #expect(store.isConnecting == false)
        #expect(store.isErrorVisible == false)
        #expect(transport.startCallCount == 2)
    }
}

@MainActor
private final class FakeACPStoreTransport: AgentTransport {
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

@MainActor
private func waitUntil(
    timeout: TimeInterval = 2,
    pollInterval: TimeInterval = 0.02,
    condition: @escaping @MainActor () -> Bool
) async -> Bool {
    let timeoutNanoseconds = UInt64(timeout * 1_000_000_000)
    let pollNanoseconds = UInt64(pollInterval * 1_000_000_000)
    var elapsed: UInt64 = 0

    while elapsed <= timeoutNanoseconds {
        if condition() {
            return true
        }

        do {
            try await Task.sleep(nanoseconds: pollNanoseconds)
        } catch {
            return false
        }

        elapsed += pollNanoseconds
    }

    return condition()
}
