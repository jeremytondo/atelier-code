import type { AgentAdapter } from "../agent-adapters/agent-adapter";
import { DomainError } from "../domain/errors";
import type { WorkspaceRecord } from "../domain/models";
import {
  applyTurnStartOverrides,
  assertNoActiveTurn,
  assertThreadBelongsToWorkspace,
  createThreadRecord,
  startTurnRecord,
} from "../domain/thread";
import {
  buildThreadStarted,
  buildTurnStarted,
} from "../protocol/notification-builders";
import {
  toProtocolSandboxPolicy,
  toProtocolThread,
  toProtocolTurn,
} from "../protocol/serializers";
import type {
  InitializeParams,
  InitializeResult,
  ThreadStartParams,
  ThreadStartResult,
  TurnStartParams,
  TurnStartResult,
  WorkspaceOpenParams,
  WorkspaceOpenResult,
} from "../protocol/types";
import type { AppServerStore } from "../store/store";
import { AgentTurnRunner, type NotificationEmitter } from "./agent-turn-runner";
import { DEFAULT_MODEL, DEFAULT_MODEL_PROVIDER } from "./defaults";
import {
  type SessionRecord,
  assertSessionInitialized,
  initializeSession,
  markActiveTurn,
  markLoadedThread,
  requireOpenedWorkspace,
  setOpenedWorkspace,
} from "./session-state";
import type { WorkspacePathAccess } from "./workspace-paths";

export interface IdGenerator {
  next(prefix: string): string;
}

export interface Clock {
  now(): number;
}

interface CommandOutcome<TResult> {
  result: TResult;
  followUp?: () => Promise<void>;
}

export class AppServerService {
  private readonly agentTurnRunner: AgentTurnRunner;

  constructor(
    private readonly store: AppServerStore,
    agentAdapter: AgentAdapter,
    private readonly workspacePaths: WorkspacePathAccess,
    private readonly ids: IdGenerator,
    private readonly clock: Clock,
  ) {
    this.agentTurnRunner = new AgentTurnRunner(store, agentAdapter, ids, clock);
  }

  initialize(
    session: SessionRecord,
    params: InitializeParams,
  ): CommandOutcome<InitializeResult> {
    if (session.initialized) {
      throw new DomainError(
        "already_initialized",
        "The connection has already been initialized.",
      );
    }

    initializeSession(
      session,
      params.clientInfo,
      params.capabilities?.optOutNotificationMethods ?? [],
    );

    return {
      result: {
        userAgent: "AtelierCode AppServer/0.1.0",
      },
    };
  }

  openWorkspace(
    session: SessionRecord,
    params: WorkspaceOpenParams,
  ): CommandOutcome<WorkspaceOpenResult> {
    assertSessionInitialized(session);
    const workspacePath = requireDirectoryPath(
      this.workspacePaths,
      params.path,
      "invalid_workspace_path",
      "workspace/open requires an existing directory path.",
    );

    const existingWorkspace = this.store.getWorkspaceByPath(workspacePath);
    if (existingWorkspace) {
      existingWorkspace.updatedAt = this.clock.now();
      this.store.saveWorkspace(existingWorkspace);
      setOpenedWorkspace(session, existingWorkspace.id);
      return {
        result: {
          workspace: existingWorkspace,
        },
      };
    }

    const now = this.clock.now();
    const workspace: WorkspaceRecord = {
      id: this.ids.next("workspace"),
      path: workspacePath,
      createdAt: now,
      updatedAt: now,
    };

    this.store.saveWorkspace(workspace);
    setOpenedWorkspace(session, workspace.id);

    return {
      result: {
        workspace,
      },
    };
  }

  startThread(
    session: SessionRecord,
    params: ThreadStartParams,
    notifications: NotificationEmitter,
  ): CommandOutcome<ThreadStartResult> {
    assertSessionInitialized(session);
    const workspace = requireOpenedWorkspace(session, this.store);

    const cwd =
      params.cwd === undefined || params.cwd === null
        ? workspace.path
        : requireDirectoryPath(
            this.workspacePaths,
            params.cwd,
            "invalid_thread_cwd",
            "thread/start requires cwd to reference an existing directory when provided.",
          );

    const now = this.clock.now();
    const thread = createThreadRecord({
      id: this.ids.next("thread"),
      workspaceId: workspace.id,
      cwd,
      now,
      ephemeral: params.ephemeral ?? false,
      model: params.model ?? DEFAULT_MODEL,
      modelProvider: params.modelProvider ?? DEFAULT_MODEL_PROVIDER,
      serviceTier: params.serviceTier ?? null,
      approvalPolicy: params.approvalPolicy ?? "on-request",
      sandboxMode: params.sandbox ?? "workspace-write",
      reasoningEffort: null,
    });

    this.store.saveThread(thread);
    markLoadedThread(session, thread.id);

    return {
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
      followUp: async () => {
        await notifications.emit(buildThreadStarted(thread));
      },
    };
  }

  startTurn(
    session: SessionRecord,
    params: TurnStartParams,
    notifications: NotificationEmitter,
  ): CommandOutcome<TurnStartResult> {
    assertSessionInitialized(session);
    const workspace = requireOpenedWorkspace(session, this.store);

    const thread = this.store.getThread(params.threadId);
    if (!thread) {
      throw new DomainError(
        "thread_not_found",
        `Thread ${params.threadId} was not found.`,
        {
          threadId: params.threadId,
        },
      );
    }

    assertThreadBelongsToWorkspace(thread, workspace);
    assertNoActiveTurn(thread);

    const resolvedCwd =
      params.cwd === undefined || params.cwd === null
        ? params.cwd
        : requireDirectoryPath(
            this.workspacePaths,
            params.cwd,
            "invalid_turn_cwd",
            "turn/start requires cwd to reference an existing directory when provided.",
          );

    let nextThread = thread;

    nextThread = applyTurnStartOverrides(nextThread, {
      cwd: resolvedCwd,
      model: params.model,
      serviceTier: params.serviceTier,
      approvalPolicy: params.approvalPolicy,
      effort: params.effort,
    });

    const startedTurn = startTurnRecord(nextThread, {
      turnId: this.ids.next("turn"),
      userItemId: this.ids.next("item"),
      input: params.input,
      now: this.clock.now(),
    });
    this.store.saveThread(startedTurn.thread);
    markLoadedThread(session, startedTurn.thread.id);
    markActiveTurn(session, startedTurn.turn.id);

    return {
      result: {
        turn: toProtocolTurn(startedTurn.turn),
      },
      followUp: async () => {
        try {
          await notifications.emit(
            buildTurnStarted(startedTurn.thread.id, startedTurn.turn),
          );

          await this.agentTurnRunner.run(
            session,
            startedTurn.thread.id,
            startedTurn.turn.id,
            params.input,
            notifications,
          );
        } catch (error) {
          await this.agentTurnRunner.failTurnExecution(
            session,
            startedTurn.thread.id,
            startedTurn.turn.id,
            error,
            notifications,
          );
        }
      },
    };
  }
}

function requireDirectoryPath(
  workspacePaths: WorkspacePathAccess,
  path: string,
  code: string,
  message: string,
): string {
  const resolvedPath = workspacePaths.resolveDirectory(path);
  if (resolvedPath === null) {
    throw new DomainError(code, message, { path });
  }

  return resolvedPath;
}
