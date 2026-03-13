//
//  AtelierCodeTests.swift
//  AtelierCodeTests
//
//  Created by Jeremy Margaritondo on 3/12/26.
//

import Foundation
import Testing
@testable import AtelierCode

struct AtelierCodeTests {

    @Test func threadStartResponseDecodesThreadID() throws {
        let payload = """
        {
          "jsonrpc": "2.0",
          "id": 2,
          "result": {
            "thread": {
              "id": "thread_123"
            }
          }
        }
        """

        let response = try JSONDecoder().decode(
            JSONRPCResponse<ThreadStartResult>.self,
            from: Data(payload.utf8)
        )

        #expect(response.id == 2)
        #expect(response.result?.thread.id == "thread_123")
    }

    @Test func agentMessageDeltaNotificationDecodesText() throws {
        let payload = """
        {
          "jsonrpc": "2.0",
          "method": "item/agentMessage/delta",
          "params": {
            "threadId": "thread_123",
            "turnId": "turn_456",
            "itemId": "item_789",
            "delta": "Hello from Codex"
          }
        }
        """

        let notification = try JSONDecoder().decode(
            JSONRPCNotification<AgentMessageDeltaParams>.self,
            from: Data(payload.utf8)
        )

        #expect(notification.method == "item/agentMessage/delta")
        #expect(notification.params.threadId == "thread_123")
        #expect(notification.params.delta == "Hello from Codex")
    }

    @Test func turnStartRequestEncodesExpectedInputShape() throws {
        let request = JSONRPCRequest(
            id: 7,
            method: "turn/start",
            params: TurnStartParams(
                threadId: "thread_123",
                input: [TurnInputItem(text: "Write a haiku")]
            )
        )

        let data = try JSONEncoder().encode(request)
        let jsonObject = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let params = try #require(jsonObject["params"] as? [String: Any])
        let input = try #require(params["input"] as? [[String: Any]])
        let firstItem = try #require(input.first)

        #expect(jsonObject["method"] as? String == "turn/start")
        #expect(params["threadId"] as? String == "thread_123")
        #expect(firstItem["type"] as? String == "text")
        #expect(firstItem["text"] as? String == "Write a haiku")
    }

}
