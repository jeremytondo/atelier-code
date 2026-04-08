import { describe, expect, test } from "bun:test";

import { createSessionRecord } from "../../app/session";
import { DEFAULT_MODEL_PROVIDER } from "../../core/config/defaults";
import { SERVER_VERSION } from "../../core/config/server-metadata";
import type { JsonRpcNotification } from "../../core/protocol/types";
import { handleThreadStart } from "./thread.handlers";

describe("thread handlers", () => {
  test("thread/start returns follow-up notifications through the protocol emitter", async () => {
    const context = createContext();
    const outcome = handleThreadStart(
      {
        id: "thread-req-1",
        method: "thread/start",
        params: {
          experimentalRawEvents: false,
          persistExtendedHistory: false,
        },
      },
      context,
      {
        startThread: (
          _session: unknown,
          _params: unknown,
          notifications: NotificationTarget,
        ) => ({
          result: {
            thread: buildProtocolThread(),
          },
          followUp: async () => {
            await notifications.emit({
              method: "thread/started",
              params: {
                thread: buildProtocolThread(),
              },
            });
          },
        }),
      } as never,
    );

    expect(outcome.response).toEqual({
      id: "thread-req-1",
      result: {
        thread: buildProtocolThread(),
      },
    });

    await outcome.followUp?.();

    expect(context.emitted).toEqual([
      {
        method: "thread/started",
        params: {
          thread: buildProtocolThread(),
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

function buildProtocolThread() {
  return {
    id: "thread-1",
    preview: "New thread",
    ephemeral: false,
    modelProvider: DEFAULT_MODEL_PROVIDER,
    createdAt: 1,
    updatedAt: 1,
    status: {
      type: "idle" as const,
    },
    path: null,
    cwd: "/tmp/project",
    cliVersion: SERVER_VERSION,
    source: "appServer" as const,
    agentNickname: null,
    agentRole: null,
    gitInfo: null,
    name: null,
    workspaceId: "workspace-1",
    turns: [],
  };
}
