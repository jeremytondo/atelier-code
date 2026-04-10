import { describe, expect, test } from "bun:test";
import { Type } from "@sinclair/typebox";
import { createLogger } from "@/app/logger";
import {
  createProtocolEngine,
  InitializeParamsSchema,
  type ProtocolNotification,
} from "@/core/protocol";
import { ok } from "@/core/shared";

const createSilentLogger = () =>
  createLogger({
    level: "error",
    write: () => {},
  });

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
      handler: ({ session }) => {
        const initialization = session.markInitialized();

        if (!initialization.ok) {
          return initialization;
        }

        return ok({
          userAgent: "AtelierCode App Server/0.1.0",
        });
      },
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
});
