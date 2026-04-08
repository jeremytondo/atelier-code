import { afterEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, relative } from "node:path";

import { NodeWorkspacePathAccess } from "./workspace.paths";

describe("NodeWorkspacePathAccess", () => {
  const tempDirectories: string[] = [];

  afterEach(() => {
    for (const directory of tempDirectories.splice(0)) {
      rmSync(directory, { force: true, recursive: true });
    }
  });

  test("resolves relative, trailing-slash, and symlink paths to one canonical directory", () => {
    const tempRoot = mkdtempSync(join(tmpdir(), "app-server-workspace-paths-"));
    tempDirectories.push(tempRoot);

    const workspace = join(tempRoot, "workspace");
    const workspaceLink = join(tempRoot, "workspace-link");
    mkdirSync(workspace);
    symlinkSync(workspace, workspaceLink);

    const relativePath = relative(process.cwd(), workspace);
    const access = new NodeWorkspacePathAccess();

    const canonicalPath = access.resolveDirectory(workspace);

    expect(canonicalPath).not.toBeNull();
    expect(access.resolveDirectory(relativePath)).toBe(canonicalPath);
    expect(access.resolveDirectory(`${workspace}/`)).toBe(canonicalPath);
    expect(access.resolveDirectory(workspaceLink)).toBe(canonicalPath);
  });

  test("returns null for missing directories", () => {
    const access = new NodeWorkspacePathAccess();

    expect(access.resolveDirectory("/tmp/ateliercode-missing-workspace")).toBe(
      null,
    );
  });
});
