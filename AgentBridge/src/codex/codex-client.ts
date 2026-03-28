import type {
  AccountReadPayload,
  AccountLoginPayload,
  ApprovalResolvePayload,
  ConversationConfiguration,
  ModelListPayload,
  ProviderCapabilities,
  ReasoningEffort,
  ThreadArchiveFilter,
  ThreadArchivePayload,
  ThreadForkPayload,
  ThreadListPayload,
  ThreadReadPayload,
  ThreadRenamePayload,
  ThreadResumePayload,
  ThreadRollbackPayload,
  ThreadStartPayload,
  ThreadUnarchivePayload,
  TurnStartPayload,
} from "../protocol/types";
import type {
  BridgeProviderAdapter,
  RuntimeThreadDefaults,
} from "../protocol/provider-adapter";
import { mergeConversationConfigurationIntoDefaults } from "../protocol/provider-adapter";
import { CodexRawClient } from "./codex-raw-client";
import type {
  CodexTransport,
  CodexTransportRequestID,
  CodexTransportResponse,
} from "./codex-transport";
import type { ReasoningEffort as RawReasoningEffort } from "./upstream/codex-cli-0.114.0/ts/ReasoningEffort";
import type { ReasoningSummary as RawReasoningSummary } from "./upstream/codex-cli-0.114.0/ts/ReasoningSummary";
import type { Account as RawAccount } from "./upstream/codex-cli-0.114.0/ts/v2/Account";
import type { AskForApproval } from "./upstream/codex-cli-0.114.0/ts/v2/AskForApproval";
import type { GetAccountResponse } from "./upstream/codex-cli-0.114.0/ts/v2/GetAccountResponse";
import type { LoginAccountParams } from "./upstream/codex-cli-0.114.0/ts/v2/LoginAccountParams";
import type { LoginAccountResponse } from "./upstream/codex-cli-0.114.0/ts/v2/LoginAccountResponse";
import type { Model as RawModel } from "./upstream/codex-cli-0.114.0/ts/v2/Model";
import type { ModelListParams as RawModelListParams } from "./upstream/codex-cli-0.114.0/ts/v2/ModelListParams";
import type { SandboxMode } from "./upstream/codex-cli-0.114.0/ts/v2/SandboxMode";
import type { SandboxPolicy } from "./upstream/codex-cli-0.114.0/ts/v2/SandboxPolicy";
import type { Thread as RawThread } from "./upstream/codex-cli-0.114.0/ts/v2/Thread";
import type { ThreadForkParams } from "./upstream/codex-cli-0.114.0/ts/v2/ThreadForkParams";
import type { ThreadForkResponse } from "./upstream/codex-cli-0.114.0/ts/v2/ThreadForkResponse";
import type { ThreadResumeParams } from "./upstream/codex-cli-0.114.0/ts/v2/ThreadResumeParams";
import type { ThreadResumeResponse } from "./upstream/codex-cli-0.114.0/ts/v2/ThreadResumeResponse";
import type { ThreadStartParams } from "./upstream/codex-cli-0.114.0/ts/v2/ThreadStartParams";
import type { ThreadStartResponse } from "./upstream/codex-cli-0.114.0/ts/v2/ThreadStartResponse";
import type { RateLimitSnapshot as RawRateLimitSnapshot } from "./upstream/codex-cli-0.114.0/ts/v2/RateLimitSnapshot";
import type { ThreadListParams as RawThreadListParams } from "./upstream/codex-cli-0.114.0/ts/v2/ThreadListParams";
import type { TurnStartParams as RawTurnStartParams } from "./upstream/codex-cli-0.114.0/ts/v2/TurnStartParams";

export const CODEX_PROVIDER_ID = "codex";

export const CODEX_PROVIDER_CAPABILITIES: ProviderCapabilities = {
  supportsThreadLifecycle: true,
  supportsThreadArchiving: true,
  supportsApprovals: true,
  supportsAuthentication: true,
  supportedModes: ["default", "plan", "review"],
};

export interface CodexThread {
  id: string;
  preview: string;
  updatedAt: number;
  name: string | null;
  status: RawThread["status"];
  turns: RawThread["turns"];
  archived: boolean;
}

export interface CodexModelReasoningEffort {
  reasoningEffort: ReasoningEffort;
  description?: string;
}

export interface CodexModelSummary {
  id: string;
  model: string;
  displayName: string;
  hidden: boolean;
  defaultReasoningEffort?: ReasoningEffort;
  supportedReasoningEfforts: CodexModelReasoningEffort[];
  inputModalities?: string[];
  supportsPersonality?: boolean;
  isDefault?: boolean;
}

export interface CodexModelListResult {
  models: CodexModelSummary[];
}

export interface CodexThreadListResult {
  threads: CodexThread[];
  nextCursor: string | null;
}

export interface CodexThreadLifecycleResult {
  thread: CodexThread;
  defaults: RuntimeThreadDefaults | null;
}

export type CodexThreadStartResult = CodexThreadLifecycleResult;
export type CodexThreadResumeResult = CodexThreadLifecycleResult;
export type CodexThreadReadResult = CodexThreadLifecycleResult;
export type CodexThreadForkResult = CodexThreadLifecycleResult;
export type CodexThreadRenameResult = CodexThreadLifecycleResult;
export type CodexThreadUnarchiveResult = CodexThreadLifecycleResult;
export type CodexThreadRollbackResult = CodexThreadLifecycleResult;

export interface CodexTurnStartResult {
  turnID: string;
}

export interface CodexAccount {
  type: "apiKey" | "chatgpt";
  email?: string;
  planType?: string;
}

export interface CodexRateLimitSnapshot {
  limitId: string | null;
  limitName: string | null;
  primary: CodexRateLimitWindow | null;
  secondary: CodexRateLimitWindow | null;
  credits: {
    usedPercent?: number | null;
    remainingAmountUsd?: number | null;
  } | null;
  planType: string | null;
}

export interface CodexRateLimitWindow {
  usedPercent: number;
  windowDurationMins: number | null;
  resetsAt: number | null;
}

export interface CodexAccountReadResult {
  account: CodexAccount | null;
  requiresOpenAIAuth: boolean;
  rateLimits: CodexRateLimitSnapshot | null;
}

export interface CodexLoginResult {
  type: "apiKey" | "chatgpt" | "chatgptAuthTokens";
  authURL?: string;
  loginID?: string;
}

export type CodexClientAdapter = BridgeProviderAdapter<
  CodexThread,
  CodexModelSummary,
  CodexAccount,
  CodexRateLimitSnapshot
>;

export class CodexClient implements CodexClientAdapter {
  readonly providerID = CODEX_PROVIDER_ID;
  readonly capabilities = CODEX_PROVIDER_CAPABILITIES;

  private readonly rawClient: CodexRawClient;
  private readonly threadDefaultsByID = new Map<string, RuntimeThreadDefaults>();

  constructor(transport: CodexTransport) {
    this.rawClient = new CodexRawClient(transport);
  }

  connect(): Promise<void> {
    return this.rawClient.connect();
  }

  async disconnect(): Promise<void> {
    this.threadDefaultsByID.clear();
    await this.rawClient.disconnect();
  }

  async listModels(
    requestID: CodexTransportRequestID,
    payload: ModelListPayload,
  ): Promise<CodexModelListResult> {
    const params: RawModelListParams = {
      limit: payload.limit,
      includeHidden: payload.includeHidden === true ? true : undefined,
    };
    const response = await this.rawClient.modelList(requestID, params);

    return {
      models: response.data.map((model) => toCodexModelSummary(model)),
    };
  }

  async startThread(
    requestID: CodexTransportRequestID,
    payload: ThreadStartPayload,
  ): Promise<CodexThreadStartResult> {
    const response = await this.rawClient.threadStart(requestID, buildThreadStartParams(payload));
    const thread = toCodexThread(response.thread);
    this.rememberThreadDefaults(thread.id, toRuntimeThreadDefaults(response));

    if (payload.title && payload.title.trim().length > 0) {
      await this.rawClient.threadSetName(`${String(requestID)}:set-name`, {
        threadId: thread.id,
        name: payload.title.trim(),
      });
      thread.name = payload.title.trim();
    }

    return {
      thread,
      defaults: this.threadDefaultsByID.get(thread.id) ?? null,
    };
  }

  async resumeThread(
    requestID: CodexTransportRequestID,
    threadID: string,
    payload: ThreadResumePayload,
  ): Promise<CodexThreadResumeResult> {
    const response = await this.rawClient.threadResume(
      requestID,
      buildThreadResumeParams(threadID, payload),
    );
    const thread = toCodexThread(response.thread);
    this.rememberThreadDefaults(thread.id, toRuntimeThreadDefaults(response));

    return {
      thread,
      defaults: this.threadDefaultsByID.get(thread.id) ?? null,
    };
  }

  async readThread(
    requestID: CodexTransportRequestID,
    threadID: string,
    payload: ThreadReadPayload,
  ): Promise<CodexThreadReadResult> {
    const response = await this.rawClient.threadRead(requestID, {
      threadId: threadID,
      includeTurns: payload.includeTurns === true,
    });
    const thread = toCodexThread(response.thread);

    return {
      thread,
      defaults: this.threadDefaultsByID.get(thread.id) ?? null,
    };
  }

  async forkThread(
    requestID: CodexTransportRequestID,
    threadID: string,
    payload: ThreadForkPayload,
  ): Promise<CodexThreadForkResult> {
    const response = await this.rawClient.threadFork(requestID, buildThreadForkParams(threadID, payload));
    const thread = toCodexThread(response.thread);
    this.rememberThreadDefaults(thread.id, toRuntimeThreadDefaults(response));

    return {
      thread,
      defaults: this.threadDefaultsByID.get(thread.id) ?? null,
    };
  }

  async archiveThread(
    requestID: CodexTransportRequestID,
    threadID: string,
    _payload: ThreadArchivePayload,
  ): Promise<void> {
    await this.rawClient.threadArchive(requestID, {
      threadId: threadID,
    });
  }

  async renameThread(
    requestID: CodexTransportRequestID,
    threadID: string,
    payload: ThreadRenamePayload,
  ): Promise<CodexThreadRenameResult> {
    const title = payload.title.trim();

    await this.rawClient.threadSetName(`${String(requestID)}:set-name`, {
      threadId: threadID,
      name: title,
    });

    const response = await this.rawClient.threadRead(requestID, {
      threadId: threadID,
      includeTurns: false,
    });
    const thread = toCodexThread(response.thread);
    thread.name = title;

    return {
      thread,
      defaults: this.threadDefaultsByID.get(thread.id) ?? null,
    };
  }

  async unarchiveThread(
    requestID: CodexTransportRequestID,
    threadID: string,
    _payload: ThreadUnarchivePayload,
  ): Promise<CodexThreadUnarchiveResult> {
    const response = await this.rawClient.threadUnarchive(requestID, {
      threadId: threadID,
    });
    const thread = toCodexThread(response.thread);

    return {
      thread,
      defaults: this.threadDefaultsByID.get(thread.id) ?? null,
    };
  }

  async rollbackThread(
    requestID: CodexTransportRequestID,
    threadID: string,
    payload: ThreadRollbackPayload,
  ): Promise<CodexThreadRollbackResult> {
    const response = await this.rawClient.threadRollback(requestID, {
      threadId: threadID,
      numTurns: payload.numTurns,
    });
    const thread = toCodexThread(response.thread);

    return {
      thread,
      defaults: this.threadDefaultsByID.get(thread.id) ?? null,
    };
  }

  async listThreads(
    requestID: CodexTransportRequestID,
    payload: ThreadListPayload,
  ): Promise<CodexThreadListResult> {
    const params: RawThreadListParams = {
      cursor: payload.cursor,
      limit: payload.limit,
      archived: mapArchiveFilter(payload.archived),
      cwd: payload.workspacePath,
    };
    const response = await this.rawClient.threadList(requestID, params);
    const archived = payload.archived === "only";

    return {
      threads: response.data.map((thread) => toCodexThread(thread, archived)),
      nextCursor: typeof response.nextCursor === "string" ? response.nextCursor : null,
    };
  }

  async startTurn(
    requestID: CodexTransportRequestID,
    threadID: string,
    payload: TurnStartPayload,
  ): Promise<CodexTurnStartResult> {
    const existingDefaults = this.threadDefaultsByID.get(threadID) ?? null;
    const turnParams = buildTurnStartParams(threadID, payload, existingDefaults);
    const response = await this.rawClient.turnStart(requestID, turnParams);

    if (existingDefaults !== null) {
      const mergedDefaults = applyPersistentTurnOverrides(existingDefaults, payload.configuration ?? {});
      this.threadDefaultsByID.set(threadID, mergedDefaults);
    }

    return {
      turnID: response.turn.id,
    };
  }

  async cancelTurn(
    requestID: CodexTransportRequestID,
    threadID: string,
    turnID: string,
  ): Promise<void> {
    await this.rawClient.turnInterrupt(requestID, {
      threadId: threadID,
      turnId: turnID,
    });
  }

  async resolveApproval(approvalID: string, payload: ApprovalResolvePayload): Promise<void> {
    await this.rawClient.respond({
      id: approvalID,
      result: {
        decision: mapApprovalResolution(payload.resolution),
      },
    });
  }

  async readAccount(
    requestID: CodexTransportRequestID,
    payload: AccountReadPayload,
  ): Promise<CodexAccountReadResult> {
    const accountResponse = await this.rawClient.readAccount(requestID, {
      refreshToken: payload.forceRefresh === true,
    });

    let rateLimits: CodexRateLimitSnapshot | null = null;

    try {
      const rateLimitResponse = await this.rawClient.readAccountRateLimits(`${String(requestID)}:rate-limits`);
      rateLimits = toCodexRateLimitSnapshot(rateLimitResponse.rateLimits);
    } catch {
      rateLimits = null;
    }

    return {
      account: toCodexAccount(accountResponse.account),
      requiresOpenAIAuth: accountResponse.requiresOpenaiAuth === true,
      rateLimits,
    };
  }

  async login(
    requestID: CodexTransportRequestID,
    payload: AccountLoginPayload,
  ): Promise<CodexLoginResult> {
    const response = await this.rawClient.login(requestID, mapLoginPayload(payload));
    return toCodexLoginResult(response);
  }

  logout(requestID: CodexTransportRequestID): Promise<void> {
    return this.rawClient.logout(requestID);
  }

  private rememberThreadDefaults(threadID: string, defaults: RuntimeThreadDefaults): void {
    this.threadDefaultsByID.set(threadID, defaults);
  }
}

function buildThreadStartParams(payload: ThreadStartPayload): ThreadStartParams {
  return {
    ...mapConversationConfiguration(payload.configuration, payload.workspacePath),
    experimentalRawEvents: false,
    persistExtendedHistory: true,
  };
}

function buildThreadResumeParams(threadID: string, payload: ThreadResumePayload): ThreadResumeParams {
  return {
    threadId: threadID,
    ...mapConversationConfiguration(payload.configuration, payload.workspacePath),
    persistExtendedHistory: true,
  };
}

function buildThreadForkParams(threadID: string, payload: ThreadForkPayload): ThreadForkParams {
  return {
    threadId: threadID,
    ...mapConversationConfiguration(payload.configuration, payload.workspacePath),
    persistExtendedHistory: true,
  };
}

function buildTurnStartParams(
  threadID: string,
  payload: TurnStartPayload,
  defaults: RuntimeThreadDefaults | null,
): RawTurnStartParams {
  const configuration = payload.configuration ?? {};
  const mappedSandboxPolicy = mapSandboxPolicy(configuration.sandboxPolicy, configuration.cwd ?? defaults?.cwd);

  return {
    threadId: threadID,
    input: [
      {
        type: "text",
        text: payload.prompt,
        text_elements: [],
      },
    ],
    cwd:
      configuration.cwd !== undefined && configuration.cwd !== defaults?.cwd
        ? configuration.cwd
        : undefined,
    approvalPolicy:
      configuration.approvalPolicy !== undefined && configuration.approvalPolicy !== defaults?.approvalPolicy
        ? mapApprovalPolicy(configuration.approvalPolicy)
        : undefined,
    sandboxPolicy:
      mappedSandboxPolicy !== undefined && !sandboxPoliciesEqual(mappedSandboxPolicy, defaults?.sandboxPolicy)
        ? mappedSandboxPolicy
        : undefined,
    model:
      configuration.model !== undefined && configuration.model !== defaults?.model
        ? configuration.model
        : undefined,
    effort:
      configuration.reasoningEffort !== undefined && configuration.reasoningEffort !== defaults?.reasoningEffort
        ? mapReasoningEffort(configuration.reasoningEffort)
        : undefined,
    summary:
      configuration.summaryMode !== undefined && configuration.summaryMode !== defaults?.summaryMode
        ? mapReasoningSummary(configuration.summaryMode)
        : undefined,
  };
}

function mapConversationConfiguration(
  configuration: ConversationConfiguration | undefined,
  fallbackCwd: string,
): Pick<ThreadStartParams, "cwd" | "model" | "approvalPolicy" | "sandbox"> {
  return {
    cwd: configuration?.cwd ?? fallbackCwd,
    model: configuration?.model,
    approvalPolicy: mapApprovalPolicy(configuration?.approvalPolicy),
    sandbox: mapSandboxMode(configuration?.sandboxPolicy),
  };
}

function toRuntimeThreadDefaults(
  response: ThreadStartResponse | ThreadResumeResponse | ThreadForkResponse,
): RuntimeThreadDefaults {
  return {
    cwd: response.cwd,
    model: response.model,
    modelProvider: response.modelProvider,
    serviceTier: response.serviceTier,
    approvalPolicy: approvalPolicyKey(response.approvalPolicy),
    sandboxPolicy: response.sandbox,
    reasoningEffort: response.reasoningEffort,
    summaryMode: null,
  };
}

function applyPersistentTurnOverrides(
  defaults: RuntimeThreadDefaults,
  configuration: TurnStartPayload["configuration"],
): RuntimeThreadDefaults {
  const mappedSandboxPolicy = mapSandboxPolicy(configuration?.sandboxPolicy, configuration?.cwd ?? defaults.cwd);
  const mergedDefaults = mergeConversationConfigurationIntoDefaults(
    defaults,
    configuration ?? {},
    mappedSandboxPolicy,
  );

  return {
    ...mergedDefaults,
    summaryMode: configuration?.summaryMode ?? defaults.summaryMode,
  };
}

function mapArchiveFilter(filter: ThreadArchiveFilter | undefined): boolean | undefined {
  switch (filter) {
    case "only":
      return true;
    case "exclude":
      return false;
    case "include":
    case undefined:
      return undefined;
  }
}

function mapApprovalPolicy(value: string | undefined): AskForApproval | undefined {
  if (
    value === "untrusted" ||
    value === "on-failure" ||
    value === "on-request" ||
    value === "never"
  ) {
    return value;
  }

  return undefined;
}

function approvalPolicyKey(value: AskForApproval): string {
  return typeof value === "string" ? value : "reject";
}

function mapReasoningEffort(value: string | undefined): RawReasoningEffort | undefined {
  if (
    value === "none" ||
    value === "minimal" ||
    value === "low" ||
    value === "medium" ||
    value === "high" ||
    value === "xhigh"
  ) {
    return value;
  }

  return undefined;
}

function mapReasoningSummary(value: string | undefined): RawReasoningSummary | undefined {
  if (value === "auto" || value === "concise" || value === "detailed" || value === "none") {
    return value;
  }

  return undefined;
}

function mapSandboxMode(value: string | undefined): SandboxMode | undefined {
  if (
    value === "read-only" ||
    value === "workspace-write" ||
    value === "danger-full-access"
  ) {
    return value;
  }

  return undefined;
}

function mapSandboxPolicy(value: string | undefined, cwd: string | undefined): SandboxPolicy | undefined {
  if (value === undefined) {
    return undefined;
  }

  switch (value) {
    case "danger-full-access":
      return { type: "dangerFullAccess" };
    case "read-only":
      return {
        type: "readOnly",
        access: {
          type: "restricted",
          includePlatformDefaults: true,
          readableRoots: cwd ? [cwd] : [],
        },
        networkAccess: false,
      };
    case "workspace-write":
      if (!cwd) {
        return undefined;
      }

      return {
        type: "workspaceWrite",
        writableRoots: [cwd],
        readOnlyAccess: {
          type: "fullAccess",
        },
        networkAccess: false,
        excludeTmpdirEnvVar: false,
        excludeSlashTmp: false,
      };
    default:
      return undefined;
  }
}

function sandboxPoliciesEqual(
  left: Record<string, unknown> | undefined,
  right: Record<string, unknown> | undefined,
): boolean {
  return JSON.stringify(left ?? null) === JSON.stringify(right ?? null);
}

function mapApprovalResolution(resolution: ApprovalResolvePayload["resolution"]): string {
  switch (resolution) {
    case "approved":
      return "accept";
    case "declined":
      return "decline";
    case "cancelled":
    case "stale":
      return "cancel";
  }
}

function mapLoginPayload(payload: AccountLoginPayload): LoginAccountParams {
  switch (payload.method) {
    case "apiKey": {
      const apiKey = payload.credentials?.apiKey;
      if (typeof apiKey !== "string" || apiKey.trim().length === 0) {
        throw new Error("Bridge account.login with method apiKey requires credentials.apiKey.");
      }

      return {
        type: "apiKey",
        apiKey: apiKey.trim(),
      };
    }
    case "chatgpt":
    case undefined:
      return {
        type: "chatgpt",
      };
    case "chatgptAuthTokens": {
      const accessToken = payload.credentials?.accessToken;
      const chatgptAccountId = payload.credentials?.chatgptAccountId;
      if (typeof accessToken !== "string" || typeof chatgptAccountId !== "string") {
        throw new Error(
          "Bridge account.login with method chatgptAuthTokens requires accessToken and chatgptAccountId.",
        );
      }

      return {
        type: "chatgptAuthTokens",
        accessToken,
        chatgptAccountId,
        chatgptPlanType:
          typeof payload.credentials?.chatgptPlanType === "string"
            ? payload.credentials.chatgptPlanType
            : undefined,
      };
    }
    default:
      throw new Error(`Bridge account.login method ${String(payload.method)} is not supported.`);
  }
}

function toCodexLoginResult(response: LoginAccountResponse): CodexLoginResult {
  switch (response.type) {
    case "apiKey":
      return {
        type: "apiKey",
      };
    case "chatgpt":
      return {
        type: "chatgpt",
        authURL: response.authUrl,
        loginID: response.loginId,
      };
    case "chatgptAuthTokens":
      return {
        type: "chatgptAuthTokens",
      };
  }
}

function toCodexThread(value: RawThread, archived = false): CodexThread {
  return {
    id: value.id,
    preview: value.preview,
    updatedAt: value.updatedAt,
    name: value.name,
    status: value.status,
    turns: value.turns,
    archived,
  };
}

function toCodexAccount(value: RawAccount | null): CodexAccount | null {
  if (value === null) {
    return null;
  }

  if (value.type === "apiKey") {
    return { type: "apiKey" };
  }

  return {
    type: "chatgpt",
    email: value.email,
    planType: value.planType,
  };
}

function toCodexModelSummary(value: RawModel): CodexModelSummary {
  return {
    id: value.id,
    model: value.model,
    displayName: value.displayName,
    hidden: value.hidden,
    defaultReasoningEffort: value.defaultReasoningEffort,
    supportedReasoningEfforts: value.supportedReasoningEfforts.map((effort) => ({
      reasoningEffort: effort.reasoningEffort,
      description: effort.description,
    })),
    inputModalities: value.inputModalities,
    supportsPersonality: value.supportsPersonality,
    isDefault: value.isDefault,
  };
}

function toCodexRateLimitSnapshot(value: RawRateLimitSnapshot): CodexRateLimitSnapshot {
  return {
    limitId: value.limitId,
    limitName: value.limitName,
    primary: value.primary
      ? {
          usedPercent: value.primary.usedPercent,
          windowDurationMins: value.primary.windowDurationMins,
          resetsAt: value.primary.resetsAt,
        }
      : null,
    secondary: value.secondary
      ? {
          usedPercent: value.secondary.usedPercent,
          windowDurationMins: value.secondary.windowDurationMins,
          resetsAt: value.secondary.resetsAt,
        }
      : null,
    credits: value.credits
      ? {
          usedPercent: null,
          remainingAmountUsd: null,
        }
      : null,
    planType: value.planType,
  };
}

export function isCodexTransportResponse(value: unknown): value is CodexTransportResponse {
  return isPlainObject(value) && "id" in value && ("result" in value || "error" in value);
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
