import { describe, expect, test } from "bun:test";

import { createSessionRecord } from "../../app/session";
import type { JsonRpcNotification } from "../../core/protocol/types";
import { handleTurnStart } from "./turn.handlers";

describe("turn handlers", () => {
  test("turn/start returns follow-up notifications through the protocol emitter", async () => {
    const context = createContext();
    const outcome = handleTurnStart(
      {
        id: "turn-req-1",
        method: "turn/start",
        params: {
          threadId: "thread-1",
          input: [
            {
              type: "text",
              text: "Ship phase 1",
            },
          ],
        },
      },
      context,
      {
        startTurn: (
          _session: unknown,
          _params: unknown,
          notifications: NotificationTarget,
        ) => ({
          result: {
            turn: buildProtocolTurn("turn-1"),
          },
          followUp: async () => {
            await notifications.emit({
              method: "turn/started",
              params: {
                threadId: "thread-1",
                turn: buildProtocolTurn("turn-1"),
              },
            });
          },
        }),
      } as never,
    );

    expect(outcome.response).toEqual({
      id: "turn-req-1",
      result: {
        turn: buildProtocolTurn("turn-1"),
      },
    });

    await outcome.followUp?.();

    expect(context.emitted).toEqual([
      {
        method: "turn/started",
        params: {
          threadId: "thread-1",
          turn: buildProtocolTurn("turn-1"),
        },
      },
    ]);
  });
});

interface NotificationTarget {
  emit<TParams>(
    notification: JsonRpcNotification<TParams>,
  ): Promise<void> | void;
}

function createContext() {
  const emitted: JsonRpcNotification[] = [];

  return {
    emitted,
    session: createSessionRecord("session-1"),
    notifications: {
      emit: async (notification: JsonRpcNotification) => {
        emitted.push(notification);
      },
    },
  };
}

function buildProtocolTurn(id: string) {
  return {
    id,
    items: [],
    status: "inProgress" as const,
    error: null,
  };
}
