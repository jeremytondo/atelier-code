import type {
  AccountLoginPayload,
  AccountReadPayload,
  ApprovalResolvePayload,
  ConversationConfiguration,
  ModelListPayload,
  ProviderCapabilities,
  ThreadForkPayload,
  ThreadListPayload,
  ThreadReadPayload,
  ThreadRenamePayload,
  ThreadRollbackPayload,
  ThreadResumePayload,
  ThreadStartPayload,
  TurnStartPayload,
} from "./types";
import type { CodexTransportRequestID } from "../codex/codex-transport";

export interface RuntimeThreadDefaults {
  cwd: string;
  model: string;
  modelProvider: string;
  serviceTier: string | null;
  approvalPolicy: string;
  sandboxPolicy: Record<string, unknown>;
  reasoningEffort: string | null;
  summaryMode: string | null;
}

export interface RuntimeThreadState<Thread> {
  thread: Thread;
  defaults: RuntimeThreadDefaults | null;
}

export interface RuntimeModelListResult<Model> {
  models: Model[];
}

export interface RuntimeThreadListResult<Thread> {
  threads: Thread[];
  nextCursor: string | null;
}

export interface RuntimeTurnStartResult {
  turnID: string;
}

export interface RuntimeAccountReadResult<Account, RateLimits> {
  account: Account | null;
  requiresOpenAIAuth: boolean;
  rateLimits: RateLimits | null;
}

export interface RuntimeLoginResult {
  type: "apiKey" | "chatgpt" | "chatgptAuthTokens";
  authURL?: string;
  loginID?: string;
}

export interface BridgeProviderAdapter<Thread, Model, Account, RateLimits> {
  readonly providerID: string;
  readonly capabilities: ProviderCapabilities;

  connect(): Promise<void>;
  disconnect(): Promise<void>;
  listModels(
    requestID: CodexTransportRequestID,
    payload: ModelListPayload,
  ): Promise<RuntimeModelListResult<Model>>;
  startThread(
    requestID: CodexTransportRequestID,
    payload: ThreadStartPayload,
  ): Promise<RuntimeThreadState<Thread>>;
  resumeThread(
    requestID: CodexTransportRequestID,
    threadID: string,
    payload: ThreadResumePayload,
  ): Promise<RuntimeThreadState<Thread>>;
  readThread(
    requestID: CodexTransportRequestID,
    threadID: string,
    payload: ThreadReadPayload,
  ): Promise<RuntimeThreadState<Thread>>;
  forkThread(
    requestID: CodexTransportRequestID,
    threadID: string,
    payload: ThreadForkPayload,
  ): Promise<RuntimeThreadState<Thread>>;
  renameThread(
    requestID: CodexTransportRequestID,
    threadID: string,
    payload: ThreadRenamePayload,
  ): Promise<RuntimeThreadState<Thread>>;
  rollbackThread(
    requestID: CodexTransportRequestID,
    threadID: string,
    payload: ThreadRollbackPayload,
  ): Promise<RuntimeThreadState<Thread>>;
  listThreads(
    requestID: CodexTransportRequestID,
    payload: ThreadListPayload,
  ): Promise<RuntimeThreadListResult<Thread>>;
  startTurn(
    requestID: CodexTransportRequestID,
    threadID: string,
    payload: TurnStartPayload,
  ): Promise<RuntimeTurnStartResult>;
  cancelTurn(
    requestID: CodexTransportRequestID,
    threadID: string,
    turnID: string,
  ): Promise<void>;
  resolveApproval(approvalID: string, payload: ApprovalResolvePayload): Promise<void>;
  readAccount(
    requestID: CodexTransportRequestID,
    payload: AccountReadPayload,
  ): Promise<RuntimeAccountReadResult<Account, RateLimits>>;
  login(requestID: CodexTransportRequestID, payload: AccountLoginPayload): Promise<RuntimeLoginResult>;
  logout(requestID: CodexTransportRequestID): Promise<void>;
}

export function mergeConversationConfigurationIntoDefaults(
  defaults: RuntimeThreadDefaults,
  configuration: ConversationConfiguration,
  mappedSandboxPolicy: Record<string, unknown> | undefined,
): RuntimeThreadDefaults {
  return {
    cwd: configuration.cwd ?? defaults.cwd,
    model: configuration.model ?? defaults.model,
    modelProvider: defaults.modelProvider,
    serviceTier: defaults.serviceTier,
    approvalPolicy: configuration.approvalPolicy ?? defaults.approvalPolicy,
    sandboxPolicy: mappedSandboxPolicy ?? defaults.sandboxPolicy,
    reasoningEffort: configuration.reasoningEffort ?? defaults.reasoningEffort,
    summaryMode: defaults.summaryMode,
  };
}
