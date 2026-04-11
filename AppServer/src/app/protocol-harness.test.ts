import { afterEach, describe, expect, test } from "bun:test";
import { mkdir, mkdtemp, realpath, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AgentAdapter } from "@/agents";
import { createAgentsModule } from "@/agents";
import { createCodexAgentAdapter } from "@/agents/codex-adapter";
import { createLogger } from "@/app/logger";
import {
  APP_SERVER_USER_AGENT,
  createAppProtocolRuntime,
  createAppTransportComponent,
} from "@/app/protocol";
import { type AppServer, createConfiguredAppServer, type SignalRegistrar } from "@/app/server";
import { createApprovalsModulePlaceholder } from "@/approvals";
import { createStoreBootstrap } from "@/core/store";
import {
  createFakeAgentAdapter,
  createFakeAgentSession,
  createTestAgentModel,
  createTestAgentThread,
} from "@/test-support/agents";
import { getAvailablePort } from "@/test-support/network";
import { createSqliteThreadsStore, createThreadsModule } from "@/threads";
import { createTurnsModulePlaceholder } from "@/turns";
import { createSqliteWorkspacesStore, createWorkspacesModule } from "@/workspaces";

const runningServers: AppServer[] = [];
const temporaryDirectories: string[] = [];

afterEach(async () => {
  while (runningServers.length > 0) {
    const server = runningServers.pop();

    if (server === undefined) {
      continue;
    }

    try {
      await server.stop("test-cleanup");
    } catch {
      // Ignore cleanup failures so the original test error stays visible.
    }
  }

  while (temporaryDirectories.length > 0) {
    const directory = temporaryDirectories.pop();

    if (directory === undefined) {
      continue;
    }

    await rm(directory, { force: true, recursive: true });
  }
});

describe("App Server protocol harness", () => {
  test("initializes over a real websocket connection without an extra initialized notification", async () => {
    const harness = await createProtocolHarness();
    const client = await connectProtocolClient(harness.port);

    try {
      client.sendJson({
        id: "req-1",
        method: "initialize",
        params: {
          clientInfo: {
            name: "AtelierCode Test",
            version: "0.1.0",
          },
        },
      });

      await expect(client.nextMessage()).resolves.toEqual({
        id: "req-1",
        result: {
          userAgent: APP_SERVER_USER_AGENT,
        },
      });
      await expect(client.nextMessage(150)).rejects.toThrow("Timed out waiting for message");
    } finally {
      await client.close();
    }
  });

  test("maps invalid json to a parse error", async () => {
    const harness = await createProtocolHarness();
    const client = await connectProtocolClient(harness.port);

    try {
      client.sendText("{");

      await expect(client.nextMessage()).resolves.toEqual({
        id: null,
        error: {
          code: -32700,
          message: "Parse error",
        },
      });
    } finally {
      await client.close();
    }
  });

  test("maps invalid envelopes to invalid request", async () => {
    const harness = await createProtocolHarness();
    const client = await connectProtocolClient(harness.port);

    try {
      client.sendJson({
        method: 123,
      });

      await expect(client.nextMessage()).resolves.toEqual({
        id: null,
        error: {
          code: -32600,
          message: "Invalid request",
        },
      });
    } finally {
      await client.close();
    }
  });

  test("maps unknown methods to method not found", async () => {
    const harness = await createProtocolHarness();
    const client = await connectProtocolClient(harness.port);

    try {
      client.sendJson({
        id: "req-unknown",
        method: "thread/start",
        params: {},
      });

      await expect(client.nextMessage()).resolves.toEqual({
        id: "req-unknown",
        error: {
          code: -32601,
          message: "Method not found",
        },
      });
    } finally {
      await client.close();
    }
  });

  test("maps invalid initialize params to invalid params", async () => {
    const harness = await createProtocolHarness();
    const client = await connectProtocolClient(harness.port);

    try {
      client.sendJson({
        id: "req-invalid-params",
        method: "initialize",
        params: {
          clientInfo: {
            name: "AtelierCode Test",
          },
        },
      });

      await expect(client.nextMessage()).resolves.toEqual({
        id: "req-invalid-params",
        error: {
          code: -32602,
          message: "Invalid params",
        },
      });
    } finally {
      await client.close();
    }
  });

  test("rejects duplicate initialize requests on the same connection", async () => {
    const harness = await createProtocolHarness();
    const client = await connectProtocolClient(harness.port);

    try {
      const initializeRequest = {
        id: "req-initialize-1",
        method: "initialize",
        params: {
          clientInfo: {
            name: "AtelierCode Test",
            version: "0.1.0",
          },
        },
      };

      client.sendJson(initializeRequest);
      await client.nextMessage();

      client.sendJson({
        ...initializeRequest,
        id: "req-initialize-2",
      });

      await expect(client.nextMessage()).resolves.toEqual({
        id: "req-initialize-2",
        error: {
          code: -33000,
          message: "Session already initialized",
          data: {
            code: "SESSION_ALREADY_INITIALIZED",
          },
        },
      });
    } finally {
      await client.close();
    }
  });

  test("returns models after initialize", async () => {
    const harness = await createProtocolHarness({
      agentAdapters: [
        createFakeProtocolAgentAdapter({
          listModelsResult: {
            ok: true,
            data: {
              models: [
                createTestAgentModel({
                  id: "gpt-5.4",
                  model: "gpt-5.4",
                  displayName: "GPT-5.4",
                  isDefault: true,
                }),
              ],
              nextCursor: "cursor-2",
            },
          },
        }),
      ],
    });
    const client = await connectProtocolClient(harness.port);

    try {
      await initializeClient(client);

      client.sendJson({
        id: "req-model-list",
        method: "model/list",
        params: {
          limit: 20,
        },
      });

      await expect(client.nextMessage()).resolves.toEqual({
        id: "req-model-list",
        result: {
          models: [
            {
              id: "gpt-5.4",
              model: "gpt-5.4",
              displayName: "GPT-5.4",
              hidden: false,
              defaultReasoningEffort: "medium",
              supportedReasoningEfforts: [
                {
                  reasoningEffort: "medium",
                  description: "Balanced",
                },
              ],
              inputModalities: ["text"],
              supportsPersonality: true,
              isDefault: true,
            },
          ],
          nextCursor: "cursor-2",
        },
      });
    } finally {
      await client.close();
    }
  });

  test("maps protocol request IDs to agent request IDs before calling the adapter", async () => {
    const session = createFakeAgentSession({
      listModels: async () => ({
        ok: true,
        data: {
          models: [createTestAgentModel()],
          nextCursor: null,
        },
      }),
    });
    const harness = await createProtocolHarness({
      agentAdapters: [
        createFakeAgentAdapter({
          session,
        }),
      ],
    });
    const client = await connectProtocolClient(harness.port);

    try {
      await initializeClient(client);

      client.sendJson({
        id: "req-model-list",
        method: "model/list",
        params: {},
      });

      await client.nextMessage();

      expect(session.listModelsCalls).toHaveLength(1);
      expect(session.listModelsCalls[0]?.requestId).not.toBe("req-model-list");
      expect(session.listModelsCalls[0]?.requestId).toEqual(
        expect.stringMatching(/^atelier-appserver:model\/list:.*:req-model-list$/),
      );
    } finally {
      await client.close();
    }
  });

  test("rejects model/list before initialize", async () => {
    const harness = await createProtocolHarness();
    const client = await connectProtocolClient(harness.port);

    try {
      client.sendJson({
        id: "req-model-list",
        method: "model/list",
        params: {},
      });

      await expect(client.nextMessage()).resolves.toEqual({
        id: "req-model-list",
        error: {
          code: -33001,
          message: "Session not initialized",
          data: {
            code: "SESSION_NOT_INITIALIZED",
          },
        },
      });
    } finally {
      await client.close();
    }
  });

  test("maps malformed model/list params to invalid params", async () => {
    const harness = await createProtocolHarness();
    const client = await connectProtocolClient(harness.port);

    try {
      await initializeClient(client);

      client.sendJson({
        id: "req-model-list",
        method: "model/list",
        params: {
          limit: "twenty",
        },
      });

      await expect(client.nextMessage()).resolves.toEqual({
        id: "req-model-list",
        error: {
          code: -32602,
          message: "Invalid params",
        },
      });
    } finally {
      await client.close();
    }
  });

  test("filters hidden models by default", async () => {
    const harness = await createProtocolHarness({
      agentAdapters: [
        createFakeProtocolAgentAdapter({
          listModelsResult: {
            ok: true,
            data: {
              models: [
                createTestAgentModel(),
                createTestAgentModel({
                  id: "gpt-5.4-hidden",
                  model: "gpt-5.4-hidden",
                  displayName: "GPT-5.4 Hidden",
                  hidden: true,
                  defaultReasoningEffort: "high",
                  supportsPersonality: false,
                }),
              ],
              nextCursor: null,
            },
          },
        }),
      ],
    });
    const client = await connectProtocolClient(harness.port);

    try {
      await initializeClient(client);

      client.sendJson({
        id: "req-model-list",
        method: "model/list",
        params: {},
      });

      await expect(client.nextMessage()).resolves.toEqual({
        id: "req-model-list",
        result: {
          models: [createTestAgentModel()],
          nextCursor: null,
        },
      });
    } finally {
      await client.close();
    }
  });

  test("includes hidden models when requested", async () => {
    const harness = await createProtocolHarness({
      agentAdapters: [
        createFakeProtocolAgentAdapter({
          listModelsResult: {
            ok: true,
            data: {
              models: [
                createTestAgentModel(),
                createTestAgentModel({
                  id: "gpt-5.4-hidden",
                  model: "gpt-5.4-hidden",
                  displayName: "GPT-5.4 Hidden",
                  hidden: true,
                  defaultReasoningEffort: "high",
                  supportsPersonality: false,
                }),
              ],
              nextCursor: null,
            },
          },
        }),
      ],
    });
    const client = await connectProtocolClient(harness.port);

    try {
      await initializeClient(client);

      client.sendJson({
        id: "req-model-list",
        method: "model/list",
        params: {
          includeHidden: true,
        },
      });

      await expect(client.nextMessage()).resolves.toEqual({
        id: "req-model-list",
        result: {
          models: [
            createTestAgentModel(),
            createTestAgentModel({
              id: "gpt-5.4-hidden",
              model: "gpt-5.4-hidden",
              displayName: "GPT-5.4 Hidden",
              hidden: true,
              defaultReasoningEffort: "high",
              supportsPersonality: false,
            }),
          ],
          nextCursor: null,
        },
      });
    } finally {
      await client.close();
    }
  });

  test("maps agent session startup failures to agent session unavailable", async () => {
    const harness = await createProtocolHarness({
      agentAdapters: [
        createFakeProtocolAgentAdapter({
          createSessionResult: {
            ok: false,
            error: {
              type: "sessionUnavailable",
              agentId: "codex",
              provider: "codex",
              code: "startupFailed",
              message: "Codex failed to start.",
            },
          },
        }),
      ],
    });
    const client = await connectProtocolClient(harness.port);

    try {
      await initializeClient(client);

      client.sendJson({
        id: "req-model-list",
        method: "model/list",
        params: {},
      });

      await expect(client.nextMessage()).resolves.toEqual({
        id: "req-model-list",
        error: {
          code: -33004,
          message: "Agent session unavailable",
          data: {
            code: "AGENT_SESSION_UNAVAILABLE",
            agentId: "codex",
            provider: "codex",
            reason: "startupFailed",
            message: "Codex failed to start.",
          },
        },
      });
    } finally {
      await client.close();
    }
  });

  test("maps provider remote errors to provider error", async () => {
    const harness = await createProtocolHarness({
      agentAdapters: [
        createFakeProtocolAgentAdapter({
          listModelsResult: {
            ok: false,
            error: {
              type: "remoteError",
              agentId: "codex",
              provider: "codex",
              requestId: "req-model-list",
              code: 418,
              message: "Provider said no.",
            },
          },
        }),
      ],
    });
    const client = await connectProtocolClient(harness.port);

    try {
      await initializeClient(client);

      client.sendJson({
        id: "req-model-list",
        method: "model/list",
        params: {},
      });

      await expect(client.nextMessage()).resolves.toEqual({
        id: "req-model-list",
        error: {
          code: -33005,
          message: "Provider error",
          data: {
            code: "PROVIDER_ERROR",
            agentId: "codex",
            provider: "codex",
            providerCode: "418",
            providerMessage: "Provider said no.",
          },
        },
      });
    } finally {
      await client.close();
    }
  });

  test("opens a workspace after initialize", async () => {
    const harness = await createProtocolHarness();
    const client = await connectProtocolClient(harness.port);

    try {
      const workspacePath = await createWorkspaceDirectory();
      const canonicalWorkspacePath = await realpath(workspacePath);

      client.sendJson({
        id: "req-initialize",
        method: "initialize",
        params: {
          clientInfo: {
            name: "AtelierCode Test",
            version: "0.1.0",
          },
        },
      });
      await client.nextMessage();

      client.sendJson({
        id: "req-workspace-open",
        method: "workspace/open",
        params: {
          workspacePath,
        },
      });

      await expect(client.nextMessage()).resolves.toEqual({
        id: "req-workspace-open",
        result: {
          workspace: {
            id: expect.any(String),
            workspacePath: canonicalWorkspacePath,
            createdAt: expect.any(String),
            lastOpenedAt: expect.any(String),
          },
        },
      });
    } finally {
      await client.close();
    }
  });

  test("rejects workspace/open before initialize", async () => {
    const harness = await createProtocolHarness();
    const client = await connectProtocolClient(harness.port);

    try {
      const workspacePath = await createWorkspaceDirectory();

      client.sendJson({
        id: "req-workspace-open",
        method: "workspace/open",
        params: {
          workspacePath,
        },
      });

      await expect(client.nextMessage()).resolves.toEqual({
        id: "req-workspace-open",
        error: {
          code: -33001,
          message: "Session not initialized",
          data: {
            code: "SESSION_NOT_INITIALIZED",
          },
        },
      });
    } finally {
      await client.close();
    }
  });

  test("maps malformed workspace/open params to invalid params", async () => {
    const harness = await createProtocolHarness();
    const client = await connectProtocolClient(harness.port);

    try {
      client.sendJson({
        id: "req-initialize",
        method: "initialize",
        params: {
          clientInfo: {
            name: "AtelierCode Test",
            version: "0.1.0",
          },
        },
      });
      await client.nextMessage();

      client.sendJson({
        id: "req-workspace-open",
        method: "workspace/open",
        params: {
          workspacePath: 123,
        },
      });

      await expect(client.nextMessage()).resolves.toEqual({
        id: "req-workspace-open",
        error: {
          code: -32602,
          message: "Invalid params",
        },
      });
    } finally {
      await client.close();
    }
  });

  test("returns the same workspace identity for repeat opens of the same canonical directory", async () => {
    const harness = await createProtocolHarness();
    const client = await connectProtocolClient(harness.port);

    try {
      const workspacePath = await createWorkspaceDirectory();
      const canonicalWorkspacePath = await realpath(workspacePath);
      const aliasWorkspacePath = join(workspacePath, ".");

      client.sendJson({
        id: "req-initialize",
        method: "initialize",
        params: {
          clientInfo: {
            name: "AtelierCode Test",
            version: "0.1.0",
          },
        },
      });
      await client.nextMessage();

      client.sendJson({
        id: "req-workspace-open-1",
        method: "workspace/open",
        params: {
          workspacePath,
        },
      });
      const firstResponse = (await client.nextMessage()) as {
        readonly result: {
          readonly workspace: {
            readonly id: string;
            readonly workspacePath: string;
          };
        };
      };

      client.sendJson({
        id: "req-workspace-open-2",
        method: "workspace/open",
        params: {
          workspacePath: aliasWorkspacePath,
        },
      });
      const secondResponse = (await client.nextMessage()) as typeof firstResponse;

      expect(firstResponse.result.workspace.workspacePath).toBe(canonicalWorkspacePath);
      expect(secondResponse.result.workspace.workspacePath).toBe(canonicalWorkspacePath);
      expect(secondResponse.result.workspace.id).toBe(firstResponse.result.workspace.id);
    } finally {
      await client.close();
    }
  });

  test("lists threads after initialize and workspace/open", async () => {
    const workspacePath = await createWorkspaceDirectory();
    const canonicalWorkspacePath = await realpath(workspacePath);
    const harness = await createProtocolHarness({
      agentAdapters: [
        createFakeProtocolAgentAdapter({
          listThreadsResult: {
            ok: true,
            data: {
              threads: [
                createTestAgentThread({
                  id: "thread-1",
                  preview: "Ship thread browsing",
                  createdAt: "2026-04-10T10:00:00.000Z",
                  updatedAt: "2026-04-10T11:00:00.000Z",
                  workspacePath: canonicalWorkspacePath,
                  name: "Thread browsing",
                  archived: false,
                  status: { type: "active", activeFlags: ["running"] },
                }),
              ],
              nextCursor: "cursor-2",
            },
          },
        }),
      ],
    });
    const client = await connectProtocolClient(harness.port);

    try {
      await initializeClient(client);
      await openWorkspaceClient(client, workspacePath);

      client.sendJson({
        id: "req-thread-list",
        method: "thread/list",
        params: {
          limit: 20,
          archived: false,
        },
      });

      await expect(client.nextMessage()).resolves.toEqual({
        id: "req-thread-list",
        result: {
          threads: [
            {
              id: "thread-1",
              preview: "Ship thread browsing",
              createdAt: "2026-04-10T10:00:00.000Z",
              updatedAt: "2026-04-10T11:00:00.000Z",
              name: "Thread browsing",
              archived: false,
              status: {
                type: "active",
                activeFlags: ["running"],
              },
            },
          ],
          nextCursor: "cursor-2",
        },
      });
    } finally {
      await client.close();
    }
  });

  test("rejects thread/list before initialize", async () => {
    const harness = await createProtocolHarness();
    const client = await connectProtocolClient(harness.port);

    try {
      client.sendJson({
        id: "req-thread-list",
        method: "thread/list",
        params: {},
      });

      await expect(client.nextMessage()).resolves.toEqual({
        id: "req-thread-list",
        error: {
          code: -33001,
          message: "Session not initialized",
          data: {
            code: "SESSION_NOT_INITIALIZED",
          },
        },
      });
    } finally {
      await client.close();
    }
  });

  test("rejects thread/list before workspace/open", async () => {
    const harness = await createProtocolHarness();
    const client = await connectProtocolClient(harness.port);

    try {
      await initializeClient(client);

      client.sendJson({
        id: "req-thread-list",
        method: "thread/list",
        params: {},
      });

      await expect(client.nextMessage()).resolves.toEqual({
        id: "req-thread-list",
        error: {
          code: -33006,
          message: "Workspace not opened",
          data: {
            code: "WORKSPACE_NOT_OPENED",
          },
        },
      });
    } finally {
      await client.close();
    }
  });

  test("maps malformed thread/list params to invalid params", async () => {
    const workspacePath = await createWorkspaceDirectory();
    const harness = await createProtocolHarness();
    const client = await connectProtocolClient(harness.port);

    try {
      await initializeClient(client);
      await openWorkspaceClient(client, workspacePath);

      client.sendJson({
        id: "req-thread-list",
        method: "thread/list",
        params: {
          limit: "twenty",
        },
      });

      await expect(client.nextMessage()).resolves.toEqual({
        id: "req-thread-list",
        error: {
          code: -32602,
          message: "Invalid params",
        },
      });
    } finally {
      await client.close();
    }
  });

  test("preserves archive filtering and nextCursor on thread/list", async () => {
    const workspacePath = await createWorkspaceDirectory();
    const canonicalWorkspacePath = await realpath(workspacePath);
    const harness = await createProtocolHarness({
      agentAdapters: [
        createFakeProtocolAgentAdapter({
          listThreadsResult: {
            ok: true,
            data: {
              threads: [
                createTestAgentThread({
                  id: "thread-archived",
                  workspacePath: canonicalWorkspacePath,
                  archived: true,
                }),
              ],
              nextCursor: "archived-cursor",
            },
          },
        }),
      ],
    });
    const client = await connectProtocolClient(harness.port);

    try {
      await initializeClient(client);
      await openWorkspaceClient(client, workspacePath);

      client.sendJson({
        id: "req-thread-list",
        method: "thread/list",
        params: {
          archived: true,
        },
      });

      await expect(client.nextMessage()).resolves.toEqual({
        id: "req-thread-list",
        result: {
          threads: [
            {
              id: "thread-archived",
              preview: "Thread preview",
              createdAt: "2026-04-10T10:00:00.000Z",
              updatedAt: "2026-04-10T11:00:00.000Z",
              name: null,
              archived: true,
              status: {
                type: "idle",
              },
            },
          ],
          nextCursor: "archived-cursor",
        },
      });
    } finally {
      await client.close();
    }
  });

  test("reads thread metadata after initialize and workspace/open", async () => {
    const workspacePath = await createWorkspaceDirectory();
    const canonicalWorkspacePath = await realpath(workspacePath);
    const harness = await createProtocolHarness({
      agentAdapters: [
        createFakeProtocolAgentAdapter({
          readThreadResult: {
            ok: true,
            data: {
              thread: createTestAgentThread({
                id: "thread-1",
                preview: "Read me",
                workspacePath: canonicalWorkspacePath,
                name: "Readable thread",
                status: { type: "systemError", message: "Provider disconnected" },
              }),
            },
          },
        }),
      ],
    });
    const client = await connectProtocolClient(harness.port);

    try {
      await initializeClient(client);
      await openWorkspaceClient(client, workspacePath);

      client.sendJson({
        id: "req-thread-read",
        method: "thread/read",
        params: {
          threadId: "thread-1",
          includeTurns: false,
        },
      });

      await expect(client.nextMessage()).resolves.toEqual({
        id: "req-thread-read",
        result: {
          thread: {
            id: "thread-1",
            preview: "Read me",
            createdAt: "2026-04-10T10:00:00.000Z",
            updatedAt: "2026-04-10T11:00:00.000Z",
            name: "Readable thread",
            archived: false,
            status: {
              type: "systemError",
              message: "Provider disconnected",
            },
          },
        },
      });
    } finally {
      await client.close();
    }
  });

  test("rejects thread/read before workspace/open", async () => {
    const harness = await createProtocolHarness();
    const client = await connectProtocolClient(harness.port);

    try {
      await initializeClient(client);

      client.sendJson({
        id: "req-thread-read",
        method: "thread/read",
        params: {
          threadId: "thread-1",
          includeTurns: false,
        },
      });

      await expect(client.nextMessage()).resolves.toEqual({
        id: "req-thread-read",
        error: {
          code: -33006,
          message: "Workspace not opened",
          data: {
            code: "WORKSPACE_NOT_OPENED",
          },
        },
      });
    } finally {
      await client.close();
    }
  });

  test("maps malformed thread/read params to invalid params", async () => {
    const workspacePath = await createWorkspaceDirectory();
    const harness = await createProtocolHarness();
    const client = await connectProtocolClient(harness.port);

    try {
      await initializeClient(client);
      await openWorkspaceClient(client, workspacePath);

      client.sendJson({
        id: "req-thread-read",
        method: "thread/read",
        params: {
          threadId: 123,
        },
      });

      await expect(client.nextMessage()).resolves.toEqual({
        id: "req-thread-read",
        error: {
          code: -32602,
          message: "Invalid params",
        },
      });
    } finally {
      await client.close();
    }
  });

  test("returns an explicit error for thread/read includeTurns=true", async () => {
    const workspacePath = await createWorkspaceDirectory();
    const harness = await createProtocolHarness();
    const client = await connectProtocolClient(harness.port);

    try {
      await initializeClient(client);
      await openWorkspaceClient(client, workspacePath);

      client.sendJson({
        id: "req-thread-read",
        method: "thread/read",
        params: {
          threadId: "thread-1",
          includeTurns: true,
        },
      });

      await expect(client.nextMessage()).resolves.toEqual({
        id: "req-thread-read",
        error: {
          code: -33007,
          message: "Thread read with includeTurns=true is not supported yet",
          data: {
            code: "THREAD_READ_INCLUDE_TURNS_UNSUPPORTED",
          },
        },
      });
    } finally {
      await client.close();
    }
  });

  test("maps provider not-found behavior through the existing provider error path", async () => {
    const workspacePath = await createWorkspaceDirectory();
    const harness = await createProtocolHarness({
      agentAdapters: [
        createFakeProtocolAgentAdapter({
          readThreadResult: {
            ok: false,
            error: {
              type: "remoteError",
              agentId: "codex",
              provider: "codex",
              requestId: "req-thread-read",
              code: 404,
              message: "Thread not found",
            },
          },
        }),
      ],
    });
    const client = await connectProtocolClient(harness.port);

    try {
      await initializeClient(client);
      await openWorkspaceClient(client, workspacePath);

      client.sendJson({
        id: "req-thread-read",
        method: "thread/read",
        params: {
          threadId: "missing-thread",
          includeTurns: false,
        },
      });

      await expect(client.nextMessage()).resolves.toEqual({
        id: "req-thread-read",
        error: {
          code: -33005,
          message: "Provider error",
          data: {
            code: "PROVIDER_ERROR",
            agentId: "codex",
            provider: "codex",
            providerCode: "404",
            providerMessage: "Thread not found",
          },
        },
      });
    } finally {
      await client.close();
    }
  });

  test("returns a workspace mismatch error when thread/read crosses workspace boundaries", async () => {
    const workspacePath = await createWorkspaceDirectory();
    const harness = await createProtocolHarness({
      agentAdapters: [
        createFakeProtocolAgentAdapter({
          readThreadResult: {
            ok: true,
            data: {
              thread: createTestAgentThread({
                id: "thread-1",
                workspacePath: "/tmp/other-project",
              }),
            },
          },
        }),
      ],
    });
    const client = await connectProtocolClient(harness.port);

    try {
      await initializeClient(client);
      await openWorkspaceClient(client, workspacePath);

      client.sendJson({
        id: "req-thread-read",
        method: "thread/read",
        params: {
          threadId: "thread-1",
          includeTurns: false,
        },
      });

      await expect(client.nextMessage()).resolves.toEqual({
        id: "req-thread-read",
        error: {
          code: -33008,
          message: "Thread does not belong to the opened workspace",
          data: {
            code: "THREAD_WORKSPACE_MISMATCH",
            threadId: "thread-1",
            openedWorkspacePath: await realpath(workspacePath),
            threadWorkspacePath: "/tmp/other-project",
          },
        },
      });
    } finally {
      await client.close();
    }
  });
});

type ProtocolTestClient = Readonly<{
  sendText: (text: string) => void;
  sendJson: (value: unknown) => void;
  nextMessage: (timeoutMs?: number) => Promise<unknown>;
  close: () => Promise<void>;
}>;

const createProtocolHarness = async (
  options: Readonly<{
    agentAdapters?: readonly AgentAdapter[];
  }> = {},
): Promise<Readonly<{ port: number }>> => {
  const port = await getAvailablePort();
  const configDirectory = await createTemporaryDirectory("atelier-appserver-protocol-");
  const config = {
    configPath: join(configDirectory, "appserver.config.json"),
    port,
    databasePath: "./var/test.sqlite",
    logLevel: "info" as const,
    agents: createTestAgentsConfig(),
  };
  const logger = createLogger({
    level: "error",
    write: () => {},
  });
  const appProtocolRuntime = createAppProtocolRuntime({
    logger,
  });
  const storeBootstrap = createStoreBootstrap({
    config,
    logger: logger.withContext({ component: "core.store" }),
  });
  const workspacesModule = createWorkspacesModule({
    logger: logger.withContext({ component: "module.workspaces" }),
    registerMethod: appProtocolRuntime.registerMethod,
    store: createSqliteWorkspacesStore(storeBootstrap.getDatabase),
  });
  const agentsModule = createAgentsModule({
    config: config.agents,
    logger: logger.withContext({ component: "module.agents" }),
    adapters: options.agentAdapters ?? [
      createCodexAgentAdapter({
        logger: logger.withContext({ component: "agents.codex" }),
      }),
    ],
    registerMethod: appProtocolRuntime.registerMethod,
  });
  const threadsModule = createThreadsModule({
    logger: logger.withContext({ component: "module.threads" }),
    registerMethod: appProtocolRuntime.registerMethod,
    registry: agentsModule.registry,
    store: createSqliteThreadsStore(storeBootstrap.getDatabase),
    getOpenedWorkspace: workspacesModule.getOpenedWorkspace,
  });
  const transportComponent = createAppTransportComponent({
    config,
    logger,
    protocol: appProtocolRuntime,
    onConnectionClosed: [
      ({ connectionId }) => {
        workspacesModule.handleConnectionClosed(connectionId);
      },
    ],
  });
  const server = createConfiguredAppServer({
    config,
    logger,
    signalRegistrar: createSignalRegistrar(),
    components: [
      appProtocolRuntime.protocolComponent,
      storeBootstrap.lifecycle,
      agentsModule.lifecycle,
      workspacesModule.lifecycle,
      threadsModule.lifecycle,
      createTurnsModulePlaceholder(),
      createApprovalsModulePlaceholder(),
      transportComponent,
    ],
  });

  await server.start();
  runningServers.push(server);

  return Object.freeze({ port });
};

const createTestAgentsConfig = () => ({
  defaultAgent: "codex",
  enabled: [
    {
      id: "codex",
      provider: "codex" as const,
    },
  ],
});

const createWorkspaceDirectory = async (): Promise<string> => {
  const rootDirectory = await createTemporaryDirectory("atelier-appserver-workspace-");
  const workspacePath = join(rootDirectory, "workspace");

  await mkdir(workspacePath, { recursive: true });

  return workspacePath;
};

const initializeClient = async (client: ProtocolTestClient): Promise<void> => {
  client.sendJson({
    id: "req-initialize",
    method: "initialize",
    params: {
      clientInfo: {
        name: "AtelierCode Test",
        version: "0.1.0",
      },
    },
  });

  await expect(client.nextMessage()).resolves.toEqual({
    id: "req-initialize",
    result: {
      userAgent: APP_SERVER_USER_AGENT,
    },
  });
};

const openWorkspaceClient = async (
  client: ProtocolTestClient,
  workspacePath: string,
): Promise<void> => {
  client.sendJson({
    id: "req-workspace-open",
    method: "workspace/open",
    params: {
      workspacePath,
    },
  });

  await expect(client.nextMessage()).resolves.toMatchObject({
    id: "req-workspace-open",
    result: {
      workspace: {
        id: expect.any(String),
        workspacePath: await realpath(workspacePath),
      },
    },
  });
};

const connectProtocolClient = async (port: number): Promise<ProtocolTestClient> => {
  const socket = new WebSocket(`ws://127.0.0.1:${port}/`);
  const bufferedMessages: unknown[] = [];
  const pendingMessages: Array<{
    resolve: (message: unknown) => void;
    reject: (error: Error) => void;
    timer: ReturnType<typeof setTimeout>;
  }> = [];

  socket.addEventListener("message", (event) => {
    const text = toMessageText(event.data);
    const message = JSON.parse(text) as unknown;
    const nextMessage = pendingMessages.shift();

    if (nextMessage === undefined) {
      bufferedMessages.push(message);
      return;
    }

    clearTimeout(nextMessage.timer);
    nextMessage.resolve(message);
  });

  socket.addEventListener("close", () => {
    while (pendingMessages.length > 0) {
      const pendingMessage = pendingMessages.shift();

      if (pendingMessage === undefined) {
        continue;
      }

      clearTimeout(pendingMessage.timer);
      pendingMessage.reject(new Error("WebSocket closed before a message arrived"));
    }
  });

  await waitForSocketOpen(socket);

  return Object.freeze({
    sendText: (text) => {
      socket.send(text);
    },
    sendJson: (value) => {
      socket.send(JSON.stringify(value));
    },
    nextMessage: (timeoutMs = 1_000) => {
      const bufferedMessage = bufferedMessages.shift();

      if (bufferedMessage !== undefined) {
        return Promise.resolve(bufferedMessage);
      }

      return new Promise<unknown>((resolve, reject) => {
        const timer = setTimeout(() => {
          reject(new Error("Timed out waiting for message"));
        }, timeoutMs);

        pendingMessages.push({
          resolve,
          reject,
          timer,
        });
      });
    },
    close: async () => {
      if (socket.readyState === WebSocket.CLOSED) {
        return;
      }

      const closePromise = new Promise<void>((resolve) => {
        socket.addEventListener(
          "close",
          () => {
            resolve();
          },
          { once: true },
        );
      });

      socket.close();
      await closePromise;
    },
  });
};

const waitForSocketOpen = async (socket: WebSocket): Promise<void> => {
  if (socket.readyState === WebSocket.OPEN) {
    return;
  }

  await new Promise<void>((resolve, reject) => {
    const onOpen = () => {
      cleanup();
      resolve();
    };
    const onError = () => {
      cleanup();
      reject(new Error("WebSocket failed to open"));
    };
    const cleanup = () => {
      socket.removeEventListener("open", onOpen);
      socket.removeEventListener("error", onError);
    };

    socket.addEventListener("open", onOpen, { once: true });
    socket.addEventListener("error", onError, { once: true });
  });
};

const createFakeProtocolAgentAdapter = (options: {
  createSessionResult?:
    | Readonly<{
        ok: true;
        data: ReturnType<typeof createFakeAgentSession>;
      }>
    | Readonly<{
        ok: false;
        error: {
          type: "sessionUnavailable";
          agentId: string;
          provider: "codex";
          code: "executableMissing" | "startupFailed" | "disconnected";
          message: string;
        };
      }>;
  listModelsResult?:
    | Readonly<{
        ok: true;
        data: {
          models: readonly ReturnType<typeof createTestAgentModel>[];
          nextCursor: string | null;
        };
      }>
    | Readonly<{
        ok: false;
        error:
          | Readonly<{
              type: "remoteError";
              agentId: string;
              provider: "codex";
              requestId: string | number;
              code: number;
              message: string;
            }>
          | Readonly<{
              type: "invalidProviderMessage";
              agentId: string;
              provider: "codex";
              message: string;
            }>;
      }>;
  listThreadsResult?:
    | Readonly<{
        ok: true;
        data: {
          threads: readonly ReturnType<typeof createTestAgentThread>[];
          nextCursor: string | null;
        };
      }>
    | Readonly<{
        ok: false;
        error:
          | Readonly<{
              type: "remoteError";
              agentId: string;
              provider: "codex";
              requestId: string | number;
              code: number;
              message: string;
            }>
          | Readonly<{
              type: "invalidProviderMessage";
              agentId: string;
              provider: "codex";
              message: string;
            }>;
      }>;
  readThreadResult?:
    | Readonly<{
        ok: true;
        data: {
          thread: ReturnType<typeof createTestAgentThread>;
        };
      }>
    | Readonly<{
        ok: false;
        error:
          | Readonly<{
              type: "remoteError";
              agentId: string;
              provider: "codex";
              requestId: string | number;
              code: number;
              message: string;
            }>
          | Readonly<{
              type: "invalidProviderMessage";
              agentId: string;
              provider: "codex";
              message: string;
            }>;
      }>;
}): AgentAdapter =>
  createFakeAgentAdapter({
    createSessionResult: options.createSessionResult,
    session: createFakeAgentSession({
      listModels: async () =>
        options.listModelsResult ?? {
          ok: true,
          data: {
            models: [createTestAgentModel()],
            nextCursor: null,
          },
        },
      listThreads: async () =>
        options.listThreadsResult ?? {
          ok: true,
          data: {
            threads: [createTestAgentThread()],
            nextCursor: null,
          },
        },
      readThread: async () =>
        options.readThreadResult ?? {
          ok: true,
          data: {
            thread: createTestAgentThread(),
          },
        },
    }),
  });

const toMessageText = (data: unknown): string => {
  if (typeof data === "string") {
    return data;
  }

  if (data instanceof ArrayBuffer) {
    return new TextDecoder().decode(data);
  }

  if (ArrayBuffer.isView(data)) {
    return new TextDecoder().decode(data);
  }

  return String(data);
};

const createSignalRegistrar = (): SignalRegistrar =>
  Object.freeze({
    subscribe: () => () => {},
  });

const createTemporaryDirectory = async (prefix: string): Promise<string> => {
  const directory = await mkdtemp(join(tmpdir(), prefix));
  temporaryDirectories.push(directory);
  return directory;
};
