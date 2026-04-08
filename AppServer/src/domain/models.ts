export interface WorkspaceRecord {
  id: string;
  path: string;
  createdAt: number;
  updatedAt: number;
}

export type ThreadActiveFlag = "turnInProgress" | "approvalPending";

export type ThreadStatusRecord =
  | { type: "notLoaded" }
  | { type: "idle" }
  | { type: "systemError" }
  | { type: "active"; activeFlags: ThreadActiveFlag[] };

export type TurnStatusRecord =
  | "completed"
  | "interrupted"
  | "failed"
  | "inProgress";

export interface TurnErrorRecord {
  code: string;
  message: string;
}

export interface TextInputRecord {
  type: "text";
  text: string;
  text_elements: [];
}

export interface ImageInputRecord {
  type: "image";
  url: string;
}

export interface LocalImageInputRecord {
  type: "localImage";
  path: string;
}

export interface SkillInputRecord {
  type: "skill";
  name: string;
  path: string;
}

export interface MentionInputRecord {
  type: "mention";
  name: string;
  path: string;
}

export type UserInputRecord =
  | TextInputRecord
  | ImageInputRecord
  | LocalImageInputRecord
  | SkillInputRecord
  | MentionInputRecord;

export type MessagePhaseRecord = "commentary" | "final_answer";

export interface UserMessageItemRecord {
  type: "userMessage";
  id: string;
  content: UserInputRecord[];
}

export interface AgentMessageItemRecord {
  type: "agentMessage";
  id: string;
  text: string;
  phase: MessagePhaseRecord | null;
}

export type ItemRecord = UserMessageItemRecord | AgentMessageItemRecord;

export interface TurnRecord {
  id: string;
  items: ItemRecord[];
  status: TurnStatusRecord;
  error: TurnErrorRecord | null;
}

export interface ThreadRecord {
  id: string;
  workspaceId: string;
  preview: string;
  createdAt: number;
  updatedAt: number;
  status: ThreadStatusRecord;
  cwd: string;
  model: string;
  modelProvider: string;
  serviceTier: ServiceTierRecord | null;
  approvalPolicy: ApprovalPolicyRecord;
  sandboxMode: SandboxModeRecord;
  reasoningEffort: ReasoningEffortRecord | null;
  name: string | null;
  turns: TurnRecord[];
}

export type ServiceTierRecord = "fast" | "flex";
export type ReasoningEffortRecord =
  | "none"
  | "minimal"
  | "low"
  | "medium"
  | "high"
  | "xhigh";
export type SandboxModeRecord =
  | "read-only"
  | "workspace-write"
  | "danger-full-access";
export interface ApprovalPolicyRejectRecord {
  sandbox_approval: boolean;
  rules: boolean;
  request_permissions: boolean;
  mcp_elicitations: boolean;
}
export type ApprovalPolicyRecord =
  | "untrusted"
  | "on-failure"
  | "on-request"
  | "never"
  | { reject: ApprovalPolicyRejectRecord };

export type ApprovalKindRecord = "command" | "fileChange" | "tool";
export type ApprovalResolutionRecord =
  | "approved"
  | "declined"
  | "cancelled"
  | "stale";
export type ApprovalStateRecord = "pending" | ApprovalResolutionRecord;

export interface ApprovalRequestRecord {
  id: string;
  threadId: string;
  turnId: string;
  itemId: string;
  kind: ApprovalKindRecord;
  state: ApprovalStateRecord;
}
