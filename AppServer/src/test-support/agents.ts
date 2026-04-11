import type { AgentAdapter } from "@/agents/adapter";
import type {
  AgentListModelsParams,
  AgentListModelsResult,
  AgentListThreadsParams,
  AgentListThreadsResult,
  AgentNotification,
  AgentOperationResult,
  AgentRequestId,
  AgentSession,
  AgentSessionLookupError,
  AgentSessionState,
  AgentThread,
  AgentThreadReadParams,
  AgentThreadResult,
} from "@/agents/contracts";
import type { AgentRegistry } from "@/agents/registry";

export type FakeAgentSession = AgentSession &
  Readonly<{
    listModelsCalls: readonly Readonly<{
      requestId: AgentRequestId;
      params: AgentListModelsParams;
    }>[];
    listThreadsCalls: readonly Readonly<{
      requestId: AgentRequestId;
      params: AgentListThreadsParams;
    }>[];
    readThreadCalls: readonly Readonly<{
      requestId: AgentRequestId;
      params: AgentThreadReadParams;
    }>[];
  }>;

export type CreateFakeAgentSessionOptions = Readonly<{
  agentId?: string;
  state?: AgentSessionState;
  listModels?: (
    requestId: AgentRequestId,
    params: AgentListModelsParams,
  ) => Promise<AgentOperationResult<AgentListModelsResult>>;
  listThreads?: (
    requestId: AgentRequestId,
    params: AgentListThreadsParams,
  ) => Promise<AgentOperationResult<AgentListThreadsResult>>;
  readThread?: (
    requestId: AgentRequestId,
    params: AgentThreadReadParams,
  ) => Promise<AgentOperationResult<AgentThreadResult>>;
}>;

export const createFakeAgentSession = (
  options: CreateFakeAgentSessionOptions = {},
): FakeAgentSession => {
  let state = options.state ?? "ready";
  const listModelsCalls: Array<
    Readonly<{
      requestId: AgentRequestId;
      params: AgentListModelsParams;
    }>
  > = [];
  const listThreadsCalls: Array<
    Readonly<{
      requestId: AgentRequestId;
      params: AgentListThreadsParams;
    }>
  > = [];
  const readThreadCalls: Array<
    Readonly<{
      requestId: AgentRequestId;
      params: AgentThreadReadParams;
    }>
  > = [];

  return {
    agentId: options.agentId ?? "codex",
    provider: "codex",
    getState: () => state,
    subscribe: (_listener: (notification: AgentNotification) => void) => () => {},
    listModels: async (requestId, params) => {
      listModelsCalls.push(
        Object.freeze({
          requestId,
          params,
        }),
      );

      return (
        (await options.listModels?.(requestId, params)) ?? {
          ok: true,
          data: {
            models: [],
            nextCursor: null,
          },
        }
      );
    },
    listThreads: async (requestId, params) => {
      listThreadsCalls.push(
        Object.freeze({
          requestId,
          params,
        }),
      );

      return (
        (await options.listThreads?.(requestId, params)) ?? {
          ok: true,
          data: {
            threads: [],
            nextCursor: null,
          },
        }
      );
    },
    startThread: async () => {
      throw new Error("startThread should not be called in this test.");
    },
    resumeThread: async () => {
      throw new Error("resumeThread should not be called in this test.");
    },
    readThread: async (requestId, params) => {
      readThreadCalls.push(
        Object.freeze({
          requestId,
          params,
        }),
      );

      return (
        (await options.readThread?.(requestId, params)) ?? {
          ok: true,
          data: {
            thread: createTestAgentThread(),
          },
        }
      );
    },
    forkThread: async () => {
      throw new Error("forkThread should not be called in this test.");
    },
    startTurn: async () => {
      throw new Error("startTurn should not be called in this test.");
    },
    steerTurn: async () => {
      throw new Error("steerTurn should not be called in this test.");
    },
    interruptTurn: async () => {
      throw new Error("interruptTurn should not be called in this test.");
    },
    resolveApproval: async () => {
      throw new Error("resolveApproval should not be called in this test.");
    },
    disconnect: async () => {
      state = "disconnected";
    },
    listModelsCalls,
    listThreadsCalls,
    readThreadCalls,
  };
};

export const createFakeAgentRegistry = (
  session: AgentSession,
): AgentRegistry &
  Readonly<{
    requestedAgentIds: readonly (string | undefined)[];
  }> => {
  const requestedAgentIds: Array<string | undefined> = [];

  return {
    requestedAgentIds,
    getDefaultAgentId: () => "codex",
    listAgents: () => [
      {
        id: "codex",
        provider: "codex",
      },
    ],
    getAgent: (agentId) =>
      agentId === "codex"
        ? {
            id: "codex",
            provider: "codex",
          }
        : undefined,
    getSession: async (agentId) => {
      requestedAgentIds.push(agentId);
      return {
        ok: true,
        data: session,
      };
    },
    disconnectAll: async () => {},
  };
};

export type CreateFakeAgentAdapterOptions = Readonly<{
  createSessionResult?:
    | Readonly<{
        ok: true;
        data: AgentSession;
      }>
    | Readonly<{
        ok: false;
        error: AgentSessionLookupError;
      }>;
  session?: AgentSession;
}>;

export const createFakeAgentAdapter = (
  options: CreateFakeAgentAdapterOptions = {},
): AgentAdapter => ({
  provider: "codex",
  createSession: async () =>
    options.createSessionResult ?? {
      ok: true,
      data: options.session ?? createFakeAgentSession(),
    },
});

export const createTestAgentModel = (
  overrides: Partial<
    Readonly<{
      id: string;
      model: string;
      displayName: string;
      hidden: boolean;
      isDefault: boolean;
      defaultReasoningEffort: "none" | "minimal" | "low" | "medium" | "high" | "xhigh";
      supportsPersonality: boolean;
    }>
  > = {},
) =>
  Object.freeze({
    id: overrides.id ?? "gpt-5.4",
    model: overrides.model ?? "gpt-5.4",
    displayName: overrides.displayName ?? "GPT-5.4",
    hidden: overrides.hidden ?? false,
    defaultReasoningEffort: overrides.defaultReasoningEffort ?? ("medium" as const),
    supportedReasoningEfforts: [
      {
        reasoningEffort: overrides.defaultReasoningEffort ?? ("medium" as const),
        description:
          (overrides.defaultReasoningEffort ?? "medium") === "high"
            ? "Deeper reasoning"
            : "Balanced",
      },
    ],
    inputModalities: ["text"],
    supportsPersonality: overrides.supportsPersonality ?? true,
    isDefault: overrides.isDefault ?? false,
  });

export const createTestAgentThread = (
  overrides: Partial<
    Readonly<{
      id: string;
      preview: string;
      createdAt: string;
      updatedAt: string;
      workspacePath: string;
      name: string | null;
      archived: boolean;
      status: AgentThread["status"];
    }>
  > = {},
) =>
  Object.freeze({
    id: overrides.id ?? "thread-1",
    preview: overrides.preview ?? "Thread preview",
    createdAt: overrides.createdAt ?? "2026-04-10T10:00:00.000Z",
    updatedAt: overrides.updatedAt ?? "2026-04-10T11:00:00.000Z",
    workspacePath: overrides.workspacePath ?? "/tmp/project",
    name: overrides.name ?? null,
    archived: overrides.archived ?? false,
    status: overrides.status ?? ({ type: "idle" } as const),
  });
