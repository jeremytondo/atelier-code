import { type ValidationResult, invalid } from "../shared";
import { isProtocolTurn } from "./shared";

export function validateTurnStartedNotification(
  params: Record<string, unknown>,
): ValidationResult<Record<string, unknown>> {
  return typeof params.threadId === "string" && isProtocolTurn(params.turn)
    ? { ok: true, value: params }
    : invalid(
        "turn/started params must include a string threadId and valid protocol turn.",
      );
}
