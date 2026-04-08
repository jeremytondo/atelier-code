import type { DomainError } from "../domain/errors";
import type { DispatchOutcome } from "./dispatcher-types";
import {
  createExecutionError,
  createInvalidParamsError,
  createInvalidRequestError,
  createMethodNotFoundError,
  createParseError,
} from "./errors";
import { assertProtocolResponse } from "./message-assertions";
import type {
  JsonRpcErrorResponse,
  JsonRpcSuccessResponse,
  RequestId,
} from "./types";

type ProtocolResponse = JsonRpcSuccessResponse | JsonRpcErrorResponse;

export function createSuccessOutcome<TResult>(
  requestId: RequestId,
  result: TResult,
  followUp?: () => Promise<void>,
): DispatchOutcome {
  return createOutcome(
    {
      id: requestId,
      result,
    },
    followUp,
  );
}

export function createParseErrorOutcome(message: string): DispatchOutcome {
  return createOutcome(createParseError(message));
}

export function createInvalidRequestErrorOutcome(
  message: string,
  requestId: RequestId | null = null,
): DispatchOutcome {
  return createOutcome(createInvalidRequestError(message, requestId));
}

export function createInvalidRequestErrorResponse(
  message: string,
  requestId: RequestId | null = null,
): JsonRpcErrorResponse {
  return assertResponse(createInvalidRequestError(message, requestId));
}

export function createInvalidParamsOutcome(
  message: string,
  requestId: RequestId,
): DispatchOutcome {
  return createOutcome(
    createInvalidParamsError("invalid_params", message, requestId),
  );
}

export function createMethodNotFoundOutcome(
  method: string,
  requestId: RequestId,
): DispatchOutcome {
  return createOutcome(createMethodNotFoundError(method, requestId));
}

export function createExecutionErrorOutcome(
  error: DomainError,
  requestId: RequestId,
): DispatchOutcome {
  return createOutcome(
    createExecutionError(error.code, error.message, requestId, error.details),
  );
}

function createOutcome(
  response: ProtocolResponse,
  followUp?: () => Promise<void>,
): DispatchOutcome {
  const outcome: DispatchOutcome = {
    response: assertResponse(response),
  };

  if (followUp) {
    outcome.followUp = followUp;
  }

  return outcome;
}

function assertResponse<TResponse extends ProtocolResponse>(
  response: TResponse,
): TResponse {
  return assertProtocolResponse(response) as TResponse;
}
