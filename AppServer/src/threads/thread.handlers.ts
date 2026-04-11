import { createAgentSessionUnavailableError, createProviderError } from "@/agents/protocol-errors";
import type { AgentRegistry } from "@/agents/registry";
import { createAgentRequestId } from "@/agents/request-id";
import type { Logger } from "@/app/logger";
import type { ProtocolDispatcher } from "@/core/protocol";
import {
  createSessionNotInitializedResult,
  createWorkspaceNotOpenedResult,
  type ProtocolMethodError,
} from "@/core/protocol/errors";
import { assertNever, type LifecycleComponent, ok } from "@/core/shared";
import {
  ThreadListParamsSchema,
  ThreadListResultSchema,
  type ThreadReadParams,
  ThreadReadParamsSchema,
  ThreadReadResultSchema,
} from "@/threads/schemas";
import { createThreadsService } from "@/threads/service";
import type { ThreadsStore } from "@/threads/store";
import type { Workspace } from "@/workspaces/schemas";

export type ThreadsFeature = Readonly<{
  lifecycle: LifecycleComponent;
}>;

export type CreateThreadsFeatureOptions = Readonly<{
  logger: Logger;
  registerMethod: ProtocolDispatcher["registerMethod"];
  registry: AgentRegistry;
  store: ThreadsStore;
  getOpenedWorkspace: (connectionId: string) => Workspace | undefined;
  now?: () => string;
}>;

export const createThreadsFeature = (options: CreateThreadsFeatureOptions): ThreadsFeature => {
  const service = createThreadsService({
    logger: options.logger,
    registry: options.registry,
    store: options.store,
    now: options.now,
  });

  options.registerMethod({
    method: "thread/list",
    paramsSchema: ThreadListParamsSchema,
    resultSchema: ThreadListResultSchema,
    handler: async ({ connectionId, params, requestId, session }) => {
      if (!session.isInitialized()) {
        return createSessionNotInitializedResult();
      }

      const workspace = options.getOpenedWorkspace(connectionId);

      if (workspace === undefined) {
        return createWorkspaceNotOpenedResult();
      }

      const agentRequestId = createAgentRequestId({
        connectionId,
        method: "thread/list",
        requestId,
      });
      const result = await service.listThreads(agentRequestId, workspace, params);

      if (!result.ok) {
        if (isProtocolMethodError(result.error)) {
          return {
            ok: false,
            error: result.error,
          };
        }

        switch (result.error.type) {
          case "sessionUnavailable":
            return {
              ok: false,
              error: createAgentSessionUnavailableError(result.error),
            };
          case "remoteError":
            return {
              ok: false,
              error: createProviderError(result.error),
            };
          default:
            return assertNever(result.error, "Unhandled thread/list protocol error");
        }
      }

      return ok(result.data);
    },
  });

  options.registerMethod({
    method: "thread/read",
    paramsSchema: ThreadReadParamsSchema,
    resultSchema: ThreadReadResultSchema,
    handler: async ({ connectionId, params, requestId, session }) => {
      if (!session.isInitialized()) {
        return createSessionNotInitializedResult();
      }

      const workspace = options.getOpenedWorkspace(connectionId);

      if (workspace === undefined) {
        return createWorkspaceNotOpenedResult();
      }

      const agentRequestId = createAgentRequestId({
        connectionId,
        method: "thread/read",
        requestId,
      });
      const result = await service.readThread(
        agentRequestId,
        workspace,
        normalizeThreadReadParams(params),
      );

      if (!result.ok) {
        if (isProtocolMethodError(result.error)) {
          return {
            ok: false,
            error: result.error,
          };
        }

        switch (result.error.type) {
          case "sessionUnavailable":
            return {
              ok: false,
              error: createAgentSessionUnavailableError(result.error),
            };
          case "remoteError":
            return {
              ok: false,
              error: createProviderError(result.error),
            };
          default:
            return assertNever(result.error, "Unhandled thread/read protocol error");
        }
      }

      return ok(result.data);
    },
  });

  return Object.freeze({
    lifecycle: Object.freeze({
      name: "feature.threads",
      start: async () => {
        options.logger.info("Threads feature ready");
      },
      stop: async (reason: string) => {
        options.logger.info("Threads feature stopped", { reason });
      },
    }),
  });
};

const normalizeThreadReadParams = (params: ThreadReadParams): ThreadReadParams =>
  Object.freeze({
    threadId: params.threadId,
    includeTurns: params.includeTurns ?? false,
  });

const isProtocolMethodError = (error: unknown): error is ProtocolMethodError =>
  typeof error === "object" &&
  error !== null &&
  !("type" in error) &&
  "code" in error &&
  typeof (error as { code: unknown }).code === "number";
