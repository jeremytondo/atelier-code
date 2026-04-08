import { toProtocolThread } from "../../core/protocol/serializers";
import type {
  JsonRpcNotification,
  ProtocolThread,
  ThreadStartedNotification,
} from "../../core/protocol/types";
import type { ThreadRecord } from "../../core/shared/models";
import { type ValidationResult, invalid } from "../../core/shared/validation";
import { isProtocolTurn } from "../turns/turn.events";

export function buildThreadStarted(
  thread: ThreadRecord,
): JsonRpcNotification<ThreadStartedNotification> {
  return {
    method: "thread/started",
    params: {
      thread: toProtocolThread(thread),
    },
  };
}

export function validateThreadStartedNotification(
  params: Record<string, unknown>,
): ValidationResult<Record<string, unknown>> {
  return isProtocolThread(params.thread)
    ? { ok: true, value: params }
    : invalid("thread/started params.thread must be a valid protocol thread.");
}

export function isProtocolThread(value: unknown): value is ProtocolThread {
  return (
    typeof value === "object" &&
    value !== null &&
    "id" in value &&
    typeof value.id === "string" &&
    "preview" in value &&
    typeof value.preview === "string" &&
    "ephemeral" in value &&
    typeof value.ephemeral === "boolean" &&
    "modelProvider" in value &&
    typeof value.modelProvider === "string" &&
    "createdAt" in value &&
    typeof value.createdAt === "number" &&
    "updatedAt" in value &&
    typeof value.updatedAt === "number" &&
    isThreadStatus("status" in value ? value.status : undefined) &&
    "path" in value &&
    (value.path === null || typeof value.path === "string") &&
    "cwd" in value &&
    typeof value.cwd === "string" &&
    "cliVersion" in value &&
    typeof value.cliVersion === "string" &&
    "source" in value &&
    value.source === "appServer" &&
    "agentNickname" in value &&
    (value.agentNickname === null || typeof value.agentNickname === "string") &&
    "agentRole" in value &&
    (value.agentRole === null || typeof value.agentRole === "string") &&
    "gitInfo" in value &&
    value.gitInfo === null &&
    "name" in value &&
    (value.name === null || typeof value.name === "string") &&
    "workspaceId" in value &&
    typeof value.workspaceId === "string" &&
    "turns" in value &&
    Array.isArray(value.turns) &&
    value.turns.every((turn) => isProtocolTurn(turn))
  );
}

function isThreadStatus(value: unknown): boolean {
  return (
    (typeof value === "object" &&
      value !== null &&
      "type" in value &&
      value.type === "notLoaded") ||
    (typeof value === "object" &&
      value !== null &&
      "type" in value &&
      value.type === "idle") ||
    (typeof value === "object" &&
      value !== null &&
      "type" in value &&
      value.type === "systemError") ||
    (typeof value === "object" &&
      value !== null &&
      "type" in value &&
      value.type === "active" &&
      "activeFlags" in value &&
      Array.isArray(value.activeFlags) &&
      value.activeFlags.every(
        (flag) => flag === "turnInProgress" || flag === "approvalPending",
      ))
  );
}
