import type { ProtocolErrorData } from "@/core/protocol/schemas";
import { err, type Result } from "@/core/shared";

export const JSON_RPC_PARSE_ERROR = -32700;
export const JSON_RPC_INVALID_REQUEST_ERROR = -32600;
export const JSON_RPC_METHOD_NOT_FOUND_ERROR = -32601;
export const JSON_RPC_INVALID_PARAMS_ERROR = -32602;
export const JSON_RPC_INTERNAL_ERROR = -32603;

export const ATELIER_SESSION_ALREADY_INITIALIZED_ERROR = -33000;

export type ProtocolMethodError = Readonly<{
  code: number;
  message: string;
  data?: ProtocolErrorData;
}>;

export const createProtocolMethodError = (
  code: number,
  message: string,
  data?: ProtocolErrorData,
): ProtocolMethodError =>
  Object.freeze(
    data === undefined
      ? { code, message }
      : {
          code,
          message,
          data,
        },
  );

export const createParseError = (): ProtocolMethodError =>
  createProtocolMethodError(JSON_RPC_PARSE_ERROR, "Parse error");

export const createInvalidRequestError = (): ProtocolMethodError =>
  createProtocolMethodError(JSON_RPC_INVALID_REQUEST_ERROR, "Invalid request");

export const createMethodNotFoundError = (): ProtocolMethodError =>
  createProtocolMethodError(JSON_RPC_METHOD_NOT_FOUND_ERROR, "Method not found");

export const createInvalidParamsError = (): ProtocolMethodError =>
  createProtocolMethodError(JSON_RPC_INVALID_PARAMS_ERROR, "Invalid params");

export const createInternalError = (): ProtocolMethodError =>
  createProtocolMethodError(
    JSON_RPC_INTERNAL_ERROR,
    "Internal error",
    Object.freeze({
      code: "INTERNAL_ERROR",
    }),
  );

export const createSessionAlreadyInitializedError = (): ProtocolMethodError =>
  createProtocolMethodError(
    ATELIER_SESSION_ALREADY_INITIALIZED_ERROR,
    "Session already initialized",
    Object.freeze({
      code: "SESSION_ALREADY_INITIALIZED",
    }),
  );

export const createSessionAlreadyInitializedResult = (): Result<never, ProtocolMethodError> =>
  err(createSessionAlreadyInitializedError());
