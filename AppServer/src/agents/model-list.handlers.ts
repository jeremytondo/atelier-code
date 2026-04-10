import { createAgentSessionUnavailableError, createProviderError } from "@/agents/protocol-errors";
import { ModelListParamsSchema, ModelListResultSchema } from "@/agents/schemas";
import type { AgentsService } from "@/agents/service";
import type { ProtocolDispatcher } from "@/core/protocol";
import { createSessionNotInitializedResult } from "@/core/protocol/errors";
import { ok } from "@/core/shared";

export type RegisterModelListMethodOptions = Readonly<{
  registerMethod: ProtocolDispatcher["registerMethod"];
  service: AgentsService;
}>;

export const registerModelListMethod = (options: RegisterModelListMethodOptions): void => {
  options.registerMethod({
    method: "model/list",
    paramsSchema: ModelListParamsSchema,
    resultSchema: ModelListResultSchema,
    handler: async ({ params, requestId, session }) => {
      if (!session.isInitialized()) {
        return createSessionNotInitializedResult();
      }

      const modelsResult = await options.service.listModels(requestId, params);

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
        }
      }

      return ok(modelsResult.data);
    },
  });
};
