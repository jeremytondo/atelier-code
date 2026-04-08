import type { AppServerService } from "../../app/server";
import { handleThreadStart } from "../../modules/threads/thread.handlers";
import { handleTurnStart } from "../../modules/turns/turn.handlers";
import { handleWorkspaceOpen } from "../../modules/workspaces/workspace.handlers";
import { DomainError } from "../shared/errors";
import { validateInitializeParams } from "../shared/validation-utils";
import {
  createExecutionErrorOutcome,
  createInvalidParamsOutcome,
  createMethodNotFoundOutcome,
  createSuccessOutcome,
} from "./dispatch-responses";
import type { DispatchContext, DispatchOutcome } from "./dispatcher-types";
import type { JsonRpcRequest } from "./types";

const REQUEST_HANDLERS: Record<
  string,
  (
    request: JsonRpcRequest,
    context: DispatchContext,
    service: AppServerService,
  ) => DispatchOutcome
> = {
  "workspace/open": (request, context, service) =>
    handleWorkspaceOpen(
      request as JsonRpcRequest & { method: "workspace/open" },
      context,
      service,
    ),
  "thread/start": (request, context, service) =>
    handleThreadStart(
      request as JsonRpcRequest & { method: "thread/start" },
      context,
      service,
    ),
  "turn/start": (request, context, service) =>
    handleTurnStart(
      request as JsonRpcRequest & { method: "turn/start" },
      context,
      service,
    ),
};

export class ProtocolDispatcher {
  constructor(private readonly service: AppServerService) {}

  dispatchParsedRequest(
    request: JsonRpcRequest,
    context: DispatchContext,
  ): DispatchOutcome {
    try {
      return this.dispatchRequest(request, context);
    } catch (error) {
      if (error instanceof DomainError) {
        return createExecutionErrorOutcome(error, request.id);
      }

      throw error;
    }
  }

  private dispatchRequest(
    request: JsonRpcRequest,
    context: DispatchContext,
  ): DispatchOutcome {
    if (request.method === "initialize") {
      const params = validateInitializeParams(request.params);
      if (!params.ok) {
        return createInvalidParamsOutcome(params.error, request.id);
      }

      const outcome = this.service.initialize(context.session, params.value);
      return createSuccessOutcome(request.id, outcome.result);
    }

    const handler = REQUEST_HANDLERS[request.method];
    if (!handler) {
      return createMethodNotFoundOutcome(request.method, request.id);
    }

    return handler(request, context, this.service);
  }
}
