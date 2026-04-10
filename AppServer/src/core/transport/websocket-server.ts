import type { Server, ServerWebSocket } from "bun";
import type { Logger } from "@/app/logger";
import type { LifecycleComponent } from "@/core/shared";

type WebSocketConnectionData = Readonly<{
  connectionId: string;
}>;

export type RawTextConnection = Readonly<{
  id: string;
  sendText: (text: string) => Promise<void>;
  close: (code?: number, reason?: string) => void;
}>;

export type RawConnectionOpenedEvent = Readonly<{
  connection: RawTextConnection;
}>;

export type RawConnectionClosedEvent = Readonly<{
  connectionId: string;
  code: number;
  reason: string;
}>;

export type RawTextMessageEvent = Readonly<{
  connectionId: string;
  text: string;
}>;

export type CreateWebSocketServerOptions = Readonly<{
  logger: Logger;
  port: number;
  path?: string;
  onConnectionOpen?: (event: RawConnectionOpenedEvent) => Promise<void> | void;
  onConnectionClose?: (event: RawConnectionClosedEvent) => Promise<void> | void;
  onTextMessage?: (event: RawTextMessageEvent) => Promise<void> | void;
}>;

export const createWebSocketServer = (
  options: CreateWebSocketServerOptions,
): LifecycleComponent => {
  const logger = options.logger;
  const path = options.path ?? "/";
  const sockets = new Map<string, ServerWebSocket<WebSocketConnectionData>>();
  let server: Server<WebSocketConnectionData> | null = null;

  const start = async (): Promise<void> => {
    if (server !== null) {
      return;
    }

    server = Bun.serve<WebSocketConnectionData>({
      port: options.port,
      fetch(request, bunServer) {
        const url = new URL(request.url);

        if (url.pathname !== path) {
          return new Response("Not Found", { status: 404 });
        }

        const connectionId = crypto.randomUUID();
        const upgraded = bunServer.upgrade(request, {
          data: { connectionId },
        });

        if (upgraded) {
          return;
        }

        logger.warn("WebSocket upgrade failed", {
          path: url.pathname,
        });

        return new Response("WebSocket upgrade failed", { status: 400 });
      },
      websocket: {
        data: {} as WebSocketConnectionData,
        open: async (socket) => {
          const connection = createRawTextConnection(socket);
          sockets.set(connection.id, socket);

          logger.info("WebSocket connection opened", {
            connectionId: connection.id,
          });

          try {
            await options.onConnectionOpen?.({ connection });
          } catch (error) {
            logger.error("WebSocket open handler failed", {
              connectionId: connection.id,
              error: getErrorMessage(error),
            });
            socket.close(1011, "Internal error");
          }
        },
        message: async (socket, message) => {
          if (typeof message !== "string") {
            logger.warn("Rejecting non-text WebSocket message", {
              connectionId: socket.data.connectionId,
            });
            socket.close(1003, "Text messages only");
            return;
          }

          try {
            await options.onTextMessage?.({
              connectionId: socket.data.connectionId,
              text: message,
            });
          } catch (error) {
            logger.error("WebSocket message handler failed", {
              connectionId: socket.data.connectionId,
              error: getErrorMessage(error),
            });
            socket.close(1011, "Internal error");
          }
        },
        close: async (socket, code, reason) => {
          sockets.delete(socket.data.connectionId);

          logger.info("WebSocket connection closed", {
            connectionId: socket.data.connectionId,
            code,
            reason,
          });

          try {
            await options.onConnectionClose?.({
              connectionId: socket.data.connectionId,
              code,
              reason,
            });
          } catch (error) {
            logger.error("WebSocket close handler failed", {
              connectionId: socket.data.connectionId,
              error: getErrorMessage(error),
            });
          }
        },
      },
    });

    logger.info("WebSocket Server started", {
      port: server.port ?? options.port,
      path,
    });
  };

  const stop = async (reason: string): Promise<void> => {
    if (server === null) {
      return;
    }

    const activeServer = server;
    server = null;

    logger.info("WebSocket Server stopping", { reason });

    for (const socket of sockets.values()) {
      socket.close(1001, reason);
    }

    const didStop = await waitForShutdown(activeServer.stop(true), 1_000);
    sockets.clear();

    if (!didStop) {
      logger.warn("WebSocket Server stop timed out", { reason });
    }

    logger.info("WebSocket Server stopped", { reason });
  };

  return Object.freeze({
    name: "core.transport",
    start,
    stop,
  });
};

const createRawTextConnection = (
  socket: ServerWebSocket<WebSocketConnectionData>,
): RawTextConnection =>
  Object.freeze({
    id: socket.data.connectionId,
    sendText: async (text: string) => {
      const sendStatus = socket.sendText(text);

      if (sendStatus > 0) {
        return;
      }

      if (sendStatus === 0) {
        throw new Error("WebSocket message was dropped");
      }

      throw new Error("WebSocket send is backpressured");
    },
    close: (code?: number, reason?: string) => {
      socket.close(code, reason);
    },
  });

const getErrorMessage = (error: unknown): string => {
  if (error instanceof Error) {
    return error.message;
  }

  return String(error);
};

const waitForShutdown = async (
  shutdownPromise: Promise<void>,
  timeoutMs: number,
): Promise<boolean> => {
  const timeoutResult = Symbol("timeout");
  const result = await Promise.race<true | typeof timeoutResult>([
    shutdownPromise.then(() => true),
    new Promise<typeof timeoutResult>((resolve) => {
      setTimeout(() => {
        resolve(timeoutResult);
      }, timeoutMs);
    }),
  ]);

  return result === true;
};
