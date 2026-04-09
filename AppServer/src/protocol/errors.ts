import type {
  JsonRpcErrorObject,
  JsonRpcErrorResponse,
  RequestId,
} from "./types";

export function createParseError(message: string): JsonRpcErrorResponse {
  return {
    id: null,
    error: buildError(-32700, message, { code: "parse_error" }),
  };
}

export function createInvalidRequestError(
  message: string,
  requestId: RequestId | null = null,
): JsonRpcErrorResponse {
  return {
    id: requestId,
    error: buildError(-32600, message, {
      code: "invalid_request",
    }),
  };
}

export function createMethodNotFoundError(
  method: string,
  requestId: RequestId,
): JsonRpcErrorResponse {
  return {
    id: requestId,
    error: buildError(-32601, `Method ${method} is not supported.`, {
      code: "method_not_found",
      method,
    }),
  };
}

export function createInvalidParamsError(
  code: string,
  message: string,
  requestId: RequestId | null = null,
): JsonRpcErrorResponse {
  return {
    id: requestId,
    error: buildError(-32602, message, {
      code,
    }),
  };
}

export function createExecutionError(
  code: string,
  message: string,
  requestId: RequestId,
  details: Record<string, string> = {},
): JsonRpcErrorResponse {
  return {
    id: requestId,
    error: buildError(-32000, message, {
      code,
      ...details,
    }),
  };
}

function buildError(
  code: number,
  message: string,
  data: JsonRpcErrorObject["data"],
): JsonRpcErrorObject {
  const baseError: JsonRpcErrorObject = {
    code,
    message,
  };

  if (data !== undefined) {
    baseError.data = data;
  }

  return baseError;
}
