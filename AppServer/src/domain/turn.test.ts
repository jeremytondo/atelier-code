import { describe, expect, test } from "bun:test";

import type { DomainError } from "./errors";
import { createThreadRecord } from "./thread";
import {
  applyAgentMessageDelta,
  applyItemCompleted,
  applyItemStarted,
  applyPendingRequest,
  completeTurn,
} from "./turn";

describe("turn event reducer", () => {
  test("adds started items and applies deltas", () => {
    const started = applyItemStarted(
      {
        id: "turn-1",
        items: [],
        status: "inProgress",
        error: null,
      },
      {
        type: "agentMessage",
        id: "item-1",
        text: "",
        phase: "final_answer",
      },
    );
    const updated = applyAgentMessageDelta(started, "item-1", "Hello");

    expect(started.items).toEqual([
      {
        type: "agentMessage",
        id: "item-1",
        text: "",
        phase: "final_answer",
      },
    ]);
    expect(updated.items).toEqual([
      {
        type: "agentMessage",
        id: "item-1",
        text: "Hello",
        phase: "final_answer",
      },
    ]);
  });

  test("throws when a delta targets an unknown item", () => {
    expect(() =>
      applyAgentMessageDelta(
        {
          id: "turn-1",
          items: [],
          status: "inProgress",
          error: null,
        },
        "missing-item",
        "Hello",
      ),
    ).toThrow(
      expect.objectContaining({
        code: "item_not_found",
      }) satisfies Partial<DomainError>,
    );
  });

  test("replaces completed items in-place", () => {
    const completed = applyItemCompleted(
      {
        id: "turn-1",
        items: [
          {
            type: "agentMessage",
            id: "item-1",
            text: "Hel",
            phase: "final_answer",
          },
        ],
        status: "inProgress",
        error: null,
      },
      {
        type: "agentMessage",
        id: "item-1",
        text: "Hello",
        phase: "final_answer",
      },
    );

    expect(completed.items).toEqual([
      {
        type: "agentMessage",
        id: "item-1",
        text: "Hello",
        phase: "final_answer",
      },
    ]);
  });

  test("marks approval pending and completes the turn", () => {
    const thread = createThreadRecord({
      id: "thread-1",
      workspaceId: "workspace-1",
      cwd: "/tmp/project",
      now: 123,
      model: "fake-codex-phase-1",
      modelProvider: "fake-codex",
      serviceTier: null,
      approvalPolicy: "on-request",
      sandboxMode: "workspace-write",
      reasoningEffort: null,
    });
    const pending = applyPendingRequest({
      ...thread,
      status: { type: "active", activeFlags: ["turnInProgress"] },
    });
    const completed = completeTurn(
      pending,
      {
        id: "turn-1",
        items: [],
        status: "inProgress",
        error: null,
      },
      "completed",
      456,
    );

    expect(pending.status).toEqual({
      type: "active",
      activeFlags: ["turnInProgress", "approvalPending"],
    });
    expect(completed.thread.status).toEqual({ type: "idle" });
    expect(completed.thread.updatedAt).toBe(456);
    expect(completed.turn.status).toBe("completed");
  });
});
