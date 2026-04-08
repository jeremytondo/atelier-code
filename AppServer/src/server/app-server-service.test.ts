import { describe, expect, test } from "bun:test";

import type { AgentAdapter } from "../agent-adapters/agent-adapter";
import {
  FakeAgentAdapter,
  type FakeAgentAdapterOptions,
} from "../agent-adapters/fake-agent-adapter";
import type { DomainError } from "../domain/errors";
import type { JsonRpcNotification } from "../protocol/types";
import { InMemoryAppServerStore } from "../store/in-memory-store";
import { AppServerService } from "./app-server-service";
import { SERVER_VERSION } from "./server-metadata";
import type { SessionRecord } from "./session-state";
import type { WorkspacePathAccess } from "./workspace-paths";

describe("AppServerService", () => {
  test("requires initialize before workspace usage", () => {
    const { service, session } = createHarness();

    expect(() =>
      service.openWorkspace(session, {
        path: "/tmp/project",
      }),
    ).toThrow(
      expect.objectContaining({
        code: "not_initialized",
      }) satisfies Partial<DomainError>,
    );
  });

  test("requires an opened workspace before thread/start", () => {
    const { service, session, notifications } = createHarness();
    initialize(service, session);

    expect(() =>
      service.startThread(
        session,
        {
          experimentalRawEvents: false,
          persistExtendedHistory: false,
        },
        notifications,
      ),
    ).toThrow(
      expect.objectContaining({
        code: "workspace_not_opened",
      }) satisfies Partial<DomainError>,
    );
  });

  test("canonicalizes workspace paths and reuses the same workspace id", () => {
    const { service, session } = createHarness({
      directoryMappings: {
        "./project": "/tmp/project",
        "/tmp/project": "/tmp/project",
        "/tmp/project/": "/tmp/project",
        "/tmp/project-link": "/tmp/project",
      },
    });
    initialize(service, session);

    const openedFromRelative = service.openWorkspace(session, {
      path: "./project",
    }).result.workspace;
    const openedFromTrailingSlash = service.openWorkspace(session, {
      path: "/tmp/project/",
    }).result.workspace;
    const openedFromSymlink = service.openWorkspace(session, {
      path: "/tmp/project-link",
    }).result.workspace;

    expect(openedFromRelative).toEqual({
      id: "workspace-1",
      path: "/tmp/project",
      createdAt: 1_700_000_000,
      updatedAt: 1_700_000_000,
    });
    expect(openedFromTrailingSlash.id).toBe("workspace-1");
    expect(openedFromTrailingSlash.path).toBe("/tmp/project");
    expect(openedFromSymlink.id).toBe("workspace-1");
    expect(openedFromSymlink.path).toBe("/tmp/project");
  });

  test("enforces thread ownership within the current workspace", () => {
    const harness = createHarness();
    initialize(harness.service, harness.session);
    const firstWorkspace = harness.service.openWorkspace(harness.session, {
      path: "/tmp/project-a",
    }).result.workspace;
    const threadOutcome = harness.service.startThread(
      harness.session,
      {
        experimentalRawEvents: false,
        persistExtendedHistory: false,
      },
      harness.notifications,
    );
    expect(firstWorkspace.id).toBe("workspace-1");

    harness.service.openWorkspace(harness.session, {
      path: "/tmp/project-b",
    });

    expect(() =>
      harness.service.startTurn(
        harness.session,
        {
          threadId: threadOutcome.result.thread.id,
          input: [
            {
              type: "text",
              text: "Wrong workspace",
              text_elements: [],
            },
          ],
        },
        harness.notifications,
      ),
    ).toThrow(
      expect.objectContaining({
        code: "thread_not_in_workspace",
      }) satisfies Partial<DomainError>,
    );
  });

  test("prevents overlapping active turns per thread", () => {
    const { service, session, notifications } = createHarness();
    initialize(service, session);
    service.openWorkspace(session, {
      path: "/tmp/project",
    });
    const threadOutcome = service.startThread(
      session,
      {
        experimentalRawEvents: false,
        persistExtendedHistory: false,
      },
      notifications,
    );
    void threadOutcome.followUp?.();

    const firstTurn = service.startTurn(
      session,
      {
        threadId: threadOutcome.result.thread.id,
        input: [
          {
            type: "text",
            text: "First request",
            text_elements: [],
          },
        ],
      },
      notifications,
    );

    expect(() =>
      service.startTurn(
        session,
        {
          threadId: threadOutcome.result.thread.id,
          input: [
            {
              type: "text",
              text: "Second request",
              text_elements: [],
            },
          ],
        },
        notifications,
      ),
    ).toThrow(
      expect.objectContaining({
        code: "turn_already_active",
      }) satisfies Partial<DomainError>,
    );

    expect(firstTurn.result.turn.status).toBe("inProgress");
  });

  test("reuses stable IDs across turn responses and notifications", async () => {
    const { emitted, service, session, notifications } = createHarness();
    initialize(service, session);
    service.openWorkspace(session, {
      path: "/tmp/project",
    });
    const threadOutcome = service.startThread(
      session,
      {
        experimentalRawEvents: false,
        persistExtendedHistory: false,
      },
      notifications,
    );
    await threadOutcome.followUp?.();

    const turnOutcome = service.startTurn(
      session,
      {
        threadId: threadOutcome.result.thread.id,
        input: [
          {
            type: "text",
            text: "Ship phase 1",
            text_elements: [],
          },
        ],
      },
      notifications,
    );
    await turnOutcome.followUp?.();

    expect(turnOutcome.result.turn.id).toBe("turn-1");
    expect(emitted[0]).toEqual({
      method: "thread/started",
      params: {
        thread: expect.objectContaining({
          id: "thread-1",
          preview: "New thread",
          ephemeral: false,
          modelProvider: "fake-codex",
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
        }),
      },
    });
    expect(emitted[1]).toEqual({
      method: "turn/started",
      params: {
        threadId: "thread-1",
        turn: {
          id: "turn-1",
          items: [],
          status: "inProgress",
          error: null,
        },
      },
    });
    expect(emitted.at(-1)).toEqual({
      method: "turn/completed",
      params: {
        threadId: "thread-1",
        turn: {
          id: "turn-1",
          items: [],
          status: "completed",
          error: null,
        },
      },
    });
  });

  test("marks a started turn failed and emits turn/completed when follow-up execution throws", async () => {
    const { emitted, service, session, notifications, store } = createHarness({
      agentAdapter: new ThrowingAgentAdapter(),
    });
    initialize(service, session);
    service.openWorkspace(session, {
      path: "/tmp/project",
    });
    const threadOutcome = service.startThread(
      session,
      {
        experimentalRawEvents: false,
        persistExtendedHistory: false,
      },
      notifications,
    );
    await threadOutcome.followUp?.();

    const turnOutcome = service.startTurn(
      session,
      {
        threadId: threadOutcome.result.thread.id,
        input: [
          {
            type: "text",
            text: "Crash after response",
            text_elements: [],
          },
        ],
      },
      notifications,
    );
    await turnOutcome.followUp?.();

    const storedThread = store.getThread("thread-1");
    const storedTurn = store.getTurn("thread-1", "turn-1");

    expect(session.activeTurnId).toBeNull();
    expect(session.pendingRequestId).toBeNull();
    expect(storedThread?.status).toEqual({ type: "systemError" });
    expect(storedTurn).toEqual({
      id: "turn-1",
      items: [
        {
          type: "userMessage",
          id: "item-1",
          content: [
            {
              type: "text",
              text: "Crash after response",
              text_elements: [],
            },
          ],
        },
        {
          type: "agentMessage",
          id: "item-2",
          text: "",
          phase: "final_answer",
        },
      ],
      status: "failed",
      error: {
        message: "adapter boom",
        additionalDetails: expect.stringContaining("adapter boom"),
      },
    });
    expect(emitted.at(-1)).toEqual({
      method: "turn/completed",
      params: {
        threadId: "thread-1",
        turn: {
          id: "turn-1",
          items: [],
          status: "failed",
          error: {
            message: "adapter boom",
            codexErrorInfo: null,
            additionalDetails: expect.stringContaining("adapter boom"),
          },
        },
      },
    });
  });

  test("tracks pending approval scoping in memory", async () => {
    const { service, session, notifications, store } = createHarness({
      approvalScript: {
        kind: "tool",
        pauseAfterRequest: true,
      },
    });
    initialize(service, session);
    service.openWorkspace(session, {
      path: "/tmp/project",
    });
    const threadOutcome = service.startThread(
      session,
      {
        experimentalRawEvents: false,
        persistExtendedHistory: false,
      },
      notifications,
    );
    await threadOutcome.followUp?.();

    const turnOutcome = service.startTurn(
      session,
      {
        threadId: threadOutcome.result.thread.id,
        input: [
          {
            type: "text",
            text: "Needs approval",
            text_elements: [],
          },
        ],
      },
      notifications,
    );
    await turnOutcome.followUp?.();

    expect(session.activeTurnId).toBe("turn-1");
    expect(session.pendingRequestId).toBe("request-1");
    expect(store.getApproval("request-1")).toEqual({
      id: "request-1",
      threadId: "thread-1",
      turnId: "turn-1",
      itemId: "item-2",
      kind: "tool",
      state: "pending",
    });
  });
});

function createHarness(
  options: FakeAgentAdapterOptions & {
    agentAdapter?: AgentAdapter;
    directoryMappings?: Record<string, string>;
  } = {},
) {
  const emitted: JsonRpcNotification[] = [];
  const store = new InMemoryAppServerStore();
  const session: SessionRecord = {
    id: "session-1",
    initialized: false,
    clientInfo: null,
    optOutNotificationMethods: new Set<string>(),
    openedWorkspaceId: null,
    loadedThreadId: null,
    activeTurnId: null,
    pendingRequestId: null,
  };

  return {
    emitted,
    store,
    service: new AppServerService(
      store,
      options.agentAdapter ?? new FakeAgentAdapter(options),
      new FakeWorkspacePathAccess(
        options.directoryMappings ?? {
          "/tmp/project": "/tmp/project",
          "/tmp/project-a": "/tmp/project-a",
          "/tmp/project-b": "/tmp/project-b",
        },
      ),
      new CounterIdGenerator(),
      {
        now: () => 1_700_000_000,
      },
    ),
    session,
    notifications: {
      emit: async (notification: JsonRpcNotification) => {
        emitted.push(notification);
      },
    },
  };
}

function initialize(service: AppServerService, session: SessionRecord): void {
  service.initialize(session, {
    clientInfo: {
      name: "Harness",
      title: null,
      version: "1.0.0",
    },
    capabilities: {
      experimentalApi: true,
    },
  });
}

class FakeWorkspacePathAccess implements WorkspacePathAccess {
  constructor(private readonly directoryMappings: Record<string, string>) {}

  resolveDirectory(path: string): string | null {
    return this.directoryMappings[path] ?? null;
  }
}

class CounterIdGenerator {
  private readonly counters = new Map<string, number>();

  next(prefix: string): string {
    const nextValue = (this.counters.get(prefix) ?? 0) + 1;
    this.counters.set(prefix, nextValue);
    return `${prefix}-${nextValue}`;
  }
}

class ThrowingAgentAdapter implements AgentAdapter {
  async *streamTurn() {
    yield {
      type: "itemStarted" as const,
      item: {
        type: "agentMessage" as const,
        id: "item-2",
        text: "",
        phase: "final_answer" as const,
      },
    };

    throw new Error("adapter boom");
  }
}
