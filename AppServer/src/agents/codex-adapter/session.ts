import { BaseEnvironmentResolver } from "@/agents/codex-adapter/base-environment";
import { discoverCodexExecutable } from "@/agents/codex-adapter/executable-discovery";
import {
  mapCodexModelSummary,
  mapCodexThreadSummary,
  mapCodexTurnSummary,
} from "@/agents/codex-adapter/model-mapper";
import {
  mapCodexDisconnectNotification,
  mapCodexResolvedApproval,
  mapCodexServerRequest,
  mapCodexTransportNotification,
} from "@/agents/codex-adapter/notification-mapper";
import type {
  CodexAskForApproval,
  CodexClientNotification,
  CodexCommandExecutionApprovalDecision,
  CodexFileChangeApprovalDecision,
  CodexInitializeParams,
  CodexMcpServerElicitationRequestResponse,
  CodexModelListParams,
  CodexThreadForkParams,
  CodexThreadReadParams,
  CodexThreadResumeParams,
  CodexThreadStartParams,
  CodexTurnInterruptParams,
  CodexTurnStartParams,
  CodexTurnSteerParams,
  CodexUserInput,
} from "@/agents/codex-adapter/protocol";
import {
  parseCodexInitializeResponse,
  parseCodexModelListResponse,
  parseCodexThreadResponse,
  parseCodexTurnInterruptResponse,
  parseCodexTurnResponse,
  parseCodexTurnSteerResponse,
} from "@/agents/codex-adapter/protocol";
import {
  CodexAppServerTransport,
  type CodexTransport,
  CodexTransportError,
  CodexTransportRemoteError,
  type CodexTransportResponse,
} from "@/agents/codex-adapter/transport";
import type { CodexAgentConfig } from "@/agents/config";
import type {
  AgentApprovalRequest,
  AgentApprovalResolveParams,
  AgentApprovalResolveResult,
  AgentDisconnectReason,
  AgentListModelsParams,
  AgentListModelsResult,
  AgentNotification,
  AgentOperationError,
  AgentOperationResult,
  AgentRequestId,
  AgentSession,
  AgentSessionLookupError,
  AgentThreadForkParams,
  AgentThreadReadParams,
  AgentThreadResult,
  AgentThreadResumeParams,
  AgentThreadStartParams,
  AgentTurnInterruptParams,
  AgentTurnResult,
  AgentTurnStartParams,
  AgentTurnSteerParams,
} from "@/agents/contracts";
import type { Logger } from "@/app/logger";
import { err, ok, type Result } from "@/core/shared";

const CODEX_INITIALIZE_REQUEST_ID = "atelier-appserver-initialize";
const CODEX_CLIENT_NAME = "AtelierCode App Server";
const CODEX_CLIENT_VERSION = "0.1.0";

export type CreateCodexAgentSessionOptions = Readonly<{
  agentId: string;
  config: CodexAgentConfig;
  logger: Logger;
  transport?: CodexTransport;
  environmentResolver?: BaseEnvironmentResolver;
}>;

export const createCodexAgentSession = async (
  options: CreateCodexAgentSessionOptions,
): Promise<Result<AgentSession, AgentSessionLookupError>> => {
  const environmentResolver =
    options.environmentResolver ??
    new BaseEnvironmentResolver({
      inheritedEnvironment: applyCodexEnvironmentOverrides(process.env, options.config),
    });
  const resolvedEnvironment = await environmentResolver.resolve();
  const executable = await discoverCodexExecutable({
    environment: resolvedEnvironment.environment,
    baseEnvironmentSource: resolvedEnvironment.diagnostics.source,
  });

  if (executable.status !== "found") {
    return err({
      type: "sessionUnavailable",
      agentId: options.agentId,
      provider: "codex",
      code: "executableMissing",
      message: "Codex executable could not be discovered for this agent session.",
      executable,
      environment: resolvedEnvironment.diagnostics,
      detail: {
        checkedPaths: executable.checkedPaths,
      },
    });
  }

  const transport =
    options.transport ??
    new CodexAppServerTransport({
      executable,
      environment: resolvedEnvironment.environment,
    });

  try {
    await transport.connect();
  } catch (error) {
    return err(
      normalizeSessionStartupError(options.agentId, executable, resolvedEnvironment, error),
    );
  }

  return ok(
    createConnectedSession({
      agentId: options.agentId,
      logger: options.logger,
      transport,
      executable,
      environment: resolvedEnvironment,
    }),
  );
};

type ConnectedSessionOptions = Readonly<{
  agentId: string;
  logger: Logger;
  transport: CodexTransport;
  executable: Awaited<ReturnType<typeof discoverCodexExecutable>>;
  environment: Awaited<ReturnType<BaseEnvironmentResolver["resolve"]>>;
}>;

const createConnectedSession = (options: ConnectedSessionOptions): AgentSession => {
  const listeners = new Set<(notification: AgentNotification) => void>();
  const approvalsByRequestId = new Map<
    string,
    { approval: AgentApprovalRequest; resolution?: AgentApprovalResolveParams["resolution"] }
  >();
  let state: AgentSession["getState"] extends () => infer T ? T : never = "idle";
  let initializePromise: Promise<Result<void, AgentOperationError>> | null = null;
  let initialized = false;

  const emit = (notification: AgentNotification): void => {
    if (notification.type === "disconnect") {
      state = "disconnected";
    }

    for (const listener of listeners) {
      listener(notification);
    }
  };

  options.transport.subscribe((event) => {
    switch (event.type) {
      case "notification": {
        if (event.notification.method === "serverRequest/resolved") {
          const params =
            typeof event.notification.params === "object" && event.notification.params !== null
              ? (event.notification.params as Record<string, unknown>)
              : null;
          const requestId = getRequestId(params?.requestId);

          if (requestId !== null) {
            const approval = approvalsByRequestId.get(requestIdKey(requestId));
            approvalsByRequestId.delete(requestIdKey(requestId));
            const resolvedApproval = mapCodexResolvedApproval(requestId, approval, {
              agentId: options.agentId,
              provider: "codex",
            });
            if (resolvedApproval !== null) {
              emit(resolvedApproval);
            }
          }
          return;
        }

        for (const notification of mapCodexTransportNotification(event.notification, {
          agentId: options.agentId,
          provider: "codex",
        })) {
          emit(notification);
        }
        return;
      }
      case "serverRequest":
        for (const notification of mapCodexServerRequest(event.request, {
          agentId: options.agentId,
          provider: "codex",
        })) {
          if (notification.type === "approval" && notification.event === "requested") {
            approvalsByRequestId.set(requestIdKey(notification.requestId), {
              approval: notification.approval,
            });
          }
          emit(notification);
        }
        return;
      case "disconnect":
        emit(
          mapCodexDisconnectNotification(event.disconnect, {
            agentId: options.agentId,
            provider: "codex",
          }),
        );
    }
  });

  const ensureInitialized = async (): Promise<Result<void, AgentOperationError>> => {
    if (initialized) {
      return ok(undefined);
    }

    if (initializePromise !== null) {
      return initializePromise;
    }

    state = "connecting";
    initializePromise = (async () => {
      try {
        const initializeParams: CodexInitializeParams = {
          clientInfo: {
            name: CODEX_CLIENT_NAME,
            title: null,
            version: CODEX_CLIENT_VERSION,
          },
          capabilities: {
            experimentalApi: true,
          },
        };
        parseCodexInitializeResponse(
          await options.transport.send({
            id: CODEX_INITIALIZE_REQUEST_ID,
            method: "initialize",
            params: initializeParams,
          }),
        );
        const initializedNotification: CodexClientNotification = {
          method: "initialized",
        };
        await options.transport.notify(initializedNotification);
        initialized = true;
        state = "ready";
        options.logger.info("Codex session initialized");
        return ok(undefined);
      } catch (error) {
        state = "disconnected";
        return err(
          normalizeOperationError(
            options.agentId,
            options.executable,
            options.environment,
            CODEX_INITIALIZE_REQUEST_ID,
            error,
          ),
        );
      } finally {
        initializePromise = null;
      }
    })();

    return initializePromise;
  };

  const runOperation = async <T>(
    requestId: AgentRequestId,
    operation: () => Promise<T>,
  ): Promise<AgentOperationResult<T>> => {
    const initializationResult = await ensureInitialized();
    if (!initializationResult.ok) {
      return initializationResult;
    }

    try {
      return ok(await operation());
    } catch (error) {
      return err(
        normalizeOperationError(
          options.agentId,
          options.executable,
          options.environment,
          requestId,
          error,
        ),
      );
    }
  };

  const listModels = async (
    requestId: AgentRequestId,
    params: AgentListModelsParams,
  ): Promise<AgentOperationResult<AgentListModelsResult>> =>
    runOperation(requestId, async () => {
      const rawParams: CodexModelListParams = {
        limit: params.limit,
        includeHidden: params.includeHidden === true ? true : undefined,
      };
      const response = parseCodexModelListResponse(
        await options.transport.send({
          id: requestId,
          method: "model/list",
          params: rawParams,
        }),
      );

      return {
        models: response.data.map((model) => mapCodexModelSummary(model)),
        nextCursor: response.nextCursor,
      };
    });

  const startThread = async (
    requestId: AgentRequestId,
    params: AgentThreadStartParams,
  ): Promise<AgentOperationResult<AgentThreadResult>> =>
    runOperation(requestId, async () => {
      const response = parseCodexThreadResponse(
        await options.transport.send({
          id: requestId,
          method: "thread/start",
          params: buildThreadStartParams(params),
        }),
      );

      return {
        thread: mapCodexThreadSummary(response.thread),
      };
    });

  const resumeThread = async (
    requestId: AgentRequestId,
    params: AgentThreadResumeParams,
  ): Promise<AgentOperationResult<AgentThreadResult>> =>
    runOperation(requestId, async () => {
      const response = parseCodexThreadResponse(
        await options.transport.send({
          id: requestId,
          method: "thread/resume",
          params: buildThreadResumeParams(params),
        }),
      );

      return {
        thread: mapCodexThreadSummary(response.thread),
      };
    });

  const readThread = async (
    requestId: AgentRequestId,
    params: AgentThreadReadParams,
  ): Promise<AgentOperationResult<AgentThreadResult>> =>
    runOperation(requestId, async () => {
      const rawParams: CodexThreadReadParams = {
        threadId: params.threadId,
        includeTurns: params.includeTurns,
      };
      const response = parseCodexThreadResponse(
        await options.transport.send({
          id: requestId,
          method: "thread/read",
          params: rawParams,
        }),
      );

      return {
        thread: mapCodexThreadSummary(response.thread),
      };
    });

  const forkThread = async (
    requestId: AgentRequestId,
    params: AgentThreadForkParams,
  ): Promise<AgentOperationResult<AgentThreadResult>> =>
    runOperation(requestId, async () => {
      const rawParams: CodexThreadForkParams = {
        threadId: params.threadId,
        persistExtendedHistory: true,
      };
      const response = parseCodexThreadResponse(
        await options.transport.send({
          id: requestId,
          method: "thread/fork",
          params: rawParams,
        }),
      );

      return {
        thread: mapCodexThreadSummary(response.thread),
      };
    });

  const startTurn = async (
    requestId: AgentRequestId,
    params: AgentTurnStartParams,
  ): Promise<AgentOperationResult<AgentTurnResult>> =>
    runOperation(requestId, async () => {
      const response = parseCodexTurnResponse(
        await options.transport.send({
          id: requestId,
          method: "turn/start",
          params: buildTurnStartParams(params),
        }),
      );

      return {
        turn: mapCodexTurnSummary(response.turn),
      };
    });

  const steerTurn = async (
    requestId: AgentRequestId,
    params: AgentTurnSteerParams,
  ): Promise<AgentOperationResult<AgentTurnResult>> =>
    runOperation(requestId, async () => {
      const response = parseCodexTurnSteerResponse(
        await options.transport.send({
          id: requestId,
          method: "turn/steer",
          params: buildTurnSteerParams(params),
        }),
      );

      return {
        turn: {
          id: response.turnId,
          status: { type: "inProgress" },
        },
      };
    });

  const interruptTurn = async (
    requestId: AgentRequestId,
    params: AgentTurnInterruptParams,
  ): Promise<AgentOperationResult<AgentTurnResult>> =>
    runOperation(requestId, async () => {
      parseCodexTurnInterruptResponse(
        await options.transport.send({
          id: requestId,
          method: "turn/interrupt",
          params: buildTurnInterruptParams(params),
        }),
      );

      return {
        turn: {
          id: params.turnId,
          status: { type: "interrupted" },
        },
      };
    });

  const resolveApproval = async (
    params: AgentApprovalResolveParams,
  ): Promise<AgentOperationResult<AgentApprovalResolveResult>> => {
    const initializationResult = await ensureInitialized();
    if (!initializationResult.ok) {
      return initializationResult;
    }

    const pendingApproval = approvalsByRequestId.get(requestIdKey(params.requestId));
    if (pendingApproval === undefined) {
      return err({
        type: "invalidProviderMessage",
        agentId: options.agentId,
        provider: "codex",
        message: `No pending approval exists for request ${String(params.requestId)}.`,
        detail: { requestId: params.requestId },
      });
    }

    pendingApproval.resolution = params.resolution;

    try {
      const response: CodexTransportResponse = {
        id: params.requestId,
        result: buildApprovalDecision(pendingApproval.approval, params),
      };
      await options.transport.respond(response);
      return ok({
        requestId: params.requestId,
        resolution: params.resolution,
      });
    } catch (error) {
      return err(
        normalizeOperationError(
          options.agentId,
          options.executable,
          options.environment,
          params.requestId,
          error,
        ),
      );
    }
  };

  return Object.freeze({
    agentId: options.agentId,
    provider: "codex",
    getState: () => state,
    subscribe: (listener) => {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    listModels,
    startThread,
    resumeThread,
    readThread,
    forkThread,
    startTurn,
    steerTurn,
    interruptTurn,
    resolveApproval,
    disconnect: async (reason?: AgentDisconnectReason) => {
      state = "disconnecting";
      await options.transport.disconnect(reason);
      state = "disconnected";
    },
  });
};

const buildThreadStartParams = (params: AgentThreadStartParams): CodexThreadStartParams => ({
  cwd: params.workspacePath,
  model: params.model,
  approvalPolicy: normalizeApprovalPolicy(params.approvalPolicy),
  sandbox: undefined,
  experimentalRawEvents: false,
  persistExtendedHistory: true,
});

const buildThreadResumeParams = (params: AgentThreadResumeParams): CodexThreadResumeParams => ({
  threadId: params.threadId,
  cwd: params.workspacePath,
  model: params.model,
  approvalPolicy: normalizeApprovalPolicy(params.approvalPolicy),
  sandbox: undefined,
  persistExtendedHistory: true,
});

const buildTurnStartParams = (params: AgentTurnStartParams): CodexTurnStartParams => ({
  threadId: params.threadId,
  input: [toTextInput(params.prompt)],
  cwd: params.cwd,
  model: params.model,
  effort: params.reasoningEffort,
});

const buildTurnSteerParams = (params: AgentTurnSteerParams): CodexTurnSteerParams => ({
  threadId: params.threadId,
  expectedTurnId: params.turnId,
  input: [toTextInput(params.prompt)],
});

const buildTurnInterruptParams = (params: AgentTurnInterruptParams): CodexTurnInterruptParams => ({
  threadId: params.threadId,
  turnId: params.turnId,
});

const toTextInput = (prompt: string): CodexUserInput => ({
  type: "text",
  text: prompt,
  text_elements: [],
});

const normalizeApprovalPolicy = (value: string | undefined): CodexAskForApproval | undefined => {
  switch (value) {
    case "untrusted":
    case "on-failure":
    case "on-request":
    case "never":
      return value;
    default:
      return undefined;
  }
};

const buildApprovalDecision = (
  approval: AgentApprovalRequest,
  params: AgentApprovalResolveParams,
):
  | CodexCommandExecutionApprovalDecision
  | CodexFileChangeApprovalDecision
  | CodexMcpServerElicitationRequestResponse => {
  switch (approval.kind) {
    case "commandExecution":
      return mapCommandApprovalResolution(params.resolution);
    case "fileChange":
      return mapFileChangeApprovalResolution(params.resolution);
    case "mcpElicitation":
      return mapMcpElicitationResolution(params.resolution);
    case "unknown":
      return mapFileChangeApprovalResolution(params.resolution);
  }
};

const mapCommandApprovalResolution = (
  resolution: AgentApprovalResolveParams["resolution"],
): CodexCommandExecutionApprovalDecision => {
  switch (resolution) {
    case "approved":
      return "accept";
    case "approvedForSession":
      return "acceptForSession";
    case "declined":
      return "decline";
    case "cancelled":
    case "stale":
      return "cancel";
  }
};

const mapFileChangeApprovalResolution = (
  resolution: AgentApprovalResolveParams["resolution"],
): CodexFileChangeApprovalDecision => {
  switch (resolution) {
    case "approved":
      return "accept";
    case "approvedForSession":
      return "acceptForSession";
    case "declined":
      return "decline";
    case "cancelled":
    case "stale":
      return "cancel";
  }
};

const mapMcpElicitationResolution = (
  resolution: AgentApprovalResolveParams["resolution"],
): CodexMcpServerElicitationRequestResponse => ({
  action:
    resolution === "approved" || resolution === "approvedForSession"
      ? "accept"
      : resolution === "declined"
        ? "decline"
        : "cancel",
  content: null,
  _meta: null,
});

const applyCodexEnvironmentOverrides = (
  environment: Readonly<Record<string, string | undefined>>,
  config: CodexAgentConfig,
): Record<string, string | undefined> => ({
  ...environment,
  ...(config.executablePath ? { ATELIERCODE_CODEX_PATH: config.executablePath } : {}),
  ...(config.environment ?? {}),
});

const normalizeSessionStartupError = (
  agentId: string,
  executable: Awaited<ReturnType<typeof discoverCodexExecutable>>,
  environment: Awaited<ReturnType<BaseEnvironmentResolver["resolve"]>>,
  error: unknown,
): AgentSessionLookupError => {
  if (error instanceof CodexTransportError) {
    return {
      type: "sessionUnavailable",
      agentId,
      provider: "codex",
      code: error.code === "provider_executable_missing" ? "executableMissing" : "startupFailed",
      message: error.message,
      executable,
      environment: environment.diagnostics,
      detail: error.detail,
    };
  }

  return {
    type: "sessionUnavailable",
    agentId,
    provider: "codex",
    code: "startupFailed",
    message: error instanceof Error ? error.message : "Codex session startup failed.",
    executable,
    environment: environment.diagnostics,
  };
};

const normalizeOperationError = (
  agentId: string,
  executable: Awaited<ReturnType<typeof discoverCodexExecutable>>,
  environment: Awaited<ReturnType<BaseEnvironmentResolver["resolve"]>>,
  requestId: AgentRequestId,
  error: unknown,
): AgentOperationError => {
  if (error instanceof CodexTransportRemoteError) {
    return {
      type: "remoteError",
      agentId,
      provider: "codex",
      requestId: error.requestId,
      code: error.code,
      message: error.message,
      data: error.data,
    };
  }

  if (error instanceof CodexTransportError) {
    return {
      type: "sessionUnavailable",
      agentId,
      provider: "codex",
      code:
        error.code === "provider_executable_missing"
          ? "executableMissing"
          : error.code === "process_exited"
            ? "disconnected"
            : "startupFailed",
      message: error.message,
      executable,
      environment: environment.diagnostics,
      detail: error.detail,
    };
  }

  return {
    type: "invalidProviderMessage",
    agentId,
    provider: "codex",
    message: `Codex operation ${String(requestId)} failed unexpectedly.`,
    detail: {
      error: error instanceof Error ? error.message : String(error),
    },
  };
};

const requestIdKey = (requestId: string | number): string =>
  `${typeof requestId}:${String(requestId)}`;

const getRequestId = (value: unknown): string | number | null =>
  typeof value === "string" ? value : Number.isInteger(value) ? (value as number) : null;
