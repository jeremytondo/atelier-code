import { DomainError } from "../domain/errors";
import type { AppServerService } from "../server/app-server-service";
import { isSupportedRequestMethod } from "../validation/request-envelope";
import {
  createExecutionErrorOutcome,
  createMethodNotFoundOutcome,
} from "./dispatch-responses";
import type { DispatchContext, DispatchOutcome } from "./dispatcher-types";
import {
  type SupportedRequest,
  dispatchSupportedRequest,
} from "./method-handlers";
import { parseRawRequest } from "./request-parser";
import type { JsonRpcRequest } from "./types";

export class ProtocolDispatcher {
  constructor(private readonly service: AppServerService) {}

  dispatchParsedRequest(
    request: JsonRpcRequest,
    context: DispatchContext,
  ): DispatchOutcome {
    if (!isSupportedRequestMethod(request.method)) {
      return createMethodNotFoundOutcome(request.method, request.id);
    }

    try {
      return dispatchSupportedRequest(request as SupportedRequest, {
        ...context,
        service: this.service,
      });
    } catch (error) {
      if (error instanceof DomainError) {
        return createExecutionErrorOutcome(error, request.id);
      }

      throw error;
    }
  }

  dispatchRawMessage(
    rawMessage: string,
    context: DispatchContext,
  ): DispatchOutcome {
    const parsedRequest = parseRawRequest(rawMessage);
    if (!parsedRequest.ok) {
      return parsedRequest.outcome;
    }

    return this.dispatchParsedRequest(parsedRequest.request, context);
  }
}
