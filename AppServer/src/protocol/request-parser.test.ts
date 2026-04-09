import { describe, expect, test } from "bun:test";

import { parseEnvelopeRequest, parseRawRequest } from "./request-parser";

describe("request-parser", () => {
  test("returns a parse error outcome for malformed JSON", () => {
    const result = parseRawRequest("{");

    expect(result).toEqual({
      ok: false,
      outcome: {
        response: {
          id: null,
          error: {
            code: -32700,
            message: "Request body must be valid JSON.",
            data: {
              code: "parse_error",
            },
          },
        },
      },
    });
  });

  test("returns an invalid request outcome for bad envelopes", () => {
    const result = parseEnvelopeRequest({
      method: "initialize",
      params: {},
    });

    expect(result).toEqual({
      ok: false,
      outcome: {
        response: {
          id: null,
          error: {
            code: -32600,
            message: "Requests must include a string or number id.",
            data: {
              code: "invalid_request",
            },
          },
        },
      },
    });
  });

  test("returns a typed request for valid envelopes", () => {
    const result = parseRawRequest(
      JSON.stringify({
        id: "initialize-1",
        method: "initialize",
        params: {
          clientInfo: {
            name: "Harness",
            title: null,
            version: "1.0.0",
          },
          capabilities: {
            experimentalApi: true,
          },
        },
      }),
    );

    expect(result).toEqual({
      ok: true,
      request: {
        id: "initialize-1",
        method: "initialize",
        params: {
          clientInfo: {
            name: "Harness",
            title: null,
            version: "1.0.0",
          },
          capabilities: {
            experimentalApi: true,
          },
        },
      },
    });
  });
});
