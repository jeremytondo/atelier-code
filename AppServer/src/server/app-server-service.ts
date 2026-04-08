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
import { toProtocolThread, toProtocolTurn } from "../protocol/serializers";
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
import {
  type NotificationEmitter,
  RuntimeTurnRunner,
} from "./runtime-turn-runner";
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
  private readonly runtimeTurnRunner: RuntimeTurnRunner;

  constructor(
    private readonly store: AppServerStore,
    agentAdapter: AgentAdapter,
    private readonly workspacePaths: WorkspacePathAccess,
    private readonly ids: IdGenerator,
    private readonly clock: Clock,
  ) {
    this.runtimeTurnRunner = new RuntimeTurnRunner(
      store,
      agentAdapter,
      ids,
      clock,
    );
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
    assertDirectoryPath(
      this.workspacePaths,
      params.path,
      "invalid_workspace_path",
      "workspace/open requires an existing directory path.",
    );

    const existingWorkspace = this.store.getWorkspaceByPath(params.path);
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
      path: params.path,
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

    const cwd = params.cwd ?? workspace.path;
    assertDirectoryPath(
      this.workspacePaths,
      cwd,
      "invalid_thread_cwd",
      "thread/start requires cwd to reference an existing directory when provided.",
    );

    const now = this.clock.now();
    const thread = createThreadRecord({
      id: this.ids.next("thread"),
      workspaceId: workspace.id,
      cwd,
      now,
      model: params.model ?? "fake-codex-phase-1",
      modelProvider: params.modelProvider ?? "fake-codex",
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
        sandbox: thread.sandboxMode,
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

    let nextThread = thread;
    if (params.cwd !== undefined && params.cwd !== null) {
      assertDirectoryPath(
        this.workspacePaths,
        params.cwd,
        "invalid_turn_cwd",
        "turn/start requires cwd to reference an existing directory when provided.",
      );
    }

    nextThread = applyTurnStartOverrides(nextThread, {
      cwd: params.cwd,
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
        await notifications.emit(
          buildTurnStarted(startedTurn.thread.id, startedTurn.turn),
        );

        await this.runtimeTurnRunner.run(
          session,
          startedTurn.thread.id,
          startedTurn.turn.id,
          params.input,
          notifications,
        );
      },
    };
  }
}

function assertDirectoryPath(
  workspacePaths: WorkspacePathAccess,
  path: string,
  code: string,
  message: string,
): void {
  if (!workspacePaths.isDirectory(path)) {
    throw new DomainError(code, message, { path });
  }
}
