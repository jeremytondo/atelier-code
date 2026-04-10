import type { AgentAdapter } from "@/agents/adapter";
import type { AgentsConfig } from "@/agents/config";
import type { AgentSessionLookupError } from "@/agents/contracts";
import { registerModelListMethod } from "@/agents/model-list.handlers";
import { type AgentRegistry, createAgentRegistry } from "@/agents/registry";
import { createAgentsService } from "@/agents/service";
import type { Logger } from "@/app/logger";
import type { ProtocolDispatcher } from "@/core/protocol";
import type { LifecycleComponent } from "@/core/shared";
import { err } from "@/core/shared";

export type AgentsFeature = Readonly<{
  lifecycle: LifecycleComponent;
  registry: AgentRegistry;
}>;

export type CreateAgentsFeatureOptions = Readonly<{
  config: AgentsConfig;
  logger: Logger;
  adapters: readonly AgentAdapter[];
  registerMethod: ProtocolDispatcher["registerMethod"];
}>;

export const createAgentsFeature = (options: CreateAgentsFeatureOptions): AgentsFeature => {
  const adaptersByProvider = new Map(
    options.adapters.map((adapter) => [adapter.provider, adapter] as const),
  );

  const createSession = async (definition: AgentsConfig["enabled"][number]) => {
    const adapter = adaptersByProvider.get(definition.provider);

    if (adapter === undefined) {
      const unsupportedProviderError: AgentSessionLookupError = {
        type: "sessionUnavailable",
        agentId: definition.id,
        provider: definition.provider,
        code: "startupFailed",
        message: `No agent adapter is registered for provider "${definition.provider}".`,
      };

      return err(unsupportedProviderError);
    }

    return adapter.createSession(definition);
  };

  const registry = createAgentRegistry({
    defaultAgentId: options.config.defaultAgent,
    agents: options.config.enabled,
    createSession,
  });
  const service = createAgentsService({
    logger: options.logger,
    registry,
  });

  registerModelListMethod({
    registerMethod: options.registerMethod,
    service,
  });

  return Object.freeze({
    registry,
    lifecycle: Object.freeze({
      name: "feature.agents",
      start: async () => {
        options.logger.info("Agents feature ready", {
          defaultAgent: options.config.defaultAgent,
          enabledAgents: options.config.enabled.map((agent) => agent.id).join(","),
          registeredProviders: [...adaptersByProvider.keys()].join(","),
        });
      },
      stop: async (reason: string) => {
        await registry.disconnectAll(reason);
        options.logger.info("Agents feature stopped", { reason });
      },
    }),
  });
};
