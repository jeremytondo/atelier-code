import type { AppServerService } from "../../app/server";
import {
  createInvalidParamsOutcome,
  createSuccessOutcome,
} from "../../core/protocol/dispatch-responses";
import type {
  DispatchContext,
  DispatchOutcome,
} from "../../core/protocol/dispatcher-types";
import { createProtocolNotificationEmitter } from "../../core/protocol/notification-emitter";
import type { JsonRpcRequest } from "../../core/protocol/types";
import { validateThreadStartParams } from "./thread.schema";

export function handleThreadStart(
  request: JsonRpcRequest & { method: "thread/start" },
  context: DispatchContext,
  service: AppServerService,
): DispatchOutcome {
  const params = validateThreadStartParams(request.params);
  if (!params.ok) {
    return createInvalidParamsOutcome(params.error, request.id);
  }

  const outcome = service.startThread(
    context.session,
    params.value,
    createProtocolNotificationEmitter(context.notifications),
  );
  return createSuccessOutcome(request.id, outcome.result, outcome.followUp);
}
