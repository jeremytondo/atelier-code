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
import { validateTurnStartParams } from "./turn.schema";

export function handleTurnStart(
  request: JsonRpcRequest & { method: "turn/start" },
  context: DispatchContext,
  service: AppServerService,
): DispatchOutcome {
  const params = validateTurnStartParams(request.params);
  if (!params.ok) {
    return createInvalidParamsOutcome(params.error, request.id);
  }

  const outcome = service.startTurn(
    context.session,
    params.value,
    createProtocolNotificationEmitter(context.notifications),
  );
  return createSuccessOutcome(request.id, outcome.result, outcome.followUp);
}
