import { assertNever, err, ok } from "@/core/shared";
import type { ThreadMethodDependencies } from "@/threads/methods/method-dependencies";
import type { ThreadsService } from "@/threads/service-types";
import {
  createInvalidProviderPayloadServiceError,
  persistThreadLinksBestEffort,
  validateThreadWorkspaceForMutation,
} from "@/threads/validation";

export const createSetThreadNameMethod =
  (context: ThreadMethodDependencies): ThreadsService["setThreadName"] =>
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
      operation: "thread/name/set",
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

    await persistThreadLinksBestEffort({
      logger: context.logger,
      store: context.store,
      operation: "thread/name/set",
      workspace,
      provider: sessionResult.data.provider,
      seenAt: context.now(),
      links: [
        Object.freeze({
          threadId: params.threadId,
          threadWorkspacePath: validationResult.data.threadWorkspacePath,
          archived: validationResult.data.archived,
        }),
      ],
    });

    return ok({});
  };
