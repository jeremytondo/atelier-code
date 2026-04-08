import { describe, expect, test } from "bun:test";

import type { ThreadRecord, TurnRecord } from "../domain/models";
import {
  DEFAULT_MODEL,
  DEFAULT_MODEL_PROVIDER,
} from "../server/defaults";
import { SERVER_VERSION } from "../server/server-metadata";
import {
  toProtocolSandboxPolicy,
  toProtocolThread,
  toProtocolTurn,
} from "./serializers";

describe("protocol serializers", () => {
  test("serializes thread/start style threads with canonical defaults", () => {
    expect(toProtocolThread(buildThreadRecord())).toEqual({
      id: "thread-1",
      preview: "Preview",
      ephemeral: false,
      modelProvider: DEFAULT_MODEL_PROVIDER,
      createdAt: 1,
      updatedAt: 2,
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
    });
  });

  test("includes turns and items when explicitly requested", () => {
    expect(
      toProtocolThread(buildThreadRecord(), { includeTurns: true }),
    ).toEqual({
      id: "thread-1",
      preview: "Preview",
      ephemeral: false,
      modelProvider: DEFAULT_MODEL_PROVIDER,
      createdAt: 1,
      updatedAt: 2,
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
      turns: [
        {
          id: "turn-1",
          items: [
            {
              type: "userMessage",
              id: "item-1",
              content: [
                {
                  type: "text",
                  text: "Hello",
                  text_elements: [],
                },
              ],
            },
          ],
          status: "completed",
          error: null,
        },
      ],
    });
  });

  test("keeps turn/start style turns itemless by default", () => {
    expect(toProtocolTurn(buildTurnRecord())).toEqual({
      id: "turn-1",
      items: [],
      status: "completed",
      error: null,
    });
  });

  test("maps workspace-write sandbox mode to a protocol sandbox policy", () => {
    expect(toProtocolSandboxPolicy("workspace-write", "/tmp/project")).toEqual({
      type: "workspaceWrite",
      writableRoots: ["/tmp/project"],
      readOnlyAccess: {
        type: "fullAccess",
      },
      networkAccess: false,
      excludeTmpdirEnvVar: false,
      excludeSlashTmp: false,
    });
  });

  test("maps read-only and danger-full-access sandbox modes to protocol sandbox policies", () => {
    expect(toProtocolSandboxPolicy("read-only", "/tmp/project")).toEqual({
      type: "readOnly",
      access: {
        type: "restricted",
        includePlatformDefaults: true,
        readableRoots: ["/tmp/project"],
      },
      networkAccess: false,
    });
    expect(
      toProtocolSandboxPolicy("danger-full-access", "/tmp/project"),
    ).toEqual({
      type: "dangerFullAccess",
    });
  });
});

function buildThreadRecord(): ThreadRecord {
  return {
    id: "thread-1",
    workspaceId: "workspace-1",
    preview: "Preview",
    ephemeral: false,
    createdAt: 1,
    updatedAt: 2,
    status: { type: "idle" },
    cwd: "/tmp/project",
    model: DEFAULT_MODEL,
    modelProvider: DEFAULT_MODEL_PROVIDER,
    serviceTier: null,
    approvalPolicy: "on-request",
    sandboxMode: "workspace-write",
    reasoningEffort: null,
    name: null,
    turns: [buildTurnRecord()],
  };
}

function buildTurnRecord(): TurnRecord {
  return {
    id: "turn-1",
    items: [
      {
        type: "userMessage",
        id: "item-1",
        content: [
          {
            type: "text",
            text: "Hello",
            text_elements: [],
          },
        ],
      },
    ],
    status: "completed",
    error: null,
  };
}
