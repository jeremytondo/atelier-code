import type { JsonRpcRequest, SupportedRequestMethod } from "../protocol/types";
import { type ValidationResult, invalid, isPlainObject } from "./shared";

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

export function isSupportedRequestMethod(
  method: string,
): method is SupportedRequestMethod {
  return (
    method === "initialize" ||
    method === "workspace/open" ||
    method === "thread/start" ||
    method === "turn/start"
  );
}
