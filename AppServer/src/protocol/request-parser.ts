import { parseJsonRpcRequest } from "../schema/request-envelope";
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
