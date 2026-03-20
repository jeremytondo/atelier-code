//
//  ACPSessionClientTests.swift
//  AtelierCodeTests
//
//  Created by Codex on 3/14/26.
//

import Foundation
import Testing
@testable import AtelierCode

@MainActor
struct ACPSessionClientTests {

    @Test func supportedProtocolVersionPolicyIsExplicit() {
        #expect(ACPProtocolVersion.supported == [ACPProtocolVersion.current])
        #expect(ACPProtocolVersion.isSupported(ACPProtocolVersion.current))
        #expect(ACPProtocolVersion.isSupported(99) == false)
    }

    @Test func interimCapabilityStrategyIsExplicitlyGeminiCompatibility() {
        #expect(ACPInterimCapabilityStrategy.atelierCodeCurrent == .geminiCompatibility)
        #expect(
            ACPClientCapabilities.atelierCodeDefaults ==
            ACPInterimCapabilityStrategy.atelierCodeCurrent.clientCapabilities
        )
        #expect(
            ACPInterimCapabilityStrategy.atelierCodeCurrent.compatibilityOnlyClientMethods ==
            [
                "fs/read_text_file",
                "fs/write_text_file",
                "terminal/create",
                "terminal/output",
                "terminal/wait_for_exit",
                "terminal/kill",
                "terminal/release",
            ]
        )
    }

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
        #expect(capabilities["terminal"] as? Bool == true)
        #expect(fileSystem["readTextFile"] as? Bool == true)
        #expect(fileSystem["writeTextFile"] as? Bool == true)

        let meta = try #require(capabilities["_meta"] as? [String: Any])
        #expect(meta["terminal_output"] as? Bool == true)
        #expect(meta["terminal-auth"] as? Bool == true)
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

        #expect(response.id == .int(2))
        #expect(response.result?.sessionId == "session_123")
    }

    @Test func responseErrorDecodesStructuredContext() throws {
        let payload = """
        {
          "jsonrpc": "2.0",
          "id": 7,
          "error": {
            "code": 404,
            "message": "Requested entity was not found",
            "data": {
              "type": "ModelNotFoundError",
              "model": "gemini-2.0-flash",
              "status": 404
            }
          }
        }
        """

        let response = try JSONDecoder().decode(
            ACPResponse<ACPPromptResponse>.self,
            from: Data(payload.utf8)
        )

        let error = try #require(response.error)
        let context = try #require(error.contextDescription)

        #expect(error.code == 404)
        #expect(error.message == "Requested entity was not found")
        #expect(context.contains("ModelNotFoundError"))
        #expect(context.contains("gemini-2.0-flash"))
        #expect(error.isModelRelated)
    }

    @Test func initializeResponseDecodesAuthMethodsAndAgentCapabilities() throws {
        let payload = """
        {
          "jsonrpc": "2.0",
          "id": 1,
          "result": {
            "protocolVersion": 1,
            "authMethods": [
              {
                "id": "oauth-personal",
                "name": "Log in with Google",
                "description": "Use your Google account"
              }
            ],
            "agentCapabilities": {
              "loadSession": true,
              "promptCapabilities": {
                "image": true,
                "audio": false,
                "embeddedContext": true
              },
              "mcp": {
                "http": true,
                "sse": true
              }
            }
          }
        }
        """

        let response = try JSONDecoder().decode(
            ACPResponse<ACPInitializeResponse>.self,
            from: Data(payload.utf8)
        )

        #expect(response.result?.authMethods?.count == 1)
        #expect(response.result?.authMethods?.first?.id == "oauth-personal")
        #expect(response.result?.agentCapabilities?.loadSession == true)
        #expect(response.result?.agentCapabilities?.promptCapabilities?.image == true)
        #expect(response.result?.agentCapabilities?.mcp?.http == true)
    }

    @Test func initializeResponseAcceptsGeminiMCPCapabilitiesFieldAlias() throws {
        let payload = """
        {
          "jsonrpc": "2.0",
          "id": 1,
          "result": {
            "protocolVersion": 1,
            "agentCapabilities": {
              "mcpCapabilities": {
                "http": true,
                "sse": true
              }
            }
          }
        }
        """

        let response = try JSONDecoder().decode(
            ACPResponse<ACPInitializeResponse>.self,
            from: Data(payload.utf8)
        )

        #expect(response.result?.agentCapabilities?.mcp?.http == true)
        #expect(response.result?.agentCapabilities?.mcp?.sse == true)
    }

    @Test func authenticateRequestEncodesExpectedShape() throws {
        let request = ACPRequest(
            id: 2,
            method: ACPMethod.authenticate.rawValue,
            params: ACPAuthenticateRequestParams(methodId: "oauth-personal")
        )

        let data = try JSONEncoder().encode(request)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let params = try #require(object["params"] as? [String: Any])

        #expect(object["method"] as? String == "authenticate")
        #expect(params["methodId"] as? String == "oauth-personal")
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

    @Test func sessionUpdateDecodesAvailableCommandsWithoutFailing() throws {
        let payload = """
        {
          "jsonrpc": "2.0",
          "method": "session/update",
          "params": {
            "sessionId": "session_123",
            "update": {
              "sessionUpdate": "available_commands_update",
              "availableCommands": [
                {
                  "name": "memory",
                  "description": "Manage memory."
                }
              ]
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
        #expect(notification.params.update.availableCommands?.first?.name == "memory")
    }

    @Test func sessionUpdateIgnoresArrayStructuredToolContentWithoutFailing() throws {
        let payload = """
        {
          "jsonrpc": "2.0",
          "method": "session/update",
          "params": {
            "sessionId": "session_123",
            "update": {
              "sessionUpdate": "tool_call_update",
              "content": [
                {
                  "type": "content",
                  "content": {
                    "type": "text",
                    "text": "Finished"
                  }
                }
              ]
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
        #expect(notification.params.update.sessionUpdate == "tool_call_update")
    }

    @Test func requestPermissionOutcomeEncodesSelectedOption() throws {
        let response = ACPClientResponse(
            id: .string("permission_1"),
            result: ACPRequestPermissionResponse(
                outcome: .selected(optionId: "allow_once")
            )
        )

        let data = try JSONEncoder().encode(response)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try #require(object["result"] as? [String: Any])
        let outcome = try #require(result["outcome"] as? [String: Any])

        #expect(object["id"] as? String == "permission_1")
        #expect(outcome["outcome"] as? String == "selected")
        #expect(outcome["optionId"] as? String == "allow_once")
    }

    @Test func sessionClientReturnsExplicitCompatibilityErrorForUnimplementedFileSystemMethod() throws {
        let transport = FakeAgentTransport()
        let client = ACPSessionClient(transport: transport)
        var errorResponse: [String: Any]?

        transport.onSend = { data in
            errorResponse = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        transport.deliver("""
        {
          "jsonrpc": "2.0",
          "id": "fs_1",
          "method": "fs/read_text_file",
          "params": {}
        }
        """)

        let response = try #require(errorResponse)
        let error = try #require(response["error"] as? [String: Any])
        let message = try #require(error["message"] as? String)
        _ = client

        #expect(response["id"] as? String == "fs_1")
        #expect(error["code"] as? Int == -32601)
        #expect(message.contains("Gemini compatibility"))
        #expect(message.contains("fs/read_text_file"))
    }

    @Test func sessionClientReturnsExplicitCompatibilityErrorForUnimplementedTerminalMethod() throws {
        let transport = FakeAgentTransport()
        let client = ACPSessionClient(transport: transport)
        var errorResponse: [String: Any]?

        transport.onSend = { data in
            errorResponse = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        transport.deliver("""
        {
          "jsonrpc": "2.0",
          "id": "terminal_1",
          "method": "terminal/create",
          "params": {}
        }
        """)

        let response = try #require(errorResponse)
        let error = try #require(response["error"] as? [String: Any])
        let message = try #require(error["message"] as? String)
        _ = client

        #expect(response["id"] as? String == "terminal_1")
        #expect(error["code"] as? Int == -32601)
        #expect(message.contains("Gemini compatibility"))
        #expect(message.contains("terminal/create"))
    }

    @Test func sessionClientKeepsGenericErrorForOtherUnsupportedClientMethods() throws {
        let transport = FakeAgentTransport()
        let client = ACPSessionClient(transport: transport)
        var errorResponse: [String: Any]?

        transport.onSend = { data in
            errorResponse = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        transport.deliver("""
        {
          "jsonrpc": "2.0",
          "id": "custom_1",
          "method": "custom/unknown",
          "params": {}
        }
        """)

        let response = try #require(errorResponse)
        let error = try #require(response["error"] as? [String: Any])
        let message = try #require(error["message"] as? String)
        _ = client

        #expect(response["id"] as? String == "custom_1")
        #expect(error["code"] as? Int == -32601)
        #expect(message == "AtelierCode does not support client ACP method custom/unknown.")
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

    @Test func sessionClientTimesOutInitializeRequest() async {
        let transport = FakeAgentTransport()
        let client = ACPSessionClient(transport: transport, requestTimeouts: .testValue)
        var sentMethods: [String] = []

        transport.onSend = { data in
            let envelope = try JSONDecoder().decode(ACPIncomingEnvelope.self, from: data)
            sentMethods.append(try #require(envelope.method))
        }

        do {
            try await client.connect(cwd: "/tmp/atelier")
            Issue.record("Expected initialize to time out.")
        } catch let error as ACPSessionClientError {
            switch error {
            case .requestTimedOut(let method, let timeout):
                #expect(method == ACPMethod.initialize.rawValue)
                #expect(abs(timeout - ACPSessionClientTimeouts.testValue.initialize) < 0.001)
            default:
                Issue.record("Unexpected ACP error: \(error.localizedDescription)")
            }
        } catch {
            Issue.record("Unexpected error: \(error.localizedDescription)")
        }

        #expect(transport.startCallCount == 1)
        #expect(sentMethods == ["initialize"])
        #expect(client.sessionID == nil)
    }

    @Test func sessionClientTimesOutSessionNewRequest() async {
        let transport = FakeAgentTransport()
        let client = ACPSessionClient(transport: transport, requestTimeouts: .testValue)
        var sentMethods: [String] = []

        transport.onSend = { data in
            let envelope = try JSONDecoder().decode(ACPIncomingEnvelope.self, from: data)
            let method = try #require(envelope.method)
            let requestID = try #require(envelope.id?.intValue)
            sentMethods.append(method)

            if method == ACPMethod.initialize.rawValue {
                transport.deliver("""
                {
                  "jsonrpc": "2.0",
                  "id": \(requestID),
                  "result": {
                    "protocolVersion": 1
                  }
                }
                """)
            }
        }

        do {
            try await client.connect(cwd: "/tmp/atelier")
            Issue.record("Expected session/new to time out.")
        } catch let error as ACPSessionClientError {
            switch error {
            case .requestTimedOut(let method, let timeout):
                #expect(method == ACPMethod.sessionNew.rawValue)
                #expect(abs(timeout - ACPSessionClientTimeouts.testValue.sessionNew) < 0.001)
            default:
                Issue.record("Unexpected ACP error: \(error.localizedDescription)")
            }
        } catch {
            Issue.record("Unexpected error: \(error.localizedDescription)")
        }

        #expect(sentMethods == ["initialize", "session/new"])
        #expect(client.negotiatedProtocolVersion == 1)
        #expect(client.sessionID == nil)
    }

    @Test func sessionClientTimesOutPromptRequest() async throws {
        let transport = FakeAgentTransport()
        let client = ACPSessionClient(transport: transport, requestTimeouts: .testValue)
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
                break

            default:
                Issue.record("Unexpected method \(method)")
            }
        }

        try await client.connect(cwd: "/tmp/atelier")

        do {
            _ = try await client.sendPrompt("Hello")
            Issue.record("Expected session/prompt to time out.")
        } catch let error as ACPSessionClientError {
            switch error {
            case .requestTimedOut(let method, let timeout):
                #expect(method == ACPMethod.sessionPrompt.rawValue)
                #expect(abs(timeout - ACPSessionClientTimeouts.testValue.sessionPrompt) < 0.001)
            default:
                Issue.record("Unexpected ACP error: \(error.localizedDescription)")
            }
        } catch {
            Issue.record("Unexpected error: \(error.localizedDescription)")
        }

        #expect(sentMethods == ["initialize", "session/new", "session/prompt"])
        #expect(client.sessionID == "session_123")
    }

    @Test func sessionClientClassifiesAuthenticationFailures() async throws {
        let transport = FakeAgentTransport()
        let client = ACPSessionClient(transport: transport)

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
                  "id": \(requestID),
                  "error": {
                    "code": 401,
                    "message": "AuthRequired: Gemini login expired",
                    "data": {
                      "authMethod": "oauth-personal",
                      "status": "expired"
                    }
                  }
                }
                """)

            default:
                Issue.record("Unexpected method \(method)")
            }
        }

        try await client.connect(cwd: "/tmp/atelier")

        do {
            _ = try await client.sendPrompt("Hello")
            Issue.record("Expected prompt to surface an authentication failure.")
        } catch let error as ACPSessionClientError {
            switch error {
            case .authenticationRequired(let method, let serverError):
                #expect(method == ACPMethod.sessionPrompt.rawValue)
                #expect(serverError.code == 401)
                #expect(serverError.contextDescription?.contains("oauth-personal") == true)
                #expect(error.localizedDescription.contains("Re-authenticate in a terminal"))
            default:
                Issue.record("Unexpected ACP error: \(error.localizedDescription)")
            }
        } catch {
            Issue.record("Unexpected error: \(error.localizedDescription)")
        }
    }

    @Test func sessionClientClassifiesModelFailures() async throws {
        let transport = FakeAgentTransport()
        let client = ACPSessionClient(transport: transport)

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
                  "id": \(requestID),
                  "error": {
                    "code": 404,
                    "message": "Requested entity was not found",
                    "data": {
                      "type": "ModelNotFoundError",
                      "model": "gemini-2.0-flash",
                      "status": 404
                    }
                  }
                }
                """)

            default:
                Issue.record("Unexpected method \(method)")
            }
        }

        try await client.connect(cwd: "/tmp/atelier")

        do {
            _ = try await client.sendPrompt("Hello")
            Issue.record("Expected prompt to surface a model failure.")
        } catch let error as ACPSessionClientError {
            switch error {
            case .modelUnavailable(let method, let serverError):
                #expect(method == ACPMethod.sessionPrompt.rawValue)
                #expect(serverError.code == 404)
                #expect(serverError.contextDescription?.contains("ModelNotFoundError") == true)
                #expect(serverError.contextDescription?.contains("gemini-2.0-flash") == true)
                #expect(error.localizedDescription.contains("configured Gemini model"))
            default:
                Issue.record("Unexpected ACP error: \(error.localizedDescription)")
            }
        } catch {
            Issue.record("Unexpected error: \(error.localizedDescription)")
        }
    }

    @Test func sessionClientHappyPathTranscriptCoversHandshakeStreamingAndPromptResponse() async throws {
        let transport = TranscriptAgentTransport(
            exchanges: [
                ACPTranscriptExchange(
                    expectedMethod: ACPMethod.initialize.rawValue,
                    assertRequest: { request in
                        let params = try TranscriptAgentTransport.dictionaryValue(forKey: "params", in: request)
                        let clientInfo = try TranscriptAgentTransport.dictionaryValue(forKey: "clientInfo", in: params)
                        let clientCapabilities = try TranscriptAgentTransport.dictionaryValue(forKey: "clientCapabilities", in: params)

                        #expect(params["protocolVersion"] as? Int == ACPProtocolVersion.current)
                        #expect(clientInfo["name"] as? String == "AtelierCode")
                        #expect(clientCapabilities["terminal"] as? Bool == true)
                    },
                    responses: { requestID in
                        ["""
                        {
                          "jsonrpc": "2.0",
                          "id": \(requestID),
                          "result": {
                            "protocolVersion": 1,
                            "authMethods": [
                              {
                                "id": "oauth-personal",
                                "name": "Log in with Google"
                              }
                            ],
                            "agentCapabilities": {
                              "loadSession": true,
                              "promptCapabilities": {
                                "image": true
                              }
                            },
                            "agentInfo": {
                              "name": "Gemini",
                              "version": "0.1.0"
                            }
                          }
                        }
                        """]
                    }
                ),
                ACPTranscriptExchange(
                    expectedMethod: ACPMethod.sessionNew.rawValue,
                    assertRequest: { request in
                        let params = try TranscriptAgentTransport.dictionaryValue(forKey: "params", in: request)
                        #expect(params["cwd"] as? String == "/tmp/atelier")
                    },
                    responses: { requestID in
                        ["""
                        {
                          "jsonrpc": "2.0",
                          "id": \(requestID),
                          "result": {
                            "sessionId": "session_123"
                          }
                        }
                        """]
                    }
                ),
                ACPTranscriptExchange(
                    expectedMethod: ACPMethod.sessionPrompt.rawValue,
                    assertRequest: { request in
                        let params = try TranscriptAgentTransport.dictionaryValue(forKey: "params", in: request)
                        let prompt = try TranscriptAgentTransport.arrayValue(forKey: "prompt", in: params)
                        let firstBlock = try #require(prompt.first as? [String: Any])

                        #expect(params["sessionId"] as? String == "session_123")
                        #expect(firstBlock["type"] as? String == "text")
                        #expect(firstBlock["text"] as? String == "Hello, Gemini")
                    },
                    responses: { requestID in
                        [
                            """
                            {
                              "jsonrpc": "2.0",
                              "method": "session/update",
                              "params": {
                                "sessionId": "session_123",
                                "update": {
                                  "sessionUpdate": "agent_message_chunk",
                                  "content": {
                                    "type": "text",
                                    "text": "Streaming"
                                  }
                                }
                              }
                            }
                            """,
                            """
                            {
                              "jsonrpc": "2.0",
                              "method": "session/update",
                              "params": {
                                "sessionId": "session_123",
                                "update": {
                                  "sessionUpdate": "agent_message_chunk",
                                  "content": {
                                    "type": "text",
                                    "text": " reply"
                                  }
                                }
                              }
                            }
                            """,
                            """
                            {
                              "jsonrpc": "2.0",
                              "id": \(requestID),
                              "result": {
                                "stopReason": "end_turn"
                              }
                            }
                            """,
                        ]
                    }
                ),
            ]
        )
        let client = ACPSessionClient(transport: transport)
        var streamedChunks: [String] = []

        client.onAgentMessageChunk = { streamedChunks.append($0) }

        try await client.connect(cwd: "/tmp/atelier")
        let promptResponse = try await client.sendPrompt("Hello, Gemini")

        #expect(transport.startCallCount == 1)
        #expect(transport.sentMethods == ["initialize", "session/new", "session/prompt"])
        #expect(transport.isExhausted)
        #expect(client.negotiatedProtocolVersion == 1)
        #expect(client.authMethods.first?.id == "oauth-personal")
        #expect(client.agentCapabilities?.loadSession == true)
        #expect(client.agentCapabilities?.promptCapabilities?.image == true)
        #expect(client.sessionID == "session_123")
        #expect(streamedChunks == ["Streaming", " reply"])
        #expect(promptResponse.stopReason == "end_turn")
    }

    @Test func sessionClientPromptFailureTranscriptSurfacesServerError() async throws {
        let transport = TranscriptAgentTransport(
            exchanges: [
                ACPTranscriptExchange(
                    expectedMethod: ACPMethod.initialize.rawValue,
                    responses: { requestID in
                        ["""
                        {
                          "jsonrpc": "2.0",
                          "id": \(requestID),
                          "result": {
                            "protocolVersion": 1
                          }
                        }
                        """]
                    }
                ),
                ACPTranscriptExchange(
                    expectedMethod: ACPMethod.sessionNew.rawValue,
                    responses: { requestID in
                        ["""
                        {
                          "jsonrpc": "2.0",
                          "id": \(requestID),
                          "result": {
                            "sessionId": "session_123"
                          }
                        }
                        """]
                    }
                ),
                ACPTranscriptExchange(
                    expectedMethod: ACPMethod.sessionPrompt.rawValue,
                    assertRequest: { request in
                        let params = try TranscriptAgentTransport.dictionaryValue(forKey: "params", in: request)
                        let prompt = try TranscriptAgentTransport.arrayValue(forKey: "prompt", in: params)
                        let firstBlock = try #require(prompt.first as? [String: Any])

                        #expect(params["sessionId"] as? String == "session_123")
                        #expect(firstBlock["text"] as? String == "Trigger failure")
                    },
                    responses: { requestID in
                        ["""
                        {
                          "jsonrpc": "2.0",
                          "id": \(requestID),
                          "error": {
                            "code": -32000,
                            "message": "Prompt failed",
                            "data": {
                              "reason": "upstream_error"
                            }
                          }
                        }
                        """]
                    }
                ),
            ]
        )
        let client = ACPSessionClient(transport: transport)

        try await client.connect(cwd: "/tmp/atelier")

        do {
            _ = try await client.sendPrompt("Trigger failure")
            Issue.record("Expected transcript prompt failure.")
        } catch let error as ACPSessionClientError {
            switch error {
            case .serverError(let method, let serverError):
                #expect(method == ACPMethod.sessionPrompt.rawValue)
                #expect(serverError.code == -32000)
                #expect(serverError.message == "Prompt failed")
                #expect(serverError.contextDescription?.contains("upstream_error") == true)
            default:
                Issue.record("Unexpected ACP error: \(error.localizedDescription)")
            }
        } catch {
            Issue.record("Unexpected error: \(error.localizedDescription)")
        }

        #expect(transport.startCallCount == 1)
        #expect(transport.sentMethods == ["initialize", "session/new", "session/prompt"])
        #expect(transport.isExhausted)
        #expect(client.sessionID == "session_123")
    }

    @Test func sessionClientDefersAuthenticationToAgent() async throws {
        let transport = FakeAgentTransport()
        let client = ACPSessionClient(transport: transport)
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
                    "authMethods": [
                      {
                        "id": "vertex-ai",
                        "name": "Vertex AI"
                      }
                    ]
                  }
                }
                """)

            case ACPMethod.sessionNew.rawValue:
                transport.deliver("""
                {
                  "jsonrpc": "2.0",
                  "id": \(requestID),
                  "result": {
                    "sessionId": "session_456"
                  }
                }
                """)

            default:
                Issue.record("Unexpected method \(method)")
            }
        }

        try await client.connect(cwd: "/tmp/atelier")

        #expect(sentMethods == ["initialize", "session/new"])
        #expect(client.sessionID == "session_456")
    }

    @Test func sessionClientRespondsToPermissionRequestDuringPrompt() async throws {
        let transport = FakeAgentTransport()
        let client = ACPSessionClient(transport: transport)
        var streamedChunks: [String] = []
        var permissionOutcomeOptionID: String?
        var promptRequestID: Int?

        client.onAgentMessageChunk = { streamedChunks.append($0) }

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

                case ACPMethod.sessionPrompt.rawValue:
                    promptRequestID = requestID
                    transport.deliver("""
                    {
                      "jsonrpc": "2.0",
                      "id": "permission_1",
                      "method": "session/request_permission",
                      "params": {
                        "sessionId": "session_123",
                        "options": [
                          {
                            "kind": "allow_once",
                            "name": "Allow once",
                            "optionId": "proceed_once"
                          },
                          {
                            "kind": "reject_once",
                            "name": "Reject once",
                            "optionId": "cancel"
                          }
                        ],
                        "toolCall": {
                          "toolCallId": "tool_123"
                        }
                      }
                    }
                    """)

                default:
                    Issue.record("Unexpected method \(method)")
                }
            } else if let requestID = object["id"] as? String, requestID == "permission_1" {
                let result = try #require(object["result"] as? [String: Any])
                let outcome = try #require(result["outcome"] as? [String: Any])
                permissionOutcomeOptionID = outcome["optionId"] as? String
                let promptRequestID = try #require(promptRequestID)

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
                        "text": "The current directory is /tmp/atelier."
                      }
                    }
                  }
                }
                """)

                transport.deliver("""
                {
                  "jsonrpc": "2.0",
                  "id": \(promptRequestID),
                  "result": {
                    "stopReason": "end_turn"
                  }
                }
                """)
            }
        }

        try await client.connect(cwd: "/tmp/atelier")
        let promptResponse = try await client.sendPrompt("Where are you?")

        #expect(permissionOutcomeOptionID == "proceed_once")
        #expect(streamedChunks == ["The current directory is /tmp/atelier."])
        #expect(promptResponse.stopReason == "end_turn")
    }

    @Test func connectReusesExistingSessionWithoutRestartingTransport() async throws {
        let transport = FakeAgentTransport()
        let client = ACPSessionClient(transport: transport)
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

    @Test func connectRejectsUnsupportedProtocolVersionBeforeCreatingSession() async {
        let transport = FakeAgentTransport()
        let client = ACPSessionClient(transport: transport)
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
                    "protocolVersion": 2
                  }
                }
                """)

            default:
                Issue.record("Unexpected method \(method)")
            }
        }

        do {
            try await client.connect(cwd: "/tmp/atelier")
            Issue.record("Expected connect to reject unsupported ACP protocol version.")
        } catch let error as ACPSessionClientError {
            switch error {
            case .unsupportedProtocolVersion(let received, let supported):
                #expect(received == 2)
                #expect(supported == [1])
            default:
                Issue.record("Unexpected ACP error: \(error.localizedDescription)")
            }
        } catch {
            Issue.record("Unexpected error: \(error.localizedDescription)")
        }

        #expect(transport.startCallCount == 1)
        #expect(sentMethods == ["initialize"])
        #expect(client.negotiatedProtocolVersion == nil)
        #expect(client.sessionID == nil)
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

private struct ACPTranscriptExchange {
    let expectedMethod: String
    let assertRequest: ([String: Any]) throws -> Void
    let responses: (Int) -> [String]

    init(
        expectedMethod: String,
        assertRequest: @escaping ([String: Any]) throws -> Void = { _ in },
        responses: @escaping (Int) -> [String]
    ) {
        self.expectedMethod = expectedMethod
        self.assertRequest = assertRequest
        self.responses = responses
    }
}

@MainActor
private final class TranscriptAgentTransport: AgentTransport {
    var onReceive: ((Result<Data, any Error>) -> Void)?

    private let exchanges: [ACPTranscriptExchange]
    private var nextExchangeIndex = 0

    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var sentMethods: [String] = []

    init(exchanges: [ACPTranscriptExchange]) {
        self.exchanges = exchanges
    }

    var isExhausted: Bool {
        nextExchangeIndex == exchanges.count
    }

    func start() throws {
        startCallCount += 1
    }

    func stop() {
        stopCallCount += 1
    }

    func send(message: Data) throws {
        let request = try Self.object(from: message)
        let method = try Self.stringValue(forKey: "method", in: request)

        guard nextExchangeIndex < exchanges.count else {
            throw TranscriptAgentTransportError.unexpectedExtraRequest(method: method)
        }

        let exchange = exchanges[nextExchangeIndex]
        guard method == exchange.expectedMethod else {
            throw TranscriptAgentTransportError.unexpectedMethod(
                expected: exchange.expectedMethod,
                actual: method,
                index: nextExchangeIndex
            )
        }

        sentMethods.append(method)
        try exchange.assertRequest(request)

        let requestID = try Self.intValue(forKey: "id", in: request)
        nextExchangeIndex += 1

        for response in exchange.responses(requestID) {
            onReceive?(.success(Data(response.utf8)))
        }
    }

    static func dictionaryValue(forKey key: String, in object: [String: Any]) throws -> [String: Any] {
        guard let value = object[key] as? [String: Any] else {
            throw TranscriptAgentTransportError.missingField(key)
        }

        return value
    }

    static func arrayValue(forKey key: String, in object: [String: Any]) throws -> [Any] {
        guard let value = object[key] as? [Any] else {
            throw TranscriptAgentTransportError.missingField(key)
        }

        return value
    }

    private static func object(from data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranscriptAgentTransportError.invalidOutgoingMessage
        }

        return object
    }

    private static func stringValue(forKey key: String, in object: [String: Any]) throws -> String {
        guard let value = object[key] as? String else {
            throw TranscriptAgentTransportError.missingField(key)
        }

        return value
    }

    private static func intValue(forKey key: String, in object: [String: Any]) throws -> Int {
        guard let value = object[key] as? Int else {
            throw TranscriptAgentTransportError.missingField(key)
        }

        return value
    }
}

private enum TranscriptAgentTransportError: LocalizedError {
    case invalidOutgoingMessage
    case missingField(String)
    case unexpectedMethod(expected: String, actual: String, index: Int)
    case unexpectedExtraRequest(method: String)

    var errorDescription: String? {
        switch self {
        case .invalidOutgoingMessage:
            return "The transcript transport could not decode the outgoing ACP request."
        case .missingField(let key):
            return "The transcript transport expected the outgoing ACP request to include \(key)."
        case .unexpectedMethod(let expected, let actual, let index):
            return "The transcript transport expected request \(index + 1) to be \(expected), but received \(actual)."
        case .unexpectedExtraRequest(let method):
            return "The transcript transport received an unexpected extra ACP request for \(method)."
        }
    }
}

private extension ACPSessionClientTimeouts {
    static let testValue = ACPSessionClientTimeouts(
        initialize: 0.05,
        sessionNew: 0.05,
        sessionPrompt: 0.05
    )
}
