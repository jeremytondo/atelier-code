import { describe, expect, test } from "bun:test";

import {
  DEFAULT_MODEL,
  DEFAULT_MODEL_PROVIDER,
} from "../../core/config/defaults";
import type { DomainError } from "../../core/shared/errors";
import type { AppServerStore } from "../../core/store/store";
import type { WorkspacePathAccess } from "../workspaces/workspace.service";
import { requireThread, startThreadRecord } from "./thread.service";

describe("thread service", () => {
  test("starts a thread with workspace defaults and protocol result data", () => {
    const outcome = startThreadRecord({
      workspace: {
        id: "workspace-1",
        path: "/tmp/project",
        createdAt: 1,
        updatedAt: 1,
      },
      params: {
        experimentalRawEvents: false,
        persistExtendedHistory: false,
      },
      workspacePaths: new FakeWorkspacePathAccess({
        "/tmp/project": "/tmp/project",
      }),
      ids: new CounterIdGenerator(),
      clock: new FixedClock(1_700_000_000),
    });

    expect(outcome.thread).toEqual({
      id: "thread-1",
      workspaceId: "workspace-1",
      preview: "New thread",
      ephemeral: false,
      createdAt: 1_700_000_000,
      updatedAt: 1_700_000_000,
      status: { type: "idle" },
      cwd: "/tmp/project",
      model: DEFAULT_MODEL,
      modelProvider: DEFAULT_MODEL_PROVIDER,
      serviceTier: null,
      approvalPolicy: "on-request",
      sandboxMode: "workspace-write",
      reasoningEffort: null,
      name: null,
      turns: [],
    });
    expect(outcome.result).toEqual({
      thread: expect.objectContaining({
        id: "thread-1",
        workspaceId: "workspace-1",
        cwd: "/tmp/project",
        turns: [],
      }),
      model: DEFAULT_MODEL,
      modelProvider: DEFAULT_MODEL_PROVIDER,
      serviceTier: null,
      cwd: "/tmp/project",
      approvalPolicy: "on-request",
      sandbox: {
        type: "workspaceWrite",
        writableRoots: ["/tmp/project"],
        readOnlyAccess: {
          type: "fullAccess",
        },
        networkAccess: false,
        excludeTmpdirEnvVar: false,
        excludeSlashTmp: false,
      },
      reasoningEffort: null,
    });
  });

  test("resolves an explicit thread cwd through workspace path access", () => {
    const outcome = startThreadRecord({
      workspace: {
        id: "workspace-1",
        path: "/tmp/project",
        createdAt: 1,
        updatedAt: 1,
      },
      params: {
        experimentalRawEvents: false,
        persistExtendedHistory: false,
        cwd: "./nested",
        model: "gpt-5.4",
        modelProvider: "openai",
      },
      workspacePaths: new FakeWorkspacePathAccess({
        "./nested": "/tmp/project/nested",
      }),
      ids: new CounterIdGenerator(),
      clock: new FixedClock(1_700_000_000),
    });

    expect(outcome.thread.cwd).toBe("/tmp/project/nested");
    expect(outcome.thread.model).toBe("gpt-5.4");
    expect(outcome.thread.modelProvider).toBe("openai");
  });

  test("requires existing threads when loading them from the store", () => {
    expect(() =>
      requireThread(
        {
          getThread: () => null,
        } satisfies Pick<AppServerStore, "getThread">,
        "thread-missing",
      ),
    ).toThrow(
      expect.objectContaining({
        code: "thread_not_found",
      }) satisfies Partial<DomainError>,
    );
  });
});

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
