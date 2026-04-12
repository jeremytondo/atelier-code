import type { AgentInvalidMessageError, AgentTurnStatus } from "@/agents/contracts";
import {
  createActiveTurnAlreadyExistsError,
  createInvalidProviderPayloadError,
  type ProtocolMethodError,
} from "@/core/protocol/errors";
import { assertNever, err, ok } from "@/core/shared";
import type { ActiveTurnConflictError } from "@/turns/active-turn-registry";
import type {
  CreateTurnsServiceOptions,
  InvalidTurnProviderPayloadError,
  TurnsService,
} from "@/turns/service-types";

export type {
  CreateTurnsServiceOptions,
  InvalidTurnProviderPayloadError,
  TurnsServiceError,
} from "@/turns/service-types";

export const createTurnsService = (options: CreateTurnsServiceOptions): TurnsService =>
  Object.freeze({
    startTurn: async (requestId, workspace, params) => {
      const sessionResult = await options.registry.getSession();

      if (!sessionResult.ok) {
        return err(sessionResult.error);
      }

      const reservationResult = options.activeTurns.reserveThread(params.threadId);

      if (!reservationResult.ok) {
        return err(reservationResult.error);
      }

      const session = sessionResult.data;
      const reservation = reservationResult.data;
      const startTurnResult = await session.startTurn(requestId, {
        threadId: params.threadId,
        prompt: params.prompt,
        cwd: workspace.workspacePath,
      });

      if (!startTurnResult.ok) {
        reservation.release();

        switch (startTurnResult.error.type) {
          case "sessionUnavailable":
          case "remoteError":
            return err(startTurnResult.error);
          case "invalidProviderMessage":
            return err(createInvalidProviderPayloadServiceError(startTurnResult.error));
          default:
            return assertNever(startTurnResult.error, "Unhandled turn/start service error");
        }
      }

      const turn = Object.freeze({
        id: startTurnResult.data.turn.id,
        status: mapTurnStatus(startTurnResult.data.turn.status),
      });
      options.activeTurns.startTurn({
        threadId: params.threadId,
        turn,
      });

      return ok({
        turn,
      });
    },
  });

export const mapInvalidProviderPayloadToProtocolError = (
  error: InvalidTurnProviderPayloadError,
): ProtocolMethodError =>
  createInvalidProviderPayloadError({
    agentId: error.agentId,
    provider: error.provider,
    operation: error.operation,
    providerMessage: error.message,
  });

export const createActiveTurnConflictProtocolError = (
  error: ActiveTurnConflictError,
): ProtocolMethodError => createActiveTurnAlreadyExistsError(error.threadId, error.activeTurnId);

const createInvalidProviderPayloadServiceError = (
  error: AgentInvalidMessageError,
): InvalidTurnProviderPayloadError =>
  Object.freeze({
    type: "invalidProviderPayload",
    agentId: error.agentId,
    provider: error.provider,
    operation: "turn/start",
    message: error.message,
    ...(error.detail ? { detail: error.detail } : {}),
  });

const mapTurnStatus = (status: AgentTurnStatus) => {
  switch (status.type) {
    case "inProgress":
      return Object.freeze({ type: "inProgress" as const });
    case "awaitingInput":
      return Object.freeze({ type: "awaitingInput" as const });
    case "completed":
      return Object.freeze({ type: "completed" as const });
    case "cancelled":
      return Object.freeze({ type: "cancelled" as const });
    case "interrupted":
      return Object.freeze({ type: "interrupted" as const });
    case "failed":
      return Object.freeze({
        type: "failed" as const,
        ...(status.message ? { message: status.message } : {}),
      });
    default:
      return assertNever(status, "Unhandled turn status");
  }
};
