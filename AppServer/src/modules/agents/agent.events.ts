import type {
  AgentMessageDeltaNotification,
  ItemCompletedNotification,
  ItemStartedNotification,
  JsonRpcNotification,
  ProtocolItem,
} from "../../core/protocol/types";
import type { ItemRecord } from "../../core/shared/models";
import {
  type ValidationResult,
  invalid,
  isPlainObject,
} from "../../core/shared/validation";

export function buildItemStarted(
  threadId: string,
  turnId: string,
  item: ItemRecord,
): JsonRpcNotification<ItemStartedNotification> {
  return {
    method: "item/started",
    params: {
      threadId,
      turnId,
      item,
    },
  };
}

export function buildAgentMessageDelta(
  threadId: string,
  turnId: string,
  itemId: string,
  delta: string,
): JsonRpcNotification<AgentMessageDeltaNotification> {
  return {
    method: "item/agentMessage/delta",
    params: {
      threadId,
      turnId,
      itemId,
      delta,
    },
  };
}

export function buildItemCompleted(
  threadId: string,
  turnId: string,
  item: ItemRecord,
): JsonRpcNotification<ItemCompletedNotification> {
  return {
    method: "item/completed",
    params: {
      threadId,
      turnId,
      item,
    },
  };
}

export function validateItemStartedNotification(
  params: Record<string, unknown>,
): ValidationResult<Record<string, unknown>> {
  return typeof params.threadId === "string" &&
    typeof params.turnId === "string" &&
    isProtocolItem(params.item)
    ? { ok: true, value: params }
    : invalid(
        "item/started params must include string threadId/turnId values and a valid protocol item.",
      );
}

export function validateAgentMessageDeltaNotification(
  params: Record<string, unknown>,
): ValidationResult<Record<string, unknown>> {
  return typeof params.threadId === "string" &&
    typeof params.turnId === "string" &&
    typeof params.itemId === "string" &&
    typeof params.delta === "string"
    ? { ok: true, value: params }
    : invalid(
        "item/agentMessage/delta params must include string threadId, turnId, itemId, and delta values.",
      );
}

export function validateItemCompletedNotification(
  params: Record<string, unknown>,
): ValidationResult<Record<string, unknown>> {
  return typeof params.threadId === "string" &&
    typeof params.turnId === "string" &&
    isProtocolItem(params.item)
    ? { ok: true, value: params }
    : invalid(
        "item/completed params must include string threadId/turnId values and a valid protocol item.",
      );
}

export function isProtocolItem(value: unknown): value is ProtocolItem {
  if (!isPlainObject(value) || typeof value.type !== "string") {
    return false;
  }

  switch (value.type) {
    case "userMessage":
      return (
        typeof value.id === "string" &&
        Array.isArray(value.content) &&
        value.content.every((input) => isUserInput(input))
      );
    case "agentMessage":
      return (
        typeof value.id === "string" &&
        typeof value.text === "string" &&
        (value.phase === null ||
          value.phase === "commentary" ||
          value.phase === "final_answer")
      );
    default:
      return false;
  }
}

function isUserInput(value: unknown): boolean {
  if (!isPlainObject(value) || typeof value.type !== "string") {
    return false;
  }

  switch (value.type) {
    case "text":
      return (
        typeof value.text === "string" && Array.isArray(value.text_elements)
      );
    case "image":
      return typeof value.url === "string";
    case "localImage":
      return typeof value.path === "string";
    case "skill":
    case "mention":
      return typeof value.name === "string" && typeof value.path === "string";
    default:
      return false;
  }
}
