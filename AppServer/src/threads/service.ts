import type {
  AgentInvalidMessageError,
  AgentProvider,
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
  createInvalidProviderPayloadError,
  createThreadReadIncludeTurnsUnsupportedResult,
  createThreadWorkspaceMismatchResult,
  type ProtocolMethodError,
} from "@/core/protocol/errors";
import { assertNever, err, getErrorMessage, ok, type Result } from "@/core/shared";
import type {
  Thread,
  ThreadArchiveParams,
  ThreadArchiveResult,
  ThreadExecutionStatus,
  ThreadForkParams,
  ThreadForkResult,
  ThreadListParams,
  ThreadListResult,
  ThreadReadParams,
  ThreadReadResult,
  ThreadResumeParams,
  ThreadResumeResult,
  ThreadSetNameParams,
  ThreadSetNameResult,
  ThreadStartParams,
  ThreadStartResult,
  ThreadUnarchiveParams,
  ThreadUnarchiveResult,
} from "@/threads/schemas";
import type { ThreadsStore, WorkspaceThreadLink } from "@/threads/store";
import { normalizeWorkspacePath, type WorkspacePathNormalizer } from "@/workspaces/path";
import type { Workspace } from "@/workspaces/schemas";

type ThreadOperation =
  | "thread/list"
  | "thread/start"
  | "thread/resume"
  | "thread/read"
  | "thread/fork"
  | "thread/archive"
  | "thread/unarchive"
  | "thread/name/set";

export type InvalidProviderPayloadError = Readonly<{
  type: "invalidProviderPayload";
  agentId: string;
  provider: AgentProvider;
  operation: ThreadOperation;
  message: string;
  detail?: Record<string, unknown>;
}>;

export type ThreadsServiceError =
  | AgentSessionUnavailableError
  | AgentRemoteError
  | InvalidProviderPayloadError
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
  forkThread: (
    requestId: AgentRequestId,
    workspace: Workspace,
    params: ThreadForkParams,
  ) => Promise<Result<ThreadForkResult, ThreadsServiceError>>;
  archiveThread: (
    requestId: AgentRequestId,
    workspace: Workspace,
    params: ThreadArchiveParams,
  ) => Promise<Result<ThreadArchiveResult, ThreadsServiceError>>;
  unarchiveThread: (
    requestId: AgentRequestId,
    workspace: Workspace,
    params: ThreadUnarchiveParams,
  ) => Promise<Result<ThreadUnarchiveResult, ThreadsServiceError>>;
  setThreadName: (
    requestId: AgentRequestId,
    workspace: Workspace,
    params: ThreadSetNameParams,
  ) => Promise<Result<ThreadSetNameResult, ThreadsServiceError>>;
}>;

export type CreateThreadsServiceOptions = Readonly<{
  logger: Logger;
  registry: AgentRegistry;
  store: ThreadsStore;
  now?: () => string;
  normalizeWorkspacePath?: WorkspacePathNormalizer;
}>;

type ThreadDefaults = Readonly<{
  model: string | null;
  reasoningEffort: AgentReasoningEffort | null;
}>;

export const createThreadsService = (options: CreateThreadsServiceOptions): ThreadsService => {
  const now = options.now ?? (() => new Date().toISOString());
  const normalizePath = options.normalizeWorkspacePath ?? normalizeWorkspacePath;

  return Object.freeze({
    listThreads: async (requestId, workspace, params) => {
      const sessionResult = await options.registry.getSession();

      if (!sessionResult.ok) {
        if (sessionResult.error.type === "sessionUnavailable") {
          return err(sessionResult.error);
        }

        throw new Error(sessionResult.error.message);
      }

      const normalizedWorkspacePath = await normalizePath(workspace.workspacePath);
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
        workspacePath: normalizedWorkspacePath,
      });

      if (!listResult.ok) {
        switch (listResult.error.type) {
          case "sessionUnavailable":
          case "remoteError":
            return err(listResult.error);
          case "invalidProviderMessage":
            return err(createInvalidProviderPayloadServiceError("thread/list", listResult.error));
          default:
            return assertNever(listResult.error, "Unhandled thread/list error");
        }
      }

      const threads = (
        await Promise.all(
          listResult.data.threads.map(async (thread) => {
            if (!(await threadBelongsToWorkspace(thread, normalizedWorkspacePath, normalizePath))) {
              options.logger.warn("Filtered cross-workspace thread from provider list", {
                threadId: thread.id,
                workspaceId: workspace.id,
                openedWorkspacePath: workspace.workspacePath,
                threadWorkspacePath: thread.workspacePath,
                provider: sessionResult.data.provider,
              });
              return undefined;
            }

            return thread;
          }),
        )
      ).filter(
        (thread): thread is (typeof listResult.data.threads)[number] => thread !== undefined,
      );

      await persistThreadLinksBestEffort(options, {
        operation: "thread/list",
        workspace,
        provider: sessionResult.data.provider,
        seenAt: now(),
        links: threads.map((thread) =>
          Object.freeze({
            threadId: thread.id,
            threadWorkspacePath: thread.workspacePath,
            archived: thread.archived,
          }),
        ),
      });

      return ok({
        threads: threads.map((thread) =>
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

      const normalizedWorkspacePath = await normalizePath(workspace.workspacePath);
      const startResult = await sessionResult.data.startThread(requestId, {
        workspacePath: normalizedWorkspacePath,
        ...(params.model ? { model: params.model } : {}),
        ...(params.reasoningEffort ? { reasoningEffort: params.reasoningEffort } : {}),
      });

      if (!startResult.ok) {
        switch (startResult.error.type) {
          case "sessionUnavailable":
          case "remoteError":
            return err(startResult.error);
          case "invalidProviderMessage":
            return err(createInvalidProviderPayloadServiceError("thread/start", startResult.error));
          default:
            return assertNever(startResult.error, "Unhandled thread/start error");
        }
      }

      if (
        !(await threadBelongsToWorkspace(
          startResult.data.thread,
          normalizedWorkspacePath,
          normalizePath,
        ))
      ) {
        return createThreadWorkspaceMismatchResult(
          startResult.data.thread.id,
          workspace.workspacePath,
          startResult.data.thread.workspacePath,
        );
      }

      const defaults = resolveThreadDefaults(startResult.data, params);
      warnOnThreadDefaultsMismatch(options.logger, {
        operation: "thread/start",
        workspace,
        threadId: startResult.data.thread.id,
        providerModel: startResult.data.model,
        providerReasoningEffort: startResult.data.reasoningEffort,
        defaults,
      });
      await persistThreadLinksBestEffort(options, {
        operation: "thread/start",
        workspace,
        provider: sessionResult.data.provider,
        seenAt: now(),
        links: [
          Object.freeze({
            threadId: startResult.data.thread.id,
            threadWorkspacePath: startResult.data.thread.workspacePath,
            archived: startResult.data.thread.archived,
            model: defaults.model,
            reasoningEffort: defaults.reasoningEffort,
          }),
        ],
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

      const normalizedWorkspacePath = await normalizePath(workspace.workspacePath);
      const existingLink = await options.store.getWorkspaceThreadLink({
        workspaceId: workspace.id,
        provider: sessionResult.data.provider,
        threadId: params.threadId,
      });
      const resolvedModel = params.model ?? existingLink?.model;
      const resolvedReasoningEffort = params.reasoningEffort ?? existingLink?.reasoningEffort;
      const resumeResult = await sessionResult.data.resumeThread(requestId, {
        threadId: params.threadId,
        workspacePath: normalizedWorkspacePath,
        ...(resolvedModel ? { model: resolvedModel } : {}),
        ...(resolvedReasoningEffort ? { reasoningEffort: resolvedReasoningEffort } : {}),
      });

      if (!resumeResult.ok) {
        switch (resumeResult.error.type) {
          case "sessionUnavailable":
          case "remoteError":
            return err(resumeResult.error);
          case "invalidProviderMessage":
            return err(
              createInvalidProviderPayloadServiceError("thread/resume", resumeResult.error),
            );
          default:
            return assertNever(resumeResult.error, "Unhandled thread/resume error");
        }
      }

      if (
        !(await threadBelongsToWorkspace(
          resumeResult.data.thread,
          normalizedWorkspacePath,
          normalizePath,
        ))
      ) {
        return createThreadWorkspaceMismatchResult(
          resumeResult.data.thread.id,
          workspace.workspacePath,
          resumeResult.data.thread.workspacePath,
        );
      }

      const defaults = resolveThreadDefaults(resumeResult.data, params, existingLink);
      warnOnThreadDefaultsMismatch(options.logger, {
        operation: "thread/resume",
        workspace,
        threadId: resumeResult.data.thread.id,
        providerModel: resumeResult.data.model,
        providerReasoningEffort: resumeResult.data.reasoningEffort,
        defaults,
      });
      await persistThreadLinksBestEffort(options, {
        operation: "thread/resume",
        workspace,
        provider: sessionResult.data.provider,
        seenAt: now(),
        links: [
          Object.freeze({
            threadId: resumeResult.data.thread.id,
            threadWorkspacePath: resumeResult.data.thread.workspacePath,
            archived: resumeResult.data.thread.archived,
            model: defaults.model,
            reasoningEffort: defaults.reasoningEffort,
          }),
        ],
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

      const normalizedWorkspacePath = await normalizePath(workspace.workspacePath);
      const existingLink = await options.store.getWorkspaceThreadLink({
        workspaceId: workspace.id,
        provider: sessionResult.data.provider,
        threadId: params.threadId,
      });
      const readResult = await sessionResult.data.readThread(requestId, {
        threadId: params.threadId,
        includeTurns: false,
      });

      if (!readResult.ok) {
        switch (readResult.error.type) {
          case "sessionUnavailable":
          case "remoteError":
            return err(readResult.error);
          case "invalidProviderMessage":
            return err(createInvalidProviderPayloadServiceError("thread/read", readResult.error));
          default:
            return assertNever(readResult.error, "Unhandled thread/read error");
        }
      }

      if (
        !(await threadBelongsToWorkspace(
          readResult.data.thread,
          normalizedWorkspacePath,
          normalizePath,
        ))
      ) {
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
    forkThread: async (requestId, workspace, params) => {
      const sessionResult = await options.registry.getSession();

      if (!sessionResult.ok) {
        if (sessionResult.error.type === "sessionUnavailable") {
          return err(sessionResult.error);
        }

        throw new Error(sessionResult.error.message);
      }

      const normalizedWorkspacePath = await normalizePath(workspace.workspacePath);
      const validationResult = await validateThreadWorkspaceForMutation(options, {
        requestId,
        operation: "thread/fork",
        workspace,
        threadId: params.threadId,
        session: sessionResult.data,
        provider: sessionResult.data.provider,
        normalizedWorkspacePath,
        normalizePath,
        seenAt: now(),
      });

      if (!validationResult.ok) {
        return validationResult;
      }

      const forkResult = await sessionResult.data.forkThread(requestId, {
        threadId: params.threadId,
        workspacePath: normalizedWorkspacePath,
        ...(params.model ? { model: params.model } : {}),
      });

      if (!forkResult.ok) {
        switch (forkResult.error.type) {
          case "sessionUnavailable":
          case "remoteError":
            return err(forkResult.error);
          case "invalidProviderMessage":
            return err(createInvalidProviderPayloadServiceError("thread/fork", forkResult.error));
          default:
            return assertNever(forkResult.error, "Unhandled thread/fork error");
        }
      }

      if (
        !(await threadBelongsToWorkspace(
          forkResult.data.thread,
          normalizedWorkspacePath,
          normalizePath,
        ))
      ) {
        return createThreadWorkspaceMismatchResult(
          forkResult.data.thread.id,
          workspace.workspacePath,
          forkResult.data.thread.workspacePath,
        );
      }

      const defaults = resolveThreadDefaults(forkResult.data, params);
      warnOnThreadDefaultsMismatch(options.logger, {
        operation: "thread/fork",
        workspace,
        threadId: forkResult.data.thread.id,
        providerModel: forkResult.data.model,
        providerReasoningEffort: forkResult.data.reasoningEffort,
        defaults,
      });
      await persistThreadLinksBestEffort(options, {
        operation: "thread/fork",
        workspace,
        provider: sessionResult.data.provider,
        seenAt: now(),
        links: [
          Object.freeze({
            threadId: forkResult.data.thread.id,
            threadWorkspacePath: forkResult.data.thread.workspacePath,
            archived: forkResult.data.thread.archived,
            model: defaults.model,
            reasoningEffort: defaults.reasoningEffort,
          }),
        ],
      });

      return ok({
        thread: mapPublicThread(forkResult.data.thread, defaults),
      });
    },
    archiveThread: async (requestId, workspace, params) => {
      const sessionResult = await options.registry.getSession();

      if (!sessionResult.ok) {
        if (sessionResult.error.type === "sessionUnavailable") {
          return err(sessionResult.error);
        }

        throw new Error(sessionResult.error.message);
      }

      const normalizedWorkspacePath = await normalizePath(workspace.workspacePath);
      const validationResult = await validateThreadWorkspaceForMutation(options, {
        requestId,
        operation: "thread/archive",
        workspace,
        threadId: params.threadId,
        session: sessionResult.data,
        provider: sessionResult.data.provider,
        normalizedWorkspacePath,
        normalizePath,
        seenAt: now(),
      });

      if (!validationResult.ok) {
        return validationResult;
      }

      const archiveResult = await sessionResult.data.archiveThread(requestId, {
        threadId: params.threadId,
      });

      if (!archiveResult.ok) {
        switch (archiveResult.error.type) {
          case "sessionUnavailable":
          case "remoteError":
            return err(archiveResult.error);
          case "invalidProviderMessage":
            return err(
              createInvalidProviderPayloadServiceError("thread/archive", archiveResult.error),
            );
          default:
            return assertNever(archiveResult.error, "Unhandled thread/archive error");
        }
      }

      await persistThreadLinksBestEffort(options, {
        operation: "thread/archive",
        workspace,
        provider: sessionResult.data.provider,
        seenAt: now(),
        links: [
          Object.freeze({
            threadId: params.threadId,
            threadWorkspacePath: validationResult.data.threadWorkspacePath,
            archived: true,
          }),
        ],
      });

      return ok({});
    },
    unarchiveThread: async (requestId, workspace, params) => {
      const sessionResult = await options.registry.getSession();

      if (!sessionResult.ok) {
        if (sessionResult.error.type === "sessionUnavailable") {
          return err(sessionResult.error);
        }

        throw new Error(sessionResult.error.message);
      }

      const normalizedWorkspacePath = await normalizePath(workspace.workspacePath);
      const validationResult = await validateThreadWorkspaceForMutation(options, {
        requestId,
        operation: "thread/unarchive",
        workspace,
        threadId: params.threadId,
        session: sessionResult.data,
        provider: sessionResult.data.provider,
        normalizedWorkspacePath,
        normalizePath,
        seenAt: now(),
      });

      if (!validationResult.ok) {
        return validationResult;
      }

      const unarchiveResult = await sessionResult.data.unarchiveThread(requestId, {
        threadId: params.threadId,
      });

      if (!unarchiveResult.ok) {
        switch (unarchiveResult.error.type) {
          case "sessionUnavailable":
          case "remoteError":
            return err(unarchiveResult.error);
          case "invalidProviderMessage":
            return err(
              createInvalidProviderPayloadServiceError("thread/unarchive", unarchiveResult.error),
            );
          default:
            return assertNever(unarchiveResult.error, "Unhandled thread/unarchive error");
        }
      }

      if (
        !(await threadBelongsToWorkspace(
          unarchiveResult.data.thread,
          normalizedWorkspacePath,
          normalizePath,
        ))
      ) {
        return createThreadWorkspaceMismatchResult(
          unarchiveResult.data.thread.id,
          workspace.workspacePath,
          unarchiveResult.data.thread.workspacePath,
        );
      }

      await persistThreadLinksBestEffort(options, {
        operation: "thread/unarchive",
        workspace,
        provider: sessionResult.data.provider,
        seenAt: now(),
        links: [
          Object.freeze({
            threadId: unarchiveResult.data.thread.id,
            threadWorkspacePath: unarchiveResult.data.thread.workspacePath,
            archived: false,
          }),
        ],
      });

      return ok({
        thread: mapPublicThread(unarchiveResult.data.thread, validationResult.data.defaults),
      });
    },
    setThreadName: async (requestId, workspace, params) => {
      const sessionResult = await options.registry.getSession();

      if (!sessionResult.ok) {
        if (sessionResult.error.type === "sessionUnavailable") {
          return err(sessionResult.error);
        }

        throw new Error(sessionResult.error.message);
      }

      const normalizedWorkspacePath = await normalizePath(workspace.workspacePath);
      const validationResult = await validateThreadWorkspaceForMutation(options, {
        requestId,
        operation: "thread/name/set",
        workspace,
        threadId: params.threadId,
        session: sessionResult.data,
        provider: sessionResult.data.provider,
        normalizedWorkspacePath,
        normalizePath,
        seenAt: now(),
      });

      if (!validationResult.ok) {
        return validationResult;
      }

      const setNameResult = await sessionResult.data.setThreadName(requestId, {
        threadId: params.threadId,
        name: params.name,
      });

      if (!setNameResult.ok) {
        switch (setNameResult.error.type) {
          case "sessionUnavailable":
          case "remoteError":
            return err(setNameResult.error);
          case "invalidProviderMessage":
            return err(
              createInvalidProviderPayloadServiceError("thread/name/set", setNameResult.error),
            );
          default:
            return assertNever(setNameResult.error, "Unhandled thread/name/set error");
        }
      }

      await persistThreadLinksBestEffort(options, {
        operation: "thread/name/set",
        workspace,
        provider: sessionResult.data.provider,
        seenAt: now(),
        links: [
          Object.freeze({
            threadId: params.threadId,
            threadWorkspacePath: validationResult.data.threadWorkspacePath,
            archived: validationResult.data.archived,
          }),
        ],
      });

      return ok({});
    },
  });
};

type ValidatedMutationThread = Readonly<{
  threadWorkspacePath: string;
  archived: boolean;
  defaults: ThreadDefaults;
}>;

const validateThreadWorkspaceForMutation = async (
  options: CreateThreadsServiceOptions,
  input: Readonly<{
    requestId: AgentRequestId;
    operation: ThreadOperation;
    workspace: Workspace;
    threadId: string;
    session: AgentSession;
    provider: AgentProvider;
    normalizedWorkspacePath: string;
    normalizePath: WorkspacePathNormalizer;
    seenAt: string;
  }>,
): Promise<Result<ValidatedMutationThread, ThreadsServiceError>> => {
  const existingLink = await options.store.getWorkspaceThreadLink({
    workspaceId: input.workspace.id,
    provider: input.provider,
    threadId: input.threadId,
  });

  if (existingLink !== undefined) {
    if (
      (await input.normalizePath(existingLink.threadWorkspacePath)) !==
      input.normalizedWorkspacePath
    ) {
      return createThreadWorkspaceMismatchResult(
        existingLink.threadId,
        input.workspace.workspacePath,
        existingLink.threadWorkspacePath,
      );
    }

    return ok(
      Object.freeze({
        threadWorkspacePath: existingLink.threadWorkspacePath,
        archived: existingLink.archived,
        defaults: getThreadDefaults(existingLink),
      }),
    );
  }

  const readResult = await input.session.readThread(input.requestId, {
    threadId: input.threadId,
    includeTurns: false,
  });

  if (!readResult.ok) {
    switch (readResult.error.type) {
      case "sessionUnavailable":
      case "remoteError":
        return err(readResult.error);
      case "invalidProviderMessage":
        return err(createInvalidProviderPayloadServiceError(input.operation, readResult.error));
      default:
        return assertNever(readResult.error, `Unhandled ${input.operation} validation error`);
    }
  }

  if (
    !(await threadBelongsToWorkspace(
      readResult.data.thread,
      input.normalizedWorkspacePath,
      input.normalizePath,
    ))
  ) {
    return createThreadWorkspaceMismatchResult(
      readResult.data.thread.id,
      input.workspace.workspacePath,
      readResult.data.thread.workspacePath,
    );
  }

  await persistThreadLinksBestEffort(options, {
    operation: input.operation,
    workspace: input.workspace,
    provider: input.provider,
    seenAt: input.seenAt,
    links: [
      Object.freeze({
        threadId: readResult.data.thread.id,
        threadWorkspacePath: readResult.data.thread.workspacePath,
        archived: readResult.data.thread.archived,
      }),
    ],
  });

  return ok(
    Object.freeze({
      threadWorkspacePath: readResult.data.thread.workspacePath,
      archived: readResult.data.thread.archived,
      defaults: getThreadDefaults(undefined),
    }),
  );
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

const persistThreadLinksBestEffort = async (
  options: CreateThreadsServiceOptions,
  input: Readonly<{
    operation: ThreadOperation;
    workspace: Workspace;
    provider: AgentProvider;
    seenAt: string;
    links: readonly Readonly<{
      threadId: string;
      threadWorkspacePath: string;
      archived: boolean;
      model?: string | null;
      reasoningEffort?: AgentReasoningEffort | null;
    }>[];
  }>,
): Promise<void> => {
  try {
    await options.store.upsertWorkspaceThreadLinks({
      workspaceId: input.workspace.id,
      provider: input.provider,
      seenAt: input.seenAt,
      links: input.links,
    });
  } catch (error) {
    options.logger.warn("Failed to persist thread linkage metadata", {
      operation: input.operation,
      workspaceId: input.workspace.id,
      workspacePath: input.workspace.workspacePath,
      provider: input.provider,
      threadCount: input.links.length,
      threadIds: input.links.map((link) => link.threadId).join(","),
      error: getErrorMessage(error),
    });
  }
};

const threadBelongsToWorkspace = async (
  thread: AgentThread,
  normalizedWorkspacePath: string,
  normalizePath: WorkspacePathNormalizer,
): Promise<boolean> => (await normalizePath(thread.workspacePath)) === normalizedWorkspacePath;

const warnOnThreadDefaultsMismatch = (
  logger: Logger,
  input: Readonly<{
    operation: ThreadOperation;
    workspace: Workspace;
    threadId: string;
    providerModel?: string;
    providerReasoningEffort?: AgentReasoningEffort | null;
    defaults: ThreadDefaults;
  }>,
): void => {
  if (
    input.defaults.model === (input.providerModel ?? null) &&
    input.defaults.reasoningEffort === (input.providerReasoningEffort ?? null)
  ) {
    return;
  }

  logger.warn("Resolved thread defaults differ from provider response", {
    operation: input.operation,
    workspaceId: input.workspace.id,
    workspacePath: input.workspace.workspacePath,
    threadId: input.threadId,
    resolvedModel: input.defaults.model,
    providerModel: input.providerModel ?? null,
    resolvedReasoningEffort: input.defaults.reasoningEffort,
    providerReasoningEffort: input.providerReasoningEffort ?? null,
  });
};

const createInvalidProviderPayloadServiceError = (
  operation: ThreadOperation,
  error: AgentInvalidMessageError,
): InvalidProviderPayloadError =>
  Object.freeze({
    type: "invalidProviderPayload",
    agentId: error.agentId,
    provider: error.provider,
    operation,
    message: error.message,
    ...(error.detail ? { detail: error.detail } : {}),
  });

export const mapInvalidProviderPayloadToProtocolError = (
  error: InvalidProviderPayloadError,
): ProtocolMethodError =>
  createInvalidProviderPayloadError({
    agentId: error.agentId,
    provider: error.provider,
    operation: error.operation,
    providerMessage: error.message,
  });

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
