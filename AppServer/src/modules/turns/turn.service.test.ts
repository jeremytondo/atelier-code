import { describe, expect, test } from "bun:test";

import type { DomainError } from "../../core/shared/errors";
import type { ThreadRecord } from "../../core/shared/models";
import type { AppServerStore } from "../../core/store/store";
import { createThreadRecord } from "../threads/thread.entity";
import type { WorkspacePathAccess } from "../workspaces/workspace.service";
import { startTurn } from "./turn.service";

describe("turn service", () => {
  test("starts a turn by applying overrides before creating the turn", () => {
    const baseThread = createThreadRecord({
      id: "thread-1",
      workspaceId: "workspace-1",
      cwd: "/tmp/project",
      now: 123,
      ephemeral: false,
      model: "gpt-5.4-mini",
      modelProvider: "openai",
      serviceTier: null,
      approvalPolicy: "on-request",
      sandboxMode: "workspace-write",
      reasoningEffort: null,
    });

    const outcome = startTurn({
      store: createStore(baseThread),
      workspace: {
        id: "workspace-1",
        path: "/tmp/project",
        createdAt: 1,
        updatedAt: 1,
      },
      params: {
        threadId: "thread-1",
        cwd: "./nested",
        model: "gpt-5.4",
        serviceTier: "fast",
        approvalPolicy: "never",
        effort: "high",
        input: [
          {
            type: "text",
            text: "Ship phase 1",
            text_elements: [],
          },
        ],
      },
      workspacePaths: new FakeWorkspacePathAccess({
        "./nested": "/tmp/project/nested",
      }),
      ids: new CounterIdGenerator(),
      clock: new FixedClock(456),
    });

    expect(outcome.thread).toEqual({
      ...baseThread,
      preview: "Ship phase 1",
      updatedAt: 456,
      status: { type: "active", activeFlags: ["turnInProgress"] },
      cwd: "/tmp/project/nested",
      model: "gpt-5.4",
      serviceTier: "fast",
      approvalPolicy: "never",
      reasoningEffort: "high",
      turns: [outcome.turn],
    });
    expect(outcome.result.turn).toEqual({
      id: "turn-1",
      items: [],
      status: "inProgress",
      error: null,
    });
  });

  test("enforces thread ownership within the opened workspace", () => {
    const thread = createThreadRecord({
      id: "thread-1",
      workspaceId: "workspace-1",
      cwd: "/tmp/project-a",
      now: 123,
      ephemeral: false,
      model: "gpt-5.4-mini",
      modelProvider: "openai",
      serviceTier: null,
      approvalPolicy: "on-request",
      sandboxMode: "workspace-write",
      reasoningEffort: null,
    });

    expect(() =>
      startTurn({
        store: createStore(thread),
        workspace: {
          id: "workspace-2",
          path: "/tmp/project-b",
          createdAt: 1,
          updatedAt: 1,
        },
        params: {
          threadId: "thread-1",
          input: [
            {
              type: "text",
              text: "Wrong workspace",
              text_elements: [],
            },
          ],
        },
        workspacePaths: new FakeWorkspacePathAccess({}),
        ids: new CounterIdGenerator(),
        clock: new FixedClock(456),
      }),
    ).toThrow(
      expect.objectContaining({
        code: "thread_not_in_workspace",
      }) satisfies Partial<DomainError>,
    );
  });

  test("prevents overlapping active turns per thread", () => {
    const thread: ThreadRecord = {
      ...createThreadRecord({
        id: "thread-1",
        workspaceId: "workspace-1",
        cwd: "/tmp/project",
        now: 123,
        ephemeral: false,
        model: "gpt-5.4-mini",
        modelProvider: "openai",
        serviceTier: null,
        approvalPolicy: "on-request",
        sandboxMode: "workspace-write",
        reasoningEffort: null,
      }),
      turns: [
        {
          id: "turn-1",
          items: [],
          status: "inProgress",
          error: null,
        },
      ],
    };

    expect(() =>
      startTurn({
        store: createStore(thread),
        workspace: {
          id: "workspace-1",
          path: "/tmp/project",
          createdAt: 1,
          updatedAt: 1,
        },
        params: {
          threadId: "thread-1",
          input: [
            {
              type: "text",
              text: "Second request",
              text_elements: [],
            },
          ],
        },
        workspacePaths: new FakeWorkspacePathAccess({}),
        ids: new CounterIdGenerator(),
        clock: new FixedClock(456),
      }),
    ).toThrow(
      expect.objectContaining({
        code: "turn_already_active",
      }) satisfies Partial<DomainError>,
    );
  });
});

function createStore(thread: ThreadRecord): Pick<AppServerStore, "getThread"> {
  return {
    getThread: (threadId) => (threadId === thread.id ? thread : null),
  };
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

class FixedClock {
  constructor(private readonly value: number) {}

  now(): number {
    return this.value;
  }
}
