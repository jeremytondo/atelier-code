import { realpathSync, statSync } from "node:fs";
import { resolve } from "node:path";

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
