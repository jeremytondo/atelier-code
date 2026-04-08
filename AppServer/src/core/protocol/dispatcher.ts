import type { AppServerService } from "../../app/server";
import { handleThreadStart } from "../../modules/threads/thread.handlers";
import { handleTurnStart } from "../../modules/turns/turn.handlers";
import { handleWorkspaceOpen } from "../../modules/workspaces/workspace.handlers";
import { DomainError } from "../shared/errors";
import {
  isSupportedRequestMethod,
  validateInitializeParams,
} from "../shared/validation";
import {
  createExecutionErrorOutcome,
  createInvalidParamsOutcome,
  createMethodNotFoundOutcome,
  createSuccessOutcome,
} from "./dispatch-responses";
import type { DispatchContext, DispatchOutcome } from "./dispatcher-types";
import { parseRawRequest } from "./request-parser";
import type { JsonRpcRequest, SupportedRequestMethod } from "./types";

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
      return this.dispatchSupportedRequest(
        request as JsonRpcRequest & { method: SupportedRequestMethod },
        context,
      );
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

  private dispatchSupportedRequest(
    request: JsonRpcRequest & { method: SupportedRequestMethod },
    context: DispatchContext,
  ): DispatchOutcome {
    switch (request.method) {
      case "initialize": {
        const params = validateInitializeParams(request.params);
        if (!params.ok) {
          return createInvalidParamsOutcome(params.error, request.id);
        }

        const outcome = this.service.initialize(context.session, params.value);
        return createSuccessOutcome(request.id, outcome.result);
      }
      case "workspace/open":
        return handleWorkspaceOpen(
          request as JsonRpcRequest & { method: "workspace/open" },
          context,
          this.service,
        );
      case "thread/start":
        return handleThreadStart(
          request as JsonRpcRequest & { method: "thread/start" },
          context,
          this.service,
        );
      case "turn/start":
        return handleTurnStart(
          request as JsonRpcRequest & { method: "turn/start" },
          context,
          this.service,
        );
    }
  }
}
