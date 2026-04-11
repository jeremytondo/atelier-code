import type { AppServerConfig } from "@/app/config";
import type { Logger } from "@/app/logger";
import {
  createProtocolEngine,
  InitializeParamsSchema,
  InitializeResultSchema,
  type ProtocolEngine,
} from "@/core/protocol";
import { ok } from "@/core/shared";
import { createWebSocketServer, type RawConnectionOpenedEvent } from "@/core/transport";

export const APP_SERVER_USER_AGENT = "AtelierCode App Server/0.1.0";

export type ConnectionClosedHandler = (
  options: Readonly<{ connectionId: string }>,
) => Promise<void> | void;

export type AppProtocolRuntime = Readonly<{
  protocolComponent: ProtocolEngine["lifecycle"];
  registerMethod: ProtocolEngine["registerMethod"];
  openConnection: ProtocolEngine["openConnection"];
  closeConnection: ProtocolEngine["closeConnection"];
  handleIncomingText: ProtocolEngine["handleIncomingText"];
  sendNotification: ProtocolEngine["sendNotification"];
}>;

export const runConnectionClosedHandlers = async (
  handlers: readonly ConnectionClosedHandler[],
  connectionId: string,
): Promise<void> => {
  const closeErrors: unknown[] = [];

  for (const handleConnectionClosed of handlers) {
    try {
      await handleConnectionClosed({ connectionId });
    } catch (error) {
      closeErrors.push(error);
    }
  }

  if (closeErrors.length === 1) {
    throw closeErrors[0];
  }

  if (closeErrors.length > 1) {
    throw new AggregateError(closeErrors, "Connection close handlers failed");
  }
};

export const createAppProtocolRuntime = (options: { logger: Logger }): AppProtocolRuntime => {
  const protocolLogger = options.logger.withContext({ component: "core.protocol" });
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

  return Object.freeze({
    protocolComponent: protocol.lifecycle,
    registerMethod: protocol.registerMethod,
    openConnection: protocol.openConnection,
    closeConnection: protocol.closeConnection,
    handleIncomingText: protocol.handleIncomingText,
    sendNotification: protocol.sendNotification,
  });
};

export const createAppTransportComponent = (options: {
  config: AppServerConfig;
  logger: Logger;
  protocol: Pick<AppProtocolRuntime, "openConnection" | "closeConnection" | "handleIncomingText">;
  onConnectionClosed?: readonly ConnectionClosedHandler[];
}) =>
  createWebSocketServer({
    logger: options.logger.withContext({ component: "core.transport" }),
    port: options.config.port,
    onConnectionOpen: ({ connection }: RawConnectionOpenedEvent) => {
      options.protocol.openConnection({
        connectionId: connection.id,
        sendText: connection.sendText,
      });
    },
    onConnectionClose: async ({ connectionId }) => {
      try {
        await runConnectionClosedHandlers(options.onConnectionClosed ?? [], connectionId);
      } finally {
        options.protocol.closeConnection(connectionId);
      }
    },
    onTextMessage: ({ connectionId, text }) =>
      options.protocol.handleIncomingText({
        connectionId,
        text,
      }),
  });
