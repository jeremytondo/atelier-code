import { describe, expect, test } from "bun:test";
import { createAgentsService } from "@/agents/service";
import {
  createFakeAgentRegistry,
  createFakeAgentSession,
  createTestAgentModel,
} from "@/test-support/agents";
import { createSilentLogger } from "@/test-support/logger";

describe("createAgentsService", () => {
  test("looks up the default agent session and forwards params while preserving nextCursor", async () => {
    const session = createFakeAgentSession({
      listModels: async () => ({
        ok: true,
        data: {
          models: [
            createTestAgentModel({
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
    const registry = createFakeAgentRegistry(session);
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
      registry: createFakeAgentRegistry(
        createFakeAgentSession({
          listModels: async () => ({
            ok: true,
            data: {
              models: [
                createTestAgentModel(),
                createTestAgentModel({
                  id: "gpt-5.4-hidden",
                  model: "gpt-5.4-hidden",
                  displayName: "GPT-5.4 Hidden",
                  hidden: true,
                  defaultReasoningEffort: "high",
                  supportsPersonality: false,
                }),
              ],
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
        models: [createTestAgentModel()],
        nextCursor: null,
      },
    });
  });

  test("includes hidden models when includeHidden is true", async () => {
    const hiddenModel = createTestAgentModel({
      id: "gpt-5.4-hidden",
      model: "gpt-5.4-hidden",
      displayName: "GPT-5.4 Hidden",
      hidden: true,
      defaultReasoningEffort: "high",
      supportsPersonality: false,
    });
    const service = createAgentsService({
      logger: createSilentLogger(),
      registry: createFakeAgentRegistry(
        createFakeAgentSession({
          listModels: async () => ({
            ok: true,
            data: {
              models: [createTestAgentModel(), hiddenModel],
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
        models: [createTestAgentModel(), hiddenModel],
        nextCursor: null,
      },
    });
  });

  test("treats invalid provider payloads as infrastructure failures", async () => {
    const service = createAgentsService({
      logger: createSilentLogger(),
      registry: createFakeAgentRegistry(
        createFakeAgentSession({
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
