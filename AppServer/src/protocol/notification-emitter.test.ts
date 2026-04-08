import { describe, expect, test } from "bun:test";

import { DEFAULT_MODEL_PROVIDER } from "../server/defaults";
import { SERVER_VERSION } from "../server/server-metadata";
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
      params: {
        thread: {
          id: "thread-1",
          preview: "New thread",
          ephemeral: false,
          modelProvider: DEFAULT_MODEL_PROVIDER,
          createdAt: 1,
          updatedAt: 1,
          status: {
            type: "idle",
          },
          path: null,
          cwd: "/tmp/project",
          cliVersion: SERVER_VERSION,
          source: "appServer",
          agentNickname: null,
          agentRole: null,
          gitInfo: null,
          name: null,
          workspaceId: "workspace-1",
          turns: [],
        },
      },
    });

    expect(emitted).toEqual([
      {
        method: "thread/started",
        params: {
          thread: {
            id: "thread-1",
            preview: "New thread",
            ephemeral: false,
            modelProvider: DEFAULT_MODEL_PROVIDER,
            createdAt: 1,
            updatedAt: 1,
            status: {
              type: "idle",
            },
            path: null,
            cwd: "/tmp/project",
            cliVersion: SERVER_VERSION,
            source: "appServer",
            agentNickname: null,
            agentRole: null,
            gitInfo: null,
            name: null,
            workspaceId: "workspace-1",
            turns: [],
          },
        },
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
