import {
  validateAgentMessageDeltaNotification,
  validateItemCompletedNotification,
  validateItemStartedNotification,
} from "../../modules/agents/agent.events";
import { validateThreadStartedNotification } from "../../modules/threads/thread.events";
import {
  validateTurnCompletedNotification,
  validateTurnStartedNotification,
} from "../../modules/turns/turn.events";
import { createInvalidParamsError } from "../shared/errors";
import { invalid, isPlainObject } from "../shared/validation";
import type {
  JsonRpcErrorResponse,
  JsonRpcNotification,
  JsonRpcSuccessResponse,
  SupportedNotificationMethod,
} from "./types";

export function assertProtocolResponse(
  message: JsonRpcSuccessResponse | JsonRpcErrorResponse,
): JsonRpcSuccessResponse | JsonRpcErrorResponse {
  if ("result" in message) {
    if (!(typeof message.id === "string" || typeof message.id === "number")) {
      throw new Error(
        "Outbound success response must include a string or number id.",
      );
    }

    return message;
  }

  if (
    !(
      message.id === null ||
      typeof message.id === "string" ||
      typeof message.id === "number"
    )
  ) {
    throw new Error(
      "Outbound error response must include a null, string, or number id.",
    );
  }

  if (
    !isPlainObject(message.error) ||
    typeof message.error.code !== "number" ||
    typeof message.error.message !== "string"
  ) {
    throw new Error(
      "Outbound error response must include a valid error object.",
    );
  }

  return message;
}

export function assertProtocolNotification<TParams>(
  message: JsonRpcNotification<TParams>,
): JsonRpcNotification<TParams> {
  if (!isSupportedNotificationMethod(message.method)) {
    throw createInvalidParamsError(
      "notification_invalid",
      `Outbound notification ${message.method} is not supported in phase 1.`,
    ).error;
  }

  const validatedParams = validateNotificationParams(
    message.method,
    message.params,
  );
  if (!validatedParams.ok) {
    throw new Error(validatedParams.error);
  }

  return message;
}

function isSupportedNotificationMethod(
  method: string,
): method is SupportedNotificationMethod {
  return (
    method === "thread/started" ||
    method === "turn/started" ||
    method === "item/started" ||
    method === "item/agentMessage/delta" ||
    method === "item/completed" ||
    method === "turn/completed"
  );
}

function validateNotificationParams(
  method: SupportedNotificationMethod,
  params: unknown,
) {
  if (!isPlainObject(params)) {
    return invalid(
      "Outbound notifications must include an object params payload.",
    );
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
