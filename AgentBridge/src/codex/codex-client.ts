import type {
  AccountReadPayload,
  AccountLoginPayload,
  ApprovalResolvePayload,
  ThreadArchiveFilter,
  ThreadListPayload,
  ThreadResumePayload,
  ThreadStartPayload,
  TurnStartPayload,
} from "../protocol/types";
import type {
  CodexTransport,
  CodexTransportRequestID,
  CodexTransportResponse,
} from "./codex-transport";

const CODEX_INITIALIZE_REQUEST_ID = "ateliercode-initialize";
const CODEX_CLIENT_NAME = "AtelierCode AgentBridge";
const CODEX_CLIENT_VERSION = "0.1.0";

export interface CodexThread {
  id: string;
  preview: string;
  updatedAt: number;
  name: string | null;
}

export interface CodexThreadListResult {
  threads: CodexThread[];
  nextCursor: string | null;
}

export interface CodexThreadStartResult {
  thread: CodexThread;
}

export interface CodexThreadResumeResult {
  thread: CodexThread;
}

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

export interface CodexClientAdapter {
  connect(): Promise<void>;
  disconnect(): Promise<void>;
  startThread(requestID: CodexTransportRequestID, payload: ThreadStartPayload): Promise<CodexThreadStartResult>;
  resumeThread(
    requestID: CodexTransportRequestID,
    threadID: string,
    payload: ThreadResumePayload,
  ): Promise<CodexThreadResumeResult>;
  listThreads(
    requestID: CodexTransportRequestID,
    payload: ThreadListPayload,
  ): Promise<CodexThreadListResult>;
  startTurn(
    requestID: CodexTransportRequestID,
    threadID: string,
    payload: TurnStartPayload,
  ): Promise<CodexTurnStartResult>;
  cancelTurn(
    requestID: CodexTransportRequestID,
    threadID: string,
    turnID: string,
  ): Promise<void>;
  resolveApproval(approvalID: string, payload: ApprovalResolvePayload): Promise<void>;
  readAccount(
    requestID: CodexTransportRequestID,
    payload: AccountReadPayload,
  ): Promise<CodexAccountReadResult>;
  login(requestID: CodexTransportRequestID, payload: AccountLoginPayload): Promise<CodexLoginResult>;
  logout(requestID: CodexTransportRequestID): Promise<void>;
}

export class CodexClient implements CodexClientAdapter {
  private initialized = false;

  constructor(private readonly transport: CodexTransport) {}

  async connect(): Promise<void> {
    await this.transport.connect();
    if (this.initialized) {
      return;
    }

    await this.transport.send({
      id: CODEX_INITIALIZE_REQUEST_ID,
      method: "initialize",
      params: {
        clientInfo: {
          name: CODEX_CLIENT_NAME,
          version: CODEX_CLIENT_VERSION,
        },
        capabilities: {
          experimentalApi: true,
        },
      },
    });
    this.initialized = true;
  }

  async disconnect(): Promise<void> {
    this.initialized = false;
    await this.transport.disconnect();
  }

  async startThread(
    requestID: CodexTransportRequestID,
    payload: ThreadStartPayload,
  ): Promise<CodexThreadStartResult> {
    const response = await this.transport.send<{ thread: unknown }>({
      id: requestID,
      method: "thread/start",
      params: {
        cwd: payload.workspacePath,
        experimentalRawEvents: false,
        persistExtendedHistory: true,
      },
    });

    const thread = toCodexThread(response.thread);

    if (payload.title && payload.title.trim().length > 0) {
      await this.transport.send({
        id: `${String(requestID)}:set-name`,
        method: "thread/name/set",
        params: {
          threadId: thread.id,
          name: payload.title.trim(),
        },
      });
      thread.name = payload.title.trim();
    }

    return { thread };
  }

  async resumeThread(
    requestID: CodexTransportRequestID,
    threadID: string,
    payload: ThreadResumePayload,
  ): Promise<CodexThreadResumeResult> {
    const response = await this.transport.send<{ thread: unknown }>({
      id: requestID,
      method: "thread/resume",
      params: {
        threadId: threadID,
        cwd: payload.workspacePath,
        persistExtendedHistory: true,
      },
    });

    return {
      thread: toCodexThread(response.thread),
    };
  }

  async listThreads(
    requestID: CodexTransportRequestID,
    payload: ThreadListPayload,
  ): Promise<CodexThreadListResult> {
    const response = await this.transport.send<{ data: unknown[]; nextCursor: string | null }>({
      id: requestID,
      method: "thread/list",
      params: {
        cursor: payload.cursor,
        limit: payload.limit,
        archived: mapArchiveFilter(payload.archived),
        cwd: payload.workspacePath,
      },
    });

    return {
      threads: response.data.map((thread) => toCodexThread(thread)),
      nextCursor: typeof response.nextCursor === "string" ? response.nextCursor : null,
    };
  }

  async startTurn(
    requestID: CodexTransportRequestID,
    threadID: string,
    payload: TurnStartPayload,
  ): Promise<CodexTurnStartResult> {
    const configuration = payload.configuration ?? {};
    const response = await this.transport.send<{ turn: { id: string } }>({
      id: requestID,
      method: "turn/start",
      params: {
        threadId: threadID,
        input: [
          {
            type: "text",
            text: payload.prompt,
            text_elements: [],
          },
        ],
        cwd: configuration.cwd,
        model: configuration.model,
        approvalPolicy: mapApprovalPolicy(configuration.approvalPolicy),
        sandboxPolicy: mapSandboxPolicy(configuration.sandboxPolicy, configuration.cwd),
        effort: mapReasoningEffort(configuration.reasoningEffort),
        summary: mapReasoningSummary(configuration.summaryMode),
        env: configuration.environment,
      },
    });

    if (!isPlainObject(response.turn) || typeof response.turn.id !== "string") {
      throw new Error("Codex turn/start response did not include a turn id.");
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
    await this.transport.send({
      id: requestID,
      method: "turn/interrupt",
      params: {
        threadId: threadID,
        turnId: turnID,
      },
    });
  }

  async resolveApproval(approvalID: string, payload: ApprovalResolvePayload): Promise<void> {
    await this.transport.respond({
      id: approvalID,
      result: {
        decision: mapApprovalResolution(payload.resolution),
      },
    });
  }

  async readAccount(
    requestID: CodexTransportRequestID,
    _payload: AccountReadPayload,
  ): Promise<CodexAccountReadResult> {
    const accountResponse = await this.transport.send<{
      account: unknown;
      requiresOpenaiAuth?: boolean;
    }>({
      id: requestID,
      method: "account/read",
      params: {},
    });

    let rateLimits: CodexRateLimitSnapshot | null = null;

    try {
      const rateLimitResponse = await this.transport.send<{
        rateLimits?: unknown;
      }>({
        id: `${String(requestID)}:rate-limits`,
        method: "account/rateLimits/read",
      });
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
    const response = await this.transport.send<{
      type: string;
      authUrl?: string;
      loginId?: string;
    }>({
      id: requestID,
      method: "account/login/start",
      params: mapLoginPayload(payload),
    });

    if (response.type !== "apiKey" && response.type !== "chatgpt" && response.type !== "chatgptAuthTokens") {
      throw new Error("Codex account/login/start returned an unsupported response type.");
    }

    return {
      type: response.type,
      authURL: typeof response.authUrl === "string" ? response.authUrl : undefined,
      loginID: typeof response.loginId === "string" ? response.loginId : undefined,
    };
  }

  async logout(requestID: CodexTransportRequestID): Promise<void> {
    await this.transport.send({
      id: requestID,
      method: "account/logout",
    });
  }
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

function mapApprovalPolicy(value: string | undefined): string | undefined {
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

function mapReasoningEffort(value: string | undefined): string | undefined {
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

function mapReasoningSummary(value: string | undefined): string | undefined {
  if (value === "auto" || value === "concise" || value === "detailed" || value === "none") {
    return value;
  }

  return undefined;
}

function mapSandboxPolicy(value: string | undefined, cwd: string | undefined): Record<string, unknown> | undefined {
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

function mapLoginPayload(payload: AccountLoginPayload): Record<string, unknown> {
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

      const result: Record<string, unknown> = {
        type: "chatgptAuthTokens",
        accessToken,
        chatgptAccountId,
      };

      const chatgptPlanType = payload.credentials?.chatgptPlanType;
      if (typeof chatgptPlanType === "string" && chatgptPlanType.length > 0) {
        result.chatgptPlanType = chatgptPlanType;
      }

      return result;
    }
    default:
      throw new Error(`Bridge account.login method ${String(payload.method)} is not supported.`);
  }
}

function toCodexThread(value: unknown): CodexThread {
  if (!isPlainObject(value) || typeof value.id !== "string") {
    throw new Error("Codex thread payload is malformed.");
  }

  return {
    id: value.id,
    preview: typeof value.preview === "string" ? value.preview : "",
    updatedAt: typeof value.updatedAt === "number" ? value.updatedAt : 0,
    name: typeof value.name === "string" ? value.name : null,
  };
}

function toCodexAccount(value: unknown): CodexAccount | null {
  if (!isPlainObject(value) || typeof value.type !== "string") {
    return null;
  }

  if (value.type === "apiKey") {
    return { type: "apiKey" };
  }

  if (value.type === "chatgpt") {
    return {
      type: "chatgpt",
      email: typeof value.email === "string" ? value.email : undefined,
      planType: typeof value.planType === "string" ? value.planType : undefined,
    };
  }

  return null;
}

function toCodexRateLimitSnapshot(value: unknown): CodexRateLimitSnapshot | null {
  if (!isPlainObject(value)) {
    return null;
  }

  return {
    limitId: typeof value.limitId === "string" ? value.limitId : null,
    limitName: typeof value.limitName === "string" ? value.limitName : null,
    primary: toCodexRateLimitWindow(value.primary),
    secondary: toCodexRateLimitWindow(value.secondary),
    credits: isPlainObject(value.credits)
      ? {
          usedPercent:
            typeof value.credits.usedPercent === "number" ? value.credits.usedPercent : null,
          remainingAmountUsd:
            typeof value.credits.remainingAmountUsd === "number"
              ? value.credits.remainingAmountUsd
              : null,
        }
      : null,
    planType: typeof value.planType === "string" ? value.planType : null,
  };
}

function toCodexRateLimitWindow(value: unknown): CodexRateLimitWindow | null {
  if (!isPlainObject(value) || typeof value.usedPercent !== "number") {
    return null;
  }

  return {
    usedPercent: value.usedPercent,
    windowDurationMins:
      typeof value.windowDurationMins === "number" ? value.windowDurationMins : null,
    resetsAt: typeof value.resetsAt === "number" ? value.resetsAt : null,
  };
}

function isPlainObject(value: unknown): value is Record<string, any> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function isCodexTransportResponse(value: unknown): value is CodexTransportResponse {
  return isPlainObject(value) && "id" in value && ("result" in value || "error" in value);
}
