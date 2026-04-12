import type {
  AgentInvalidMessageError,
  AgentProvider,
  AgentRemoteError,
  AgentRequestId,
  AgentSession,
  AgentSessionUnavailableError,
  AgentThread,
} from "@/agents/contracts";
import type { Logger } from "@/app/logger";
import {
  createThreadWorkspaceMismatchResult,
  type ProtocolMethodError,
} from "@/core/protocol/errors";
import { assertNever, err, getErrorMessage, ok, type Result } from "@/core/shared";
import { getThreadDefaults, type ThreadDefaults } from "@/threads/response-mapper";
import type { ThreadsStore } from "@/threads/store";
import type { WorkspacePathNormalizer } from "@/workspaces/path";
import type { Workspace } from "@/workspaces/schemas";

export type ThreadOperation =
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

export type ThreadsValidationError =
  | AgentSessionUnavailableError
  | AgentRemoteError
  | InvalidProviderPayloadError
  | ProtocolMethodError;

export type ValidatedMutationThread = Readonly<{
  threadWorkspacePath: string;
  archived: boolean;
  defaults: ThreadDefaults;
}>;

export const validateThreadWorkspaceForMutation = async (
  input: Readonly<{
    logger: Logger;
    store: ThreadsStore;
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
): Promise<Result<ValidatedMutationThread, ThreadsValidationError>> => {
  const existingLink = await input.store.getWorkspaceThreadLink({
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

  // When local linkage is missing, refresh provider-authoritative metadata for
  // the target thread. For `thread/fork`, this validates the parent thread; the
  // caller decides which parent metadata should carry into the fork response.
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

  await persistThreadLinksBestEffort({
    logger: input.logger,
    store: input.store,
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

// Provider mutations remain authoritative even if local metadata persistence
// fails. We log and repair the cached linkage opportunistically on later
// thread/list or thread/read validation passes instead of turning a successful
// provider mutation into an App Server error.
export const persistThreadLinksBestEffort = async (
  input: Readonly<{
    logger: Logger;
    store: ThreadsStore;
    operation: ThreadOperation;
    workspace: Workspace;
    provider: AgentProvider;
    seenAt: string;
    links: readonly Readonly<{
      threadId: string;
      threadWorkspacePath: string;
      archived: boolean;
      model?: string | null;
      reasoningEffort?: import("@/agents/contracts").AgentReasoningEffort | null;
    }>[];
  }>,
): Promise<void> => {
  try {
    await input.store.upsertWorkspaceThreadLinks({
      workspaceId: input.workspace.id,
      provider: input.provider,
      seenAt: input.seenAt,
      links: input.links,
    });
  } catch (error) {
    input.logger.warn("Failed to persist thread linkage metadata", {
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

export const threadBelongsToWorkspace = async (
  thread: AgentThread,
  normalizedWorkspacePath: string,
  normalizePath: WorkspacePathNormalizer,
): Promise<boolean> => (await normalizePath(thread.workspacePath)) === normalizedWorkspacePath;

export const createInvalidProviderPayloadServiceError = (
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
