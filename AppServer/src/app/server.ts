import {
  APP_SERVER_NAME,
  SERVER_VERSION,
  buildHealthcheckReport,
} from "../core/config/server-metadata";
import { ProtocolDispatcher } from "../core/protocol/dispatcher";
import { parseRawRequest } from "../core/protocol/request-parser";
import { serializeProtocolMessage } from "../core/protocol/serializers";
import type {
  InitializeParams,
  InitializeResult,
  JsonRpcNotification,
  ThreadStartParams,
  ThreadStartResult,
  TurnStartParams,
  TurnStartResult,
  WorkspaceOpenParams,
  WorkspaceOpenResult,
} from "../core/protocol/types";
import { DomainError } from "../core/shared/errors";
import {
  CounterIdGenerator,
  type IdGenerator,
} from "../core/shared/id-generator";
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
  startTurn,
} from "../modules/turns/turn.service";
import {
  NodeWorkspacePathAccess,
  type WorkspacePathAccess,
  openWorkspaceRecord,
} from "../modules/workspaces/workspace.service";
import {
  type SessionRecord,
  assertSessionInitialized,
  createSessionRecord,
  initializeSession,
  markActiveTurn,
  markLoadedThread,
  requireOpenedWorkspace,
  setOpenedWorkspace,
} from "./session";

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
  const service = new AppServerService(
    new InMemoryAppServerStore(),
    new FakeAgentAdapter(),
    new NodeWorkspacePathAccess(),
    new CounterIdGenerator(),
    {
      now: () => Math.floor(Date.now() / 1000),
    },
  );
  const dispatcher = new ProtocolDispatcher(service);
  const sessions = new Map<string, SessionRecord>();
  const transport = await startWebSocketServer({
    port,
    healthcheckResponse: buildHealthcheckReport(),
    onConnectionOpen(connectionId) {
      sessions.set(connectionId, createSessionRecord(connectionId));
    },
    onConnectionClose(connectionId) {
      sessions.delete(connectionId);
    },
    onMessage({ connectionId, message }) {
      const session = ensureSession(sessions, connectionId);
      const parsedRequest = parseRawRequest(message);
      const outcome = parsedRequest.ok
        ? dispatcher.dispatchParsedRequest(parsedRequest.request, {
            session,
            notifications: {
              async emit<TParams>(
                notification: JsonRpcNotification<TParams>,
              ): Promise<void> {
                if (
                  session.optOutNotificationMethods.has(notification.method)
                ) {
                  return;
                }

                transport.send(
                  connectionId,
                  serializeProtocolMessage(notification),
                );
              },
            },
          })
        : parsedRequest.outcome;

      transport.send(connectionId, serializeProtocolMessage(outcome.response));

      if (outcome.followUp) {
        void runFollowUp(outcome.followUp);
      }
    },
  });

  return transport;
}

export async function startServer(): Promise<AppServerHandle> {
  return createAppServer();
}

export { APP_SERVER_NAME, buildHealthcheckReport, SERVER_VERSION };

function ensureSession(
  sessions: Map<string, SessionRecord>,
  connectionId: string,
): SessionRecord {
  const existingSession = sessions.get(connectionId);
  if (existingSession) {
    return existingSession;
  }

  const session = createSessionRecord(connectionId);
  sessions.set(connectionId, session);
  return session;
}

async function runFollowUp(followUp: () => Promise<void>): Promise<void> {
  try {
    await followUp();
  } catch (error) {
    console.error("App Server follow-up execution failed.", error);
  }
}
