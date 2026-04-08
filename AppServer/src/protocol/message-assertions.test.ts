import { describe, expect, test } from "bun:test";

import { DEFAULT_MODEL_PROVIDER } from "../server/defaults";
import { SERVER_VERSION } from "../server/server-metadata";
import {
  assertProtocolNotification,
  assertProtocolResponse,
} from "./message-assertions";

describe("message-assertions", () => {
  test("rejects success responses without valid ids", () => {
    expect(() =>
      assertProtocolResponse({
        id: null,
        result: {},
      } as never),
    ).toThrow("Outbound success response must include a string or number id.");
  });

  test("rejects error responses without valid error objects", () => {
    expect(() =>
      assertProtocolResponse({
        id: "request-1",
        error: {
          code: "bad",
          message: "Nope",
        },
      } as never),
    ).toThrow("Outbound error response must include a valid error object.");
  });

  test("rejects unsupported notification methods", () => {
    expect(() =>
      assertProtocolNotification({
        method: "turn/unknown",
        params: {},
      }),
    ).toThrow(
      expect.objectContaining({
        code: -32602,
        message:
          "Outbound notification turn/unknown is not supported in phase 1.",
      }),
    );
  });

  test("rejects invalid thread/started payloads", () => {
    expect(() =>
      assertProtocolNotification({
        method: "thread/started",
        params: {
          thread: {
            id: "thread-1",
          },
        },
      }),
    ).toThrow("thread/started params.thread must be a valid protocol thread.");
  });

  test("rejects invalid turn/started payloads", () => {
    expect(() =>
      assertProtocolNotification({
        method: "turn/started",
        params: {
          threadId: "thread-1",
          turn: {
            id: "turn-1",
          },
        },
      }),
    ).toThrow(
      "turn/started params must include a string threadId and valid protocol turn.",
    );
  });

  test("rejects invalid item/started payloads", () => {
    expect(() =>
      assertProtocolNotification({
        method: "item/started",
        params: {
          threadId: "thread-1",
          turnId: "turn-1",
          item: {
            type: "plan",
          },
        },
      }),
    ).toThrow(
      "item/started params must include string threadId/turnId values and a valid protocol item.",
    );
  });

  test("rejects invalid item/agentMessage/delta payloads", () => {
    expect(() =>
      assertProtocolNotification({
        method: "item/agentMessage/delta",
        params: {
          threadId: "thread-1",
          turnId: "turn-1",
          itemId: "item-1",
          delta: 1,
        },
      }),
    ).toThrow(
      "item/agentMessage/delta params must include string threadId, turnId, itemId, and delta values.",
    );
  });

  test("rejects invalid item/completed payloads", () => {
    expect(() =>
      assertProtocolNotification({
        method: "item/completed",
        params: {
          threadId: "thread-1",
          turnId: "turn-1",
          item: {
            type: "agentMessage",
            id: "item-1",
            phase: "final_answer",
          },
        },
      }),
    ).toThrow(
      "item/completed params must include string threadId/turnId values and a valid protocol item.",
    );
  });

  test("rejects invalid turn/completed payloads", () => {
    expect(() =>
      assertProtocolNotification({
        method: "turn/completed",
        params: {
          threadId: "thread-1",
          turn: {
            id: "turn-1",
            items: [],
            status: "done",
            error: null,
          },
        },
      }),
    ).toThrow(
      "turn/completed params must include a string threadId and valid protocol turn.",
    );
  });

  test("returns valid protocol messages unchanged", () => {
    expect(
      assertProtocolResponse({
        id: "request-1",
        result: {
          ok: true,
        },
      }),
    ).toEqual({
      id: "request-1",
      result: {
        ok: true,
      },
    });

    expect(
      assertProtocolNotification({
        method: "thread/started",
        params: {
          thread: buildProtocolThread(),
        },
      }),
    ).toEqual({
      method: "thread/started",
      params: {
        thread: buildProtocolThread(),
      },
    });
  });
});

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
