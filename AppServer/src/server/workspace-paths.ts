import { statSync } from "node:fs";

export interface WorkspacePathAccess {
  isDirectory(path: string): boolean;
}

export class NodeWorkspacePathAccess implements WorkspacePathAccess {
  isDirectory(path: string): boolean {
    try {
      return statSync(path).isDirectory();
    } catch {
      return false;
    }
  }
}
