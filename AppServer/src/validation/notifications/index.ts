import type { SupportedNotificationMethod } from "../../protocol/types";
import { type ValidationResult, invalid, isPlainObject } from "../shared";
import { validateAgentMessageDeltaNotification } from "./agent-message-delta";
import { validateItemCompletedNotification } from "./item-completed";
import { validateItemStartedNotification } from "./item-started";
import { isSupportedNotificationMethod } from "./methods";
import { validateThreadStartedNotification } from "./thread-started";
import { validateTurnCompletedNotification } from "./turn-completed";
import { validateTurnStartedNotification } from "./turn-started";

export { isSupportedNotificationMethod } from "./methods";

export function validateNotificationParams(
  method: SupportedNotificationMethod,
  params: unknown,
): ValidationResult<Record<string, unknown>> {
  if (!isPlainObject(params)) {
    return invalid(
      "Outbound notifications must include an object params payload.",
    );
  }

  if (!isSupportedNotificationMethod(method)) {
    return invalid(`Unsupported notification method ${method}.`);
  }

  switch (method) {
    case "thread/started":
      return validateThreadStartedNotification(params);
    case "turn/started":
      return validateTurnStartedNotification(params);
    case "item/started":
      return validateItemStartedNotification(params);
    case "item/agentMessage/delta":
      return validateAgentMessageDeltaNotification(params);
    case "item/completed":
      return validateItemCompletedNotification(params);
    case "turn/completed":
      return validateTurnCompletedNotification(params);
  }
}
