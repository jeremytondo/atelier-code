import { describe, expect, test } from "bun:test";

import {
  assertProtocolNotification,
  assertProtocolResponse,
} from "./message-assertions";

describe("message-assertions", () => {
  test("rejects success responses without valid ids", () => {
    expect(() =>
      assertProtocolResponse({
        id: null,
        result: {},
      } as never),
    ).toThrow("Outbound success response must include a string or number id.");
  });

  test("rejects error responses without valid error objects", () => {
    expect(() =>
      assertProtocolResponse({
        id: "request-1",
        error: {
          code: "bad",
          message: "Nope",
        },
      } as never),
    ).toThrow("Outbound error response must include a valid error object.");
  });

  test("rejects unsupported notification methods", () => {
    expect(() =>
      assertProtocolNotification({
        method: "turn/unknown",
        params: {},
      }),
    ).toThrow(
      expect.objectContaining({
        code: -32602,
        message:
          "Outbound notification turn/unknown is not supported in phase 1.",
      }),
    );
  });

  test("rejects non-object notification params", () => {
    expect(() =>
      assertProtocolNotification({
        method: "turn/started",
        params: "nope",
      }),
    ).toThrow("Outbound notifications must include an object params payload.");
  });

  test("returns valid protocol messages unchanged", () => {
    expect(
      assertProtocolResponse({
        id: "request-1",
        result: {
          ok: true,
        },
      }),
    ).toEqual({
      id: "request-1",
      result: {
        ok: true,
      },
    });

    expect(
      assertProtocolNotification({
        method: "thread/started",
        params: {},
      }),
    ).toEqual({
      method: "thread/started",
      params: {},
    });
  });
});
