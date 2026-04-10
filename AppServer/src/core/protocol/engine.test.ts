import { describe, expect, test } from "bun:test";
import { Type } from "@sinclair/typebox";
import {
  createProtocolEngine,
  InitializeParamsSchema,
  type ProtocolNotification,
} from "@/core/protocol";
import { createCapturingLogger, createSilentLogger } from "@/test-support/logger";

describe("ProtocolEngine", () => {
  test("maps unexpected handler failures to internal errors with structured data", async () => {
    const outbound: string[] = [];
    const engine = createProtocolEngine({
      logger: createSilentLogger(),
    });

    engine.registerMethod({
      method: "initialize",
      paramsSchema: InitializeParamsSchema,
      resultSchema: Type.Object(
        {
          userAgent: Type.String(),
        },
        { additionalProperties: false },
      ),
      handler: () => {
        throw new Error("boom");
      },
    });

    engine.openConnection({
      connectionId: "connection-1",
      sendText: async (text) => {
        outbound.push(text);
      },
    });

    await engine.handleIncomingText({
      connectionId: "connection-1",
      text: JSON.stringify({
        id: "req-1",
        method: "initialize",
        params: {
          clientInfo: {
            name: "AtelierCode Test",
            version: "0.1.0",
          },
        },
      }),
    });

    expect(JSON.parse(outbound[0] ?? "null")).toEqual({
      id: "req-1",
      error: {
        code: -32603,
        message: "Internal error",
        data: {
          code: "INTERNAL_ERROR",
        },
      },
    });
  });

  test("serializes outbound notifications for later protocol slices", async () => {
    const outbound: string[] = [];
    const engine = createProtocolEngine({
      logger: createSilentLogger("error"),
    });

    engine.openConnection({
      connectionId: "connection-1",
      sendText: async (text) => {
        outbound.push(text);
      },
    });

    const notification: ProtocolNotification = {
      method: "thread/status/changed",
      params: {
        threadId: "thread-1",
        status: "idle",
      },
    };

    await engine.sendNotification({
      connectionId: "connection-1",
      notification,
    });

    expect(JSON.parse(outbound[0] ?? "null")).toEqual(notification);
  });

  test("swallows send failures during outbound notifications and logs the error", async () => {
    const { logger, records } = createCapturingLogger();
    const engine = createProtocolEngine({ logger });

    engine.openConnection({
      connectionId: "connection-1",
      sendText: async () => {
        throw new Error("transport failed");
      },
    });

    await expect(
      engine.sendNotification({
        connectionId: "connection-1",
        notification: {
          method: "thread/status/changed",
          params: {
            threadId: "thread-1",
            status: "idle",
          },
        },
      }),
    ).resolves.toBeUndefined();

    expect(records).toContainEqual(
      expect.objectContaining({
        level: "error",
        message: "Protocol send failed",
        connectionId: "connection-1",
        error: "transport failed",
      }),
    );
  });

  test("ignores stale connections after lifecycle stop clears the registry", async () => {
    const outbound: string[] = [];
    const { logger, records } = createCapturingLogger();
    const engine = createProtocolEngine({ logger });

    engine.openConnection({
      connectionId: "connection-1",
      sendText: async (text) => {
        outbound.push(text);
      },
    });

    await engine.lifecycle.stop("test-stop");

    await engine.sendNotification({
      connectionId: "connection-1",
      notification: {
        method: "thread/status/changed",
        params: {
          threadId: "thread-1",
          status: "idle",
        },
      },
    });

    await engine.handleIncomingText({
      connectionId: "connection-1",
      text: JSON.stringify({
        id: "req-1",
        method: "initialize",
        params: {
          clientInfo: {
            name: "AtelierCode Test",
            version: "0.1.0",
          },
        },
      }),
    });

    expect(outbound).toEqual([]);
    expect(records).toContainEqual(
      expect.objectContaining({
        level: "warn",
        message: "Protocol send skipped for unknown connection",
        connectionId: "connection-1",
      }),
    );
    expect(records).toContainEqual(
      expect.objectContaining({
        level: "warn",
        message: "Protocol received text for an unknown connection",
        connectionId: "connection-1",
      }),
    );
  });

  test("rejects invalid outbound notifications before writing to the transport", async () => {
    const outbound: string[] = [];
    const { logger, records } = createCapturingLogger();
    const engine = createProtocolEngine({ logger });

    engine.openConnection({
      connectionId: "connection-1",
      sendText: async (text) => {
        outbound.push(text);
      },
    });

    await engine.sendNotification({
      connectionId: "connection-1",
      notification: {
        method: "",
      } as ProtocolNotification,
    });

    expect(outbound).toEqual([]);
    expect(records).toContainEqual(
      expect.objectContaining({
        level: "error",
        message: "Protocol notification serialization failed",
        connectionId: "connection-1",
      }),
    );
  });

  test("ignores inbound text for an unknown connection", async () => {
    const { logger, records } = createCapturingLogger();
    const engine = createProtocolEngine({ logger });

    await engine.handleIncomingText({
      connectionId: "missing-connection",
      text: JSON.stringify({
        id: "req-1",
        method: "initialize",
        params: {
          clientInfo: {
            name: "AtelierCode Test",
            version: "0.1.0",
          },
        },
      }),
    });

    expect(records).toContainEqual(
      expect.objectContaining({
        level: "warn",
        message: "Protocol received text for an unknown connection",
        connectionId: "missing-connection",
      }),
    );
  });
});
