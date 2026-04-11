import type {
  AgentInvalidMessageError,
  AgentReasoningEffort,
  AgentRemoteError,
  AgentRequestId,
  AgentSession,
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
  ThreadResumeParams,
  ThreadResumeResult,
  ThreadStartParams,
  ThreadStartResult,
} from "@/threads/schemas";
import type { ThreadsStore, WorkspaceThreadLink } from "@/threads/store";
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
  startThread: (
    requestId: AgentRequestId,
    workspace: Workspace,
    params: ThreadStartParams,
  ) => Promise<Result<ThreadStartResult, ThreadsServiceError>>;
  resumeThread: (
    requestId: AgentRequestId,
    workspace: Workspace,
    params: ThreadResumeParams,
  ) => Promise<Result<ThreadResumeResult, ThreadsServiceError>>;
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

type ThreadDefaults = Readonly<{
  model: string | null;
  reasoningEffort: AgentReasoningEffort | null;
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

      const existingLinks = await options.store.listWorkspaceThreadLinks({
        workspaceId: workspace.id,
        provider: sessionResult.data.provider,
      });
      const defaultsByThreadId = new Map(
        existingLinks.map((link) => [link.threadId, link] as const),
      );

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
        threads: listResult.data.threads.map((thread) =>
          mapPublicThread(thread, getThreadDefaults(defaultsByThreadId.get(thread.id))),
        ),
        nextCursor: listResult.data.nextCursor,
      });
    },
    startThread: async (requestId, workspace, params) => {
      const sessionResult = await options.registry.getSession();

      if (!sessionResult.ok) {
        if (sessionResult.error.type === "sessionUnavailable") {
          return err(sessionResult.error);
        }

        throw new Error(sessionResult.error.message);
      }

      const startResult = await sessionResult.data.startThread(requestId, {
        workspacePath: workspace.workspacePath,
        ...(params.model ? { model: params.model } : {}),
        ...(params.reasoningEffort ? { reasoningEffort: params.reasoningEffort } : {}),
      });

      if (!startResult.ok) {
        switch (startResult.error.type) {
          case "sessionUnavailable":
          case "remoteError":
            return err(startResult.error);
          case "invalidProviderMessage":
            return throwInvalidProviderMessage(options.logger, startResult.error);
          default:
            return assertNever(startResult.error, "Unhandled thread/start error");
        }
      }

      if (startResult.data.thread.workspacePath !== workspace.workspacePath) {
        return createThreadWorkspaceMismatchResult(
          startResult.data.thread.id,
          workspace.workspacePath,
          startResult.data.thread.workspacePath,
        );
      }

      const defaults = resolveThreadDefaults(startResult.data, params);
      await persistThreadLink(options.store, {
        workspace,
        session: sessionResult.data,
        seenAt: now(),
        thread: startResult.data.thread,
        defaults,
      });

      return ok({
        thread: mapPublicThread(startResult.data.thread, defaults),
      });
    },
    resumeThread: async (requestId, workspace, params) => {
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
      const resolvedModel = params.model ?? existingLink?.model;
      const resolvedReasoningEffort = params.reasoningEffort ?? existingLink?.reasoningEffort;
      const resumeResult = await sessionResult.data.resumeThread(requestId, {
        threadId: params.threadId,
        workspacePath: workspace.workspacePath,
        ...(resolvedModel ? { model: resolvedModel } : {}),
        ...(resolvedReasoningEffort ? { reasoningEffort: resolvedReasoningEffort } : {}),
      });

      if (!resumeResult.ok) {
        switch (resumeResult.error.type) {
          case "sessionUnavailable":
          case "remoteError":
            return err(resumeResult.error);
          case "invalidProviderMessage":
            return throwInvalidProviderMessage(options.logger, resumeResult.error);
          default:
            return assertNever(resumeResult.error, "Unhandled thread/resume error");
        }
      }

      if (resumeResult.data.thread.workspacePath !== workspace.workspacePath) {
        return createThreadWorkspaceMismatchResult(
          resumeResult.data.thread.id,
          workspace.workspacePath,
          resumeResult.data.thread.workspacePath,
        );
      }

      const defaults = resolveThreadDefaults(resumeResult.data, params, existingLink);
      await persistThreadLink(options.store, {
        workspace,
        session: sessionResult.data,
        seenAt: now(),
        thread: resumeResult.data.thread,
        defaults,
      });

      return ok({
        thread: mapPublicThread(resumeResult.data.thread, defaults),
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
        thread: mapPublicThread(readResult.data.thread, getThreadDefaults(existingLink)),
      });
    },
  });
};

const resolveThreadDefaults = (
  result: Readonly<{
    model?: string;
    reasoningEffort?: AgentReasoningEffort | null;
  }>,
  params: Readonly<{
    model?: string;
    reasoningEffort?: AgentReasoningEffort;
  }>,
  existingLink?: WorkspaceThreadLink,
): ThreadDefaults =>
  Object.freeze({
    model: params.model ?? existingLink?.model ?? result.model ?? null,
    reasoningEffort:
      params.reasoningEffort ?? existingLink?.reasoningEffort ?? result.reasoningEffort ?? null,
  });

const persistThreadLink = async (
  store: ThreadsStore,
  input: Readonly<{
    workspace: Workspace;
    session: AgentSession;
    seenAt: string;
    thread: AgentThread;
    defaults: ThreadDefaults;
  }>,
): Promise<void> => {
  await store.upsertWorkspaceThreadLinks({
    workspaceId: input.workspace.id,
    provider: input.session.provider,
    seenAt: input.seenAt,
    links: [
      Object.freeze({
        threadId: input.thread.id,
        threadWorkspacePath: input.thread.workspacePath,
        archived: input.thread.archived,
        model: input.defaults.model,
        reasoningEffort: input.defaults.reasoningEffort,
      }),
    ],
  });
};

const mapPublicThread = (thread: AgentThread, defaults: ThreadDefaults): Thread =>
  Object.freeze({
    id: thread.id,
    preview: thread.preview,
    createdAt: thread.createdAt,
    updatedAt: thread.updatedAt,
    name: thread.name,
    archived: thread.archived,
    model: defaults.model,
    reasoningEffort: defaults.reasoningEffort,
    status: mapPublicThreadStatus(thread.status),
  });

const getThreadDefaults = (link: WorkspaceThreadLink | undefined): ThreadDefaults =>
  Object.freeze({
    model: link?.model ?? null,
    reasoningEffort: link?.reasoningEffort ?? null,
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
  logger.error("Thread operation returned an invalid provider message", {
    agentId: error.agentId,
    provider: error.provider,
    message: error.message,
    ...(error.detail ? { detail: JSON.stringify(error.detail) } : {}),
  });

  throw new Error(error.message, { cause: error });
};
