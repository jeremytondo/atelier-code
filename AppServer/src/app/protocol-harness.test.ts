import { afterEach, describe, expect, test } from "bun:test";
import { createLogger } from "@/app/logger";
import { APP_SERVER_USER_AGENT } from "@/app/protocol";
import { type AppServer, createConfiguredAppServer, type SignalRegistrar } from "@/app/server";
import { getAvailablePort } from "@/test-support/network";

const runningServers: AppServer[] = [];

afterEach(async () => {
  while (runningServers.length > 0) {
    const server = runningServers.pop();

    if (server === undefined) {
      continue;
    }

    try {
      await server.stop("test-cleanup");
    } catch {
      // Ignore cleanup failures so the original test error stays visible.
    }
  }
});

describe("App Server protocol harness", () => {
  test("initializes over a real websocket connection without an extra initialized notification", async () => {
    const harness = await createProtocolHarness();
    const client = await connectProtocolClient(harness.port);

    try {
      client.sendJson({
        id: "req-1",
        method: "initialize",
        params: {
          clientInfo: {
            name: "AtelierCode Test",
            version: "0.1.0",
          },
        },
      });

      await expect(client.nextMessage()).resolves.toEqual({
        id: "req-1",
        result: {
          userAgent: APP_SERVER_USER_AGENT,
        },
      });
      await expect(client.nextMessage(150)).rejects.toThrow("Timed out waiting for message");
    } finally {
      await client.close();
    }
  });

  test("maps invalid json to a parse error", async () => {
    const harness = await createProtocolHarness();
    const client = await connectProtocolClient(harness.port);

    try {
      client.sendText("{");

      await expect(client.nextMessage()).resolves.toEqual({
        id: null,
        error: {
          code: -32700,
          message: "Parse error",
        },
      });
    } finally {
      await client.close();
    }
  });

  test("maps invalid envelopes to invalid request", async () => {
    const harness = await createProtocolHarness();
    const client = await connectProtocolClient(harness.port);

    try {
      client.sendJson({
        method: 123,
      });

      await expect(client.nextMessage()).resolves.toEqual({
        id: null,
        error: {
          code: -32600,
          message: "Invalid request",
        },
      });
    } finally {
      await client.close();
    }
  });

  test("maps unknown methods to method not found", async () => {
    const harness = await createProtocolHarness();
    const client = await connectProtocolClient(harness.port);

    try {
      client.sendJson({
        id: "req-unknown",
        method: "thread/start",
        params: {},
      });

      await expect(client.nextMessage()).resolves.toEqual({
        id: "req-unknown",
        error: {
          code: -32601,
          message: "Method not found",
        },
      });
    } finally {
      await client.close();
    }
  });

  test("maps invalid initialize params to invalid params", async () => {
    const harness = await createProtocolHarness();
    const client = await connectProtocolClient(harness.port);

    try {
      client.sendJson({
        id: "req-invalid-params",
        method: "initialize",
        params: {
          clientInfo: {
            name: "AtelierCode Test",
          },
        },
      });

      await expect(client.nextMessage()).resolves.toEqual({
        id: "req-invalid-params",
        error: {
          code: -32602,
          message: "Invalid params",
        },
      });
    } finally {
      await client.close();
    }
  });

  test("rejects duplicate initialize requests on the same connection", async () => {
    const harness = await createProtocolHarness();
    const client = await connectProtocolClient(harness.port);

    try {
      const initializeRequest = {
        id: "req-initialize-1",
        method: "initialize",
        params: {
          clientInfo: {
            name: "AtelierCode Test",
            version: "0.1.0",
          },
        },
      };

      client.sendJson(initializeRequest);
      await client.nextMessage();

      client.sendJson({
        ...initializeRequest,
        id: "req-initialize-2",
      });

      await expect(client.nextMessage()).resolves.toEqual({
        id: "req-initialize-2",
        error: {
          code: -33000,
          message: "Session already initialized",
          data: {
            code: "SESSION_ALREADY_INITIALIZED",
          },
        },
      });
    } finally {
      await client.close();
    }
  });
});

type ProtocolTestClient = Readonly<{
  sendText: (text: string) => void;
  sendJson: (value: unknown) => void;
  nextMessage: (timeoutMs?: number) => Promise<unknown>;
  close: () => Promise<void>;
}>;

const createProtocolHarness = async (): Promise<Readonly<{ port: number }>> => {
  const port = await getAvailablePort();
  const server = createConfiguredAppServer({
    config: {
      configPath: "/tmp/appserver.config.json",
      port,
      databasePath: "./var/test.sqlite",
      logLevel: "info",
    },
    logger: createLogger({
      level: "error",
      write: () => {},
    }),
    signalRegistrar: createSignalRegistrar(),
  });

  await server.start();
  runningServers.push(server);

  return Object.freeze({ port });
};

const connectProtocolClient = async (port: number): Promise<ProtocolTestClient> => {
  const socket = new WebSocket(`ws://127.0.0.1:${port}/`);
  const bufferedMessages: unknown[] = [];
  const pendingMessages: Array<{
    resolve: (message: unknown) => void;
    reject: (error: Error) => void;
    timer: ReturnType<typeof setTimeout>;
  }> = [];

  socket.addEventListener("message", (event) => {
    const text = toMessageText(event.data);
    const message = JSON.parse(text) as unknown;
    const nextMessage = pendingMessages.shift();

    if (nextMessage === undefined) {
      bufferedMessages.push(message);
      return;
    }

    clearTimeout(nextMessage.timer);
    nextMessage.resolve(message);
  });

  socket.addEventListener("close", () => {
    while (pendingMessages.length > 0) {
      const pendingMessage = pendingMessages.shift();

      if (pendingMessage === undefined) {
        continue;
      }

      clearTimeout(pendingMessage.timer);
      pendingMessage.reject(new Error("WebSocket closed before a message arrived"));
    }
  });

  await waitForSocketOpen(socket);

  return Object.freeze({
    sendText: (text) => {
      socket.send(text);
    },
    sendJson: (value) => {
      socket.send(JSON.stringify(value));
    },
    nextMessage: (timeoutMs = 1_000) => {
      const bufferedMessage = bufferedMessages.shift();

      if (bufferedMessage !== undefined) {
        return Promise.resolve(bufferedMessage);
      }

      return new Promise<unknown>((resolve, reject) => {
        const timer = setTimeout(() => {
          reject(new Error("Timed out waiting for message"));
        }, timeoutMs);

        pendingMessages.push({
          resolve,
          reject,
          timer,
        });
      });
    },
    close: async () => {
      if (socket.readyState === WebSocket.CLOSED) {
        return;
      }

      const closePromise = new Promise<void>((resolve) => {
        socket.addEventListener(
          "close",
          () => {
            resolve();
          },
          { once: true },
        );
      });

      socket.close();
      await closePromise;
    },
  });
};

const waitForSocketOpen = async (socket: WebSocket): Promise<void> => {
  if (socket.readyState === WebSocket.OPEN) {
    return;
  }

  await new Promise<void>((resolve, reject) => {
    const onOpen = () => {
      cleanup();
      resolve();
    };
    const onError = () => {
      cleanup();
      reject(new Error("WebSocket failed to open"));
    };
    const cleanup = () => {
      socket.removeEventListener("open", onOpen);
      socket.removeEventListener("error", onError);
    };

    socket.addEventListener("open", onOpen, { once: true });
    socket.addEventListener("error", onError, { once: true });
  });
};

const toMessageText = (data: unknown): string => {
  if (typeof data === "string") {
    return data;
  }

  if (data instanceof ArrayBuffer) {
    return new TextDecoder().decode(data);
  }

  if (ArrayBuffer.isView(data)) {
    return new TextDecoder().decode(data);
  }

  return String(data);
};

const createSignalRegistrar = (): SignalRegistrar =>
  Object.freeze({
    subscribe: () => () => {},
  });
