import type { ClientNotification } from "./upstream/codex-cli-0.114.0/ts/ClientNotification";
import type { InitializeParams } from "./upstream/codex-cli-0.114.0/ts/InitializeParams";
import type { InitializeResponse } from "./upstream/codex-cli-0.114.0/ts/InitializeResponse";
import type { ModelListParams } from "./upstream/codex-cli-0.114.0/ts/v2/ModelListParams";
import type { ModelListResponse } from "./upstream/codex-cli-0.114.0/ts/v2/ModelListResponse";
import type { ThreadArchiveParams } from "./upstream/codex-cli-0.114.0/ts/v2/ThreadArchiveParams";
import type { ThreadArchiveResponse } from "./upstream/codex-cli-0.114.0/ts/v2/ThreadArchiveResponse";
import type { ThreadForkParams } from "./upstream/codex-cli-0.114.0/ts/v2/ThreadForkParams";
import type { ThreadForkResponse } from "./upstream/codex-cli-0.114.0/ts/v2/ThreadForkResponse";
import type { ThreadListParams } from "./upstream/codex-cli-0.114.0/ts/v2/ThreadListParams";
import type { ThreadListResponse } from "./upstream/codex-cli-0.114.0/ts/v2/ThreadListResponse";
import type { ThreadReadParams } from "./upstream/codex-cli-0.114.0/ts/v2/ThreadReadParams";
import type { ThreadReadResponse } from "./upstream/codex-cli-0.114.0/ts/v2/ThreadReadResponse";
import type { ThreadResumeParams } from "./upstream/codex-cli-0.114.0/ts/v2/ThreadResumeParams";
import type { ThreadResumeResponse } from "./upstream/codex-cli-0.114.0/ts/v2/ThreadResumeResponse";
import type { ThreadRollbackParams } from "./upstream/codex-cli-0.114.0/ts/v2/ThreadRollbackParams";
import type { ThreadRollbackResponse } from "./upstream/codex-cli-0.114.0/ts/v2/ThreadRollbackResponse";
import type { ThreadSetNameParams } from "./upstream/codex-cli-0.114.0/ts/v2/ThreadSetNameParams";
import type { ThreadSetNameResponse } from "./upstream/codex-cli-0.114.0/ts/v2/ThreadSetNameResponse";
import type { ThreadStartParams } from "./upstream/codex-cli-0.114.0/ts/v2/ThreadStartParams";
import type { ThreadStartResponse } from "./upstream/codex-cli-0.114.0/ts/v2/ThreadStartResponse";
import type { ThreadUnarchiveParams } from "./upstream/codex-cli-0.114.0/ts/v2/ThreadUnarchiveParams";
import type { ThreadUnarchiveResponse } from "./upstream/codex-cli-0.114.0/ts/v2/ThreadUnarchiveResponse";
import type { TurnInterruptParams } from "./upstream/codex-cli-0.114.0/ts/v2/TurnInterruptParams";
import type { TurnInterruptResponse } from "./upstream/codex-cli-0.114.0/ts/v2/TurnInterruptResponse";
import type { TurnStartParams } from "./upstream/codex-cli-0.114.0/ts/v2/TurnStartParams";
import type { TurnStartResponse } from "./upstream/codex-cli-0.114.0/ts/v2/TurnStartResponse";
import type { GetAccountParams } from "./upstream/codex-cli-0.114.0/ts/v2/GetAccountParams";
import type { GetAccountRateLimitsResponse } from "./upstream/codex-cli-0.114.0/ts/v2/GetAccountRateLimitsResponse";
import type { GetAccountResponse } from "./upstream/codex-cli-0.114.0/ts/v2/GetAccountResponse";
import type { LoginAccountParams } from "./upstream/codex-cli-0.114.0/ts/v2/LoginAccountParams";
import type { LoginAccountResponse } from "./upstream/codex-cli-0.114.0/ts/v2/LoginAccountResponse";
import type {
  CodexTransport,
  CodexTransportRequestID,
  CodexTransportResponse,
} from "./codex-transport";

const CODEX_INITIALIZE_REQUEST_ID = "ateliercode-initialize";
const CODEX_CLIENT_NAME = "AtelierCode AgentBridge";
const CODEX_CLIENT_VERSION = "0.1.0";

export class CodexRawClient {
  private initialized = false;

  constructor(private readonly transport: CodexTransport) {}

  async connect(): Promise<void> {
    await this.transport.connect();
    if (this.initialized) {
      return;
    }

    const initializeParams: InitializeParams = {
      clientInfo: {
        name: CODEX_CLIENT_NAME,
        title: null,
        version: CODEX_CLIENT_VERSION,
      },
      capabilities: {
        experimentalApi: true,
      },
    };
    await this.transport.send<InitializeResponse>({
      id: CODEX_INITIALIZE_REQUEST_ID,
      method: "initialize",
      params: initializeParams,
    });

    const initialized: ClientNotification = {
      method: "initialized",
    };
    await this.transport.notify(initialized);
    this.initialized = true;
  }

  async disconnect(): Promise<void> {
    this.initialized = false;
    await this.transport.disconnect();
  }

  modelList(requestID: CodexTransportRequestID, params: ModelListParams): Promise<ModelListResponse> {
    return this.transport.send<ModelListResponse>({
      id: requestID,
      method: "model/list",
      params,
    });
  }

  threadStart(requestID: CodexTransportRequestID, params: ThreadStartParams): Promise<ThreadStartResponse> {
    return this.transport.send<ThreadStartResponse>({
      id: requestID,
      method: "thread/start",
      params,
    });
  }

  threadResume(
    requestID: CodexTransportRequestID,
    params: ThreadResumeParams,
  ): Promise<ThreadResumeResponse> {
    return this.transport.send<ThreadResumeResponse>({
      id: requestID,
      method: "thread/resume",
      params,
    });
  }

  threadRead(requestID: CodexTransportRequestID, params: ThreadReadParams): Promise<ThreadReadResponse> {
    return this.transport.send<ThreadReadResponse>({
      id: requestID,
      method: "thread/read",
      params,
    });
  }

  threadFork(requestID: CodexTransportRequestID, params: ThreadForkParams): Promise<ThreadForkResponse> {
    return this.transport.send<ThreadForkResponse>({
      id: requestID,
      method: "thread/fork",
      params,
    });
  }

  threadArchive(
    requestID: CodexTransportRequestID,
    params: ThreadArchiveParams,
  ): Promise<ThreadArchiveResponse> {
    return this.transport.send<ThreadArchiveResponse>({
      id: requestID,
      method: "thread/archive",
      params,
    });
  }

  threadSetName(
    requestID: CodexTransportRequestID,
    params: ThreadSetNameParams,
  ): Promise<ThreadSetNameResponse> {
    return this.transport.send<ThreadSetNameResponse>({
      id: requestID,
      method: "thread/name/set",
      params,
    });
  }

  threadUnarchive(
    requestID: CodexTransportRequestID,
    params: ThreadUnarchiveParams,
  ): Promise<ThreadUnarchiveResponse> {
    return this.transport.send<ThreadUnarchiveResponse>({
      id: requestID,
      method: "thread/unarchive",
      params,
    });
  }

  threadRollback(
    requestID: CodexTransportRequestID,
    params: ThreadRollbackParams,
  ): Promise<ThreadRollbackResponse> {
    return this.transport.send<ThreadRollbackResponse>({
      id: requestID,
      method: "thread/rollback",
      params,
    });
  }

  threadList(requestID: CodexTransportRequestID, params: ThreadListParams): Promise<ThreadListResponse> {
    return this.transport.send<ThreadListResponse>({
      id: requestID,
      method: "thread/list",
      params,
    });
  }

  turnStart(requestID: CodexTransportRequestID, params: TurnStartParams): Promise<TurnStartResponse> {
    return this.transport.send<TurnStartResponse>({
      id: requestID,
      method: "turn/start",
      params,
    });
  }

  turnInterrupt(
    requestID: CodexTransportRequestID,
    params: TurnInterruptParams,
  ): Promise<TurnInterruptResponse> {
    return this.transport.send<TurnInterruptResponse>({
      id: requestID,
      method: "turn/interrupt",
      params,
    });
  }

  readAccount(requestID: CodexTransportRequestID, params: GetAccountParams): Promise<GetAccountResponse> {
    return this.transport.send<GetAccountResponse>({
      id: requestID,
      method: "account/read",
      params,
    });
  }

  readAccountRateLimits(requestID: CodexTransportRequestID): Promise<GetAccountRateLimitsResponse> {
    return this.transport.send<GetAccountRateLimitsResponse>({
      id: requestID,
      method: "account/rateLimits/read",
    });
  }

  login(requestID: CodexTransportRequestID, params: LoginAccountParams): Promise<LoginAccountResponse> {
    return this.transport.send<LoginAccountResponse>({
      id: requestID,
      method: "account/login/start",
      params,
    });
  }

  logout(requestID: CodexTransportRequestID): Promise<void> {
    return this.transport.send<void>({
      id: requestID,
      method: "account/logout",
    });
  }

  respond(response: CodexTransportResponse): Promise<void> {
    return this.transport.respond(response);
  }
}
