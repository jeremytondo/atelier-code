import { realpath } from "node:fs/promises";
import { resolve } from "node:path";

export type WorkspacePathNormalizer = (workspacePath: string) => Promise<string>;

export const normalizeWorkspacePath: WorkspacePathNormalizer = async (workspacePath) => {
  try {
    return await realpath(workspacePath);
  } catch {
    return resolve(workspacePath);
  }
};
