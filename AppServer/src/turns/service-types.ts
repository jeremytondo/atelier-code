import type {
  AgentRemoteError,
  AgentRequestId,
  AgentSessionLookupError,
  AgentSessionUnavailableError,
} from "@/agents/contracts";
import type { AgentRegistry } from "@/agents/registry";
import type { Logger } from "@/app/logger";
import type { ActiveTurnConflictError, ActiveTurnRegistry } from "@/turns/active-turn-registry";
import type { TurnStartParams, TurnStartResult } from "@/turns/schemas";
import type { Workspace } from "@/workspaces/schemas";

export type InvalidTurnProviderPayloadError = Readonly<{
  type: "invalidProviderPayload";
  agentId: string;
  provider: string;
  operation: "turn/start";
  message: string;
  detail?: Record<string, unknown>;
}>;

export type TurnsServiceError =
  | AgentSessionLookupError
  | AgentSessionUnavailableError
  | AgentRemoteError
  | ActiveTurnConflictError
  | InvalidTurnProviderPayloadError;

export type TurnsService = Readonly<{
  startTurn: (
    requestId: AgentRequestId,
    workspace: Workspace,
    params: TurnStartParams,
  ) => Promise<{ ok: true; data: TurnStartResult } | { ok: false; error: TurnsServiceError }>;
}>;

export type CreateTurnsServiceOptions = Readonly<{
  logger: Logger;
  registry: AgentRegistry;
  activeTurns: ActiveTurnRegistry;
}>;
