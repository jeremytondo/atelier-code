import { describe, expect, test } from "bun:test";

import { createSessionRecord } from "../../app/session";
import { DEFAULT_MODEL, DEFAULT_MODEL_PROVIDER } from "../config/defaults";
import { SERVER_VERSION } from "../config/server-metadata";
import { DomainError } from "../shared/errors";
import { ProtocolDispatcher } from "./dispatcher";
import type { JsonRpcNotification } from "./types";

describe("ProtocolDispatcher", () => {
  test("returns method not found for unknown phase methods", () => {
    const dispatcher = new ProtocolDispatcher(createFakeService());

    const outcome = dispatcher.dispatchParsedRequest(
      {
        id: "request-1",
        method: "workspace/close",
      },
      createDispatchContext(),
    );

    expect(outcome.response).toEqual({
      id: "request-1",
      error: {
        code: -32601,
        message: "Method workspace/close is not supported.",
        data: {
          code: "method_not_found",
          method: "workspace/close",
        },
      },
    });
  });

  test("maps domain errors to execution errors", () => {
    const dispatcher = new ProtocolDispatcher(
      createFakeService({
        openWorkspace: () => {
          throw new DomainError(
            "not_initialized",
            "The connection must initialize before using other methods.",
          );
        },
      }),
    );

    const outcome = dispatcher.dispatchParsedRequest(
      {
        id: "workspace-1",
        method: "workspace/open",
        params: {
          path: "/tmp/project",
        },
      },
      createDispatchContext(),
    );

    expect(outcome.response).toEqual({
      id: "workspace-1",
      error: {
        code: -32000,
        message: "The connection must initialize before using other methods.",
        data: {
          code: "not_initialized",
        },
      },
    });
  });
});

function createDispatchContext() {
  return {
    session: createSessionRecord("session-1"),
    notifications: {
      emit: async (_notification: JsonRpcNotification) => {},
    },
  };
}

function createFakeService(
  overrides: Partial<{
    initialize: (...args: unknown[]) => unknown;
    openWorkspace: (...args: unknown[]) => unknown;
    startThread: (...args: unknown[]) => unknown;
    startTurn: (...args: unknown[]) => unknown;
  }> = {},
) {
  return {
    initialize:
      overrides.initialize ?? (() => ({ result: { userAgent: "fake" } })),
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
          model: DEFAULT_MODEL,
          modelProvider: DEFAULT_MODEL_PROVIDER,
          serviceTier: null,
          cwd: "/tmp/project",
          approvalPolicy: "on-request",
          sandbox: {
            type: "workspaceWrite",
            writableRoots: ["/tmp/project"],
            readOnlyAccess: {
              type: "fullAccess",
            },
            networkAccess: false,
            excludeTmpdirEnvVar: false,
            excludeSlashTmp: false,
          },
          reasoningEffort: null,
        },
      })),
    startTurn:
      overrides.startTurn ??
      (() => ({
        result: {
          turn: {
            id: "turn-1",
            items: [],
            status: "inProgress",
            error: null,
          },
        },
      })),
  } as never;
}
