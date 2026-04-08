import { describe, expect, test } from "bun:test";

import { FakeAgentAdapter } from "./fake.adapter";

describe("FakeAgentAdapter", () => {
  test("emits a fixed happy-path event order", async () => {
    const adapter = new FakeAgentAdapter({
      deltaChunks: ["Hello", " world"],
      tickDelayMs: 0,
    });

    const events = [];
    for await (const event of adapter.streamTurn({
      thread: {
        id: "thread-1",
        workspaceId: "workspace-1",
        preview: "Preview",
        ephemeral: false,
        createdAt: 1,
        updatedAt: 1,
        status: { type: "active", activeFlags: ["turnInProgress"] },
        cwd: "/tmp/project",
        model: "fake-codex-phase-1",
        modelProvider: "fake-codex",
        serviceTier: null,
        approvalPolicy: "on-request",
        sandboxMode: "workspace-write",
        reasoningEffort: null,
        name: null,
        turns: [],
      },
      turn: {
        id: "turn-1",
        items: [],
        status: "inProgress",
        error: null,
      },
      input: [
        {
          type: "text",
          text: "Hello world",
          text_elements: [],
        },
      ],
      createItemId: () => "item-1",
    })) {
      events.push(event);
    }

    expect(events.map((event) => event.type)).toEqual([
      "itemStarted",
      "agentMessageDelta",
      "agentMessageDelta",
      "itemCompleted",
      "turnCompleted",
    ]);
  });

  test("keeps delta payloads and terminal completion deterministic", async () => {
    const adapter = new FakeAgentAdapter({
      deltaChunks: ["A", "B", "C"],
      tickDelayMs: 0,
    });

    const events = [];
    for await (const event of adapter.streamTurn({
      thread: {
        id: "thread-1",
        workspaceId: "workspace-1",
        preview: "Preview",
        ephemeral: false,
        createdAt: 1,
        updatedAt: 1,
        status: { type: "active", activeFlags: ["turnInProgress"] },
        cwd: "/tmp/project",
        model: "fake-codex-phase-1",
        modelProvider: "fake-codex",
        serviceTier: null,
        approvalPolicy: "on-request",
        sandboxMode: "workspace-write",
        reasoningEffort: null,
        name: null,
        turns: [],
      },
      turn: {
        id: "turn-1",
        items: [],
        status: "inProgress",
        error: null,
      },
      input: [
        {
          type: "text",
          text: "Ignored",
          text_elements: [],
        },
      ],
      createItemId: () => "item-7",
    })) {
      events.push(event);
    }

    expect(events[1]).toEqual({
      type: "agentMessageDelta",
      itemId: "item-7",
      delta: "A",
    });
    expect(events[2]).toEqual({
      type: "agentMessageDelta",
      itemId: "item-7",
      delta: "B",
    });
    expect(events[3]).toEqual({
      type: "agentMessageDelta",
      itemId: "item-7",
      delta: "C",
    });
    expect(events[4]).toEqual({
      type: "itemCompleted",
      item: {
        type: "agentMessage",
        id: "item-7",
        text: "ABC",
        phase: "final_answer",
      },
    });
  });
});
