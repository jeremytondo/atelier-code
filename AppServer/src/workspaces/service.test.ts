import { afterEach, describe, expect, test } from "bun:test";
import { mkdir, mkdtemp, realpath, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createWorkspacesService } from "@/workspaces/service";
import { createInMemoryWorkspacesStore } from "@/workspaces/store";

const temporaryDirectories: string[] = [];

afterEach(async () => {
  while (temporaryDirectories.length > 0) {
    const directory = temporaryDirectories.pop();

    if (directory === undefined) {
      continue;
    }

    await rm(directory, { force: true, recursive: true });
  }
});

describe("createWorkspacesService", () => {
  test("treats canonical paths as the same workspace", async () => {
    const tempDirectory = await createTemporaryDirectory("atelier-appserver-workspaces-service-");
    const workspaceDirectory = join(tempDirectory, "workspace");
    const symlinkPath = join(tempDirectory, "workspace-link");
    const store = createInMemoryWorkspacesStore();
    const service = createWorkspacesService({
      store,
      createWorkspaceId: createIncrementingWorkspaceId(),
      now: createTimestampSequence(["2026-04-10T10:00:00.000Z", "2026-04-10T11:00:00.000Z"]),
    });

    await mkdir(workspaceDirectory, { recursive: true });
    await symlink(workspaceDirectory, symlinkPath);
    const canonicalWorkspacePath = await realpath(workspaceDirectory);

    const firstOpen = await service.openWorkspace({
      workspacePath: workspaceDirectory,
    });
    const secondOpen = await service.openWorkspace({
      workspacePath: symlinkPath,
    });

    expect(firstOpen).toEqual({
      ok: true,
      data: {
        id: "workspace-1",
        workspacePath: canonicalWorkspacePath,
        createdAt: "2026-04-10T10:00:00.000Z",
        lastOpenedAt: "2026-04-10T10:00:00.000Z",
      },
    });
    expect(secondOpen).toEqual({
      ok: true,
      data: {
        id: "workspace-1",
        workspacePath: canonicalWorkspacePath,
        createdAt: "2026-04-10T10:00:00.000Z",
        lastOpenedAt: "2026-04-10T11:00:00.000Z",
      },
    });
  });

  test("only generates a workspace id when a new workspace is created", async () => {
    const tempDirectory = await createTemporaryDirectory("atelier-appserver-workspaces-service-");
    const workspaceDirectory = join(tempDirectory, "workspace");
    let createWorkspaceIdCallCount = 0;
    const service = createWorkspacesService({
      store: createInMemoryWorkspacesStore(),
      createWorkspaceId: () => {
        createWorkspaceIdCallCount += 1;
        return "workspace-1";
      },
      now: createTimestampSequence(["2026-04-10T10:00:00.000Z", "2026-04-10T11:00:00.000Z"]),
    });

    await mkdir(workspaceDirectory, { recursive: true });

    await service.openWorkspace({
      workspacePath: workspaceDirectory,
    });
    await service.openWorkspace({
      workspacePath: workspaceDirectory,
    });

    expect(createWorkspaceIdCallCount).toBe(1);
  });

  test("returns a domain error when the workspace path does not exist", async () => {
    const service = createWorkspacesService({
      store: createInMemoryWorkspacesStore(),
    });

    const result = await service.openWorkspace({
      workspacePath: "/definitely/missing/workspace",
    });

    expect(result).toMatchObject({
      ok: false,
      error: {
        code: -33002,
        message: "Workspace path does not exist",
        data: {
          code: "WORKSPACE_PATH_NOT_FOUND",
          workspacePath: "/definitely/missing/workspace",
        },
      },
    });
  });

  test("returns a domain error when the workspace path points to a file", async () => {
    const tempDirectory = await createTemporaryDirectory("atelier-appserver-workspaces-service-");
    const workspaceFile = join(tempDirectory, "workspace.txt");
    const service = createWorkspacesService({
      store: createInMemoryWorkspacesStore(),
    });

    await writeFile(workspaceFile, "hello");
    const canonicalWorkspaceFile = await realpath(workspaceFile);

    const result = await service.openWorkspace({
      workspacePath: workspaceFile,
    });

    expect(result).toMatchObject({
      ok: false,
      error: {
        code: -33003,
        message: "Workspace path is not a directory",
        data: {
          code: "WORKSPACE_PATH_NOT_DIRECTORY",
          workspacePath: canonicalWorkspaceFile,
        },
      },
    });
  });
});

const createTimestampSequence = (timestamps: readonly string[]) => {
  let index = 0;

  return () => {
    const timestamp = timestamps[index] ?? timestamps[timestamps.length - 1];
    index += 1;
    return timestamp;
  };
};

const createIncrementingWorkspaceId = () => {
  let nextId = 1;

  return () => {
    const workspaceId = `workspace-${nextId}`;
    nextId += 1;
    return workspaceId;
  };
};

const createTemporaryDirectory = async (prefix: string): Promise<string> => {
  const directory = await mkdtemp(join(tmpdir(), prefix));
  temporaryDirectories.push(directory);
  return directory;
};
