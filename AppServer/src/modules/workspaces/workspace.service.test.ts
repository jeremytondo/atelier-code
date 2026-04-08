import { describe, expect, test } from "bun:test";

import type { DomainError } from "../../core/shared/errors";
import type { WorkspaceRecord } from "../../core/shared/models";
import type { AppServerStore } from "../../core/store/store";
import type { WorkspacePathAccess } from "./workspace.service";
import { openWorkspaceRecord } from "./workspace.service";

describe("workspace service", () => {
  test("canonicalizes workspace paths and reuses the same workspace id", () => {
    const workspaces = new Map<string, WorkspaceRecord>();
    const store: Pick<AppServerStore, "getWorkspaceByPath"> = {
      getWorkspaceByPath: (path) => workspaces.get(path) ?? null,
    };
    const workspacePaths = new FakeWorkspacePathAccess({
      "./project": "/tmp/project",
      "/tmp/project": "/tmp/project",
      "/tmp/project/": "/tmp/project",
      "/tmp/project-link": "/tmp/project",
    });
    const ids = new CounterIdGenerator();
    const clock = new SequenceClock(
      1_700_000_000,
      1_700_000_100,
      1_700_000_200,
    );

    const openedFromRelative = openWorkspaceRecord({
      store,
      workspacePaths,
      path: "./project",
      ids,
      clock,
    });
    workspaces.set(openedFromRelative.path, openedFromRelative);

    const openedFromTrailingSlash = openWorkspaceRecord({
      store,
      workspacePaths,
      path: "/tmp/project/",
      ids,
      clock,
    });
    const openedFromSymlink = openWorkspaceRecord({
      store,
      workspacePaths,
      path: "/tmp/project-link",
      ids,
      clock,
    });

    expect(openedFromRelative).toEqual({
      id: "workspace-1",
      path: "/tmp/project",
      createdAt: 1_700_000_000,
      updatedAt: 1_700_000_000,
    });
    expect(openedFromTrailingSlash.id).toBe("workspace-1");
    expect(openedFromTrailingSlash.path).toBe("/tmp/project");
    expect(openedFromTrailingSlash.updatedAt).toBe(1_700_000_100);
    expect(openedFromSymlink.id).toBe("workspace-1");
    expect(openedFromSymlink.path).toBe("/tmp/project");
    expect(openedFromSymlink.updatedAt).toBe(1_700_000_200);
  });

  test("rejects non-directory workspace paths", () => {
    expect(() =>
      openWorkspaceRecord({
        store: {
          getWorkspaceByPath: () => null,
        },
        workspacePaths: new FakeWorkspacePathAccess({}),
        path: "/tmp/missing",
        ids: new CounterIdGenerator(),
        clock: new SequenceClock(1),
      }),
    ).toThrow(
      expect.objectContaining({
        code: "invalid_workspace_path",
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

class SequenceClock {
  private index = 0;

  constructor(...values: number[]) {
    this.values = values;
  }

  private readonly values: number[];

  now(): number {
    const value =
      this.values[Math.min(this.index, this.values.length - 1)] ??
      this.values[0] ??
      0;
    this.index += 1;
    return value;
  }
}
