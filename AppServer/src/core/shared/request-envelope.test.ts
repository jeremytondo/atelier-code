import { describe, expect, test } from "bun:test";

import { isSupportedRequestMethod, parseJsonRpcRequest } from "./validation";

describe("request-envelope", () => {
  test("rejects non-object requests", () => {
    expect(parseJsonRpcRequest(null)).toEqual({
      ok: false,
      error: "Requests must be JSON objects.",
    });
  });

  test("rejects requests without an id", () => {
    expect(
      parseJsonRpcRequest({
        method: "initialize",
      }),
    ).toEqual({
      ok: false,
      error: "Requests must include a string or number id.",
    });
  });

  test("rejects requests without a string method", () => {
    expect(
      parseJsonRpcRequest({
        id: "request-1",
        method: 42,
      }),
    ).toEqual({
      ok: false,
      error: "Requests must include a string method.",
    });
  });

  test("returns typed requests for valid envelopes", () => {
    expect(
      parseJsonRpcRequest({
        id: "request-1",
        method: "initialize",
        params: {
          clientInfo: {
            name: "Harness",
          },
        },
      }),
    ).toEqual({
      ok: true,
      value: {
        id: "request-1",
        method: "initialize",
        params: {
          clientInfo: {
            name: "Harness",
          },
        },
      },
    });
  });

  test("identifies supported request methods", () => {
    expect(isSupportedRequestMethod("thread/start")).toBe(true);
    expect(isSupportedRequestMethod("thread/resume")).toBe(false);
  });
});
