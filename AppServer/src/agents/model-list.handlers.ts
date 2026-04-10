import { createAgentSessionUnavailableError, createProviderError } from "@/agents/protocol-errors";
import { createAgentRequestId } from "@/agents/request-id";
import { ModelListParamsSchema, ModelListResultSchema } from "@/agents/schemas";
import type { AgentsService } from "@/agents/service";
import type { ProtocolDispatcher } from "@/core/protocol";
import { createSessionNotInitializedResult } from "@/core/protocol/errors";
import { assertNever, ok } from "@/core/shared";

export type RegisterModelListMethodOptions = Readonly<{
  registerMethod: ProtocolDispatcher["registerMethod"];
  service: AgentsService;
}>;

export const registerModelListMethod = (options: RegisterModelListMethodOptions): void => {
  options.registerMethod({
    method: "model/list",
    paramsSchema: ModelListParamsSchema,
    resultSchema: ModelListResultSchema,
    handler: async ({ connectionId, params, requestId, session }) => {
      if (!session.isInitialized()) {
        return createSessionNotInitializedResult();
      }

      const agentRequestId = createAgentRequestId({
        connectionId,
        method: "model/list",
        requestId,
      });
      const modelsResult = await options.service.listModels(agentRequestId, params);

      if (!modelsResult.ok) {
        switch (modelsResult.error.type) {
          case "sessionUnavailable":
            return {
              ok: false,
              error: createAgentSessionUnavailableError(modelsResult.error),
            };
          case "remoteError":
            return {
              ok: false,
              error: createProviderError(modelsResult.error),
            };
          default:
            return assertNever(modelsResult.error, "Unhandled model/list protocol error");
        }
      }

      return ok(modelsResult.data);
    },
  });
};
