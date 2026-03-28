export type BridgeHealthStatus = "ok" | "degraded";
export type ProviderReadiness = "available" | "degraded";
export type ExecutableDiscoveryStatus = "found" | "missing";
export type ExecutableDiscoverySource = "environment" | "path" | "known-path" | "not-found";
export type BridgeEnvironmentSource = "inherited" | "login_probe" | "fallback";
export type BridgeStartupErrorCode =
  | "provider_executable_missing"
  | "embedded_bridge_missing"
  | "protocol_mismatch";

export type ISO8601Timestamp = string;
export type ProviderIdentifier = string;
export type BridgeTransport = "websocket";
export type BridgeHandshakeType = "hello" | "welcome";
export type BridgeCommandType =
  | "model.list"
  | "thread.start"
  | "thread.resume"
  | "thread.list"
  | "thread.read"
  | "thread.fork"
  | "thread.rename"
  | "thread.rollback"
  | "turn.start"
  | "turn.cancel"
  | "approval.resolve"
  | "account.read"
  | "account.login"
  | "account.logout";
export type BridgeEventType =
  | "model.list.result"
  | "thread.started"
  | "turn.started"
  | "message.delta"
  | "thinking.delta"
  | "tool.started"
  | "tool.output"
  | "tool.completed"
  | "fileChange.started"
  | "fileChange.completed"
  | "approval.requested"
  | "approval.resolved"
  | "diff.updated"
  | "plan.updated"
  | "turn.completed"
  | "thread.list.result"
  | "account.login.result"
  | "auth.changed"
  | "rateLimit.updated"
  | "error"
  | "provider.status";
export type BridgeMessageType = BridgeHandshakeType | BridgeCommandType | BridgeEventType;
export type ThreadArchiveFilter = "exclude" | "include" | "only";
export type ThreadRuntimeState = "notLoaded" | "idle" | "running" | "error";
export type TurnCompletionStatus = "completed" | "failed" | "cancelled" | "interrupted";
export type ActivityStatus = "running" | "completed" | "failed" | "cancelled";
export type ToolKind = "command" | "mcp" | "webSearch" | "other";
export type ApprovalKind = "command" | "fileChange" | "generic";
export type ApprovalResolution = "approved" | "declined" | "cancelled" | "stale";
export type RiskLevel = "low" | "medium" | "high";
export type AuthState = "unknown" | "signed_out" | "signed_in";
export type PlanStepStatus = "pending" | "in_progress" | "completed";
export type ProviderConnectionStatus = "starting" | "ready" | "degraded" | "disconnected" | "error";
export type RateLimitBucketKind = "requests" | "tokens" | "other";
export type ReasoningEffort = "none" | "minimal" | "low" | "medium" | "high" | "xhigh";
export type ProviderModeKind = "default" | "plan" | "review";

export interface BridgeEnvelopeBase<TType extends BridgeMessageType = BridgeMessageType> {
  type: TType;
  timestamp: ISO8601Timestamp;
  provider?: ProviderIdentifier;
  threadID?: string;
  turnID?: string;
  itemID?: string;
  activityID?: string;
}

export interface BridgeCommandEnvelope<
  TType extends BridgeCommandType = BridgeCommandType,
  TPayload = unknown,
> extends BridgeEnvelopeBase<TType> {
  id: string;
  provider: ProviderIdentifier;
  payload: TPayload;
}

export interface BridgeEventEnvelope<
  TType extends BridgeEventType = BridgeEventType,
  TPayload = unknown,
> extends BridgeEnvelopeBase<TType> {
  requestID?: string;
  payload: TPayload;
}

export interface BridgeHandshakeEnvelope<
  TType extends BridgeHandshakeType = BridgeHandshakeType,
  TPayload = unknown,
> extends BridgeEnvelopeBase<TType> {
  payload: TPayload;
}

export interface ThreadSummary {
  id: string;
  providerID: ProviderIdentifier;
  title: string;
  previewText: string;
  updatedAt: ISO8601Timestamp;
  archived?: boolean;
  running?: boolean;
  errorMessage?: string;
  messages?: ConversationMessage[];
}

export interface ConversationMessage {
  id: string;
  role: "user" | "assistant";
  text: string;
}

export interface ProviderSummary {
  id: ProviderIdentifier;
  displayName: string;
  status: ProviderReadiness;
  capabilities: ProviderCapabilities;
}

export interface ProviderCapabilities {
  supportsThreadLifecycle: boolean;
  supportsThreadArchiving: boolean;
  supportsApprovals: boolean;
  supportsAuthentication: boolean;
  supportedModes: ProviderModeKind[];
}

export interface AccountSummary {
  id?: string;
  displayName: string;
  email?: string;
}

export interface PlanStep {
  id: string;
  title: string;
  status: PlanStepStatus;
}

export interface DiffFileSummary {
  id: string;
  path: string;
  additions: number;
  deletions: number;
}

export interface ApprovalCommandContext {
  command: string;
  workingDirectory?: string;
}

export interface RateLimitBucket {
  id: string;
  kind: RateLimitBucketKind;
  limit?: number;
  remaining?: number;
  resetAt?: ISO8601Timestamp;
  detail?: string;
}

export interface ModelReasoningEffortSummary {
  reasoningEffort: ReasoningEffort;
  description?: string;
}

export interface ModelSummary {
  id: string;
  model: string;
  displayName: string;
  hidden: boolean;
  defaultReasoningEffort?: ReasoningEffort;
  supportedReasoningEfforts: ModelReasoningEffortSummary[];
  inputModalities?: string[];
  supportsPersonality?: boolean;
  isDefault?: boolean;
}

export interface ConversationConfiguration {
  cwd?: string;
  model?: string;
  reasoningEffort?: string;
  sandboxPolicy?: string;
  approvalPolicy?: string;
}

export interface TurnStartConfiguration extends ConversationConfiguration {
  summaryMode?: string;
  environment?: Record<string, string>;
}

export interface HelloPayload {
  appVersion: string;
  protocolVersion: number;
  supportedProtocolVersions?: readonly number[];
  clientName: string;
  platform?: string;
  transport?: BridgeTransport;
}

export interface BridgeEnvironmentDiagnostics {
  source: BridgeEnvironmentSource;
  shellPath: string;
  probeError: string | null;
  pathDirectoryCount: number;
  homeDirectory: string | null;
}

export interface WelcomePayload {
  bridgeVersion: string;
  protocolVersion: number;
  supportedProtocolVersions: readonly number[];
  sessionID: string;
  transport: BridgeTransport;
  providers: ProviderSummary[];
  environment: BridgeEnvironmentDiagnostics;
}

export interface HelloEnvelope extends BridgeHandshakeEnvelope<"hello", HelloPayload> {
  id: string;
}

export interface WelcomeEnvelope extends BridgeHandshakeEnvelope<"welcome", WelcomePayload> {
  requestID: string;
}

export interface ThreadStartPayload {
  workspacePath: string;
  title?: string;
  configuration?: ConversationConfiguration;
}

export interface ModelListPayload {
  limit?: number;
  includeHidden?: boolean;
}

export interface ThreadResumePayload {
  workspacePath: string;
  configuration?: ConversationConfiguration;
}

export interface ThreadListPayload {
  workspacePath: string;
  cursor?: string;
  limit?: number;
  archived?: ThreadArchiveFilter;
}

export interface ThreadReadPayload {
  includeTurns?: boolean;
}

export interface ThreadForkPayload {
  workspacePath: string;
  configuration?: ConversationConfiguration;
}

export interface ThreadRenamePayload {
  title: string;
}

export interface ThreadRollbackPayload {
  numTurns: number;
}

export interface TurnStartPayload {
  prompt: string;
  configuration?: TurnStartConfiguration;
}

export interface TurnCancelPayload {
  reason?: string;
}

export interface ApprovalResolvePayload {
  approvalID: string;
  resolution: ApprovalResolution;
  rememberDecision?: boolean;
}

export interface AccountReadPayload {
  forceRefresh?: boolean;
}

export interface AccountLoginPayload {
  method?: string;
  credentials?: Record<string, string>;
}

export interface AccountLogoutPayload {
  scope?: "provider" | "all";
}

export interface ThreadStartCommand extends BridgeCommandEnvelope<"thread.start", ThreadStartPayload> {}

export interface ModelListCommand extends BridgeCommandEnvelope<"model.list", ModelListPayload> {}

export interface ThreadResumeCommand extends BridgeCommandEnvelope<"thread.resume", ThreadResumePayload> {
  threadID: string;
}

export interface ThreadListCommand extends BridgeCommandEnvelope<"thread.list", ThreadListPayload> {}

export interface ThreadReadCommand extends BridgeCommandEnvelope<"thread.read", ThreadReadPayload> {
  threadID: string;
}

export interface ThreadForkCommand extends BridgeCommandEnvelope<"thread.fork", ThreadForkPayload> {
  threadID: string;
}

export interface ThreadRenameCommand extends BridgeCommandEnvelope<"thread.rename", ThreadRenamePayload> {
  threadID: string;
}

export interface ThreadRollbackCommand extends BridgeCommandEnvelope<"thread.rollback", ThreadRollbackPayload> {
  threadID: string;
}

export interface TurnStartCommand extends BridgeCommandEnvelope<"turn.start", TurnStartPayload> {
  threadID: string;
}

export interface TurnCancelCommand extends BridgeCommandEnvelope<"turn.cancel", TurnCancelPayload> {
  threadID: string;
  turnID: string;
}

export interface ApprovalResolveCommand
  extends BridgeCommandEnvelope<"approval.resolve", ApprovalResolvePayload> {
  threadID: string;
  turnID?: string;
}

export interface AccountReadCommand extends BridgeCommandEnvelope<"account.read", AccountReadPayload> {}

export interface AccountLoginCommand extends BridgeCommandEnvelope<"account.login", AccountLoginPayload> {}

export interface AccountLogoutCommand
  extends BridgeCommandEnvelope<"account.logout", AccountLogoutPayload> {}

export type BridgeCommand =
  | ModelListCommand
  | ThreadStartCommand
  | ThreadResumeCommand
  | ThreadListCommand
  | ThreadReadCommand
  | ThreadForkCommand
  | ThreadRenameCommand
  | ThreadRollbackCommand
  | TurnStartCommand
  | TurnCancelCommand
  | ApprovalResolveCommand
  | AccountReadCommand
  | AccountLoginCommand
  | AccountLogoutCommand;

export interface TurnStartedPayload {
  status: "in_progress";
  startedAt?: ISO8601Timestamp;
}

export interface ThreadStartedPayload {
  thread: ThreadSummary;
}

export interface MessageDeltaPayload {
  messageID: string;
  delta: string;
}

export interface ThinkingDeltaPayload {
  delta: string;
}

export interface ToolStartedPayload {
  title: string;
  detail?: string;
  kind: ToolKind;
  command?: string;
  workingDirectory?: string;
}

export interface ToolOutputPayload {
  stream?: "stdout" | "stderr" | "combined";
  delta: string;
}

export interface ToolCompletedPayload {
  status: Exclude<ActivityStatus, "running">;
  detail?: string;
  exitCode?: number | null;
}

export interface FileChangeStartedPayload {
  title: string;
  detail?: string;
  files: DiffFileSummary[];
}

export interface FileChangeCompletedPayload {
  status: Exclude<ActivityStatus, "running">;
  detail?: string;
  files: DiffFileSummary[];
}

export interface ApprovalRequestedPayload {
  approvalID: string;
  kind: ApprovalKind;
  title: string;
  detail: string;
  command?: ApprovalCommandContext;
  files?: DiffFileSummary[];
  riskLevel?: RiskLevel;
}

export interface ApprovalResolvedPayload {
  approvalID: string;
  resolution: ApprovalResolution;
}

export interface DiffUpdatedPayload {
  summary: string;
  files: DiffFileSummary[];
}

export interface PlanUpdatedPayload {
  summary?: string;
  steps: PlanStep[];
}

export interface TurnCompletedPayload {
  status: TurnCompletionStatus;
  detail?: string;
}

export interface ModelListResultPayload {
  models: ModelSummary[];
}

export interface ThreadListResultPayload {
  threads: ThreadSummary[];
  nextCursor?: string | null;
}

export interface AccountLoginResultPayload {
  method: "apiKey" | "chatgpt" | "chatgptAuthTokens";
  authURL?: string;
  loginID?: string;
}

export interface AuthChangedPayload {
  state: AuthState;
  account?: AccountSummary | null;
}

export interface RateLimitUpdatedPayload {
  accountID?: string;
  buckets: RateLimitBucket[];
}

export interface ErrorPayload {
  code: string;
  message: string;
  retryable?: boolean;
  detail?: Record<string, unknown>;
}

export interface ProviderStatusPayload {
  status: ProviderConnectionStatus;
  detail: string;
  executablePath?: string;
  environment?: BridgeEnvironmentDiagnostics;
}

export interface TurnStartedEvent extends BridgeEventEnvelope<"turn.started", TurnStartedPayload> {
  requestID: string;
  threadID: string;
  turnID: string;
}

export interface ThreadStartedEvent extends BridgeEventEnvelope<"thread.started", ThreadStartedPayload> {
  threadID: string;
}

export interface MessageDeltaEvent extends BridgeEventEnvelope<"message.delta", MessageDeltaPayload> {
  threadID: string;
  turnID: string;
  itemID: string;
}

export interface ThinkingDeltaEvent extends BridgeEventEnvelope<"thinking.delta", ThinkingDeltaPayload> {
  threadID: string;
  turnID: string;
  itemID: string;
}

export interface ToolStartedEvent extends BridgeEventEnvelope<"tool.started", ToolStartedPayload> {
  threadID: string;
  turnID: string;
  activityID: string;
}

export interface ToolOutputEvent extends BridgeEventEnvelope<"tool.output", ToolOutputPayload> {
  threadID: string;
  turnID: string;
  activityID: string;
}

export interface ToolCompletedEvent extends BridgeEventEnvelope<"tool.completed", ToolCompletedPayload> {
  threadID: string;
  turnID: string;
  activityID: string;
}

export interface FileChangeStartedEvent
  extends BridgeEventEnvelope<"fileChange.started", FileChangeStartedPayload> {
  threadID: string;
  turnID: string;
  activityID: string;
}

export interface FileChangeCompletedEvent
  extends BridgeEventEnvelope<"fileChange.completed", FileChangeCompletedPayload> {
  threadID: string;
  turnID: string;
  activityID: string;
}

export interface ApprovalRequestedEvent
  extends BridgeEventEnvelope<"approval.requested", ApprovalRequestedPayload> {
  threadID: string;
  turnID: string;
}

export interface ApprovalResolvedEvent
  extends BridgeEventEnvelope<"approval.resolved", ApprovalResolvedPayload> {
  requestID: string;
  threadID: string;
  turnID?: string;
}

export interface DiffUpdatedEvent extends BridgeEventEnvelope<"diff.updated", DiffUpdatedPayload> {
  threadID: string;
  turnID: string;
}

export interface PlanUpdatedEvent extends BridgeEventEnvelope<"plan.updated", PlanUpdatedPayload> {
  threadID: string;
  turnID: string;
}

export interface TurnCompletedEvent extends BridgeEventEnvelope<"turn.completed", TurnCompletedPayload> {
  threadID: string;
  turnID: string;
}

export interface ThreadListResultEvent
  extends BridgeEventEnvelope<"thread.list.result", ThreadListResultPayload> {
  requestID: string;
}

export interface ModelListResultEvent
  extends BridgeEventEnvelope<"model.list.result", ModelListResultPayload> {
  requestID: string;
}

export interface AccountLoginResultEvent
  extends BridgeEventEnvelope<"account.login.result", AccountLoginResultPayload> {
  requestID: string;
}

export interface AuthChangedEvent extends BridgeEventEnvelope<"auth.changed", AuthChangedPayload> {}

export interface RateLimitUpdatedEvent
  extends BridgeEventEnvelope<"rateLimit.updated", RateLimitUpdatedPayload> {}

export interface ErrorEvent extends BridgeEventEnvelope<"error", ErrorPayload> {}

export interface ProviderStatusEvent extends BridgeEventEnvelope<"provider.status", ProviderStatusPayload> {}

export type BridgeEvent =
  | ModelListResultEvent
  | ThreadStartedEvent
  | ThreadArchivedEvent
  | ThreadUnarchivedEvent
  | TurnStartedEvent
  | MessageDeltaEvent
  | ThinkingDeltaEvent
  | ToolStartedEvent
  | ToolOutputEvent
  | ToolCompletedEvent
  | FileChangeStartedEvent
  | FileChangeCompletedEvent
  | ApprovalRequestedEvent
  | ApprovalResolvedEvent
  | DiffUpdatedEvent
  | PlanUpdatedEvent
  | TurnCompletedEvent
  | ThreadListResultEvent
  | AccountLoginResultEvent
  | AuthChangedEvent
  | RateLimitUpdatedEvent
  | ErrorEvent
  | ProviderStatusEvent;

export type BridgeHandshake = HelloEnvelope | WelcomeEnvelope;
export type BridgeMessage = BridgeHandshake | BridgeCommand | BridgeEvent;

export interface ExecutableDiscoveryResult {
  executableName: string;
  status: ExecutableDiscoveryStatus;
  resolvedPath: string | null;
  source: ExecutableDiscoverySource;
  baseEnvironmentSource: BridgeEnvironmentSource;
  checkedPaths: string[];
}

export interface ProviderHealth {
  provider: "codex";
  status: ProviderReadiness;
  detail: string;
  capabilities: ProviderCapabilities;
  executable: ExecutableDiscoveryResult;
  environment: BridgeEnvironmentDiagnostics;
}

export interface BridgeStartupError {
  code: BridgeStartupErrorCode;
  message: string;
  recoverySuggestion?: string;
}

export interface BridgeHealthReport {
  bridgeVersion: string;
  protocolVersion: number;
  status: BridgeHealthStatus;
  generatedAt: string;
  providers: ProviderHealth[];
  errors: BridgeStartupError[];
}

export interface BridgeRuntimeStartupRecord {
  recordType: "bridge.startup";
  bridgeVersion: string;
  protocolVersion: number;
  transport: BridgeTransport;
  host: string;
  port: number;
  pid: number;
  startedAt: ISO8601Timestamp;
}
