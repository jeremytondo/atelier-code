import { describe, expect, test } from "bun:test";
import { createActiveTurnRegistry } from "@/turns/active-turn-registry";

describe("active turn registry", () => {
  test("reconciles streamed item state against the final completed item payload", () => {
    const registry = createActiveTurnRegistry();

    registry.startTurn({
      threadId: "thread-1",
      turn: {
        id: "turn-1",
        status: {
          type: "inProgress",
        },
      },
    });
    registry.recordItemStarted({
      threadId: "thread-1",
      turnId: "turn-1",
      item: {
        id: "item-1",
        kind: "agent_message",
        rawItem: {
          id: "item-1",
          type: "agent_message",
          status: "in_progress",
        },
      },
    });
    registry.appendMessageText({
      threadId: "thread-1",
      turnId: "turn-1",
      itemId: "item-1",
      delta: "Hello",
    });
    registry.appendMessageText({
      threadId: "thread-1",
      turnId: "turn-1",
      itemId: "item-1",
      delta: " world",
    });
    registry.recordItemCompleted({
      threadId: "thread-1",
      turnId: "turn-1",
      item: {
        id: "item-1",
        kind: "agent_message",
        rawItem: {
          id: "item-1",
          type: "agent_message",
          status: "completed",
          text: "Hello world",
        },
      },
    });

    expect(registry.getActiveTurn("thread-1")).toEqual({
      threadId: "thread-1",
      turn: {
        id: "turn-1",
        status: {
          type: "inProgress",
        },
      },
      items: [
        {
          item: {
            id: "item-1",
            kind: "agent_message",
            rawItem: {
              id: "item-1",
              type: "agent_message",
              status: "completed",
              text: "Hello world",
            },
          },
          messageText: "Hello world",
          reasoningText: "",
          reasoningSummaryText: "",
          commandOutput: "",
          toolProgress: [],
        },
      ],
    });
  });

  test("clears per-thread state", () => {
    const registry = createActiveTurnRegistry();

    registry.startTurn({
      threadId: "thread-1",
      turn: {
        id: "turn-1",
        status: {
          type: "inProgress",
        },
      },
    });

    expect(registry.clearThread("thread-1")).toEqual({
      threadId: "thread-1",
      turn: {
        id: "turn-1",
        status: {
          type: "inProgress",
        },
      },
      items: [],
    });
    expect(registry.getActiveTurn("thread-1")).toBeUndefined();
  });
});
