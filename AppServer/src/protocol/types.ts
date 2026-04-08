import type {
  ApprovalPolicyRecord,
  ItemRecord,
  ReasoningEffortRecord,
  SandboxModeRecord,
  ServiceTierRecord,
  ThreadRecord,
  TurnRecord,
  UserInputRecord,
  WorkspaceRecord,
} from "../domain/models";

export type RequestId = string | number;

export interface ClientInfo {
  name: string;
  title: string | null;
  version: string;
}

export interface InitializeCapabilities {
  experimentalApi: boolean;
  optOutNotificationMethods?: string[] | null;
}

export interface JsonRpcRequest {
  id: RequestId;
  method: string;
  params?: unknown;
}

export interface JsonRpcSuccessResponse<TResult = unknown> {
  id: RequestId;
  result: TResult;
}

export interface JsonRpcErrorData {
  code: string;
  [key: string]: string | number | boolean | null | undefined;
}

export interface JsonRpcErrorObject {
  code: number;
  message: string;
  data?: JsonRpcErrorData;
}

export interface JsonRpcErrorResponse {
  id: RequestId | null;
  error: JsonRpcErrorObject;
}

export interface JsonRpcNotification<TParams = unknown> {
  method: string;
  params: TParams;
}

export interface InitializeParams {
  clientInfo: ClientInfo;
  capabilities: InitializeCapabilities | null;
}

export interface InitializeResult {
  userAgent: string;
}

export interface WorkspaceOpenParams {
  path: string;
}

export interface WorkspaceOpenResult {
  workspace: WorkspaceRecord;
}

export interface ThreadStartParams {
  model?: string | null;
  modelProvider?: string | null;
  serviceTier?: ServiceTierRecord | null;
  cwd?: string | null;
  approvalPolicy?: ApprovalPolicyRecord | null;
  sandbox?: SandboxModeRecord | null;
  config?: Record<string, unknown> | null;
  serviceName?: string | null;
  baseInstructions?: string | null;
  developerInstructions?: string | null;
  personality?: string | null;
  ephemeral?: boolean | null;
  dynamicTools?: unknown[] | null;
  mockExperimentalField?: string | null;
  experimentalRawEvents: boolean;
  persistExtendedHistory: boolean;
}

export interface ThreadStartResult {
  thread: ProtocolThread;
  model: string;
  modelProvider: string;
  serviceTier: ServiceTierRecord | null;
  cwd: string;
  approvalPolicy: ApprovalPolicyRecord;
  sandbox: SandboxModeRecord;
  reasoningEffort: ReasoningEffortRecord | null;
}

export interface TurnStartParams {
  threadId: string;
  input: UserInputRecord[];
  cwd?: string | null;
  approvalPolicy?: ApprovalPolicyRecord | null;
  sandboxPolicy?: unknown;
  model?: string | null;
  serviceTier?: ServiceTierRecord | null;
  effort?: ReasoningEffortRecord | null;
  summary?: unknown;
  personality?: string | null;
  outputSchema?: unknown;
  collaborationMode?: unknown;
}

export interface TurnStartResult {
  turn: ProtocolTurn;
}

export interface ThreadStartedNotification {
  thread: ProtocolThread;
}

export interface TurnStartedNotification {
  threadId: string;
  turn: ProtocolTurn;
}

export interface ItemStartedNotification {
  threadId: string;
  turnId: string;
  item: ProtocolItem;
}

export interface AgentMessageDeltaNotification {
  threadId: string;
  turnId: string;
  itemId: string;
  delta: string;
}

export interface ItemCompletedNotification {
  threadId: string;
  turnId: string;
  item: ProtocolItem;
}

export interface TurnCompletedNotification {
  threadId: string;
  turn: ProtocolTurn;
}

export type SupportedRequestMethod =
  | "initialize"
  | "workspace/open"
  | "thread/start"
  | "turn/start";

export type SupportedNotificationMethod =
  | "thread/started"
  | "turn/started"
  | "item/started"
  | "item/agentMessage/delta"
  | "item/completed"
  | "turn/completed";

export type ProtocolItem = ItemRecord;

export interface ProtocolTurn {
  id: TurnRecord["id"];
  items: [];
  status: TurnRecord["status"];
  error: TurnRecord["error"];
}

export interface ProtocolThread {
  id: ThreadRecord["id"];
  workspaceId: ThreadRecord["workspaceId"];
  preview: ThreadRecord["preview"];
  createdAt: ThreadRecord["createdAt"];
  updatedAt: ThreadRecord["updatedAt"];
  status: ThreadRecord["status"];
  cwd: ThreadRecord["cwd"];
  modelProvider: ThreadRecord["modelProvider"];
  name: ThreadRecord["name"];
  turns: [];
}
