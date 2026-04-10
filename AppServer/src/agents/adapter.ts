import type { EnabledAgentConfig } from "@/agents/config";
import type { AgentProvider, AgentSession, AgentSessionLookupError } from "@/agents/contracts";
import type { Result } from "@/core/shared";

export type AgentAdapter = Readonly<{
  provider: AgentProvider;
  createSession: (
    definition: EnabledAgentConfig,
  ) => Promise<Result<AgentSession, AgentSessionLookupError>>;
}>;
