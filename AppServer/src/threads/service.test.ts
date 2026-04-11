import { describe, expect, test } from "bun:test";
import {
  createFakeAgentRegistry,
  createFakeAgentSession,
  createTestAgentThread,
} from "@/test-support/agents";
import { createSilentLogger } from "@/test-support/logger";
import { createThreadsService } from "@/threads/service";
import { createInMemoryThreadsStore } from "@/threads/store";

const workspace = Object.freeze({
  id: "workspace-1",
  workspacePath: "/tmp/project",
  createdAt: "2026-04-10T09:00:00.000Z",
  lastOpenedAt: "2026-04-10T09:00:00.000Z",
});

describe("createThreadsService", () => {
  test("scopes thread/list to the opened workspace and maps public thread metadata", async () => {
    const session = createFakeAgentSession({
      listThreads: async () => ({
        ok: true,
        data: {
          threads: [
            createTestAgentThread({
              id: "thread-1",
              preview: "Ship thread browsing",
              createdAt: "2026-04-10T10:00:00.000Z",
              updatedAt: "2026-04-10T11:00:00.000Z",
              workspacePath: "/tmp/project",
              name: "Thread browsing",
              archived: false,
              status: { type: "active", activeFlags: ["running"] },
            }),
          ],
          nextCursor: "cursor-2",
        },
      }),
    });
    const store = createInMemoryThreadsStore();
    const service = createThreadsService({
      logger: createSilentLogger("error"),
      registry: createFakeAgentRegistry(session),
      store,
      now: () => "2026-04-10T12:00:00.000Z",
    });

    const result = await service.listThreads("req-1", workspace, {
      archived: false,
      limit: 20,
    });

    expect(result).toEqual({
      ok: true,
      data: {
        threads: [
          {
            id: "thread-1",
            preview: "Ship thread browsing",
            createdAt: "2026-04-10T10:00:00.000Z",
            updatedAt: "2026-04-10T11:00:00.000Z",
            name: "Thread browsing",
            archived: false,
            status: { type: "active", activeFlags: ["running"] },
          },
        ],
        nextCursor: "cursor-2",
      },
    });
    expect(session.listThreadsCalls).toEqual([
      {
        requestId: "req-1",
        params: {
          archived: false,
          limit: 20,
          workspacePath: "/tmp/project",
        },
      },
    ]);
    await expect(
      store.listWorkspaceThreadLinks({
        workspaceId: "workspace-1",
        provider: "codex",
      }),
    ).resolves.toEqual([
      {
        workspaceId: "workspace-1",
        provider: "codex",
        threadId: "thread-1",
        threadWorkspacePath: "/tmp/project",
        archived: false,
        firstSeenAt: "2026-04-10T12:00:00.000Z",
        lastSeenAt: "2026-04-10T12:00:00.000Z",
      },
    ]);
  });

  test("returns an explicit domain error when thread/read requests turns", async () => {
    const session = createFakeAgentSession();
    const service = createThreadsService({
      logger: createSilentLogger("error"),
      registry: createFakeAgentRegistry(session),
      store: createInMemoryThreadsStore(),
    });

    const result = await service.readThread("req-1", workspace, {
      threadId: "thread-1",
      includeTurns: true,
    });

    expect(result).toMatchObject({
      ok: false,
      error: {
        code: -33007,
        message: "Thread read with includeTurns=true is not supported yet",
        data: {
          code: "THREAD_READ_INCLUDE_TURNS_UNSUPPORTED",
        },
      },
    });
    expect(session.readThreadCalls).toEqual([]);
  });

  test("returns a workspace mismatch error when provider metadata does not match the opened workspace", async () => {
    const session = createFakeAgentSession({
      readThread: async () => ({
        ok: true,
        data: {
          thread: createTestAgentThread({
            id: "thread-9",
            workspacePath: "/tmp/other-project",
          }),
        },
      }),
    });
    const service = createThreadsService({
      logger: createSilentLogger("error"),
      registry: createFakeAgentRegistry(session),
      store: createInMemoryThreadsStore(),
    });

    const result = await service.readThread("req-1", workspace, {
      threadId: "thread-9",
      includeTurns: false,
    });

    expect(result).toMatchObject({
      ok: false,
      error: {
        code: -33008,
        message: "Thread does not belong to the opened workspace",
        data: {
          code: "THREAD_WORKSPACE_MISMATCH",
          threadId: "thread-9",
          openedWorkspacePath: "/tmp/project",
          threadWorkspacePath: "/tmp/other-project",
        },
      },
    });
  });

  test("reuses stored archive linkage as a read hint and keeps linkage idempotent", async () => {
    const store = createInMemoryThreadsStore([
      {
        workspaceId: "workspace-1",
        provider: "codex",
        threadId: "thread-1",
        threadWorkspacePath: "/tmp/project",
        archived: true,
        firstSeenAt: "2026-04-10T09:30:00.000Z",
        lastSeenAt: "2026-04-10T09:30:00.000Z",
      },
    ]);
    const session = createFakeAgentSession({
      readThread: async () => ({
        ok: true,
        data: {
          thread: createTestAgentThread({
            id: "thread-1",
            workspacePath: "/tmp/project",
            archived: true,
          }),
        },
      }),
    });
    const service = createThreadsService({
      logger: createSilentLogger("error"),
      registry: createFakeAgentRegistry(session),
      store,
      now: () => "2026-04-10T12:00:00.000Z",
    });

    const result = await service.readThread("req-2", workspace, {
      threadId: "thread-1",
      includeTurns: false,
    });

    expect(result).toEqual({
      ok: true,
      data: {
        thread: {
          id: "thread-1",
          preview: "Thread preview",
          createdAt: "2026-04-10T10:00:00.000Z",
          updatedAt: "2026-04-10T11:00:00.000Z",
          name: null,
          archived: true,
          status: { type: "idle" },
        },
      },
    });
    expect(session.readThreadCalls).toEqual([
      {
        requestId: "req-2",
        params: {
          threadId: "thread-1",
          includeTurns: false,
          archived: true,
        },
      },
    ]);
    await expect(
      store.listWorkspaceThreadLinks({
        workspaceId: "workspace-1",
        provider: "codex",
      }),
    ).resolves.toEqual([
      {
        workspaceId: "workspace-1",
        provider: "codex",
        threadId: "thread-1",
        threadWorkspacePath: "/tmp/project",
        archived: true,
        firstSeenAt: "2026-04-10T09:30:00.000Z",
        lastSeenAt: "2026-04-10T12:00:00.000Z",
      },
    ]);
  });
});
