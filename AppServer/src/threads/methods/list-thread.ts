import { assertNever, err, ok } from "@/core/shared";
import type { ThreadMethodDependencies } from "@/threads/methods/method-dependencies";
import { getThreadDefaults, mapPublicThread } from "@/threads/response-mapper";
import type { ThreadsService } from "@/threads/service-types";
import {
  createInvalidProviderPayloadServiceError,
  persistThreadLinksBestEffort,
  threadBelongsToWorkspace,
} from "@/threads/validation";

export const createListThreadMethod =
  (context: ThreadMethodDependencies): ThreadsService["listThreads"] =>
  async (requestId, workspace, params) => {
    const sessionResult = await context.registry.getSession();

    if (!sessionResult.ok) {
      if (sessionResult.error.type === "sessionUnavailable") {
        return err(sessionResult.error);
      }

      throw new Error(sessionResult.error.message);
    }

    const normalizedWorkspacePath = await context.normalizePath(workspace.workspacePath);
    const existingLinks = await context.store.listWorkspaceThreadLinks({
      workspaceId: workspace.id,
      provider: sessionResult.data.provider,
    });
    const defaultsByThreadId = new Map(existingLinks.map((link) => [link.threadId, link] as const));

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
          if (
            !(await threadBelongsToWorkspace(
              thread,
              normalizedWorkspacePath,
              context.normalizePath,
            ))
          ) {
            context.logger.warn("Filtered cross-workspace thread from provider list", {
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
    ).filter((thread): thread is (typeof listResult.data.threads)[number] => thread !== undefined);

    await persistThreadLinksBestEffort({
      logger: context.logger,
      store: context.store,
      operation: "thread/list",
      workspace,
      provider: sessionResult.data.provider,
      seenAt: context.now(),
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
  };
