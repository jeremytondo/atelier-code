import type { Result } from "@/core/shared";

export type AgentProvider = "codex";
export type AgentRequestId = string | number;
export type AgentReasoningEffort = "none" | "minimal" | "low" | "medium" | "high" | "xhigh";

export type AgentEnvironmentSource = "inherited" | "login_probe" | "fallback";
export type AgentExecutableDiscoveryStatus = "found" | "missing";
export type AgentExecutableDiscoverySource = "environment" | "path" | "known-path" | "not-found";

export type AgentSessionState = "idle" | "connecting" | "ready" | "disconnecting" | "disconnected";

export type AgentDisconnectReason =
  | "requested_disconnect"
  | "app_socket_disconnected"
  | "provider_executable_missing"
  | "startup_failed"
  | "process_exited"
  | "request_timeout"
  | "malformed_output";

export type AgentEnvironmentDiagnostics = Readonly<{
  source: AgentEnvironmentSource;
  shellPath: string;
  probeError: string | null;
  pathDirectoryCount: number;
  homeDirectory: string | null;
}>;

export type AgentExecutableDiscovery = Readonly<{
  executableName: string;
  status: AgentExecutableDiscoveryStatus;
  resolvedPath: string | null;
  source: AgentExecutableDiscoverySource;
  baseEnvironmentSource: AgentEnvironmentSource;
  checkedPaths: readonly string[];
}>;

export type AgentModelReasoningEffort = Readonly<{
  reasoningEffort: AgentReasoningEffort;
  description?: string;
}>;

export type AgentModelSummary = Readonly<{
  id: string;
  model: string;
  displayName: string;
  hidden: boolean;
  defaultReasoningEffort?: AgentReasoningEffort;
  supportedReasoningEfforts: readonly AgentModelReasoningEffort[];
  inputModalities?: readonly string[];
  supportsPersonality?: boolean;
  isDefault: boolean;
}>;

export type AgentThreadExecutionStatus =
  | Readonly<{ type: "notLoaded" }>
  | Readonly<{ type: "idle" }>
  | Readonly<{ type: "active"; activeFlags: readonly string[] }>
  | Readonly<{ type: "systemError"; message?: string }>;

export type AgentTurnStatus =
  | Readonly<{ type: "inProgress" }>
  | Readonly<{ type: "awaitingInput" }>
  | Readonly<{ type: "completed" }>
  | Readonly<{ type: "failed"; message?: string }>
  | Readonly<{ type: "cancelled" }>
  | Readonly<{ type: "interrupted" }>;

export type AgentThreadSummary = Readonly<{
  id: string;
  preview: string;
  updatedAt: string;
  name: string | null;
  archived: boolean;
  status: AgentThreadExecutionStatus;
}>;

export type AgentTurnSummary = Readonly<{
  id: string;
  status: AgentTurnStatus;
}>;

export type AgentPlanStep = Readonly<{
  step: string;
  status: "pending" | "in_progress" | "completed";
}>;

export type AgentDiffFileSummary = Readonly<{
  path: string;
  additions: number;
  deletions: number;
}>;

export type AgentApprovalKind = "commandExecution" | "fileChange" | "mcpElicitation" | "unknown";

export type AgentApprovalRequest = Readonly<{
  requestId: AgentRequestId;
  kind: AgentApprovalKind;
  threadId?: string;
  turnId?: string;
  itemId?: string;
  rawRequest: unknown;
}>;

export type AgentApprovalResolution =
  | "approved"
  | "approvedForSession"
  | "declined"
  | "cancelled"
  | "stale";

export type AgentNotificationBase = Readonly<{
  agentId: string;
  provider: AgentProvider;
  receivedAt: string;
  rawMethod: string;
  rawPayload?: unknown;
  threadId?: string;
  turnId?: string;
  itemId?: string;
}>;

export type AgentThreadNotification = AgentNotificationBase &
  Readonly<{
    type: "thread";
    event: "started" | "statusChanged" | "archived" | "unarchived" | "closed";
    thread: AgentThreadSummary;
  }>;

export type AgentTurnNotification = AgentNotificationBase &
  Readonly<{
    type: "turn";
    event: "started" | "completed";
    turn: AgentTurnSummary;
  }>;

export type AgentItemNotification = AgentNotificationBase &
  Readonly<{
    type: "item";
    event: "started" | "completed";
    item: Readonly<{
      id: string;
      kind: string;
      rawItem: unknown;
    }>;
  }>;

export type AgentReasoningNotification = AgentNotificationBase &
  Readonly<{
    type: "reasoning";
    event: "summaryTextDelta" | "summaryPartAdded" | "textDelta";
    delta?: string;
    summaryPart?: unknown;
  }>;

export type AgentPlanNotification = AgentNotificationBase &
  Readonly<{
    type: "plan";
    event: "updated";
    explanation?: string;
    steps: readonly AgentPlanStep[];
  }>;

export type AgentDiffNotification = AgentNotificationBase &
  Readonly<{
    type: "diff";
    event: "updated";
    diff: string;
    summary: readonly AgentDiffFileSummary[];
  }>;

export type AgentApprovalNotification = AgentNotificationBase &
  Readonly<{
    type: "approval";
    event: "requested" | "resolved";
    requestId: AgentRequestId;
    approval: AgentApprovalRequest;
    resolution?: AgentApprovalResolution;
  }>;

export type AgentDisconnectNotification = AgentNotificationBase &
  Readonly<{
    type: "disconnect";
    reason: AgentDisconnectReason;
    message: string;
    exitCode?: number | null;
    detail?: Record<string, unknown>;
  }>;

export type AgentErrorNotification = AgentNotificationBase &
  Readonly<{
    type: "error";
    code: string;
    message: string;
    detail?: unknown;
  }>;

export type AgentNotification =
  | AgentThreadNotification
  | AgentTurnNotification
  | AgentItemNotification
  | AgentReasoningNotification
  | AgentPlanNotification
  | AgentDiffNotification
  | AgentApprovalNotification
  | AgentDisconnectNotification
  | AgentErrorNotification;

export type AgentSessionUnavailableError = Readonly<{
  type: "sessionUnavailable";
  agentId: string;
  provider: AgentProvider;
  code: "executableMissing" | "startupFailed" | "disconnected";
  message: string;
  executable?: AgentExecutableDiscovery;
  environment?: AgentEnvironmentDiagnostics;
  detail?: Record<string, unknown>;
}>;

export type AgentRemoteError = Readonly<{
  type: "remoteError";
  agentId: string;
  provider: AgentProvider;
  requestId: AgentRequestId;
  code: number;
  message: string;
  data?: unknown;
}>;

export type AgentInvalidMessageError = Readonly<{
  type: "invalidProviderMessage";
  agentId: string;
  provider: AgentProvider;
  message: string;
  detail?: Record<string, unknown>;
}>;

export type AgentOperationError =
  | AgentSessionUnavailableError
  | AgentRemoteError
  | AgentInvalidMessageError;

export type AgentSessionLookupError =
  | Readonly<{
      type: "agentNotFound";
      agentId: string;
      message: string;
    }>
  | AgentSessionUnavailableError;

export type AgentOperationResult<T> = Result<T, AgentOperationError>;
export type AgentSessionLookupResult<T> = Result<T, AgentSessionLookupError>;

export type AgentListModelsParams = Readonly<{
  limit?: number;
  includeHidden?: boolean;
}>;

export type AgentListModelsResult = Readonly<{
  models: readonly AgentModelSummary[];
  nextCursor: string | null;
}>;

export type AgentThreadStartParams = Readonly<{
  workspacePath: string;
  title?: string;
  model?: string;
  reasoningEffort?: AgentReasoningEffort;
  approvalPolicy?: string;
  sandbox?: unknown;
}>;

export type AgentThreadResumeParams = Readonly<{
  threadId: string;
  workspacePath: string;
  model?: string;
  reasoningEffort?: AgentReasoningEffort;
  approvalPolicy?: string;
  sandbox?: unknown;
}>;

export type AgentThreadReadParams = Readonly<{
  threadId: string;
  includeTurns: boolean;
}>;

export type AgentThreadForkParams = Readonly<{
  threadId: string;
}>;

export type AgentThreadResult = Readonly<{
  thread: AgentThreadSummary;
}>;

export type AgentTurnStartParams = Readonly<{
  threadId: string;
  prompt: string;
  model?: string;
  reasoningEffort?: AgentReasoningEffort;
  cwd?: string;
}>;

export type AgentTurnSteerParams = Readonly<{
  threadId: string;
  turnId: string;
  prompt: string;
}>;

export type AgentTurnInterruptParams = Readonly<{
  threadId: string;
  turnId: string;
}>;

export type AgentTurnResult = Readonly<{
  turn: AgentTurnSummary;
}>;

export type AgentApprovalResolveParams = Readonly<{
  requestId: AgentRequestId;
  resolution: AgentApprovalResolution;
}>;

export type AgentApprovalResolveResult = Readonly<{
  requestId: AgentRequestId;
  resolution: AgentApprovalResolution;
}>;

export type AgentSession = Readonly<{
  agentId: string;
  provider: AgentProvider;
  getState: () => AgentSessionState;
  subscribe: (listener: (notification: AgentNotification) => void) => () => void;
  listModels: (
    requestId: AgentRequestId,
    params: AgentListModelsParams,
  ) => Promise<AgentOperationResult<AgentListModelsResult>>;
  startThread: (
    requestId: AgentRequestId,
    params: AgentThreadStartParams,
  ) => Promise<AgentOperationResult<AgentThreadResult>>;
  resumeThread: (
    requestId: AgentRequestId,
    params: AgentThreadResumeParams,
  ) => Promise<AgentOperationResult<AgentThreadResult>>;
  readThread: (
    requestId: AgentRequestId,
    params: AgentThreadReadParams,
  ) => Promise<AgentOperationResult<AgentThreadResult>>;
  forkThread: (
    requestId: AgentRequestId,
    params: AgentThreadForkParams,
  ) => Promise<AgentOperationResult<AgentThreadResult>>;
  startTurn: (
    requestId: AgentRequestId,
    params: AgentTurnStartParams,
  ) => Promise<AgentOperationResult<AgentTurnResult>>;
  steerTurn: (
    requestId: AgentRequestId,
    params: AgentTurnSteerParams,
  ) => Promise<AgentOperationResult<AgentTurnResult>>;
  interruptTurn: (
    requestId: AgentRequestId,
    params: AgentTurnInterruptParams,
  ) => Promise<AgentOperationResult<AgentTurnResult>>;
  resolveApproval: (
    params: AgentApprovalResolveParams,
  ) => Promise<AgentOperationResult<AgentApprovalResolveResult>>;
  disconnect: (reason?: AgentDisconnectReason) => Promise<void>;
}>;
