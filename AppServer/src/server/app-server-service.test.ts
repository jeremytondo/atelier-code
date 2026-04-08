import { describe, expect, test } from "bun:test";

import {
  FakeAgentAdapter,
  type FakeAgentAdapterOptions,
} from "../agent-adapters/fake-agent-adapter";
import type { DomainError } from "../domain/errors";
import type { JsonRpcNotification } from "../protocol/types";
import { InMemoryAppServerStore } from "../store/in-memory-store";
import { AppServerService } from "./app-server-service";
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

function createHarness(options: FakeAgentAdapterOptions = {}) {
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
      new FakeAgentAdapter(options),
      new FakeWorkspacePathAccess([
        "/tmp/project",
        "/tmp/project-a",
        "/tmp/project-b",
      ]),
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
  constructor(private readonly directories: string[]) {}

  isDirectory(path: string): boolean {
    return this.directories.includes(path);
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
