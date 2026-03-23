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

    @Test func missingExecutableFailureProducesRecoveryIssue() async throws {
        let transport = FakeACPStoreTransport()
        transport.onStart = {
            throw GeminiExecutableLocatorError.executableNotFound(
                executableName: "gemini",
                searchedPaths: ["/tmp/missing-gemini"]
            )
        }
        let store = ACPStore(
            transport: transport,
            cwd: "/tmp/atelier",
            geminiSettings: GeminiAppSettings(executableOverridePath: "/tmp/missing-gemini")
        )

        await store.connect()

        let recoveryIssue = try #require(store.recoveryIssue)
        #expect(recoveryIssue.kind == .missingExecutable)
        #expect(recoveryIssue.detail.contains("/tmp/missing-gemini"))
        #expect(store.recoverySetupState?.title == "Gemini executable not found")
    }

    @Test func authenticationFailureProducesRecoveryIssue() async throws {
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
                  "error": {
                    "code": -32000,
                    "message": "Authentication required"
                  }
                }
                """)

            default:
                Issue.record("Unexpected method \(method)")
            }
        }

        await store.connect()

        let recoveryIssue = try #require(store.recoveryIssue)
        #expect(recoveryIssue.kind == .authenticationRequired)
        #expect(recoveryIssue.suggestedCommand == "gemini")
        #expect(store.statusText == "Gemini authentication required")
    }

    @Test func modelUnavailableFailureProducesRecoveryIssue() async throws {
        let transport = FakeACPStoreTransport()
        let store = ACPStore(
            transport: transport,
            cwd: "/tmp/atelier",
            geminiSettings: GeminiAppSettings(defaultModel: "gemini-bad-model")
        )

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
                  "error": {
                    "code": -32000,
                    "message": "Model not found"
                  }
                }
                """)

            default:
                Issue.record("Unexpected method \(method)")
            }
        }

        await store.connect()

        let recoveryIssue = try #require(store.recoveryIssue)
        #expect(recoveryIssue.kind == .modelUnavailable)
        #expect(recoveryIssue.detail.contains("gemini-bad-model"))
        #expect(store.statusText == "Configured Gemini model unavailable")
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

    @Test func sendMessageRetainsRichActivitiesAlongsideAssistantText() async throws {
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
                """)

                transport.deliver("""
                {
                  "jsonrpc": "2.0",
                  "method": "session/update",
                  "params": {
                    "sessionId": "session_123",
                    "update": {
                      "sessionUpdate": "agent_thought_chunk",
                      "content": {
                        "type": "text",
                        "text": "Inspecting the request"
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
                      "sessionUpdate": "tool_call_update",
                      "toolCallId": "tool_123",
                      "title": "Read workspace",
                      "status": "running",
                      "content": {
                        "type": "text",
                        "text": "Scanning project files"
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
                        "text": "Ready."
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

        await store.sendMessage("Do some work")

        let assistantMessageID = try #require(store.messages.last?.id)
        let activities = store.activities(for: assistantMessageID)

        #expect(store.messages.last?.text == "Ready.")
        #expect(activities.count == 3)
        #expect(activities[0].kind == .availableCommands)
        #expect(activities[0].commands.first?.name == "memory")
        #expect(activities[1].kind == .thinking)
        #expect(activities[1].detail == "Inspecting the request")
        #expect(activities[2].kind == .tool)
        #expect(activities[2].toolCallId == "tool_123")
        #expect(activities[2].detail?.contains("Scanning project files") == true)
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

        #expect(await waitUntil(timeout: 5) { store.pendingPermissionRequests.count == 1 })
        let permissionPrompt = try #require(store.pendingPermissionRequests.first)
        let allowOnceAction = try #require(permissionPrompt.actions.first(where: { action in
            if case .allowOnce = action.kind {
                return true
            }
            return false
        }))
        store.resolvePermissionRequest(permissionPrompt, with: allowOnceAction)

        let created = await waitUntil(timeout: 5) {
            outboundResponses["terminal_create_store"] != nil
        }
        #expect(created)

        let createResponse = try #require(outboundResponses["terminal_create_store"])
        let result = try #require(createResponse["result"] as? [String: Any])
        let terminalID = try #require(result["terminalId"] as? String)

        let updated = await waitUntil(timeout: 5) {
            store.terminalStates[terminalID]?.output.contains("store terminal") == true
        }
        #expect(updated)

        let activityAppended = await waitUntil(timeout: 5) {
            let assistantMessageID = store.messages.last?.id
            guard let assistantMessageID else { return false }
            return store.activities(for: assistantMessageID).contains(where: {
                $0.kind == .terminal && $0.terminal?.terminalId == terminalID
            })
        }
        #expect(activityAppended)
        #expect(store.hostActivities.contains(where: { $0.kind == .permission }))
    }

    @Test func cancelPromptSendsCancelAndLeavesSessionUsable() async {
        let transport = FakeACPStoreTransport()
        let store = ACPStore(transport: transport, cwd: "/tmp/atelier")
        var sentMethods: [String] = []
        var promptRequestID: Int?

        transport.onSend = { data in
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let method = try #require(object["method"] as? String)
            sentMethods.append(method)

            switch method {
            case ACPMethod.initialize.rawValue:
                let requestID = try #require(object["id"] as? Int)
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
                let requestID = try #require(object["id"] as? Int)
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
                promptRequestID = try #require(object["id"] as? Int)

            case ACPMethod.sessionCancel.rawValue:
                let requestID = try #require(promptRequestID)
                transport.deliver("""
                {
                  "jsonrpc": "2.0",
                  "id": \(requestID),
                  "result": {
                    "stopReason": "cancelled"
                  }
                }
                """)

            default:
                Issue.record("Unexpected method \(method)")
            }
        }

        let sendTask = Task {
            await store.sendMessage("Please stop")
        }

        #expect(await waitUntil { promptRequestID != nil })
        await store.cancelPrompt()

        #expect(store.connectionState == .cancelling)
        await sendTask.value

        #expect(sentMethods == ["initialize", "session/new", "session/prompt", "session/cancel"])
        #expect(store.connectionState == .ready)
        #expect(store.isSending == false)
        #expect(store.isErrorVisible == false)
        #expect(store.messages.last?.text == "Generation cancelled.")
    }

    @Test func fileReadPermissionRuleCanBeSavedForWorkspace() async throws {
        let fileManager = FileManager.default
        let workspaceURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = workspaceURL.appendingPathComponent("notes.txt")
        try fileManager.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        try Data("hello\nworkspace".utf8).write(to: fileURL)
        defer {
            try? fileManager.removeItem(at: workspaceURL)
        }

        let transport = FakeACPStoreTransport()
        let permissionPersistence = InMemoryWorkspacePermissionPersistence()
        let store = ACPStore(
            transport: transport,
            cwd: workspaceURL.path,
            permissionPersistence: permissionPersistence
        )
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
          "id": "fs_1",
          "method": "fs/read_text_file",
          "params": {
            "sessionId": "session_123",
            "path": "notes.txt"
          }
        }
        """)

        #expect(await waitUntil(timeout: 5) { store.pendingPermissionRequests.count == 1 })
        let prompt = try #require(store.pendingPermissionRequests.first)
        let allowWorkspaceAction = try #require(prompt.actions.first(where: { action in
            if case .allowAlwaysForWorkspace = action.kind {
                return true
            }
            return false
        }))
        store.resolvePermissionRequest(prompt, with: allowWorkspaceAction)

        #expect(await waitUntil(timeout: 5) { outboundResponses["fs_1"] != nil })
        let firstResponse = try #require(outboundResponses["fs_1"])
        let firstResult = try #require(firstResponse["result"] as? [String: Any])
        #expect(firstResult["content"] as? String == "hello\nworkspace")
        #expect(permissionPersistence.storedDecisions[workspaceURL.path]?[.fileRead] == .allow)

        transport.deliver("""
        {
          "jsonrpc": "2.0",
          "id": "fs_2",
          "method": "fs/read_text_file",
          "params": {
            "sessionId": "session_123",
            "path": "notes.txt"
          }
        }
        """)

        #expect(await waitUntil(timeout: 5) { outboundResponses["fs_2"] != nil })
        let secondResponse = try #require(outboundResponses["fs_2"])
        let secondResult = try #require(secondResponse["result"] as? [String: Any])
        #expect(secondResult["content"] as? String == "hello\nworkspace")
        #expect(store.pendingPermissionRequests.isEmpty)
    }

    @Test func connectResumesPersistedSessionWhenAvailable() async {
        let transport = FakeACPStoreTransport()
        let sessionPersistence = InMemoryWorkspaceSessionPersistence(
            storedSessions: ["/tmp/atelier": "session_resume"]
        )
        let store = ACPStore(
            transport: transport,
            cwd: "/tmp/atelier",
            sessionPersistence: sessionPersistence
        )
        var sentMethods: [String] = []

        transport.onSend = { data in
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let method = try #require(object["method"] as? String)
            sentMethods.append(method)

            switch method {
            case ACPMethod.initialize.rawValue:
                let requestID = try #require(object["id"] as? Int)
                transport.deliver("""
                {
                  "jsonrpc": "2.0",
                  "id": \(requestID),
                  "result": {
                    "protocolVersion": 1,
                    "agentCapabilities": {
                      "loadSession": true
                    }
                  }
                }
                """)

            case ACPMethod.sessionLoad.rawValue:
                let params = try #require(object["params"] as? [String: Any])
                #expect(params["sessionId"] as? String == "session_resume")
                let requestID = try #require(object["id"] as? Int)
                transport.deliver("""
                {
                  "jsonrpc": "2.0",
                  "id": \(requestID),
                  "result": {}
                }
                """)

            default:
                Issue.record("Unexpected method \(method)")
            }
        }

        await store.connect()

        #expect(sentMethods == ["initialize", "session/load"])
        #expect(store.connectionState == .ready)
        #expect(store.isErrorVisible == false)
        #expect(sessionPersistence.storedSessions["/tmp/atelier"] == "session_resume")
    }

    @Test func connectFallsBackToNewSessionAfterResumeFailure() async {
        let transport = FakeACPStoreTransport()
        let sessionPersistence = InMemoryWorkspaceSessionPersistence(
            storedSessions: ["/tmp/atelier": "session_stale"]
        )
        let store = ACPStore(
            transport: transport,
            cwd: "/tmp/atelier",
            sessionPersistence: sessionPersistence
        )
        var sentMethods: [String] = []

        transport.onSend = { data in
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let method = try #require(object["method"] as? String)
            sentMethods.append(method)

            switch method {
            case ACPMethod.initialize.rawValue:
                let requestID = try #require(object["id"] as? Int)
                transport.deliver("""
                {
                  "jsonrpc": "2.0",
                  "id": \(requestID),
                  "result": {
                    "protocolVersion": 1,
                    "agentCapabilities": {
                      "loadSession": true
                    }
                  }
                }
                """)

            case ACPMethod.sessionLoad.rawValue:
                let requestID = try #require(object["id"] as? Int)
                transport.deliver("""
                {
                  "jsonrpc": "2.0",
                  "id": \(requestID),
                  "error": {
                    "code": -32000,
                    "message": "Session expired"
                  }
                }
                """)

            case ACPMethod.sessionNew.rawValue:
                let requestID = try #require(object["id"] as? Int)
                transport.deliver("""
                {
                  "jsonrpc": "2.0",
                  "id": \(requestID),
                  "result": {
                    "sessionId": "session_fresh"
                  }
                }
                """)

            default:
                Issue.record("Unexpected method \(method)")
            }
        }

        await store.connect()

        #expect(sentMethods == ["initialize", "session/load", "session/new"])
        #expect(store.connectionState == .ready)
        #expect(sessionPersistence.storedSessions["/tmp/atelier"] == "session_fresh")
    }

    @Test func resumeTransportFailureResetsStoreCleanly() async {
        let transport = FakeACPStoreTransport()
        let sessionPersistence = InMemoryWorkspaceSessionPersistence(
            storedSessions: ["/tmp/atelier": "session_resume"]
        )
        let failurePersistence = InMemoryWorkspaceFailurePersistence()
        let store = ACPStore(
            transport: transport,
            cwd: "/tmp/atelier",
            sessionPersistence: sessionPersistence,
            failurePersistence: failurePersistence
        )

        transport.onSend = { data in
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let method = try #require(object["method"] as? String)

            switch method {
            case ACPMethod.initialize.rawValue:
                let requestID = try #require(object["id"] as? Int)
                transport.deliver("""
                {
                  "jsonrpc": "2.0",
                  "id": \(requestID),
                  "result": {
                    "protocolVersion": 1,
                    "agentCapabilities": {
                      "loadSession": true
                    }
                  }
                }
                """)

            case ACPMethod.sessionLoad.rawValue:
                transport.fail(FakeACPStoreTransportError.transportStopped)

            default:
                Issue.record("Unexpected method \(method)")
            }
        }

        await store.connect()

        #expect(store.connectionState == .disconnected)
        #expect(store.isConnecting == false)
        #expect(store.isSending == false)
        #expect(store.isErrorVisible == true)
        #expect(store.statusText == "Gemini connection failed")
        #expect(store.lastErrorDescription == FakeACPStoreTransportError.transportStopped.localizedDescription)
        #expect(store.recoveryIssue?.kind == .transportFailure)
        #expect(store.latestFailureSnapshot?.workspacePath == "/tmp/atelier")
        #expect(failurePersistence.storedSnapshots["/tmp/atelier"]?.title == "Gemini connection failed")
    }

    @Test func transportFailureResetsSendabilityAndSurfacesError() async {
        let transport = FakeACPStoreTransport()
        let failurePersistence = InMemoryWorkspaceFailurePersistence()
        let store = ACPStore(
            transport: transport,
            cwd: "/tmp/atelier",
            failurePersistence: failurePersistence
        )

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
        #expect(store.statusText == "Gemini connection failed")
        #expect(store.lastErrorDescription == FakeACPStoreTransportError.transportStopped.localizedDescription)
        #expect(store.canSendPrompt == false)
        #expect(store.recoveryIssue?.kind == .transportFailure)
        #expect(store.latestFailureSnapshot?.underlyingError == FakeACPStoreTransportError.transportStopped.localizedDescription)
        #expect(failurePersistence.storedSnapshots["/tmp/atelier"]?.underlyingError == FakeACPStoreTransportError.transportStopped.localizedDescription)
    }

    @Test func transportFailurePreservesTerminalEvidenceAndRecentActivity() async throws {
        let transport = FakeACPStoreTransport()
        let failurePersistence = InMemoryWorkspaceFailurePersistence()
        let store = ACPStore(
            transport: transport,
            cwd: "/tmp/atelier",
            failurePersistence: failurePersistence
        )

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
        store.hostActivities = [
            ACPMessageActivity(
                sequence: 1,
                kind: .tool,
                title: "Tool: Search workspace",
                detail: "Scanning the repo before the transport stopped."
            )
        ]
        store.terminalStates = [
            "terminal_1": ACPTerminalState(
                id: "terminal_1",
                command: "rg ACPStore",
                cwd: "/tmp/atelier",
                output: "ACPStore.swift",
                truncated: false,
                exitStatus: nil,
                isReleased: false
            )
        ]

        transport.fail(FakeACPStoreTransportError.transportStopped)

        #expect(store.terminalStates["terminal_1"]?.command == "rg ACPStore")
        #expect(store.hostActivities.count == 1)

        let snapshot = try #require(store.latestFailureSnapshot)
        #expect(snapshot.lastTerminalCommand == "rg ACPStore")
        #expect(snapshot.recentActivities.first?.title == "Tool: Search workspace")
        #expect(snapshot.recentTerminals.first?.command == "rg ACPStore")
        #expect(failurePersistence.storedSnapshots["/tmp/atelier"] == snapshot)
    }

    @Test func recoverableResumeFailurePersistsFailureDetailsWhileConnectingFreshSession() async throws {
        let transport = FakeACPStoreTransport()
        let sessionPersistence = InMemoryWorkspaceSessionPersistence(
            storedSessions: ["/tmp/atelier": "session_resume"]
        )
        let failurePersistence = InMemoryWorkspaceFailurePersistence()
        let store = ACPStore(
            transport: transport,
            cwd: "/tmp/atelier",
            sessionPersistence: sessionPersistence,
            failurePersistence: failurePersistence
        )

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
                    "protocolVersion": 1,
                    "agentCapabilities": {
                      "loadSession": true
                    }
                  }
                }
                """)

            case ACPMethod.sessionLoad.rawValue:
                transport.deliver("""
                {
                  "jsonrpc": "2.0",
                  "id": \(requestID),
                  "error": {
                    "code": -32000,
                    "message": "Session is no longer available"
                  }
                }
                """)

            case ACPMethod.sessionNew.rawValue:
                transport.deliver("""
                {
                  "jsonrpc": "2.0",
                  "id": \(requestID),
                  "result": {
                    "sessionId": "session_fresh"
                  }
                }
                """)

            default:
                Issue.record("Unexpected method \(method)")
            }
        }

        await store.connect()

        #expect(store.connectionState == .ready)
        #expect(store.recoveryIssue == nil)
        #expect(store.latestFailureSnapshot?.recoveryKind == .sessionResumeFailure)
        #expect(store.latestFailureSnapshot?.lastRequestMethod == ACPMethod.sessionLoad.rawValue)
        #expect(store.hostActivities.last?.title == "Started a fresh ACP session")
        #expect(failurePersistence.storedSnapshots["/tmp/atelier"]?.recoveryKind == .sessionResumeFailure)
    }

    @Test func deadTransportFailureProducesPreciseRecoveryIssue() async {
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
                throw ACPSessionClientError.deadTransport(
                    method: ACPMethod.sessionPrompt.rawValue,
                    requestID: requestID
                )

            default:
                Issue.record("Unexpected method \(method)")
            }
        }

        await store.sendMessage("Trigger dead transport")

        #expect(store.recoveryIssue?.kind == .deadTransportWhileSending)
        #expect(store.statusText == "Gemini transport was already gone")
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

        let capturedSnapshot = store.latestFailureSnapshot

        #expect(store.connectionState == .disconnected)
        #expect(store.isSending == false)
        #expect(store.isErrorVisible == true)
        #expect(store.statusText == "Gemini connection failed")
        #expect(store.lastErrorDescription?.contains("Prompt failed") == true)
        #expect(store.recoveryIssue?.detail.contains("Prompt failed") == true)
        #expect(transport.stopCallCount == 1)

        await store.connect()

        #expect(store.connectionState == .ready)
        #expect(store.isConnecting == false)
        #expect(store.isErrorVisible == false)
        #expect(transport.startCallCount == 2)
        #expect(store.latestFailureSnapshot == capturedSnapshot)
    }

    @Test func teardownClearsTransientStateAndStopsTransport() async {
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
        store.messages = [ConversationMessage(role: .assistant, text: "Temporary transcript")]
        store.activitiesByMessageID = [UUID(): []]
        store.hostActivities = [
            ACPMessageActivity(
                sequence: 1,
                kind: .permission,
                title: "Permission granted",
                detail: "Temporary permission"
            )
        ]
        store.terminalStates = [
            "terminal_1": ACPTerminalState(
                id: "terminal_1",
                command: "pwd",
                cwd: "/tmp/atelier",
                output: "/tmp/atelier",
                truncated: false,
                exitStatus: nil,
                isReleased: false
            )
        ]
        store.pendingPermissionRequests = [
            ACPPermissionPrompt(
                source: .fileRead,
                title: "Read workspace file",
                detail: "/tmp/atelier/file.txt",
                persistenceScope: .fileRead,
                actions: [
                    ACPPermissionPromptAction(
                        id: "allow_once",
                        title: "Allow once",
                        role: .primary,
                        kind: .allowOnce
                    )
                ]
            )
        ]
        store.draftPrompt = "Temporary draft"
        store.lastErrorDescription = "Temporary error"
        store.currentAssistantMessageIndex = 0
        store.scrollTargetMessageID = UUID()

        store.teardown()

        #expect(store.connectionState == .disconnected)
        #expect(store.messages.isEmpty)
        #expect(store.activitiesByMessageID.isEmpty)
        #expect(store.hostActivities.isEmpty)
        #expect(store.terminalStates.isEmpty)
        #expect(store.pendingPermissionRequests.isEmpty)
        #expect(store.draftPrompt.isEmpty)
        #expect(store.isConnecting == false)
        #expect(store.isSending == false)
        #expect(store.lastErrorDescription == nil)
        #expect(store.currentAssistantMessageIndex == nil)
        #expect(store.scrollTargetMessageID == nil)
        #expect(transport.stopCallCount == 1)
    }
}

@MainActor
private final class FakeACPStoreTransport: AgentTransport {
    var onReceive: ((Result<Data, any Error>) -> Void)?
    var onStart: (() throws -> Void)?
    var onSend: ((Data) throws -> Void)?

    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0

    func start() throws {
        startCallCount += 1
        try onStart?()
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
private final class InMemoryWorkspaceSessionPersistence: ACPWorkspaceSessionPersisting {
    var storedSessions: [String: String]

    init(storedSessions: [String: String] = [:]) {
        self.storedSessions = storedSessions
    }

    func sessionID(for workspaceRoot: String) -> String? {
        storedSessions[workspaceRoot]
    }

    func save(sessionID: String, for workspaceRoot: String) {
        storedSessions[workspaceRoot] = sessionID
    }

    func removeSession(for workspaceRoot: String) {
        storedSessions.removeValue(forKey: workspaceRoot)
    }
}

@MainActor
private final class InMemoryWorkspacePermissionPersistence: ACPWorkspacePermissionPersisting {
    var storedDecisions: [String: [ACPWorkspacePermissionScope: ACPWorkspacePermissionRuleDecision]] = [:]

    func decision(
        for workspaceRoot: String,
        scope: ACPWorkspacePermissionScope
    ) -> ACPWorkspacePermissionRuleDecision? {
        storedDecisions[workspaceRoot]?[scope]
    }

    func save(
        decision: ACPWorkspacePermissionRuleDecision,
        for workspaceRoot: String,
        scope: ACPWorkspacePermissionScope
    ) {
        var workspaceDecisions = storedDecisions[workspaceRoot] ?? [:]
        workspaceDecisions[scope] = decision
        storedDecisions[workspaceRoot] = workspaceDecisions
    }

    func removeDecision(for workspaceRoot: String, scope: ACPWorkspacePermissionScope) {
        storedDecisions[workspaceRoot]?.removeValue(forKey: scope)
        if storedDecisions[workspaceRoot]?.isEmpty == true {
            storedDecisions.removeValue(forKey: workspaceRoot)
        }
    }

    func removeAllDecisions(for workspaceRoot: String) {
        storedDecisions.removeValue(forKey: workspaceRoot)
    }
}

@MainActor
private final class InMemoryWorkspaceFailurePersistence: ACPWorkspaceFailurePersisting {
    var storedSnapshots: [String: ACPTransportFailureSnapshot] = [:]

    func snapshot(for workspaceRoot: String) -> ACPTransportFailureSnapshot? {
        storedSnapshots[workspaceRoot]
    }

    func save(snapshot: ACPTransportFailureSnapshot, for workspaceRoot: String) {
        storedSnapshots[workspaceRoot] = snapshot
    }

    func removeSnapshot(for workspaceRoot: String) {
        storedSnapshots.removeValue(forKey: workspaceRoot)
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
