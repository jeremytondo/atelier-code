import { type ValidationResult, invalid } from "../shared";
import { isProtocolItem } from "./shared";

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
