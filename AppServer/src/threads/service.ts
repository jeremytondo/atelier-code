import {
  createInvalidProviderPayloadError,
  type ProtocolMethodError,
} from "@/core/protocol/errors";
import { createArchiveThreadMethod } from "@/threads/methods/archive-thread";
import { createForkThreadMethod } from "@/threads/methods/fork-thread";
import { createListThreadMethod } from "@/threads/methods/list-thread";
import type { ThreadMethodDependencies } from "@/threads/methods/method-dependencies";
import { createReadThreadMethod } from "@/threads/methods/read-thread";
import { createResumeThreadMethod } from "@/threads/methods/resume-thread";
import { createSetThreadNameMethod } from "@/threads/methods/set-thread-name";
import { createStartThreadMethod } from "@/threads/methods/start-thread";
import { createUnarchiveThreadMethod } from "@/threads/methods/unarchive-thread";
import type { CreateThreadsServiceOptions, ThreadsService } from "@/threads/service-types";
import type { InvalidProviderPayloadError } from "@/threads/validation";
import { normalizeWorkspacePath } from "@/workspaces/path";

export type {
  CreateThreadsServiceOptions,
  ThreadsService,
  ThreadsServiceError,
} from "@/threads/service-types";
export type { InvalidProviderPayloadError } from "@/threads/validation";

export const createThreadsService = (options: CreateThreadsServiceOptions): ThreadsService => {
  const context: ThreadMethodDependencies = Object.freeze({
    logger: options.logger,
    registry: options.registry,
    store: options.store,
    now: options.now ?? (() => new Date().toISOString()),
    normalizePath: options.normalizeWorkspacePath ?? normalizeWorkspacePath,
  });

  return Object.freeze({
    listThreads: createListThreadMethod(context),
    startThread: createStartThreadMethod(context),
    resumeThread: createResumeThreadMethod(context),
    readThread: createReadThreadMethod(context),
    forkThread: createForkThreadMethod(context),
    archiveThread: createArchiveThreadMethod(context),
    unarchiveThread: createUnarchiveThreadMethod(context),
    setThreadName: createSetThreadNameMethod(context),
  });
};

export const mapInvalidProviderPayloadToProtocolError = (
  error: InvalidProviderPayloadError,
): ProtocolMethodError =>
  createInvalidProviderPayloadError({
    agentId: error.agentId,
    provider: error.provider,
    operation: error.operation,
    providerMessage: error.message,
  });
