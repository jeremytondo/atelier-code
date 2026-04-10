import { describe, expect, test } from "bun:test";
import {
  mapCodexServerRequest,
  mapCodexTransportNotification,
} from "@/agents/codex-adapter/notification-mapper";
import type {
  CodexCommandExecutionRequestApprovalParams,
  CodexReasoningTextDeltaNotification,
  CodexTurnDiffUpdatedNotification,
  CodexTurnPlanUpdatedNotification,
} from "@/agents/codex-adapter/protocol";

const context = {
  agentId: "codex",
  provider: "codex" as const,
  receivedAt: "2026-04-10T12:00:00.000Z",
};

describe("mapCodexTransportNotification", () => {
  test("maps pinned plan and diff fixtures into provider-neutral notifications", () => {
    const planFixture: CodexTurnPlanUpdatedNotification = {
      threadId: "thread-1",
      turnId: "turn-1",
      explanation: "Ship the session layer",
      plan: [
        {
          step: "Implement transport",
          status: "completed",
        },
        {
          step: "Add tests",
          status: "inProgress",
        },
      ],
    };
    const diffFixture: CodexTurnDiffUpdatedNotification = {
      threadId: "thread-1",
      turnId: "turn-1",
      diff: [
        "diff --git a/src/example.ts b/src/example.ts",
        "--- a/src/example.ts",
        "+++ b/src/example.ts",
        "+added",
        "-removed",
      ].join("\n"),
    };

    const mappedPlan = mapCodexTransportNotification(
      {
        method: "turn/plan/updated",
        params: planFixture,
      },
      context,
    );
    const mappedDiff = mapCodexTransportNotification(
      {
        method: "turn/diff/updated",
        params: diffFixture,
      },
      context,
    );

    expect(mappedPlan).toEqual([
      {
        agentId: "codex",
        provider: "codex",
        receivedAt: "2026-04-10T12:00:00.000Z",
        rawMethod: "turn/plan/updated",
        rawPayload: planFixture,
        type: "plan",
        event: "updated",
        threadId: "thread-1",
        turnId: "turn-1",
        explanation: "Ship the session layer",
        steps: [
          {
            step: "Implement transport",
            status: "completed",
          },
          {
            step: "Add tests",
            status: "in_progress",
          },
        ],
      },
    ]);
    expect(mappedDiff).toEqual([
      {
        agentId: "codex",
        provider: "codex",
        receivedAt: "2026-04-10T12:00:00.000Z",
        rawMethod: "turn/diff/updated",
        rawPayload: diffFixture,
        type: "diff",
        event: "updated",
        threadId: "thread-1",
        turnId: "turn-1",
        diff: diffFixture.diff,
        summary: [
          {
            path: "src/example.ts",
            additions: 1,
            deletions: 1,
          },
        ],
      },
    ]);
  });

  test("maps pinned reasoning fixtures into provider-neutral notifications", () => {
    const reasoningFixture: CodexReasoningTextDeltaNotification = {
      threadId: "thread-1",
      turnId: "turn-1",
      itemId: "item-1",
      delta: "Thinking...",
      contentIndex: 0,
    };

    expect(
      mapCodexTransportNotification(
        {
          method: "item/reasoning/textDelta",
          params: reasoningFixture,
        },
        context,
      ),
    ).toEqual([
      {
        agentId: "codex",
        provider: "codex",
        receivedAt: "2026-04-10T12:00:00.000Z",
        rawMethod: "item/reasoning/textDelta",
        rawPayload: reasoningFixture,
        type: "reasoning",
        event: "textDelta",
        threadId: "thread-1",
        turnId: "turn-1",
        itemId: "item-1",
        delta: "Thinking...",
      },
    ]);
  });
});

describe("mapCodexServerRequest", () => {
  test("maps command approval requests into provider-neutral approval notifications", () => {
    const approvalFixture: CodexCommandExecutionRequestApprovalParams = {
      threadId: "thread-1",
      turnId: "turn-1",
      itemId: "item-1",
      command: "git status",
      cwd: "/tmp/project",
      commandActions: [
        {
          type: "unknown",
          command: "git status",
        },
      ],
    };

    expect(
      mapCodexServerRequest(
        {
          id: "approval-1",
          method: "item/commandExecution/requestApproval",
          params: approvalFixture,
        },
        context,
      ),
    ).toEqual([
      {
        agentId: "codex",
        provider: "codex",
        receivedAt: "2026-04-10T12:00:00.000Z",
        rawMethod: "item/commandExecution/requestApproval",
        rawPayload: approvalFixture,
        type: "approval",
        event: "requested",
        requestId: "approval-1",
        threadId: "thread-1",
        turnId: "turn-1",
        itemId: "item-1",
        approval: {
          requestId: "approval-1",
          kind: "commandExecution",
          threadId: "thread-1",
          turnId: "turn-1",
          itemId: "item-1",
          rawRequest: {
            id: "approval-1",
            method: "item/commandExecution/requestApproval",
            params: approvalFixture,
          },
        },
      },
    ]);
  });
});
