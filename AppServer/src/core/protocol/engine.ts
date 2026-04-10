import type { Static, TSchema } from "@sinclair/typebox";
import { Value } from "@sinclair/typebox/value";
import type { Logger } from "@/app/logger";
import {
  createProtocolDispatcher,
  type ProtocolDispatcher,
  type ProtocolSession,
} from "@/core/protocol/dispatcher";
import {
  createInternalError,
  createInvalidParamsError,
  createInvalidRequestError,
  createMethodNotFoundError,
  createParseError,
  createSessionAlreadyInitializedResult,
  type ProtocolMethodError,
} from "@/core/protocol/errors";
import {
  type ProtocolErrorResponse,
  ProtocolErrorResponseSchema,
  type ProtocolNotification,
  ProtocolNotificationSchema,
  type ProtocolRequest,
  ProtocolRequestSchema,
  type ProtocolSuccessResponse,
  ProtocolSuccessResponseSchema,
  type RequestId,
  RequestIdSchema,
} from "@/core/protocol/schemas";
import { getErrorMessage, type LifecycleComponent, ok, type Result } from "@/core/shared";

export type ProtocolSendText = (text: string) => Promise<void>;

type ProtocolConnectionRecord = {
  initialized: boolean;
  sendText: ProtocolSendText;
};

export type ProtocolSerializationError = Readonly<{
  message: string;
}>;

export type CreateProtocolEngineOptions = Readonly<{
  logger: Logger;
}>;

export type ProtocolEngine = Readonly<{
  lifecycle: LifecycleComponent;
  registerMethod: ProtocolDispatcher["registerMethod"];
  openConnection: (options: Readonly<{ connectionId: string; sendText: ProtocolSendText }>) => void;
  closeConnection: (connectionId: string) => void;
  handleIncomingText: (options: Readonly<{ connectionId: string; text: string }>) => Promise<void>;
  sendNotification: (
    options: Readonly<{ connectionId: string; notification: ProtocolNotification }>,
  ) => Promise<void>;
}>;

export const createProtocolEngine = (options: CreateProtocolEngineOptions): ProtocolEngine => {
  const dispatcher = createProtocolDispatcher();
  const connections = new Map<string, ProtocolConnectionRecord>();
  const logger = options.logger;

  const lifecycle: LifecycleComponent = Object.freeze({
    name: "core.protocol",
    start: async () => {
      logger.info("Protocol engine ready");
    },
    stop: async () => {
      connections.clear();
      logger.info("Protocol engine stopped");
    },
  });

  const openConnection = (
    connection: Readonly<{ connectionId: string; sendText: ProtocolSendText }>,
  ) => {
    connections.set(connection.connectionId, {
      initialized: false,
      sendText: connection.sendText,
    });

    logger.info("Protocol connection registered", {
      connectionId: connection.connectionId,
    });
  };

  const closeConnection = (connectionId: string) => {
    if (!connections.delete(connectionId)) {
      return;
    }

    logger.info("Protocol connection removed", { connectionId });
  };

  const sendSerializedText = async (connectionId: string, text: string): Promise<void> => {
    const connection = connections.get(connectionId);

    if (connection === undefined) {
      logger.warn("Protocol send skipped for unknown connection", {
        connectionId,
      });
      return;
    }

    try {
      await connection.sendText(text);
    } catch (error) {
      logger.error("Protocol send failed", {
        connectionId,
        error: getErrorMessage(error),
      });
    }
  };

  const sendSuccessResponse = async (
    connectionId: string,
    response: ProtocolSuccessResponse,
  ): Promise<void> => {
    const serialized = serializeWithSchema(ProtocolSuccessResponseSchema, response);

    if (!serialized.ok) {
      logger.error("Protocol success response serialization failed", {
        connectionId,
        error: serialized.error.message,
      });
      return;
    }

    await sendSerializedText(connectionId, serialized.data);
  };

  const sendErrorResponse = async (
    connectionId: string,
    response: ProtocolErrorResponse,
  ): Promise<void> => {
    const serialized = serializeWithSchema(ProtocolErrorResponseSchema, response);

    if (!serialized.ok) {
      logger.error("Protocol error response serialization failed", {
        connectionId,
        error: serialized.error.message,
      });
      return;
    }

    await sendSerializedText(connectionId, serialized.data);
  };

  const sendNotification: ProtocolEngine["sendNotification"] = async ({
    connectionId,
    notification,
  }) => {
    const serialized = serializeWithSchema(ProtocolNotificationSchema, notification);

    if (!serialized.ok) {
      logger.error("Protocol notification serialization failed", {
        connectionId,
        error: serialized.error.message,
      });
      return;
    }

    await sendSerializedText(connectionId, serialized.data);
  };

  const handleRequest = async (
    connectionId: string,
    request: ProtocolRequest,
    connection: ProtocolConnectionRecord,
  ): Promise<void> => {
    logger.debug("Protocol request received", {
      connectionId,
      method: request.method,
    });

    const registeredMethod = dispatcher.getMethod(request.method);

    if (registeredMethod === undefined) {
      await sendErrorResponse(connectionId, {
        id: request.id,
        error: createMethodNotFoundError(),
      });
      return;
    }

    if (!Value.Check(registeredMethod.paramsSchema, request.params)) {
      logger.warn("Protocol params validation failed", {
        connectionId,
        method: request.method,
      });

      await sendErrorResponse(connectionId, {
        id: request.id,
        error: createInvalidParamsError(),
      });
      return;
    }

    const session = createProtocolSession(connection);

    try {
      const methodResult = await registeredMethod.handler({
        connectionId,
        params: request.params,
        session,
      });

      if (!methodResult.ok) {
        await sendErrorResponse(connectionId, {
          id: request.id,
          error: methodResult.error,
        });
        return;
      }

      if (!Value.Check(registeredMethod.resultSchema, methodResult.data)) {
        logger.error("Protocol method returned an invalid result", {
          connectionId,
          method: request.method,
        });

        await sendErrorResponse(connectionId, {
          id: request.id,
          error: createInternalError(),
        });
        return;
      }

      await sendSuccessResponse(connectionId, {
        id: request.id,
        result: methodResult.data,
      });
    } catch (error) {
      logger.error("Protocol method failed unexpectedly", {
        connectionId,
        method: request.method,
        error: getErrorMessage(error),
      });

      await sendErrorResponse(connectionId, {
        id: request.id,
        error: createInternalError(),
      });
    }
  };

  const handleIncomingText: ProtocolEngine["handleIncomingText"] = async ({
    connectionId,
    text,
  }) => {
    const connection = connections.get(connectionId);

    if (connection === undefined) {
      logger.warn("Protocol received text for an unknown connection", {
        connectionId,
      });
      return;
    }

    const parsedPayload = parseIncomingText(text);

    if (!parsedPayload.ok) {
      logger.warn("Protocol parse error", {
        connectionId,
      });

      await sendErrorResponse(connectionId, {
        id: null,
        error: createParseError(),
      });
      return;
    }

    if (Value.Check(ProtocolRequestSchema, parsedPayload.data)) {
      // TypeBox validates at runtime, but TypeScript does not narrow from Value.Check().
      const request = parsedPayload.data as ProtocolRequest;
      await handleRequest(connectionId, request, connection);
      return;
    }

    if (Value.Check(ProtocolNotificationSchema, parsedPayload.data)) {
      // TypeBox validates at runtime, but TypeScript does not narrow from Value.Check().
      const notification = parsedPayload.data as ProtocolNotification;

      logger.debug("Ignoring inbound client notification", {
        connectionId,
        method: notification.method,
      });
      return;
    }

    logger.warn("Protocol invalid request envelope", {
      connectionId,
    });

    await sendErrorResponse(connectionId, {
      id: extractResponseId(parsedPayload.data),
      error: createInvalidRequestError(),
    });
  };

  return Object.freeze({
    lifecycle,
    registerMethod: dispatcher.registerMethod,
    openConnection,
    closeConnection,
    handleIncomingText,
    sendNotification,
  });
};

const createProtocolSession = (connection: ProtocolConnectionRecord): ProtocolSession =>
  Object.freeze({
    isInitialized: () => connection.initialized,
    markInitialized: () => {
      if (connection.initialized) {
        return createSessionAlreadyInitializedResult();
      }

      connection.initialized = true;
      return ok(undefined);
    },
  });

const parseIncomingText = (text: string): Result<unknown, ProtocolMethodError> => {
  try {
    return ok(JSON.parse(text) as unknown);
  } catch {
    return {
      ok: false,
      error: createParseError(),
    };
  }
};

const serializeWithSchema = <TSchemaValue extends TSchema>(
  schema: TSchemaValue,
  candidate: Static<TSchemaValue>,
): Result<string, ProtocolSerializationError> => {
  if (!Value.Check(schema, candidate)) {
    const validationErrors = [...Value.Errors(schema, candidate)].map((issue) => {
      const path = issue.path || "/";
      return `${path}: ${issue.message}`;
    });

    return {
      ok: false,
      error: Object.freeze({
        message: validationErrors.join("; "),
      }),
    };
  }

  try {
    return ok(JSON.stringify(candidate));
  } catch (error) {
    return {
      ok: false,
      error: Object.freeze({
        message: getErrorMessage(error),
      }),
    };
  }
};

const extractResponseId = (candidate: unknown): RequestId | null => {
  if (!isRecord(candidate) || !Value.Check(RequestIdSchema, candidate.id)) {
    return null;
  }

  return candidate.id as RequestId;
};

const isRecord = (candidate: unknown): candidate is Record<string, unknown> =>
  typeof candidate === "object" && candidate !== null && !Array.isArray(candidate);
