import type {
  AgentRemoteError,
  AgentRequestId,
  AgentSessionUnavailableError,
} from "@/agents/contracts";
import type { AgentRegistry } from "@/agents/registry";
import type { Logger } from "@/app/logger";
import type { ProtocolMethodError } from "@/core/protocol/errors";
import type {
  ThreadArchiveParams,
  ThreadArchiveResult,
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
import type { ThreadsStore } from "@/threads/store";
import type { InvalidProviderPayloadError } from "@/threads/validation";
import type { WorkspacePathNormalizer } from "@/workspaces/path";
import type { Workspace } from "@/workspaces/schemas";

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
  ) => Promise<{ ok: true; data: ThreadListResult } | { ok: false; error: ThreadsServiceError }>;
  startThread: (
    requestId: AgentRequestId,
    workspace: Workspace,
    params: ThreadStartParams,
  ) => Promise<{ ok: true; data: ThreadStartResult } | { ok: false; error: ThreadsServiceError }>;
  resumeThread: (
    requestId: AgentRequestId,
    workspace: Workspace,
    params: ThreadResumeParams,
  ) => Promise<{ ok: true; data: ThreadResumeResult } | { ok: false; error: ThreadsServiceError }>;
  readThread: (
    requestId: AgentRequestId,
    workspace: Workspace,
    params: ThreadReadParams,
  ) => Promise<{ ok: true; data: ThreadReadResult } | { ok: false; error: ThreadsServiceError }>;
  forkThread: (
    requestId: AgentRequestId,
    workspace: Workspace,
    params: ThreadForkParams,
  ) => Promise<{ ok: true; data: ThreadForkResult } | { ok: false; error: ThreadsServiceError }>;
  archiveThread: (
    requestId: AgentRequestId,
    workspace: Workspace,
    params: ThreadArchiveParams,
  ) => Promise<{ ok: true; data: ThreadArchiveResult } | { ok: false; error: ThreadsServiceError }>;
  unarchiveThread: (
    requestId: AgentRequestId,
    workspace: Workspace,
    params: ThreadUnarchiveParams,
  ) => Promise<
    { ok: true; data: ThreadUnarchiveResult } | { ok: false; error: ThreadsServiceError }
  >;
  setThreadName: (
    requestId: AgentRequestId,
    workspace: Workspace,
    params: ThreadSetNameParams,
  ) => Promise<{ ok: true; data: ThreadSetNameResult } | { ok: false; error: ThreadsServiceError }>;
}>;

export type CreateThreadsServiceOptions = Readonly<{
  logger: Logger;
  registry: AgentRegistry;
  store: ThreadsStore;
  now?: () => string;
  normalizeWorkspacePath?: WorkspacePathNormalizer;
}>;
