import type { Logger } from "@/app/logger";
import type { ProtocolDispatcher } from "@/core/protocol";
import { createSessionNotInitializedResult } from "@/core/protocol/errors";
import { type LifecycleComponent, ok } from "@/core/shared";
import {
  type Workspace,
  WorkspaceOpenParamsSchema,
  WorkspaceOpenResultSchema,
} from "@/workspaces/schemas";
import { type CreateWorkspacesServiceOptions, createWorkspacesService } from "@/workspaces/service";

export type WorkspacesModule = Readonly<{
  lifecycle: LifecycleComponent;
  getOpenedWorkspace: (connectionId: string) => Workspace | undefined;
  handleConnectionClosed: (connectionId: string) => void;
}>;

export type CreateWorkspacesModuleOptions = Readonly<
  {
    logger: Logger;
    registerMethod: ProtocolDispatcher["registerMethod"];
    onWorkspaceOpened?: (
      input: Readonly<{
        connectionId: string;
        previousWorkspace: Workspace | undefined;
        workspace: Workspace;
      }>,
    ) => void;
  } & CreateWorkspacesServiceOptions
>;

export const createWorkspacesModule = (
  options: CreateWorkspacesModuleOptions,
): WorkspacesModule => {
  const service = createWorkspacesService(options);
  const openedWorkspacesByConnectionId = new Map<string, Workspace>();

  options.registerMethod({
    method: "workspace/open",
    paramsSchema: WorkspaceOpenParamsSchema,
    resultSchema: WorkspaceOpenResultSchema,
    handler: async ({ connectionId, params, session }) => {
      if (!session.isInitialized()) {
        return createSessionNotInitializedResult();
      }

      const workspaceResult = await service.openWorkspace(params);

      if (!workspaceResult.ok) {
        return workspaceResult;
      }

      const previousWorkspace = openedWorkspacesByConnectionId.get(connectionId);
      openedWorkspacesByConnectionId.set(connectionId, workspaceResult.data);
      options.onWorkspaceOpened?.({
        connectionId,
        previousWorkspace,
        workspace: workspaceResult.data,
      });

      options.logger.info("Workspace opened", {
        connectionId,
        workspaceId: workspaceResult.data.id,
        workspacePath: workspaceResult.data.workspacePath,
      });

      return ok({
        workspace: workspaceResult.data,
      });
    },
  });

  return Object.freeze({
    lifecycle: Object.freeze({
      name: "module.workspaces",
      start: async () => {
        options.logger.info("Workspaces module ready");
      },
      stop: async (reason: string) => {
        openedWorkspacesByConnectionId.clear();
        options.logger.info("Workspaces module stopped", { reason });
      },
    }),
    getOpenedWorkspace: (connectionId) => openedWorkspacesByConnectionId.get(connectionId),
    handleConnectionClosed: (connectionId) => {
      openedWorkspacesByConnectionId.delete(connectionId);
    },
  });
};
