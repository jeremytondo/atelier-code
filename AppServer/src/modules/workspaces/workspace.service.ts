import { realpathSync, statSync } from "node:fs";
import { resolve } from "node:path";

import { DomainError } from "../../core/shared/errors";
import type { IdGenerator } from "../../core/shared/id-generator";
import type { WorkspaceRecord } from "../../core/shared/models";
import type { AppServerStore } from "../../core/store/store";

interface Clock {
  now(): number;
}

export interface WorkspacePathAccess {
  resolveDirectory(path: string): string | null;
}

export class NodeWorkspacePathAccess implements WorkspacePathAccess {
  resolveDirectory(path: string): string | null {
    try {
      const resolvedPath = resolve(path);
      const canonicalPath = realpathSync.native(resolvedPath);
      return statSync(canonicalPath).isDirectory() ? canonicalPath : null;
    } catch {
      return null;
    }
  }
}

export interface OpenWorkspaceInput {
  store: Pick<AppServerStore, "getWorkspaceByPath">;
  workspacePaths: WorkspacePathAccess;
  path: string;
  ids: IdGenerator;
  clock: Clock;
}

export function openWorkspaceRecord(
  input: OpenWorkspaceInput,
): WorkspaceRecord {
  const workspacePath = requireDirectoryPath(
    input.workspacePaths,
    input.path,
    "invalid_workspace_path",
    "workspace/open requires an existing directory path.",
  );
  const existingWorkspace = input.store.getWorkspaceByPath(workspacePath);
  if (existingWorkspace) {
    return {
      ...existingWorkspace,
      updatedAt: input.clock.now(),
    };
  }

  const now = input.clock.now();
  return {
    id: input.ids.next("workspace"),
    path: workspacePath,
    createdAt: now,
    updatedAt: now,
  };
}

export function requireDirectoryPath(
  workspacePaths: WorkspacePathAccess,
  path: string,
  code: string,
  message: string,
): string {
  const resolvedPath = workspacePaths.resolveDirectory(path);
  if (resolvedPath === null) {
    throw new DomainError(code, message, { path });
  }

  return resolvedPath;
}
