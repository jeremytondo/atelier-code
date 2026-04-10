import type { AgentAdapter } from "@/agents/adapter";
import { createCodexAgentSession } from "@/agents/codex-adapter/session";
import type { CodexAgentConfig } from "@/agents/config";
import type { Logger } from "@/app/logger";

export type CreateCodexAgentAdapterOptions = Readonly<{
  logger: Logger;
}>;

export const createCodexAgentAdapter = (options: CreateCodexAgentAdapterOptions): AgentAdapter => ({
  provider: "codex",
  createSession: async (definition) =>
    createCodexAgentSession({
      agentId: definition.id,
      config: definition as CodexAgentConfig,
      logger: options.logger.withContext({
        agentId: definition.id,
        provider: definition.provider,
      }),
    }),
});
