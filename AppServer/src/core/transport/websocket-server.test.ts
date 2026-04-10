import { describe, expect, test } from "bun:test";
import { assertWebSocketSendSucceeded, waitForShutdown } from "@/core/transport/websocket-server";

describe("WebSocket transport helpers", () => {
  test("treats Bun backpressure as a queued send rather than a failure", () => {
    expect(() => {
      assertWebSocketSendSucceeded(-1);
    }).not.toThrow();
    expect(() => {
      assertWebSocketSendSucceeded(42);
    }).not.toThrow();
  });

  test("still fails when Bun reports a dropped frame", () => {
    expect(() => {
      assertWebSocketSendSucceeded(0);
    }).toThrow("WebSocket message was dropped");
  });

  test("clears the shutdown timeout after the server stops", async () => {
    let clearedTimer: ReturnType<typeof setTimeout> | null = null;
    let scheduledTimer: ReturnType<typeof setTimeout> | null = null;

    const didStop = await waitForShutdown(Promise.resolve(), 1_000, {
      setTimer: (callback, timeoutMs) => {
        scheduledTimer = setTimeout(callback, timeoutMs);
        return scheduledTimer;
      },
      clearTimer: (timer) => {
        clearedTimer = timer;
        clearTimeout(timer);
      },
    });

    expect(didStop).toBe(true);
    expect(clearedTimer).toBe(scheduledTimer);
  });
});
