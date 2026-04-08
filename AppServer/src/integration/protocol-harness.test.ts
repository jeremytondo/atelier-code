import { afterEach, describe, expect, test } from "bun:test";

import type { JsonRpcNotification } from "../protocol/types";
import {
  type ServerProcessHarness,
  spawnServerProcess,
} from "../test-support/server-process";
import { WebSocketHarness } from "../test-support/ws-harness";

describe("phase 1 websocket harness", () => {
  const servers: ServerProcessHarness[] = [];
  const harnesses: WebSocketHarness[] = [];

  afterEach(async () => {
    for (const harness of harnesses.splice(0)) {
      await harness.close();
    }

    for (const server of servers.splice(0)) {
      await server.stop();
    }
  });

  test("publishes startup JSON and serves GET /healthz", async () => {
    const server = await spawnServerProcess(process.cwd());
    servers.push(server);

    expect(server.startup).toEqual({
      recordType: "app-server.startup",
      host: "127.0.0.1",
      port: expect.any(Number),
      version: "0.1.0",
      pid: expect.any(Number),
    });

    const response = await fetch(
      `http://${server.startup.host}:${server.startup.port}/healthz`,
    );
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      status: "ok",
      server: "ateliercode-app-server",
      version: "0.1.0",
    });
  });

  test("requires initialize before other methods", async () => {
    const { harness } = await startServerAndSocket(servers, harnesses);

    const response = await harness.sendRequest(
      harness.buildRequest("req-1", "workspace/open", {
        path: process.cwd(),
      }),
    );

    expect(response).toEqual({
      id: "req-1",
      error: {
        code: -32000,
        message: "The connection must initialize before using other methods.",
        data: {
          code: "not_initialized",
        },
      },
    });
  });

  test("returns stable errors for malformed JSON and bad envelopes", async () => {
    const { harness } = await startServerAndSocket(servers, harnesses);

    harness.sendRaw("{");
    expect(await harness.nextResponse()).toEqual({
      id: null,
      error: {
        code: -32700,
        message: "Request body must be valid JSON.",
        data: {
          code: "parse_error",
        },
      },
    });

    harness.sendRaw(JSON.stringify({ method: "initialize", params: {} }));
    expect(await harness.nextResponse()).toEqual({
      id: null,
      error: {
        code: -32600,
        message: "Requests must include a string or number id.",
        data: {
          code: "invalid_request",
        },
      },
    });
  });

  test("rejects a second initialize call on the same connection", async () => {
    const { harness } = await startServerAndSocket(servers, harnesses);

    await initializeHarness(harness);

    const response = await harness.sendRequest(
      harness.buildRequest("initialize-2", "initialize", {
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

    expect(response).toEqual({
      id: "initialize-2",
      error: {
        code: -32000,
        message: "The connection has already been initialized.",
        data: {
          code: "already_initialized",
        },
      },
    });
  });

  test("drives initialize -> workspace/open -> thread/start -> turn/start with ordered notifications", async () => {
    const { harness } = await startServerAndSocket(servers, harnesses);

    expect(await initializeHarness(harness)).toEqual({
      id: "initialize-1",
      result: {
        userAgent: "AtelierCode AppServer/0.1.0",
      },
    });

    const workspaceOpen = await harness.sendRequest(
      harness.buildRequest("workspace-1", "workspace/open", {
        path: process.cwd(),
      }),
    );
    expect(workspaceOpen).toEqual({
      id: "workspace-1",
      result: {
        workspace: {
          id: "workspace-1",
          path: process.cwd(),
          createdAt: expect.any(Number),
          updatedAt: expect.any(Number),
        },
      },
    });

    const threadStart = await harness.requestAndCollect(
      harness.buildRequest("thread-req-1", "thread/start", {
        experimentalRawEvents: false,
        persistExtendedHistory: false,
      }),
      1,
    );
    expect(threadStart.response).toEqual({
      id: "thread-req-1",
      result: {
        thread: {
          id: "thread-1",
          workspaceId: "workspace-1",
          preview: "New thread",
          createdAt: expect.any(Number),
          updatedAt: expect.any(Number),
          status: {
            type: "idle",
          },
          cwd: process.cwd(),
          modelProvider: "fake-codex",
          name: null,
          turns: [],
        },
        model: "fake-codex-phase-1",
        modelProvider: "fake-codex",
        serviceTier: null,
        cwd: process.cwd(),
        approvalPolicy: "on-request",
        sandbox: "workspace-write",
        reasoningEffort: null,
      },
    });
    expect(threadStart.notifications).toEqual([
      {
        method: "thread/started",
        params: {
          thread: {
            id: "thread-1",
            workspaceId: "workspace-1",
            preview: "New thread",
            createdAt: expect.any(Number),
            updatedAt: expect.any(Number),
            status: {
              type: "idle",
            },
            cwd: process.cwd(),
            modelProvider: "fake-codex",
            name: null,
            turns: [],
          },
        },
      },
    ]);

    const turnStart = await harness.requestAndCollect(
      harness.buildRequest("turn-req-1", "turn/start", {
        threadId: "thread-1",
        input: [
          {
            type: "text",
            text: "Ship phase 1",
            text_elements: [],
          },
        ],
      }),
      6,
    );
    expect(turnStart.response).toEqual({
      id: "turn-req-1",
      result: {
        turn: {
          id: "turn-1",
          items: [],
          status: "inProgress",
          error: null,
        },
      },
    });
    expect(notificationMethods(turnStart.notifications)).toEqual([
      "turn/started",
      "item/started",
      "item/agentMessage/delta",
      "item/agentMessage/delta",
      "item/completed",
      "turn/completed",
    ]);
  });

  test("returns a stable bad-id error for unknown threads", async () => {
    const { harness } = await startServerAndSocket(servers, harnesses);
    await initializeHarness(harness);
    await openWorkspace(harness);

    const response = await harness.sendRequest(
      harness.buildRequest("turn-unknown", "turn/start", {
        threadId: "missing-thread",
        input: [
          {
            type: "text",
            text: "Hello",
            text_elements: [],
          },
        ],
      }),
    );

    expect(response).toEqual({
      id: "turn-unknown",
      error: {
        code: -32000,
        message: "Thread missing-thread was not found.",
        data: {
          code: "thread_not_found",
          threadId: "missing-thread",
        },
      },
    });
  });

  test("returns turn_already_active when a second turn starts before the first finishes", async () => {
    const { harness } = await startServerAndSocket(servers, harnesses);
    await initializeHarness(harness);
    await openWorkspace(harness);
    await harness.requestAndCollect(
      harness.buildRequest("thread-req-1", "thread/start", {
        experimentalRawEvents: false,
        persistExtendedHistory: false,
      }),
      1,
    );

    const firstResponse = await harness.sendRequest(
      harness.buildRequest("turn-1", "turn/start", {
        threadId: "thread-1",
        input: [
          {
            type: "text",
            text: "First",
            text_elements: [],
          },
        ],
      }),
    );
    expect(firstResponse).toEqual({
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

    const secondResponse = await harness.sendRequest(
      harness.buildRequest("turn-2", "turn/start", {
        threadId: "thread-1",
        input: [
          {
            type: "text",
            text: "Second",
            text_elements: [],
          },
        ],
      }),
    );

    expect(secondResponse).toEqual({
      id: "turn-2",
      error: {
        code: -32000,
        message: "Thread thread-1 already has an active turn.",
        data: {
          code: "turn_already_active",
          threadId: "thread-1",
          turnId: "turn-1",
        },
      },
    });
  });
});

async function startServerAndSocket(
  servers: ServerProcessHarness[],
  harnesses: WebSocketHarness[],
): Promise<{
  server: ServerProcessHarness;
  harness: WebSocketHarness;
}> {
  const server = await spawnServerProcess(process.cwd());
  servers.push(server);

  const harness = new WebSocketHarness(
    `ws://${server.startup.host}:${server.startup.port}/`,
  );
  harnesses.push(harness);
  await harness.waitForOpen();

  return { server, harness };
}

async function initializeHarness(harness: WebSocketHarness) {
  return harness.sendRequest(
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
}

async function openWorkspace(harness: WebSocketHarness) {
  return harness.sendRequest(
    harness.buildRequest("workspace-1", "workspace/open", {
      path: process.cwd(),
    }),
  );
}

function notificationMethods(notifications: JsonRpcNotification[]): string[] {
  return notifications.map((notification) => notification.method);
}
