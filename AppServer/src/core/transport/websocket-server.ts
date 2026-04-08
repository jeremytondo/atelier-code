import { createServer } from "node:net";

import type { AppServerService } from "../../app/server";
import { type SessionRecord, createSessionRecord } from "../../app/session";
import { buildHealthcheckReport } from "../config/server-metadata";
import { createInvalidRequestErrorResponse } from "../protocol/dispatch-responses";
import { ProtocolDispatcher } from "../protocol/dispatcher";

const DEFAULT_HOST = "127.0.0.1";

export interface AppServerHandle {
  host: string;
  port: number;
  stop(): void;
}

interface SocketData {
  session: SessionRecord;
}

export interface StartServerOptions {
  host?: string;
  port?: number;
  service: AppServerService;
}

export async function startWebSocketServer(
  options: StartServerOptions,
): Promise<AppServerHandle> {
  const dispatcher = new ProtocolDispatcher(options.service);
  const port = await resolvePort(
    options.host ?? DEFAULT_HOST,
    options.port ?? 0,
  );
  const server = Bun.serve<SocketData>({
    hostname: options.host ?? DEFAULT_HOST,
    port,
    fetch(request, webSocketServer) {
      const url = new URL(request.url);

      if (request.method === "GET" && url.pathname === "/healthz") {
        return Response.json(buildHealthcheckReport());
      }

      if (url.pathname !== "/") {
        return new Response("Not found.", { status: 404 });
      }

      const upgraded = webSocketServer.upgrade(request, {
        data: {
          session: createSessionRecord(crypto.randomUUID()),
        },
      });

      if (upgraded) {
        return undefined;
      }

      return new Response("Expected WebSocket upgrade.", { status: 426 });
    },
    websocket: {
      async message(socket, rawMessage) {
        const textMessage = decodeMessage(rawMessage);
        if (textMessage === null) {
          const response = createInvalidRequestErrorResponse(
            "Binary frames are not supported.",
          );
          socket.send(JSON.stringify(response));
          return;
        }

        const outcome = dispatcher.dispatchRawMessage(textMessage, {
          session: socket.data.session,
          notifications: {
            emit: async (notification) => {
              if (
                socket.data.session.optOutNotificationMethods.has(
                  notification.method,
                )
              ) {
                return;
              }

              socket.send(JSON.stringify(notification));
            },
          },
        });

        socket.send(JSON.stringify(outcome.response));

        if (outcome.followUp) {
          void runFollowUp(outcome.followUp);
        }
      },
    },
  });

  return {
    host: options.host ?? DEFAULT_HOST,
    port: server.port ?? port,
    stop() {
      server.stop(true);
    },
  };
}

async function runFollowUp(followUp: () => Promise<void>): Promise<void> {
  try {
    await followUp();
  } catch (error) {
    console.error("App Server follow-up execution failed.", error);
  }
}

function decodeMessage(
  rawMessage: string | Buffer | Uint8Array | ArrayBuffer | Buffer[],
): string | null {
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

  return null;
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
