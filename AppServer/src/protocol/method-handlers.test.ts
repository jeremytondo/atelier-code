import { describe, expect, test } from "bun:test";

import { DEFAULT_MODEL_PROVIDER } from "../server/defaults";
import { SERVER_VERSION } from "../server/server-metadata";
import { createSessionRecord } from "../server/session-state";
import {
  handleInitialize,
  handleThreadStart,
  handleTurnStart,
  handleWorkspaceOpen,
} from "./method-handlers";
import type { JsonRpcNotification } from "./types";

describe("method-handlers", () => {
  test("initialize validates params before invoking the service", () => {
    let called = false;
    const context = createContext({
      initialize: () => {
        called = true;
        return {
          result: {
            userAgent: "fake",
          },
        };
      },
    });

    const outcome = handleInitialize(
      {
        id: "initialize-1",
        method: "initialize",
        params: {},
      },
      context,
    );

    expect(called).toBe(false);
    expect(outcome.response).toEqual({
      id: "initialize-1",
      error: {
        code: -32602,
        message: "initialize clientInfo must be an object.",
        data: {
          code: "invalid_params",
        },
      },
    });
  });

  test("initialize returns the service result for valid params", () => {
    let receivedParams: unknown;
    const context = createContext({
      initialize: (_session, params) => {
        receivedParams = params;
        return {
          result: {
            userAgent: "AtelierCode AppServer/0.1.0",
          },
        };
      },
    });

    const outcome = handleInitialize(
      {
        id: "initialize-1",
        method: "initialize",
        params: {
          clientInfo: {
            name: "Harness",
            title: null,
            version: "1.0.0",
          },
          capabilities: {
            experimentalApi: true,
          },
        },
      },
      context,
    );

    expect(receivedParams).toEqual({
      clientInfo: {
        name: "Harness",
        title: null,
        version: "1.0.0",
      },
      capabilities: {
        experimentalApi: true,
      },
    });
    expect(outcome.response).toEqual({
      id: "initialize-1",
      result: {
        userAgent: "AtelierCode AppServer/0.1.0",
      },
    });
  });

  test("workspace/open rejects invalid params", () => {
    let called = false;
    const context = createContext({
      openWorkspace: () => {
        called = true;
        return {
          result: {
            workspace: {
              id: "workspace-1",
              path: "/tmp/project",
              createdAt: 1,
              updatedAt: 1,
            },
          },
        };
      },
    });

    const outcome = handleWorkspaceOpen(
      {
        id: "workspace-1",
        method: "workspace/open",
        params: {
          path: "",
        },
      },
      context,
    );

    expect(called).toBe(false);
    expect(outcome.response).toEqual({
      id: "workspace-1",
      error: {
        code: -32602,
        message: "workspace/open params must include a non-empty path.",
        data: {
          code: "invalid_params",
        },
      },
    });
  });

  test("thread/start returns follow-up notifications through the protocol emitter", async () => {
    const context = createContext({
      startThread: (_session, _params, notifications: NotificationTarget) => ({
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
    });

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

  test("turn/start returns follow-up notifications through the protocol emitter", async () => {
    const context = createContext({
      startTurn: (_session, _params, notifications: NotificationTarget) => ({
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
    });

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

interface ServiceOverrides {
  initialize?: (session: unknown, params: unknown) => unknown;
  openWorkspace?: (session: unknown, params: unknown) => unknown;
  startThread?: (
    session: unknown,
    params: unknown,
    notifications: NotificationTarget,
  ) => unknown;
  startTurn?: (
    session: unknown,
    params: unknown,
    notifications: NotificationTarget,
  ) => unknown;
}

function createContext(overrides: ServiceOverrides = {}) {
  const emitted: JsonRpcNotification[] = [];

  return {
    emitted,
    session: createSessionRecord("session-1"),
    notifications: {
      emit: async (notification: JsonRpcNotification) => {
        emitted.push(notification);
      },
    },
    service: {
      initialize:
        overrides.initialize ??
        (() => ({
          result: {
            userAgent: "fake",
          },
        })),
      openWorkspace:
        overrides.openWorkspace ??
        (() => ({
          result: {
            workspace: {
              id: "workspace-1",
              path: "/tmp/project",
              createdAt: 1,
              updatedAt: 1,
            },
          },
        })),
      startThread:
        overrides.startThread ??
        (() => ({
          result: {
            thread: buildProtocolThread(),
          },
        })),
      startTurn:
        overrides.startTurn ??
        (() => ({
          result: {
            turn: buildProtocolTurn("turn-1"),
          },
        })),
    } as never,
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

function buildProtocolTurn(id: string) {
  return {
    id,
    items: [],
    status: "inProgress" as const,
    error: null,
  };
}
