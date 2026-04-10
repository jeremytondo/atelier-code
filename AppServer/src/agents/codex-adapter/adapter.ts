import type { AgentAdapter } from "@/agents/adapter";
import { createCodexAgentSession } from "@/agents/codex-adapter/session";
import type { CodexAgentConfig, EnabledAgentConfig } from "@/agents/config";
import type { Logger } from "@/app/logger";
import { err } from "@/core/shared";

export type CreateCodexAgentAdapterOptions = Readonly<{
  logger: Logger;
}>;

export const createCodexAgentAdapter = (options: CreateCodexAgentAdapterOptions): AgentAdapter => ({
  provider: "codex",
  createSession: async (definition) => {
    const agentId = definition.id;
    const configuredProvider = definition.provider;

    if (!isCodexAgentConfig(definition)) {
      return err({
        type: "sessionUnavailable",
        agentId,
        provider: "codex",
        code: "startupFailed",
        message: `Codex adapter received non-Codex agent config for provider "${configuredProvider}".`,
      });
    }

    return createCodexAgentSession({
      agentId,
      config: definition,
      logger: options.logger.withContext({
        agentId,
        provider: configuredProvider,
      }),
    });
  },
});

const isCodexAgentConfig = (definition: EnabledAgentConfig): definition is CodexAgentConfig =>
  definition.provider === "codex";
