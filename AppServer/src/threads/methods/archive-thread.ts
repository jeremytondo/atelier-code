import { assertNever, err, ok } from "@/core/shared";
import type { ThreadMethodDependencies } from "@/threads/methods/method-dependencies";
import type { ThreadsService } from "@/threads/service-types";
import {
  createInvalidProviderPayloadServiceError,
  persistThreadLinksBestEffort,
  validateThreadWorkspaceForMutation,
} from "@/threads/validation";

export const createArchiveThreadMethod =
  (context: ThreadMethodDependencies): ThreadsService["archiveThread"] =>
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
      operation: "thread/archive",
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

    await persistThreadLinksBestEffort({
      logger: context.logger,
      store: context.store,
      operation: "thread/archive",
      workspace,
      provider: sessionResult.data.provider,
      seenAt: context.now(),
      links: [
        Object.freeze({
          threadId: params.threadId,
          threadWorkspacePath: validationResult.data.threadWorkspacePath,
          archived: true,
        }),
      ],
    });

    return ok({});
  };
