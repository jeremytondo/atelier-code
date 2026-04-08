import { describe, expect, test } from "bun:test";

import type { ThreadRecord, TurnRecord } from "../domain/models";
import { SERVER_VERSION } from "../server/server-metadata";
import { toProtocolThread, toProtocolTurn } from "./serializers";

describe("protocol serializers", () => {
  test("serializes thread/start style threads with canonical defaults", () => {
    expect(toProtocolThread(buildThreadRecord())).toEqual({
      id: "thread-1",
      preview: "Preview",
      ephemeral: false,
      modelProvider: "fake-codex",
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
      modelProvider: "fake-codex",
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
    model: "fake-codex-phase-1",
    modelProvider: "fake-codex",
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
