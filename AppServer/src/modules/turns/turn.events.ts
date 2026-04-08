import { toProtocolTurn } from "../../core/protocol/serializers";
import type {
  JsonRpcNotification,
  ProtocolTurn,
  TurnCompletedNotification,
  TurnStartedNotification,
} from "../../core/protocol/types";
import type { TurnRecord } from "../../core/shared/models";
import {
  type ValidationResult,
  invalid,
  isPlainObject,
} from "../../core/shared/validation-utils";
import { isProtocolItem } from "../agents/agent.events";

export function buildTurnStarted(
  threadId: string,
  turn: TurnRecord,
): JsonRpcNotification<TurnStartedNotification> {
  return {
    method: "turn/started",
    params: {
      threadId,
      turn: toProtocolTurn(turn),
    },
  };
}

export function buildTurnCompleted(
  threadId: string,
  turn: TurnRecord,
): JsonRpcNotification<TurnCompletedNotification> {
  return {
    method: "turn/completed",
    params: {
      threadId,
      turn: toProtocolTurn(turn),
    },
  };
}

export function validateTurnStartedNotification(
  params: Record<string, unknown>,
): ValidationResult<Record<string, unknown>> {
  return typeof params.threadId === "string" && isProtocolTurn(params.turn)
    ? { ok: true, value: params }
    : invalid(
        "turn/started params must include a string threadId and valid protocol turn.",
      );
}

export function validateTurnCompletedNotification(
  params: Record<string, unknown>,
): ValidationResult<Record<string, unknown>> {
  return typeof params.threadId === "string" && isProtocolTurn(params.turn)
    ? { ok: true, value: params }
    : invalid(
        "turn/completed params must include a string threadId and valid protocol turn.",
      );
}

export function isProtocolTurn(value: unknown): value is ProtocolTurn {
  return (
    isPlainObject(value) &&
    typeof value.id === "string" &&
    Array.isArray(value.items) &&
    value.items.every((item) => isProtocolItem(item)) &&
    isTurnStatus(value.status) &&
    isTurnError(value.error)
  );
}

function isTurnStatus(value: unknown): boolean {
  return (
    value === "completed" ||
    value === "interrupted" ||
    value === "failed" ||
    value === "inProgress"
  );
}

function isTurnError(value: unknown): boolean {
  return (
    value === null ||
    (isPlainObject(value) &&
      typeof value.message === "string" &&
      value.agentErrorInfo === null &&
      (value.additionalDetails === null ||
        typeof value.additionalDetails === "string"))
  );
}
