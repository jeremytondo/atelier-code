import { afterEach, describe, expect, test } from "bun:test";
import { realpathSync } from "node:fs";

import { AppServerService } from "../src/app/server";
import { createSessionRecord } from "../src/app/session";
import { buildHealthcheckReport } from "../src/core/config/server-metadata";
import { ProtocolDispatcher } from "../src/core/protocol/dispatcher";
import { parseRawRequest } from "../src/core/protocol/request-parser";
import { serializeProtocolMessage } from "../src/core/protocol/serializers";
import { CounterIdGenerator } from "../src/core/shared/id-generator";
import { InMemoryAppServerStore } from "../src/core/store/in-memory-store";
import {
  type AppServerHandle,
  startWebSocketServer,
} from "../src/core/transport/websocket-server";
import type { AgentAdapter } from "../src/modules/agents/agent.adapter";
import { WebSocketHarness } from "./support/ws-harness";

describe("websocket follow-up failures", () => {
  const workspacePath = realpathSync.native(process.cwd());
  const stores: InMemoryAppServerStore[] = [];
  const servers: AppServerHandle[] = [];
  const harnesses: WebSocketHarness[] = [];

  afterEach(async () => {
    for (const harness of harnesses.splice(0)) {
      await harness.close();
    }

    for (const server of servers.splice(0)) {
      server.stop();
    }

    stores.splice(0);
  });

  test("marks the turn failed and keeps the server healthy after post-response errors", async () => {
    const store = new InMemoryAppServerStore();
    stores.push(store);
    const service = new AppServerService(
      store,
      new ThrowingAgentAdapter(),
      new FakeWorkspacePathAccess({
        [workspacePath]: workspacePath,
      }),
      new CounterIdGenerator(),
      {
        now: () => 1_700_000_000,
      },
    );
    const dispatcher = new ProtocolDispatcher(service);
    const sessions = new Map<string, ReturnType<typeof createSessionRecord>>();

    const server = await startWebSocketServer({
      healthcheckResponse: buildHealthcheckReport(),
      onConnectionOpen(connectionId) {
        sessions.set(connectionId, createSessionRecord(connectionId));
      },
      onConnectionClose(connectionId) {
        sessions.delete(connectionId);
      },
      async onMessage({ connectionId, message }) {
        const session =
          sessions.get(connectionId) ?? createSessionRecord(connectionId);
        sessions.set(connectionId, session);

        const parsedRequest = parseRawRequest(message);
        const outcome = parsedRequest.ok
          ? dispatcher.dispatchParsedRequest(parsedRequest.request, {
              session,
              notifications: {
                async emit(notification) {
                  if (
                    session.optOutNotificationMethods.has(notification.method)
                  ) {
                    return;
                  }

                  server.send(
                    connectionId,
                    serializeProtocolMessage(notification),
                  );
                },
              },
            })
          : parsedRequest.outcome;

        server.send(connectionId, serializeProtocolMessage(outcome.response));

        if (outcome.followUp) {
          await outcome.followUp();
        }
      },
    });
    servers.push(server);

    const harness = new WebSocketHarness(`ws://${server.host}:${server.port}/`);
    harnesses.push(harness);
    await harness.waitForOpen();

    await harness.sendRequest(
      harness.buildRequest("initialize-1", "initialize", {
        clientInfo: {
          name: "Harness",
          title: null,
          version: "1.0.0",
        },
        capabilities: {
          experimentalApi: true,
        },
      }),
    );
    await harness.sendRequest(
      harness.buildRequest("workspace-1", "workspace/open", {
        path: workspacePath,
      }),
    );
    await harness.requestAndCollect(
      harness.buildRequest("thread-1", "thread/start", {
        experimentalRawEvents: false,
        persistExtendedHistory: false,
      }),
      1,
    );

    const turnStart = await harness.requestAndCollect(
      harness.buildRequest("turn-1", "turn/start", {
        threadId: "thread-1",
        input: [
          {
            type: "text",
            text: "trigger failure",
            text_elements: [],
          },
        ],
      }),
      3,
    );

    expect(turnStart.response).toEqual({
      id: "turn-1",
      result: {
        turn: {
          id: "turn-1",
          items: [],
          status: "inProgress",
          error: null,
        },
      },
    });
    expect(
      turnStart.notifications.map((notification) => notification.method),
    ).toEqual(["turn/started", "item/started", "turn/completed"]);
    expect(turnStart.notifications.at(-1)).toEqual({
      method: "turn/completed",
      params: {
        threadId: "thread-1",
        turn: {
          id: "turn-1",
          items: [],
          status: "failed",
          error: {
            message: "adapter boom",
            agentErrorInfo: null,
            additionalDetails: expect.stringContaining("adapter boom"),
          },
        },
      },
    });
    expect(store.getThread("thread-1")?.status).toEqual({
      type: "systemError",
    });
    expect(store.getTurn("thread-1", "turn-1")?.status).toBe("failed");

    const healthcheck = await fetch(
      `http://${server.host}:${server.port}/healthz`,
    );
    expect(healthcheck.status).toBe(200);
    expect(await healthcheck.json()).toEqual({
      status: "ok",
      server: "ateliercode-app-server",
      version: "0.1.0",
    });
  });
});

class FakeWorkspacePathAccess {
  constructor(private readonly mappings: Record<string, string>) {}

  resolveDirectory(path: string): string | null {
    return this.mappings[path] ?? null;
  }
}

class ThrowingAgentAdapter implements AgentAdapter {
  async *streamTurn() {
    yield {
      type: "itemStarted" as const,
      item: {
        type: "agentMessage" as const,
        id: "item-2",
        text: "",
        phase: "final_answer" as const,
      },
    };

    throw new Error("adapter boom");
  }
}
