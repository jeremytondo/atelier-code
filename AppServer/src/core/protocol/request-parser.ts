import {
  type ValidationResult,
  invalid,
  isPlainObject,
} from "../shared/validation-utils";
import {
  createInvalidRequestErrorOutcome,
  createParseErrorOutcome,
} from "./dispatch-responses";
import type { DispatchOutcome } from "./dispatcher-types";
import type { JsonRpcRequest } from "./types";

export type ParsedRequestResult =
  | {
      ok: true;
      request: JsonRpcRequest;
    }
  | {
      ok: false;
      outcome: DispatchOutcome;
    };

export function parseRawRequest(rawMessage: string): ParsedRequestResult {
  let parsedMessage: unknown;

  try {
    parsedMessage = JSON.parse(rawMessage);
  } catch {
    return {
      ok: false,
      outcome: createParseErrorOutcome("Request body must be valid JSON."),
    };
  }

  return parseEnvelopeRequest(parsedMessage);
}

export function parseEnvelopeRequest(value: unknown): ParsedRequestResult {
  const request = parseJsonRpcRequest(value);
  if (!request.ok) {
    return {
      ok: false,
      outcome: createInvalidRequestErrorOutcome(request.error),
    };
  }

  return {
    ok: true,
    request: request.value,
  };
}

export function parseJsonRpcRequest(
  value: unknown,
): ValidationResult<JsonRpcRequest> {
  if (!isPlainObject(value)) {
    return invalid("Requests must be JSON objects.");
  }

  const { id, method, params } = value;
  if (!(typeof id === "string" || typeof id === "number")) {
    return invalid("Requests must include a string or number id.");
  }

  if (typeof method !== "string") {
    return invalid("Requests must include a string method.");
  }

  return {
    ok: true,
    value: {
      id,
      method,
      params,
    },
  };
}
