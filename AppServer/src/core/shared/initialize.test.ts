import { describe, expect, test } from "bun:test";

import { validateInitializeParams } from "./validation";

describe("initialize validation", () => {
  test("rejects missing clientInfo", () => {
    expect(validateInitializeParams({})).toEqual({
      ok: false,
      error: "initialize clientInfo must be an object.",
    });
  });

  test("rejects invalid opt-out notification methods", () => {
    expect(
      validateInitializeParams({
        clientInfo: {
          name: "Harness",
          title: null,
          version: "1.0.0",
        },
        capabilities: {
          experimentalApi: true,
          optOutNotificationMethods: [1],
        },
      }),
    ).toEqual({
      ok: false,
      error:
        "initialize optOutNotificationMethods must be a string array when provided.",
    });
  });

  test("returns typed initialize params", () => {
    expect(
      validateInitializeParams({
        clientInfo: {
          name: "Harness",
          title: null,
          version: "1.0.0",
        },
        capabilities: {
          experimentalApi: true,
          optOutNotificationMethods: ["turn/completed"],
        },
      }),
    ).toEqual({
      ok: true,
      value: {
        clientInfo: {
          name: "Harness",
          title: null,
          version: "1.0.0",
        },
        capabilities: {
          experimentalApi: true,
          optOutNotificationMethods: ["turn/completed"],
        },
      },
    });
  });
});
