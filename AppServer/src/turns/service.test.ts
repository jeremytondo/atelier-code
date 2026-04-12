import { describe, expect, test } from "bun:test";
import {
  createFakeAgentRegistry,
  createFakeAgentSession,
  createTestAgentTurn,
} from "@/test-support/agents";
import { createSilentLogger } from "@/test-support/logger";
import { createActiveTurnRegistry } from "@/turns";
import { createTurnsService } from "@/turns/service";

const workspace = Object.freeze({
  id: "workspace-1",
  workspacePath: "/tmp/project",
  createdAt: "2026-04-10T09:00:00.000Z",
  lastOpenedAt: "2026-04-10T09:00:00.000Z",
});

describe("createTurnsService", () => {
  test("enforces one active turn per thread", async () => {
    const activeTurns = createActiveTurnRegistry();
    const session = createFakeAgentSession({
      startTurn: async () => ({
        ok: true,
        data: {
          turn: createTestAgentTurn({
            id: "turn-1",
          }),
        },
      }),
    });
    const service = createTurnsService({
      logger: createSilentLogger("error"),
      registry: createFakeAgentRegistry(session),
      activeTurns,
    });

    await expect(
      service.startTurn("req-1", workspace, {
        threadId: "thread-1",
        prompt: "Start the first turn",
      }),
    ).resolves.toEqual({
      ok: true,
      data: {
        turn: {
          id: "turn-1",
          status: {
            type: "inProgress",
          },
        },
      },
    });
    await expect(
      service.startTurn("req-2", workspace, {
        threadId: "thread-1",
        prompt: "Try to start another turn",
      }),
    ).resolves.toEqual({
      ok: false,
      error: {
        type: "activeTurnConflict",
        threadId: "thread-1",
        activeTurnId: "turn-1",
        message: "Thread already has an active turn.",
      },
    });
  });

  test("releases a pending reservation when turn/start fails", async () => {
    let callCount = 0;
    const service = createTurnsService({
      logger: createSilentLogger("error"),
      registry: createFakeAgentRegistry(
        createFakeAgentSession({
          startTurn: async () => {
            callCount += 1;

            if (callCount === 1) {
              return {
                ok: false,
                error: {
                  type: "remoteError",
                  agentId: "codex",
                  provider: "codex",
                  requestId: "req-1",
                  code: -32603,
                  message: "provider failed",
                },
              };
            }

            return {
              ok: true,
              data: {
                turn: createTestAgentTurn({
                  id: "turn-2",
                }),
              },
            };
          },
        }),
      ),
      activeTurns: createActiveTurnRegistry(),
    });

    await expect(
      service.startTurn("req-1", workspace, {
        threadId: "thread-1",
        prompt: "This one fails",
      }),
    ).resolves.toEqual({
      ok: false,
      error: {
        type: "remoteError",
        agentId: "codex",
        provider: "codex",
        requestId: "req-1",
        code: -32603,
        message: "provider failed",
      },
    });
    await expect(
      service.startTurn("req-2", workspace, {
        threadId: "thread-1",
        prompt: "This one succeeds",
      }),
    ).resolves.toEqual({
      ok: true,
      data: {
        turn: {
          id: "turn-2",
          status: {
            type: "inProgress",
          },
        },
      },
    });
  });
});
