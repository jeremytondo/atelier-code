import { type ValidationResult, invalid } from "../shared";

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
