import type {
  AgentInvalidMessageError,
  AgentRemoteError,
  AgentRequestId,
  AgentSessionUnavailableError,
  AgentThread,
} from "@/agents/contracts";
import type { AgentRegistry } from "@/agents/registry";
import type { Logger } from "@/app/logger";
import {
  createThreadReadIncludeTurnsUnsupportedResult,
  createThreadWorkspaceMismatchResult,
  type ProtocolMethodError,
} from "@/core/protocol/errors";
import { assertNever, err, ok, type Result } from "@/core/shared";
import type {
  Thread,
  ThreadExecutionStatus,
  ThreadListParams,
  ThreadListResult,
  ThreadReadParams,
  ThreadReadResult,
} from "@/threads/schemas";
import type { ThreadsStore } from "@/threads/store";
import type { Workspace } from "@/workspaces/schemas";

export type ThreadsServiceError =
  | AgentSessionUnavailableError
  | AgentRemoteError
  | ProtocolMethodError;

export type ThreadsService = Readonly<{
  listThreads: (
    requestId: AgentRequestId,
    workspace: Workspace,
    params: ThreadListParams,
  ) => Promise<Result<ThreadListResult, ThreadsServiceError>>;
  readThread: (
    requestId: AgentRequestId,
    workspace: Workspace,
    params: ThreadReadParams,
  ) => Promise<Result<ThreadReadResult, ThreadsServiceError>>;
}>;

export type CreateThreadsServiceOptions = Readonly<{
  logger: Logger;
  registry: AgentRegistry;
  store: ThreadsStore;
  now?: () => string;
}>;

export const createThreadsService = (options: CreateThreadsServiceOptions): ThreadsService => {
  const now = options.now ?? (() => new Date().toISOString());

  return Object.freeze({
    listThreads: async (requestId, workspace, params) => {
      const sessionResult = await options.registry.getSession();

      if (!sessionResult.ok) {
        if (sessionResult.error.type === "sessionUnavailable") {
          return err(sessionResult.error);
        }

        throw new Error(sessionResult.error.message);
      }

      const listResult = await sessionResult.data.listThreads(requestId, {
        cursor: params.cursor,
        limit: params.limit,
        archived: params.archived,
        workspacePath: workspace.workspacePath,
      });

      if (!listResult.ok) {
        switch (listResult.error.type) {
          case "sessionUnavailable":
          case "remoteError":
            return err(listResult.error);
          case "invalidProviderMessage":
            return throwInvalidProviderMessage(options.logger, listResult.error);
          default:
            return assertNever(listResult.error, "Unhandled thread/list error");
        }
      }

      await options.store.upsertWorkspaceThreadLinks({
        workspaceId: workspace.id,
        provider: sessionResult.data.provider,
        seenAt: now(),
        links: listResult.data.threads.map((thread) =>
          Object.freeze({
            threadId: thread.id,
            threadWorkspacePath: thread.workspacePath,
            archived: thread.archived,
          }),
        ),
      });

      return ok({
        threads: listResult.data.threads.map(mapPublicThread),
        nextCursor: listResult.data.nextCursor,
      });
    },
    readThread: async (requestId, workspace, params) => {
      if (params.includeTurns === true) {
        return createThreadReadIncludeTurnsUnsupportedResult();
      }

      const sessionResult = await options.registry.getSession();

      if (!sessionResult.ok) {
        if (sessionResult.error.type === "sessionUnavailable") {
          return err(sessionResult.error);
        }

        throw new Error(sessionResult.error.message);
      }

      const existingLink = await options.store.getWorkspaceThreadLink({
        workspaceId: workspace.id,
        provider: sessionResult.data.provider,
        threadId: params.threadId,
      });
      const readResult = await sessionResult.data.readThread(requestId, {
        threadId: params.threadId,
        includeTurns: false,
        archived: existingLink?.archived,
      });

      if (!readResult.ok) {
        switch (readResult.error.type) {
          case "sessionUnavailable":
          case "remoteError":
            return err(readResult.error);
          case "invalidProviderMessage":
            return throwInvalidProviderMessage(options.logger, readResult.error);
          default:
            return assertNever(readResult.error, "Unhandled thread/read error");
        }
      }

      if (readResult.data.thread.workspacePath !== workspace.workspacePath) {
        return createThreadWorkspaceMismatchResult(
          readResult.data.thread.id,
          workspace.workspacePath,
          readResult.data.thread.workspacePath,
        );
      }

      await options.store.upsertWorkspaceThreadLinks({
        workspaceId: workspace.id,
        provider: sessionResult.data.provider,
        seenAt: now(),
        links: [
          Object.freeze({
            threadId: readResult.data.thread.id,
            threadWorkspacePath: readResult.data.thread.workspacePath,
            archived: readResult.data.thread.archived,
          }),
        ],
      });

      return ok({
        thread: mapPublicThread(readResult.data.thread),
      });
    },
  });
};

const mapPublicThread = (thread: AgentThread): Thread =>
  Object.freeze({
    id: thread.id,
    preview: thread.preview,
    createdAt: thread.createdAt,
    updatedAt: thread.updatedAt,
    name: thread.name,
    archived: thread.archived,
    status: mapPublicThreadStatus(thread.status),
  });

const mapPublicThreadStatus = (status: AgentThread["status"]): ThreadExecutionStatus => {
  switch (status.type) {
    case "notLoaded":
      return Object.freeze({ type: "notLoaded" });
    case "idle":
      return Object.freeze({ type: "idle" });
    case "active":
      return Object.freeze({
        type: "active",
        activeFlags: [...status.activeFlags],
      });
    case "systemError":
      return Object.freeze({
        type: "systemError",
        ...(status.message ? { message: status.message } : {}),
      });
    default:
      return assertNever(status, "Unhandled public thread status");
  }
};

const throwInvalidProviderMessage = (logger: Logger, error: AgentInvalidMessageError): never => {
  logger.error("Thread browsing returned an invalid provider message", {
    agentId: error.agentId,
    provider: error.provider,
    message: error.message,
    ...(error.detail ? { detail: JSON.stringify(error.detail) } : {}),
  });

  throw new Error(error.message, { cause: error });
};
