import { type ValidationResult, invalid } from "../shared";
import { isProtocolThread } from "./shared";

export function validateThreadStartedNotification(
  params: Record<string, unknown>,
): ValidationResult<Record<string, unknown>> {
  return isProtocolThread(params.thread)
    ? { ok: true, value: params }
    : invalid("thread/started params.thread must be a valid protocol thread.");
}
