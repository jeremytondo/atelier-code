import type {
  ApprovalRequestRecord,
  ThreadRecord,
  TurnRecord,
  WorkspaceRecord,
} from "../domain/models";
import type { AppServerStore } from "./store";

export class InMemoryAppServerStore implements AppServerStore {
  private readonly workspacesById = new Map<string, WorkspaceRecord>();
  private readonly workspaceIdsByPath = new Map<string, string>();
  private readonly threadsById = new Map<string, ThreadRecord>();
  private readonly approvalsById = new Map<string, ApprovalRequestRecord>();

  getWorkspaceById(id: string): WorkspaceRecord | null {
    return this.workspacesById.get(id) ?? null;
  }

  getWorkspaceByPath(path: string): WorkspaceRecord | null {
    const workspaceId = this.workspaceIdsByPath.get(path);
    if (!workspaceId) {
      return null;
    }

    return this.workspacesById.get(workspaceId) ?? null;
  }

  saveWorkspace(workspace: WorkspaceRecord): void {
    this.workspacesById.set(workspace.id, workspace);
    this.workspaceIdsByPath.set(workspace.path, workspace.id);
  }

  getThread(threadId: string): ThreadRecord | null {
    return this.threadsById.get(threadId) ?? null;
  }

  saveThread(thread: ThreadRecord): void {
    this.threadsById.set(thread.id, thread);
  }

  getTurn(threadId: string, turnId: string): TurnRecord | null {
    const thread = this.getThread(threadId);
    if (!thread) {
      return null;
    }

    return thread.turns.find((turn) => turn.id === turnId) ?? null;
  }

  saveTurn(threadId: string, turn: TurnRecord): void {
    const thread = this.getThread(threadId);
    if (!thread) {
      return;
    }

    const existingTurnIndex = thread.turns.findIndex(
      (candidate) => candidate.id === turn.id,
    );
    if (existingTurnIndex === -1) {
      thread.turns.push(turn);
    } else {
      thread.turns[existingTurnIndex] = turn;
    }

    this.saveThread(thread);
  }

  getApproval(approvalId: string): ApprovalRequestRecord | null {
    return this.approvalsById.get(approvalId) ?? null;
  }

  saveApproval(approval: ApprovalRequestRecord): void {
    this.approvalsById.set(approval.id, approval);
  }
}
