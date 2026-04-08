import { describe, expect, test } from "bun:test";

import { createSessionRecord } from "../../app/session";
import type { JsonRpcNotification } from "../../core/protocol/types";
import { handleWorkspaceOpen } from "./workspace.handlers";

describe("workspace handlers", () => {
  test("workspace/open rejects invalid params", () => {
    let called = false;

    const outcome = handleWorkspaceOpen(
      {
        id: "workspace-1",
        method: "workspace/open",
        params: {
          path: "",
        },
      },
      createContext(),
      {
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
      } as never,
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
});

function createContext() {
  return {
    session: createSessionRecord("session-1"),
    notifications: {
      emit: async (_notification: JsonRpcNotification) => {},
    },
  };
}
