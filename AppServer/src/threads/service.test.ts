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
  test("scopes thread/list to the opened workspace and surfaces stored defaults", async () => {
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
    const store = createInMemoryThreadsStore([
      {
        workspaceId: "workspace-1",
        provider: "codex",
        threadId: "thread-1",
        threadWorkspacePath: "/tmp/project",
        archived: false,
        model: "gpt-5.4",
        reasoningEffort: "medium",
        firstSeenAt: "2026-04-10T09:30:00.000Z",
        lastSeenAt: "2026-04-10T09:30:00.000Z",
      },
    ]);
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
            model: "gpt-5.4",
            reasoningEffort: "medium",
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
  });

  test("starts a thread, persists resolved defaults, and returns the public thread shape", async () => {
    const session = createFakeAgentSession({
      startThread: async () => ({
        ok: true,
        data: {
          thread: createTestAgentThread({
            id: "thread-2",
            workspacePath: "/tmp/project",
            status: { type: "idle" },
          }),
          model: "gpt-5.4",
          reasoningEffort: "high",
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

    const result = await service.startThread("req-start", workspace, {
      reasoningEffort: "high",
    });

    expect(result).toEqual({
      ok: true,
      data: {
        thread: {
          id: "thread-2",
          preview: "Thread preview",
          createdAt: "2026-04-10T10:00:00.000Z",
          updatedAt: "2026-04-10T11:00:00.000Z",
          name: null,
          archived: false,
          model: "gpt-5.4",
          reasoningEffort: "high",
          status: { type: "idle" },
        },
      },
    });
    expect(session.startThreadCalls).toEqual([
      {
        requestId: "req-start",
        params: {
          workspacePath: "/tmp/project",
          reasoningEffort: "high",
        },
      },
    ]);
    await expect(
      store.getWorkspaceThreadLink({
        workspaceId: "workspace-1",
        provider: "codex",
        threadId: "thread-2",
      }),
    ).resolves.toMatchObject({
      model: "gpt-5.4",
      reasoningEffort: "high",
    });
  });

  test("resumes a thread using stored defaults when the request omits overrides", async () => {
    const store = createInMemoryThreadsStore([
      {
        workspaceId: "workspace-1",
        provider: "codex",
        threadId: "thread-1",
        threadWorkspacePath: "/tmp/project",
        archived: true,
        model: "gpt-5.4-mini",
        reasoningEffort: "low",
        firstSeenAt: "2026-04-10T09:30:00.000Z",
        lastSeenAt: "2026-04-10T09:30:00.000Z",
      },
    ]);
    const session = createFakeAgentSession({
      resumeThread: async () => ({
        ok: true,
        data: {
          thread: createTestAgentThread({
            id: "thread-1",
            workspacePath: "/tmp/project",
            archived: true,
            status: { type: "idle" },
          }),
          model: "gpt-5.4-mini",
          reasoningEffort: "low",
        },
      }),
    });
    const service = createThreadsService({
      logger: createSilentLogger("error"),
      registry: createFakeAgentRegistry(session),
      store,
      now: () => "2026-04-10T12:00:00.000Z",
    });

    const result = await service.resumeThread("req-resume", workspace, {
      threadId: "thread-1",
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
          model: "gpt-5.4-mini",
          reasoningEffort: "low",
          status: { type: "idle" },
        },
      },
    });
    expect(session.resumeThreadCalls).toEqual([
      {
        requestId: "req-resume",
        params: {
          threadId: "thread-1",
          workspacePath: "/tmp/project",
          model: "gpt-5.4-mini",
          reasoningEffort: "low",
        },
      },
    ]);
  });

  test("lets explicit resume overrides win over stored defaults", async () => {
    const store = createInMemoryThreadsStore([
      {
        workspaceId: "workspace-1",
        provider: "codex",
        threadId: "thread-1",
        threadWorkspacePath: "/tmp/project",
        archived: false,
        model: "gpt-5.4-mini",
        reasoningEffort: "low",
        firstSeenAt: "2026-04-10T09:30:00.000Z",
        lastSeenAt: "2026-04-10T09:30:00.000Z",
      },
    ]);
    const session = createFakeAgentSession({
      resumeThread: async () => ({
        ok: true,
        data: {
          thread: createTestAgentThread({
            id: "thread-1",
            workspacePath: "/tmp/project",
          }),
          model: "gpt-5.4",
          reasoningEffort: null,
        },
      }),
    });
    const service = createThreadsService({
      logger: createSilentLogger("error"),
      registry: createFakeAgentRegistry(session),
      store,
      now: () => "2026-04-10T12:00:00.000Z",
    });

    const result = await service.resumeThread("req-resume", workspace, {
      threadId: "thread-1",
      model: "gpt-5.4",
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
          archived: false,
          model: "gpt-5.4",
          reasoningEffort: "low",
          status: { type: "idle" },
        },
      },
    });
    await expect(
      store.getWorkspaceThreadLink({
        workspaceId: "workspace-1",
        provider: "codex",
        threadId: "thread-1",
      }),
    ).resolves.toMatchObject({
      model: "gpt-5.4",
      reasoningEffort: "low",
    });
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
    expect(session.resumeThreadCalls).toEqual([]);
  });

  test("thread/read stays point-in-time and surfaces stored defaults", async () => {
    const store = createInMemoryThreadsStore([
      {
        workspaceId: "workspace-1",
        provider: "codex",
        threadId: "thread-1",
        threadWorkspacePath: "/tmp/project",
        archived: true,
        model: "gpt-5.4",
        reasoningEffort: null,
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

    const result = await service.readThread("req-read", workspace, {
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
          model: "gpt-5.4",
          reasoningEffort: null,
          status: { type: "idle" },
        },
      },
    });
    expect(session.readThreadCalls).toEqual([
      {
        requestId: "req-read",
        params: {
          threadId: "thread-1",
          includeTurns: false,
          archived: true,
        },
      },
    ]);
    expect(session.resumeThreadCalls).toEqual([]);
  });

  test("returns a workspace mismatch error when provider metadata does not match the opened workspace", async () => {
    const session = createFakeAgentSession({
      resumeThread: async () => ({
        ok: true,
        data: {
          thread: createTestAgentThread({
            id: "thread-9",
            workspacePath: "/tmp/other-project",
          }),
          model: "gpt-5.4",
          reasoningEffort: "medium",
        },
      }),
    });
    const service = createThreadsService({
      logger: createSilentLogger("error"),
      registry: createFakeAgentRegistry(session),
      store: createInMemoryThreadsStore(),
    });

    const result = await service.resumeThread("req-1", workspace, {
      threadId: "thread-9",
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
});
