import type { AppServerService } from "../../app/server";
import {
  createInvalidParamsOutcome,
  createSuccessOutcome,
} from "../../core/protocol/dispatch-responses";
import type {
  DispatchContext,
  DispatchOutcome,
} from "../../core/protocol/dispatcher-types";
import type { JsonRpcRequest } from "../../core/protocol/types";
import { validateWorkspaceOpenParams } from "./workspace.schema";

export function handleWorkspaceOpen(
  request: JsonRpcRequest & { method: "workspace/open" },
  context: DispatchContext,
  service: AppServerService,
): DispatchOutcome {
  const params = validateWorkspaceOpenParams(request.params);
  if (!params.ok) {
    return createInvalidParamsOutcome(params.error, request.id);
  }

  const outcome = service.openWorkspace(context.session, params.value);
  return createSuccessOutcome(request.id, outcome.result, outcome.followUp);
}
