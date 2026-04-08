import { createServer } from "node:net";

const DEFAULT_HOST = "127.0.0.1";

export interface AppServerHandle {
  host: string;
  port: number;
  send(connectionId: string, message: string): boolean;
  stop(): void;
}

interface SocketData {
  connectionId: string;
}

interface ConnectionSocket {
  send(message: string): unknown;
}

export interface StartServerOptions {
  host?: string;
  port?: number;
  healthcheckResponse?: unknown;
  onConnectionOpen?(connectionId: string): void;
  onConnectionClose?(connectionId: string): void;
  onMessage(event: {
    connectionId: string;
    message: string;
  }): Promise<void> | void;
}

export async function startWebSocketServer(
  options: StartServerOptions,
): Promise<AppServerHandle> {
  const port = await resolvePort(
    options.host ?? DEFAULT_HOST,
    options.port ?? 0,
  );
  const connections = new Map<string, ConnectionSocket>();
  const server = Bun.serve<SocketData>({
    hostname: options.host ?? DEFAULT_HOST,
    port,
    fetch(request, webSocketServer) {
      const url = new URL(request.url);

      if (
        request.method === "GET" &&
        url.pathname === "/healthz" &&
        options.healthcheckResponse !== undefined
      ) {
        return Response.json(options.healthcheckResponse);
      }

      if (url.pathname !== "/") {
        return new Response("Not found.", { status: 404 });
      }

      const connectionId = crypto.randomUUID();
      const upgraded = webSocketServer.upgrade(request, {
        data: {
          connectionId,
        },
      });

      if (upgraded) {
        return undefined;
      }

      return new Response("Expected WebSocket upgrade.", { status: 426 });
    },
    websocket: {
      open(socket) {
        connections.set(socket.data.connectionId, socket);
        options.onConnectionOpen?.(socket.data.connectionId);
      },
      close(socket) {
        connections.delete(socket.data.connectionId);
        options.onConnectionClose?.(socket.data.connectionId);
      },
      message(socket, rawMessage) {
        void Promise.resolve(
          options.onMessage({
            connectionId: socket.data.connectionId,
            message: decodeMessage(rawMessage),
          }),
        ).catch((error) => {
          console.error("App Server inbound message handling failed.", error);
        });
      },
    },
  });

  return {
    host: options.host ?? DEFAULT_HOST,
    port: server.port ?? port,
    send(connectionId: string, message: string): boolean {
      const connection = connections.get(connectionId);
      if (!connection) {
        return false;
      }

      connection.send(message);
      return true;
    },
    stop() {
      server.stop(true);
    },
  };
}

function decodeMessage(
  rawMessage: string | Buffer | Uint8Array | ArrayBuffer | Buffer[],
): string {
  if (typeof rawMessage === "string") {
    return rawMessage;
  }

  if (rawMessage instanceof ArrayBuffer) {
    return new TextDecoder().decode(rawMessage);
  }

  if (rawMessage instanceof Uint8Array) {
    return new TextDecoder().decode(rawMessage);
  }

  if (Array.isArray(rawMessage)) {
    const bytes = rawMessage.flatMap((chunk) => Array.from(chunk));
    return new TextDecoder().decode(new Uint8Array(bytes));
  }

  return new TextDecoder().decode(rawMessage);
}

async function resolvePort(
  host: string,
  preferredPort: number,
): Promise<number> {
  if (preferredPort !== 0) {
    return preferredPort;
  }

  return new Promise<number>((resolve, reject) => {
    const probe = createServer();

    probe.once("error", reject);
    probe.listen(0, host, () => {
      const address = probe.address();
      if (typeof address !== "object" || address === null) {
        probe.close(() => {
          reject(new Error("Failed to resolve an ephemeral port."));
        });
        return;
      }

      probe.close((error) => {
        if (error) {
          reject(error);
          return;
        }

        resolve(address.port);
      });
    });
  });
}
