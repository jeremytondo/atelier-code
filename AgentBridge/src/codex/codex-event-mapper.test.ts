import { describe, expect, test } from "bun:test";

import { DefaultCodexEventMapper } from "./codex-event-mapper";

describe("DefaultCodexEventMapper", () => {
  test("maps codex notifications into bridge events", () => {
    const mapper = new DefaultCodexEventMapper();

    const turnStarted = mapper.mapNotification({
      method: "turn/started",
      params: {
        threadId: "thread-1",
        turn: {
          id: "turn-1",
        },
      },
    });
    const messageDelta = mapper.mapNotification({
      method: "item/agentMessage/delta",
      params: {
        threadId: "thread-1",
        turnId: "turn-1",
        itemId: "assistant-1",
        delta: "Hello",
      },
    });
    const reasoningDelta = mapper.mapNotification({
      method: "item/reasoning/summaryTextDelta",
      params: {
        threadId: "thread-1",
        turnId: "turn-1",
        itemId: "reasoning-1",
        delta: "Thinking",
      },
    });
    const toolStarted = mapper.mapNotification({
      method: "item/started",
      params: {
        threadId: "thread-1",
        turnId: "turn-1",
        item: {
          type: "commandExecution",
          id: "command-1",
          command: "swift test",
          cwd: "/tmp/project",
        },
      },
    });
    const toolCompleted = mapper.mapNotification({
      method: "item/completed",
      params: {
        threadId: "thread-1",
        turnId: "turn-1",
        item: {
          type: "commandExecution",
          id: "command-1",
          status: "completed",
          exitCode: 0,
          durationMs: 1200,
        },
      },
    });
    const diffUpdated = mapper.mapNotification({
      method: "turn/diff/updated",
      params: {
        threadId: "thread-1",
        turnId: "turn-1",
        diff: [
          "diff --git a/src/app.ts b/src/app.ts",
          "--- a/src/app.ts",
          "+++ b/src/app.ts",
          "+const next = true;",
          "-const prev = false;",
        ].join("\n"),
      },
    });
    const planUpdated = mapper.mapNotification({
      method: "turn/plan/updated",
      params: {
        threadId: "thread-1",
        turnId: "turn-1",
        explanation: "Ship the feature",
        plan: [
          { step: "Implement", status: "completed" },
          { step: "Verify", status: "inProgress" },
        ],
      },
    });
    const authChanged = mapper.mapNotification({
      method: "account/updated",
      params: {
        authMode: "chatgpt",
        planType: "pro",
      },
    });
    const rateLimits = mapper.mapNotification({
      method: "account/rateLimits/updated",
      params: {
        rateLimits: {
          limitId: "requests",
          limitName: "Requests",
          primary: {
            usedPercent: 25,
            windowDurationMins: 60,
            resetsAt: 1_700_000_100,
          },
          secondary: null,
        },
      },
    });

    expect(turnStarted[0]).toEqual(
      expect.objectContaining({
        type: "turn.started",
        threadID: "thread-1",
        turnID: "turn-1",
      }),
    );
    expect(messageDelta[0]).toEqual(
      expect.objectContaining({
        type: "message.delta",
        itemID: "assistant-1",
        payload: {
          messageID: "assistant-1",
          delta: "Hello",
        },
      }),
    );
    expect(reasoningDelta[0]).toEqual(
      expect.objectContaining({
        type: "thinking.delta",
        itemID: "reasoning-1",
      }),
    );
    expect(toolStarted[0]).toEqual(
      expect.objectContaining({
        type: "tool.started",
        activityID: "command-1",
        payload: expect.objectContaining({
          kind: "command",
          command: "swift test",
        }),
      }),
    );
    expect(toolCompleted[0]).toEqual(
      expect.objectContaining({
        type: "tool.completed",
        payload: expect.objectContaining({
          status: "completed",
          exitCode: 0,
        }),
      }),
    );
    expect(diffUpdated[0]).toEqual(
      expect.objectContaining({
        type: "diff.updated",
        payload: {
          summary: "src/app.ts",
          files: [
            {
              id: "src/app.ts",
              path: "src/app.ts",
              additions: 1,
              deletions: 1,
            },
          ],
        },
      }),
    );
    expect(planUpdated[0]).toEqual(
      expect.objectContaining({
        type: "plan.updated",
        payload: {
          summary: "Ship the feature",
          steps: [
            { id: "step-0", title: "Implement", status: "completed" },
            { id: "step-1", title: "Verify", status: "in_progress" },
          ],
        },
      }),
    );
    expect(authChanged[0]).toEqual(
      expect.objectContaining({
        type: "auth.changed",
        payload: {
          state: "signed_in",
          account: {
            displayName: "chatgpt (pro)",
          },
        },
      }),
    );
    expect(rateLimits[0]).toEqual(
      expect.objectContaining({
        type: "rateLimit.updated",
        payload: {
          buckets: [
            expect.objectContaining({
              id: "requests:primary",
              kind: "requests",
            }),
          ],
        },
      }),
    );
  });

  test("maps approval requests and malformed notifications", () => {
    const mapper = new DefaultCodexEventMapper();

    const approval = mapper.mapServerRequest({
      id: "approval-1",
      method: "item/commandExecution/requestApproval",
      params: {
        threadId: "thread-1",
        turnId: "turn-1",
        itemId: "command-1",
        command: "git push",
        cwd: "/tmp/project",
        reason: "Network access required",
      },
    });
    const malformed = mapper.mapNotification({
      method: "turn/completed",
      params: {
        threadId: "thread-1",
      },
    });

    expect(approval[0]).toEqual(
      expect.objectContaining({
        type: "approval.requested",
        threadID: "thread-1",
        turnID: "turn-1",
        payload: expect.objectContaining({
          approvalID: "approval-1",
          kind: "command",
        }),
      }),
    );
    expect(malformed[0]).toEqual(
      expect.objectContaining({
        type: "error",
        payload: expect.objectContaining({
          code: "malformed_provider_notification",
        }),
      }),
    );
  });
});
