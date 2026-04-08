import type {
  ProtocolItem,
  ProtocolThread,
  ProtocolTurn,
} from "../../protocol/types";
import { isPlainObject } from "../shared";

export function isProtocolThread(value: unknown): value is ProtocolThread {
  return (
    isPlainObject(value) &&
    typeof value.id === "string" &&
    typeof value.preview === "string" &&
    typeof value.ephemeral === "boolean" &&
    typeof value.modelProvider === "string" &&
    typeof value.createdAt === "number" &&
    typeof value.updatedAt === "number" &&
    isThreadStatus(value.status) &&
    (value.path === null || typeof value.path === "string") &&
    typeof value.cwd === "string" &&
    typeof value.cliVersion === "string" &&
    value.source === "appServer" &&
    (value.agentNickname === null || typeof value.agentNickname === "string") &&
    (value.agentRole === null || typeof value.agentRole === "string") &&
    value.gitInfo === null &&
    (value.name === null || typeof value.name === "string") &&
    typeof value.workspaceId === "string" &&
    Array.isArray(value.turns) &&
    value.turns.every((turn) => isProtocolTurn(turn))
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

function isThreadStatus(value: unknown): boolean {
  return (
    (isPlainObject(value) && value.type === "notLoaded") ||
    (isPlainObject(value) && value.type === "idle") ||
    (isPlainObject(value) && value.type === "systemError") ||
    (isPlainObject(value) &&
      value.type === "active" &&
      Array.isArray(value.activeFlags) &&
      value.activeFlags.every(
        (flag) => flag === "turnInProgress" || flag === "approvalPending",
      ))
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
      value.codexErrorInfo === null &&
      (value.additionalDetails === null ||
        typeof value.additionalDetails === "string"))
  );
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
