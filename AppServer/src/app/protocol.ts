import type { AppServerConfig } from "@/app/config";
import type { Logger } from "@/app/logger";
import {
  createProtocolEngine,
  InitializeParamsSchema,
  InitializeResultSchema,
  type ProtocolEngine,
} from "@/core/protocol";
import { type LifecycleComponent, ok } from "@/core/shared";
import { createWebSocketServer, type RawConnectionOpenedEvent } from "@/core/transport";

export const APP_SERVER_USER_AGENT = "AtelierCode App Server/0.1.0";

export type ConnectionClosedHandler = (
  options: Readonly<{ connectionId: string }>,
) => Promise<void> | void;

export type AppProtocolComponents = Readonly<{
  protocolComponent: LifecycleComponent;
  transportComponent: LifecycleComponent;
  registerMethod: ProtocolEngine["registerMethod"];
}>;

export const createAppProtocolComponents = (options: {
  config: AppServerConfig;
  logger: Logger;
  onConnectionClosed?: readonly ConnectionClosedHandler[];
}): AppProtocolComponents => {
  const protocolLogger = options.logger.withContext({ component: "core.protocol" });
  const transportLogger = options.logger.withContext({ component: "core.transport" });
  const protocol = createProtocolEngine({
    logger: protocolLogger,
  });

  protocol.registerMethod({
    method: "initialize",
    paramsSchema: InitializeParamsSchema,
    resultSchema: InitializeResultSchema,
    handler: ({ connectionId, params, session }) => {
      const initializationResult = session.markInitialized();

      if (!initializationResult.ok) {
        return initializationResult;
      }

      protocolLogger.info("Connection initialized", {
        connectionId,
        clientName: params.clientInfo.name,
        clientVersion: params.clientInfo.version,
      });

      return ok({
        userAgent: APP_SERVER_USER_AGENT,
      });
    },
  });

  const transportComponent = createWebSocketServer({
    logger: transportLogger,
    port: options.config.port,
    onConnectionOpen: ({ connection }: RawConnectionOpenedEvent) => {
      protocol.openConnection({
        connectionId: connection.id,
        sendText: connection.sendText,
      });
    },
    onConnectionClose: async ({ connectionId }) => {
      try {
        for (const handleConnectionClosed of options.onConnectionClosed ?? []) {
          await handleConnectionClosed({ connectionId });
        }
      } finally {
        protocol.closeConnection(connectionId);
      }
    },
    onTextMessage: ({ connectionId, text }) =>
      protocol.handleIncomingText({
        connectionId,
        text,
      }),
  });

  return Object.freeze({
    protocolComponent: protocol.lifecycle,
    transportComponent,
    registerMethod: protocol.registerMethod,
  });
};
