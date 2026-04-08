import {
  DEFAULT_MODEL,
  DEFAULT_MODEL_PROVIDER,
} from "../../core/config/defaults";
import {
  toProtocolSandboxPolicy,
  toProtocolThread,
} from "../../core/protocol/serializers";
import type {
  ThreadStartParams,
  ThreadStartResult,
} from "../../core/protocol/types";
import { DomainError } from "../../core/shared/errors";
import type { ThreadRecord, WorkspaceRecord } from "../../core/shared/models";
import type { AppServerStore } from "../../core/store/store";
import {
  type WorkspacePathAccess,
  requireDirectoryPath,
} from "../workspaces/workspace.service";
import { createThreadRecord } from "./thread.entity";

interface IdGenerator {
  next(prefix: string): string;
}

interface Clock {
  now(): number;
}

export interface StartThreadInput {
  workspace: WorkspaceRecord;
  params: ThreadStartParams;
  workspacePaths: WorkspacePathAccess;
  ids: IdGenerator;
  clock: Clock;
}

export function startThreadRecord(input: StartThreadInput): {
  thread: ThreadRecord;
  result: ThreadStartResult;
} {
  const cwd =
    input.params.cwd === undefined || input.params.cwd === null
      ? input.workspace.path
      : requireDirectoryPath(
          input.workspacePaths,
          input.params.cwd,
          "invalid_thread_cwd",
          "thread/start requires cwd to reference an existing directory when provided.",
        );

  const now = input.clock.now();
  const thread = createThreadRecord({
    id: input.ids.next("thread"),
    workspaceId: input.workspace.id,
    cwd,
    now,
    ephemeral: input.params.ephemeral ?? false,
    model: input.params.model ?? DEFAULT_MODEL,
    modelProvider: input.params.modelProvider ?? DEFAULT_MODEL_PROVIDER,
    serviceTier: input.params.serviceTier ?? null,
    approvalPolicy: input.params.approvalPolicy ?? "on-request",
    sandboxMode: input.params.sandbox ?? "workspace-write",
    reasoningEffort: null,
  });

  return {
    thread,
    result: {
      thread: toProtocolThread(thread),
      model: thread.model,
      modelProvider: thread.modelProvider,
      serviceTier: thread.serviceTier,
      cwd: thread.cwd,
      approvalPolicy: thread.approvalPolicy,
      sandbox: toProtocolSandboxPolicy(thread.sandboxMode, thread.cwd),
      reasoningEffort: thread.reasoningEffort,
    },
  };
}

export function requireThread(
  store: Pick<AppServerStore, "getThread">,
  threadId: string,
): ThreadRecord {
  const thread = store.getThread(threadId);
  if (!thread) {
    throw new DomainError(
      "thread_not_found",
      `Thread ${threadId} was not found.`,
      {
        threadId,
      },
    );
  }

  return thread;
}
