import { isSupportedNotificationMethod } from "../schema/notification-methods";
import { isPlainObject } from "../schema/shared";
import { createInvalidParamsError } from "./errors";
import type {
  JsonRpcErrorResponse,
  JsonRpcNotification,
  JsonRpcSuccessResponse,
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

  if (!isPlainObject(message.params)) {
    throw new Error(
      "Outbound notifications must include an object params payload.",
    );
  }

  return message;
}
