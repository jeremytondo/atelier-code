import type {
  ApprovalRequestRecord,
  ThreadRecord,
  TurnRecord,
  WorkspaceRecord,
} from "../shared/models";

export interface AppServerStore {
  getWorkspaceById(id: string): WorkspaceRecord | null;
  getWorkspaceByPath(path: string): WorkspaceRecord | null;
  saveWorkspace(workspace: WorkspaceRecord): void;
  getThread(threadId: string): ThreadRecord | null;
  saveThread(thread: ThreadRecord): void;
  getTurn(threadId: string, turnId: string): TurnRecord | null;
  saveTurn(threadId: string, turn: TurnRecord): void;
  getApproval(approvalId: string): ApprovalRequestRecord | null;
  saveApproval(approval: ApprovalRequestRecord): void;
}
