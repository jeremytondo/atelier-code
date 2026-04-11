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
} from "@/threads/validation";

export const createStartThreadMethod =
  (context: ThreadMethodDependencies): ThreadsService["startThread"] =>
  async (requestId, workspace, params) => {
    const sessionResult = await context.registry.getSession();

    if (!sessionResult.ok) {
      if (sessionResult.error.type === "sessionUnavailable") {
        return err(sessionResult.error);
      }

      throw new Error(sessionResult.error.message);
    }

    const normalizedWorkspacePath = await context.normalizePath(workspace.workspacePath);
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
        context.normalizePath,
      ))
    ) {
      return createThreadWorkspaceMismatchResult(
        startResult.data.thread.id,
        workspace.workspacePath,
        startResult.data.thread.workspacePath,
      );
    }

    const defaults = resolveThreadDefaults(startResult.data, params);
    warnOnThreadDefaultsMismatch(context.logger, {
      operation: "thread/start",
      workspace,
      threadId: startResult.data.thread.id,
      providerModel: startResult.data.model,
      providerReasoningEffort: startResult.data.reasoningEffort,
      defaults,
    });
    await persistThreadLinksBestEffort({
      logger: context.logger,
      store: context.store,
      operation: "thread/start",
      workspace,
      provider: sessionResult.data.provider,
      seenAt: context.now(),
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
  };
