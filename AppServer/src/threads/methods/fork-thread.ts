import { createThreadWorkspaceMismatchResult } from "@/core/protocol/errors";
import { assertNever, err, ok } from "@/core/shared";
import type { ThreadMethodDependencies } from "@/threads/methods/method-dependencies";
import {
  mapPublicThread,
  resolveThreadDefaults,
  warnOnThreadDefaultsMismatch,
} from "@/threads/response-mapper";
import type { ThreadsService } from "@/threads/service-types";
import {
  createInvalidProviderPayloadServiceError,
  persistThreadLinksBestEffort,
  threadBelongsToWorkspace,
  validateThreadWorkspaceForMutation,
} from "@/threads/validation";

export const createForkThreadMethod =
  (context: ThreadMethodDependencies): ThreadsService["forkThread"] =>
  async (requestId, workspace, params) => {
    const sessionResult = await context.registry.getSession();

    if (!sessionResult.ok) {
      if (sessionResult.error.type === "sessionUnavailable") {
        return err(sessionResult.error);
      }

      throw new Error(sessionResult.error.message);
    }

    const normalizedWorkspacePath = await context.normalizePath(workspace.workspacePath);
    const validationResult = await validateThreadWorkspaceForMutation({
      logger: context.logger,
      store: context.store,
      requestId,
      operation: "thread/fork",
      workspace,
      threadId: params.threadId,
      session: sessionResult.data,
      provider: sessionResult.data.provider,
      normalizedWorkspacePath,
      normalizePath: context.normalizePath,
      seenAt: context.now(),
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
        context.normalizePath,
      ))
    ) {
      return createThreadWorkspaceMismatchResult(
        forkResult.data.thread.id,
        workspace.workspacePath,
        forkResult.data.thread.workspacePath,
      );
    }

    const defaults = resolveThreadDefaults(forkResult.data, params);
    warnOnThreadDefaultsMismatch(context.logger, {
      operation: "thread/fork",
      workspace,
      threadId: forkResult.data.thread.id,
      providerModel: forkResult.data.model,
      providerReasoningEffort: forkResult.data.reasoningEffort,
      defaults,
    });
    await persistThreadLinksBestEffort({
      logger: context.logger,
      store: context.store,
      operation: "thread/fork",
      workspace,
      provider: sessionResult.data.provider,
      seenAt: context.now(),
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
  };
