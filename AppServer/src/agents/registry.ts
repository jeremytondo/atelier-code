import type { EnabledAgentConfig } from "@/agents/config";
import type {
  AgentNotification,
  AgentSession,
  AgentSessionLookupError,
  AgentSessionLookupResult,
} from "@/agents/contracts";
import { err, ok, type Result } from "@/core/shared";

export type AgentSessionFactory = (
  definition: EnabledAgentConfig,
) => Promise<Result<AgentSession, AgentSessionLookupError>>;

export type AgentRegistry = Readonly<{
  getDefaultAgentId: () => string;
  listAgents: () => readonly EnabledAgentConfig[];
  getAgent: (agentId: string) => EnabledAgentConfig | undefined;
  getSession: (agentId?: string) => Promise<AgentSessionLookupResult<AgentSession>>;
  disconnectAll: (reason?: string) => Promise<void>;
}>;

export type CreateAgentRegistryOptions = Readonly<{
  defaultAgentId: string;
  agents: readonly EnabledAgentConfig[];
  createSession: AgentSessionFactory;
}>;

export const createAgentRegistry = (options: CreateAgentRegistryOptions): AgentRegistry => {
  const agentsById = new Map(options.agents.map((agent) => [agent.id, agent] as const));
  const activeSessionsById = new Map<string, AgentSession>();
  const pendingSessionsById = new Map<string, Promise<AgentSessionLookupResult<AgentSession>>>();

  const resolveAgentId = (agentId: string | undefined): string => agentId ?? options.defaultAgentId;

  const bindSessionLifecycle = (session: AgentSession): void => {
    session.subscribe((notification: AgentNotification) => {
      if (notification.type !== "disconnect") {
        return;
      }

      const activeSession = activeSessionsById.get(session.agentId);
      if (activeSession === session) {
        activeSessionsById.delete(session.agentId);
      }
    });
  };

  const getSession = async (
    requestedAgentId?: string,
  ): Promise<AgentSessionLookupResult<AgentSession>> => {
    const agentId = resolveAgentId(requestedAgentId);
    const definition = agentsById.get(agentId);

    if (definition === undefined) {
      return err({
        type: "agentNotFound",
        agentId,
        message: `Agent "${agentId}" is not configured.`,
      });
    }

    const cachedSession = activeSessionsById.get(agentId);
    if (cachedSession !== undefined && cachedSession.getState() !== "disconnected") {
      return ok(cachedSession);
    }

    const pendingSession = pendingSessionsById.get(agentId);
    if (pendingSession !== undefined) {
      return pendingSession;
    }

    const sessionPromise = (async () => {
      const sessionResult = await options.createSession(definition);

      if (sessionResult.ok) {
        activeSessionsById.set(agentId, sessionResult.data);
        bindSessionLifecycle(sessionResult.data);
      }

      pendingSessionsById.delete(agentId);
      return sessionResult;
    })();

    pendingSessionsById.set(agentId, sessionPromise);
    return sessionPromise;
  };

  return Object.freeze({
    getDefaultAgentId: () => options.defaultAgentId,
    listAgents: () => options.agents,
    getAgent: (agentId) => agentsById.get(agentId),
    getSession,
    disconnectAll: async () => {
      pendingSessionsById.clear();
      const sessions = [...activeSessionsById.values()];
      activeSessionsById.clear();
      await Promise.all(sessions.map((session) => session.disconnect("requested_disconnect")));
    },
  });
};
