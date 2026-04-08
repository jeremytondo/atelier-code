import {
  APP_SERVER_NAME,
  SERVER_VERSION,
  buildHealthcheckReport,
} from "../core/config/server-metadata";
import type {
  InitializeParams,
  InitializeResult,
  ThreadStartParams,
  ThreadStartResult,
  TurnStartParams,
  TurnStartResult,
  WorkspaceOpenParams,
  WorkspaceOpenResult,
} from "../core/protocol/types";
import { CounterIdGenerator } from "../core/shared/counter-id";
import { DomainError } from "../core/shared/errors";
import { InMemoryAppServerStore } from "../core/store/in-memory-store";
import type { AppServerStore } from "../core/store/store";
import {
  type AppServerHandle,
  startWebSocketServer,
} from "../core/transport/websocket-server";
import type { AgentAdapter } from "../modules/agents/agent.adapter";
import { FakeAgentAdapter } from "../modules/agents/fake.adapter";
import { buildThreadStarted } from "../modules/threads/thread.events";
import { startThreadRecord } from "../modules/threads/thread.service";
import { buildTurnStarted } from "../modules/turns/turn.events";
import {
  AgentTurnRunner,
  type NotificationEmitter,
} from "../modules/turns/turn.runner";
import { startTurn } from "../modules/turns/turn.service";
import { NodeWorkspacePathAccess } from "../modules/workspaces/workspace.paths";
import type { WorkspacePathAccess } from "../modules/workspaces/workspace.paths";
import { openWorkspaceRecord } from "../modules/workspaces/workspace.service";
import {
  type SessionRecord,
  assertSessionInitialized,
  initializeSession,
  markActiveTurn,
  markLoadedThread,
  requireOpenedWorkspace,
  setOpenedWorkspace,
} from "./session";

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
        userAgent: `AtelierCode AppServer/${SERVER_VERSION}`,
      },
    };
  }

  openWorkspace(
    session: SessionRecord,
    params: WorkspaceOpenParams,
  ): CommandOutcome<WorkspaceOpenResult> {
    assertSessionInitialized(session);
    const workspace = openWorkspaceRecord({
      store: this.store,
      workspacePaths: this.workspacePaths,
      path: params.path,
      ids: this.ids,
      clock: this.clock,
    });
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
    const outcome = startThreadRecord({
      workspace,
      params,
      workspacePaths: this.workspacePaths,
      ids: this.ids,
      clock: this.clock,
    });

    this.store.saveThread(outcome.thread);
    markLoadedThread(session, outcome.thread.id);

    return {
      result: outcome.result,
      followUp: async () => {
        await notifications.emit(buildThreadStarted(outcome.thread));
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
    const outcome = startTurn({
      store: this.store,
      workspace,
      params,
      workspacePaths: this.workspacePaths,
      ids: this.ids,
      clock: this.clock,
    });
    this.store.saveThread(outcome.thread);
    markLoadedThread(session, outcome.thread.id);
    markActiveTurn(session, outcome.turn.id);

    return {
      result: outcome.result,
      followUp: async () => {
        try {
          await notifications.emit(
            buildTurnStarted(outcome.thread.id, outcome.turn),
          );

          await this.agentTurnRunner.run(
            session,
            outcome.thread.id,
            outcome.turn.id,
            params.input,
            notifications,
          );
        } catch (error) {
          await this.agentTurnRunner.failTurnExecution(
            session,
            outcome.thread.id,
            outcome.turn.id,
            error,
            notifications,
          );
        }
      },
    };
  }
}

export async function createAppServer(port = 0): Promise<AppServerHandle> {
  return startWebSocketServer({
    port,
    service: new AppServerService(
      new InMemoryAppServerStore(),
      new FakeAgentAdapter(),
      new NodeWorkspacePathAccess(),
      new CounterIdGenerator(),
      {
        now: () => Math.floor(Date.now() / 1000),
      },
    ),
  });
}

export async function startServer(): Promise<AppServerHandle> {
  return createAppServer();
}

export { APP_SERVER_NAME, buildHealthcheckReport, SERVER_VERSION };
