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

export const createResumeThreadMethod =
  (context: ThreadMethodDependencies): ThreadsService["resumeThread"] =>
  async (requestId, workspace, params) => {
    const sessionResult = await context.registry.getSession();

    if (!sessionResult.ok) {
      if (sessionResult.error.type === "sessionUnavailable") {
        return err(sessionResult.error);
      }

      throw new Error(sessionResult.error.message);
    }

    const normalizedWorkspacePath = await context.normalizePath(workspace.workspacePath);
    const existingLink = await context.store.getWorkspaceThreadLink({
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
          return err(createInvalidProviderPayloadServiceError("thread/resume", resumeResult.error));
        default:
          return assertNever(resumeResult.error, "Unhandled thread/resume error");
      }
    }

    if (
      !(await threadBelongsToWorkspace(
        resumeResult.data.thread,
        normalizedWorkspacePath,
        context.normalizePath,
      ))
    ) {
      return createThreadWorkspaceMismatchResult(
        resumeResult.data.thread.id,
        workspace.workspacePath,
        resumeResult.data.thread.workspacePath,
      );
    }

    const defaults = resolveThreadDefaults(resumeResult.data, params, existingLink);
    warnOnThreadDefaultsMismatch(context.logger, {
      operation: "thread/resume",
      workspace,
      threadId: resumeResult.data.thread.id,
      providerModel: resumeResult.data.model,
      providerReasoningEffort: resumeResult.data.reasoningEffort,
      defaults,
    });
    await persistThreadLinksBestEffort({
      logger: context.logger,
      store: context.store,
      operation: "thread/resume",
      workspace,
      provider: sessionResult.data.provider,
      seenAt: context.now(),
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
  };
