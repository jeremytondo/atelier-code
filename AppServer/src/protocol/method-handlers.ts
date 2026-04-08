import type { AppServerService } from "../server/app-server-service";
import { validateInitializeParams } from "../validation/initialize";
import { validateThreadStartParams } from "../validation/thread/start";
import { validateTurnStartParams } from "../validation/turn/start";
import { validateWorkspaceOpenParams } from "../validation/workspace/open";
import {
  createInvalidParamsOutcome,
  createSuccessOutcome,
} from "./dispatch-responses";
import type { DispatchContext, DispatchOutcome } from "./dispatcher-types";
import { createProtocolNotificationEmitter } from "./notification-emitter";
import type { JsonRpcRequest, SupportedRequestMethod } from "./types";

export interface MethodHandlerContext extends DispatchContext {
  service: AppServerService;
}

export type SupportedRequest = {
  [TMethod in SupportedRequestMethod]: JsonRpcRequest & {
    method: TMethod;
  };
}[SupportedRequestMethod];

type SupportedRequestByMethod<TMethod extends SupportedRequestMethod> = Extract<
  SupportedRequest,
  { method: TMethod }
>;

type MethodHandler<TMethod extends SupportedRequestMethod> = (
  request: SupportedRequestByMethod<TMethod>,
  context: MethodHandlerContext,
) => DispatchOutcome;

export const methodHandlers: {
  [TMethod in SupportedRequestMethod]: MethodHandler<TMethod>;
} = {
  initialize: handleInitialize,
  "workspace/open": handleWorkspaceOpen,
  "thread/start": handleThreadStart,
  "turn/start": handleTurnStart,
};

export function dispatchSupportedRequest(
  request: SupportedRequest,
  context: MethodHandlerContext,
): DispatchOutcome {
  switch (request.method) {
    case "initialize":
      return methodHandlers.initialize(request, context);
    case "workspace/open":
      return methodHandlers["workspace/open"](request, context);
    case "thread/start":
      return methodHandlers["thread/start"](request, context);
    case "turn/start":
      return methodHandlers["turn/start"](request, context);
  }
}

export function handleInitialize(
  request: SupportedRequestByMethod<"initialize">,
  context: MethodHandlerContext,
): DispatchOutcome {
  const params = validateInitializeParams(request.params);
  if (!params.ok) {
    return createInvalidParamsOutcome(params.error, request.id);
  }

  const outcome = context.service.initialize(context.session, params.value);
  return createSuccessOutcome(request.id, outcome.result);
}

export function handleWorkspaceOpen(
  request: SupportedRequestByMethod<"workspace/open">,
  context: MethodHandlerContext,
): DispatchOutcome {
  const params = validateWorkspaceOpenParams(request.params);
  if (!params.ok) {
    return createInvalidParamsOutcome(params.error, request.id);
  }

  const outcome = context.service.openWorkspace(context.session, params.value);
  return createSuccessOutcome(request.id, outcome.result, outcome.followUp);
}

export function handleThreadStart(
  request: SupportedRequestByMethod<"thread/start">,
  context: MethodHandlerContext,
): DispatchOutcome {
  const params = validateThreadStartParams(request.params);
  if (!params.ok) {
    return createInvalidParamsOutcome(params.error, request.id);
  }

  const outcome = context.service.startThread(
    context.session,
    params.value,
    createProtocolNotificationEmitter(context.notifications),
  );
  return createSuccessOutcome(request.id, outcome.result, outcome.followUp);
}

export function handleTurnStart(
  request: SupportedRequestByMethod<"turn/start">,
  context: MethodHandlerContext,
): DispatchOutcome {
  const params = validateTurnStartParams(request.params);
  if (!params.ok) {
    return createInvalidParamsOutcome(params.error, request.id);
  }

  const outcome = context.service.startTurn(
    context.session,
    params.value,
    createProtocolNotificationEmitter(context.notifications),
  );
  return createSuccessOutcome(request.id, outcome.result, outcome.followUp);
}
