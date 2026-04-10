import { describe, expect, test } from "bun:test";
import type {
  AgentListModelsParams,
  AgentListModelsResult,
  AgentNotification,
  AgentSession,
} from "@/agents/contracts";
import type { AgentRegistry } from "@/agents/registry";
import { createAgentsService } from "@/agents/service";
import { createSilentLogger } from "@/test-support/logger";

describe("createAgentsService", () => {
  test("looks up the default agent session and forwards params while preserving nextCursor", async () => {
    const session = createFakeSession({
      listModels: async () => ({
        ok: true,
        data: {
          models: [
            createVisibleModel({
              id: "gpt-5.4",
              model: "gpt-5.4",
              displayName: "GPT-5.4",
              isDefault: true,
            }),
          ],
          nextCursor: "cursor-2",
        },
      }),
    });
    const registry = createFakeRegistry(session);
    const service = createAgentsService({
      logger: createSilentLogger(),
      registry,
    });

    const result = await service.listModels("req-model-list", {
      limit: 25,
      includeHidden: true,
    });

    expect(registry.requestedAgentIds).toEqual([undefined]);
    expect(session.listModelsCalls).toEqual([
      {
        requestId: "req-model-list",
        params: {
          limit: 25,
          includeHidden: true,
        },
      },
    ]);
    expect(result).toEqual({
      ok: true,
      data: {
        models: [
          {
            id: "gpt-5.4",
            model: "gpt-5.4",
            displayName: "GPT-5.4",
            hidden: false,
            defaultReasoningEffort: "medium",
            supportedReasoningEfforts: [
              {
                reasoningEffort: "medium",
                description: "Balanced",
              },
            ],
            inputModalities: ["text"],
            supportsPersonality: true,
            isDefault: true,
          },
        ],
        nextCursor: "cursor-2",
      },
    });
  });

  test("filters hidden models when includeHidden is omitted", async () => {
    const service = createAgentsService({
      logger: createSilentLogger(),
      registry: createFakeRegistry(
        createFakeSession({
          listModels: async () => ({
            ok: true,
            data: {
              models: [createVisibleModel(), createHiddenModel()],
              nextCursor: null,
            },
          }),
        }),
      ),
    });

    const result = await service.listModels("req-model-list", {});

    expect(result).toEqual({
      ok: true,
      data: {
        models: [createVisibleModel()],
        nextCursor: null,
      },
    });
  });

  test("includes hidden models when includeHidden is true", async () => {
    const service = createAgentsService({
      logger: createSilentLogger(),
      registry: createFakeRegistry(
        createFakeSession({
          listModels: async () => ({
            ok: true,
            data: {
              models: [createVisibleModel(), createHiddenModel()],
              nextCursor: null,
            },
          }),
        }),
      ),
    });

    const result = await service.listModels("req-model-list", {
      includeHidden: true,
    });

    expect(result).toEqual({
      ok: true,
      data: {
        models: [createVisibleModel(), createHiddenModel()],
        nextCursor: null,
      },
    });
  });

  test("treats invalid provider payloads as infrastructure failures", async () => {
    const service = createAgentsService({
      logger: createSilentLogger(),
      registry: createFakeRegistry(
        createFakeSession({
          listModels: async () => ({
            ok: false,
            error: {
              type: "invalidProviderMessage",
              agentId: "codex",
              provider: "codex",
              message: "Malformed provider payload.",
            },
          }),
        }),
      ),
    });

    await expect(service.listModels("req-model-list", {})).rejects.toThrow(
      "Malformed provider payload.",
    );
  });
});

const createFakeRegistry = (
  session: AgentSession,
): AgentRegistry & {
  requestedAgentIds: Array<string | undefined>;
} => {
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

const createFakeSession = (options: {
  listModels: (
    requestId: string | number,
    params: AgentListModelsParams,
  ) => Promise<
    | Readonly<{
        ok: true;
        data: AgentListModelsResult;
      }>
    | Readonly<{
        ok: false;
        error: {
          type: "invalidProviderMessage";
          agentId: string;
          provider: "codex";
          message: string;
          detail?: Record<string, unknown>;
        };
      }>
  >;
}): AgentSession & {
  listModelsCalls: Array<
    Readonly<{
      requestId: string | number;
      params: AgentListModelsParams;
    }>
  >;
} => {
  const listModelsCalls: Array<
    Readonly<{
      requestId: string | number;
      params: AgentListModelsParams;
    }>
  > = [];

  return {
    agentId: "codex",
    provider: "codex",
    getState: () => "ready",
    subscribe: (_listener: (notification: AgentNotification) => void) => () => {},
    listModels: async (requestId, params) => {
      listModelsCalls.push({
        requestId,
        params,
      });

      return options.listModels(requestId, params);
    },
    startThread: async () => {
      throw new Error("startThread should not be called in this test.");
    },
    resumeThread: async () => {
      throw new Error("resumeThread should not be called in this test.");
    },
    readThread: async () => {
      throw new Error("readThread should not be called in this test.");
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
    disconnect: async () => {},
    listModelsCalls,
  };
};

const createVisibleModel = (
  overrides: Partial<
    Readonly<{
      id: string;
      model: string;
      displayName: string;
      isDefault: boolean;
    }>
  > = {},
) =>
  Object.freeze({
    id: overrides.id ?? "gpt-5.4",
    model: overrides.model ?? "gpt-5.4",
    displayName: overrides.displayName ?? "GPT-5.4",
    hidden: false,
    defaultReasoningEffort: "medium" as const,
    supportedReasoningEfforts: [
      {
        reasoningEffort: "medium" as const,
        description: "Balanced",
      },
    ],
    inputModalities: ["text"],
    supportsPersonality: true,
    isDefault: overrides.isDefault ?? false,
  });

const createHiddenModel = () =>
  Object.freeze({
    id: "gpt-5.4-hidden",
    model: "gpt-5.4-hidden",
    displayName: "GPT-5.4 Hidden",
    hidden: true,
    defaultReasoningEffort: "high" as const,
    supportedReasoningEfforts: [
      {
        reasoningEffort: "high" as const,
        description: "Deeper reasoning",
      },
    ],
    inputModalities: ["text"],
    supportsPersonality: false,
    isDefault: false,
  });
