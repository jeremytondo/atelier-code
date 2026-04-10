import type {
  AgentInvalidMessageError,
  AgentModelSummary,
  AgentRemoteError,
  AgentRequestId,
  AgentSessionUnavailableError,
} from "@/agents/contracts";
import type { AgentRegistry } from "@/agents/registry";
import type { ModelListParams, ModelListResult, ModelSummary } from "@/agents/schemas";
import type { Logger } from "@/app/logger";
import { err, ok, type Result } from "@/core/shared";

export type AgentsServiceError = AgentSessionUnavailableError | AgentRemoteError;

export type AgentsService = Readonly<{
  listModels: (
    requestId: AgentRequestId,
    params: ModelListParams,
  ) => Promise<Result<ModelListResult, AgentsServiceError>>;
}>;

export type CreateAgentsServiceOptions = Readonly<{
  logger: Logger;
  registry: AgentRegistry;
}>;

export const createAgentsService = (options: CreateAgentsServiceOptions): AgentsService =>
  Object.freeze({
    listModels: async (requestId, params) => {
      const sessionResult = await options.registry.getSession();

      if (!sessionResult.ok) {
        if (sessionResult.error.type === "sessionUnavailable") {
          return err(sessionResult.error);
        }

        throw new Error(sessionResult.error.message);
      }

      const modelsResult = await sessionResult.data.listModels(requestId, params);

      if (!modelsResult.ok) {
        switch (modelsResult.error.type) {
          case "sessionUnavailable":
          case "remoteError":
            return err(modelsResult.error);
          case "invalidProviderMessage":
            throwInvalidProviderMessage(options.logger, modelsResult.error);
        }

        throw new Error("Unhandled agent model/list error.");
      }

      const models =
        params.includeHidden === true
          ? modelsResult.data.models.map(mapModelSummary)
          : modelsResult.data.models
              .filter((model: AgentModelSummary) => !model.hidden)
              .map(mapModelSummary);

      return ok({
        models,
        nextCursor: modelsResult.data.nextCursor,
      });
    },
  });

const mapModelSummary = (model: AgentModelSummary): ModelSummary =>
  Object.freeze({
    id: model.id,
    model: model.model,
    displayName: model.displayName,
    hidden: model.hidden,
    defaultReasoningEffort: model.defaultReasoningEffort,
    supportedReasoningEfforts: model.supportedReasoningEfforts.map((effort) =>
      Object.freeze({
        reasoningEffort: effort.reasoningEffort,
        ...(effort.description ? { description: effort.description } : {}),
      }),
    ),
    ...(model.inputModalities ? { inputModalities: [...model.inputModalities] } : {}),
    ...(model.supportsPersonality !== undefined
      ? { supportsPersonality: model.supportsPersonality }
      : {}),
    isDefault: model.isDefault,
  });

const throwInvalidProviderMessage = (logger: Logger, error: AgentInvalidMessageError): never => {
  logger.error("Agent operation returned an invalid provider message", {
    agentId: error.agentId,
    provider: error.provider,
    message: error.message,
    ...(error.detail ? { detail: JSON.stringify(error.detail) } : {}),
  });

  throw new Error(error.message, { cause: error });
};
