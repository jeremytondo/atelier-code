import { describe, expect, test } from "bun:test";

import { createProtocolNotificationEmitter } from "./notification-emitter";
import type { JsonRpcNotification } from "./types";

describe("notification-emitter", () => {
  test("asserts protocol notifications before forwarding them", async () => {
    const emitted: JsonRpcNotification[] = [];
    const emitter = createProtocolNotificationEmitter({
      emit(notification) {
        emitted.push(notification);
      },
    });

    await emitter.emit({
      method: "thread/started",
      params: {},
    });

    expect(emitted).toEqual([
      {
        method: "thread/started",
        params: {},
      },
    ]);

    expect(() =>
      emitter.emit({
        method: "thread/unknown",
        params: {},
      } as JsonRpcNotification<Record<string, never>>),
    ).toThrow(
      expect.objectContaining({
        code: -32602,
        message:
          "Outbound notification thread/unknown is not supported in phase 1.",
      }),
    );

    expect(emitted).toHaveLength(1);
  });
});
