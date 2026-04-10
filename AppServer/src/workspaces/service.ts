import { realpath, stat } from "node:fs/promises";
import {
  createWorkspacePathNotDirectoryResult,
  createWorkspacePathNotFoundResult,
  type ProtocolMethodError,
} from "@/core/protocol/errors";
import { ok, type Result } from "@/core/shared";
import type { Workspace, WorkspaceOpenParams } from "@/workspaces/schemas";
import type { WorkspacesStore } from "@/workspaces/store";

export type WorkspacesService = Readonly<{
  openWorkspace: (params: WorkspaceOpenParams) => Promise<Result<Workspace, ProtocolMethodError>>;
}>;

export type CreateWorkspacesServiceOptions = Readonly<{
  store: WorkspacesStore;
  createWorkspaceId?: () => string;
  now?: () => string;
  realpathPath?: typeof realpath;
  statPath?: typeof stat;
}>;

export const createWorkspacesService = (
  options: CreateWorkspacesServiceOptions,
): WorkspacesService => {
  const createWorkspaceId = options.createWorkspaceId ?? (() => crypto.randomUUID());
  const now = options.now ?? (() => new Date().toISOString());
  const resolveRealPath = options.realpathPath ?? realpath;
  const readPathStats = options.statPath ?? stat;

  return Object.freeze({
    openWorkspace: async (params) => {
      const canonicalWorkspacePath = await canonicalizeWorkspacePath(
        params.workspacePath,
        resolveRealPath,
        readPathStats,
      );

      if (!canonicalWorkspacePath.ok) {
        return canonicalWorkspacePath;
      }

      const openedAt = now();
      const workspace = await options.store.openWorkspace({
        workspaceId: createWorkspaceId(),
        workspacePath: canonicalWorkspacePath.data,
        openedAt,
      });

      return ok(workspace);
    },
  });
};

const canonicalizeWorkspacePath = async (
  workspacePath: string,
  resolveRealPath: typeof realpath,
  readPathStats: typeof stat,
): Promise<Result<string, ProtocolMethodError>> => {
  let canonicalWorkspacePath: string;

  try {
    canonicalWorkspacePath = await resolveRealPath(workspacePath);
  } catch {
    return createWorkspacePathNotFoundResult(workspacePath);
  }

  try {
    const pathStats = await readPathStats(canonicalWorkspacePath);

    if (!pathStats.isDirectory()) {
      return createWorkspacePathNotDirectoryResult(canonicalWorkspacePath);
    }
  } catch {
    return createWorkspacePathNotFoundResult(workspacePath);
  }

  return ok(canonicalWorkspacePath);
};
