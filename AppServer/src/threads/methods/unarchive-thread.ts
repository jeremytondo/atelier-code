import { createThreadWorkspaceMismatchResult } from "@/core/protocol/errors";
import { assertNever, err, ok } from "@/core/shared";
import type { ThreadMethodDependencies } from "@/threads/methods/method-dependencies";
import { mapPublicThread } from "@/threads/response-mapper";
import type { ThreadsService } from "@/threads/service-types";
import {
  createInvalidProviderPayloadServiceError,
  persistThreadLinksBestEffort,
  threadBelongsToWorkspace,
  validateThreadWorkspaceForMutation,
} from "@/threads/validation";

export const createUnarchiveThreadMethod =
  (context: ThreadMethodDependencies): ThreadsService["unarchiveThread"] =>
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
      operation: "thread/unarchive",
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
        context.normalizePath,
      ))
    ) {
      return createThreadWorkspaceMismatchResult(
        unarchiveResult.data.thread.id,
        workspace.workspacePath,
        unarchiveResult.data.thread.workspacePath,
      );
    }

    await persistThreadLinksBestEffort({
      logger: context.logger,
      store: context.store,
      operation: "thread/unarchive",
      workspace,
      provider: sessionResult.data.provider,
      seenAt: context.now(),
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
  };
