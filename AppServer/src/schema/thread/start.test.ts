import { describe, expect, test } from "bun:test";

import { validateThreadStartParams } from "./start";

describe("thread/start schema", () => {
  test("requires experimentalRawEvents", () => {
    expect(
      validateThreadStartParams({
        persistExtendedHistory: false,
      }),
    ).toEqual({
      ok: false,
      error: "thread/start params must include boolean experimentalRawEvents.",
    });
  });

  test("rejects invalid approval policies", () => {
    expect(
      validateThreadStartParams({
        experimentalRawEvents: false,
        persistExtendedHistory: false,
        approvalPolicy: {
          reject: {
            sandbox_approval: true,
          },
        },
      }),
    ).toEqual({
      ok: false,
      error:
        "thread/start approvalPolicy must be a Codex-shaped approval policy when provided.",
    });
  });

  test("returns typed thread/start params", () => {
    expect(
      validateThreadStartParams({
        experimentalRawEvents: false,
        persistExtendedHistory: true,
        model: "gpt-5.4",
        serviceTier: "flex",
        cwd: "/tmp/project",
        approvalPolicy: "on-request",
        sandbox: "workspace-write",
        config: {
          provider: "codex",
        },
        serviceName: "Atelier",
        baseInstructions: "Base",
        developerInstructions: "Developer",
        personality: "helpful",
        ephemeral: true,
        dynamicTools: ["search"],
        mockExperimentalField: "mock",
      }),
    ).toEqual({
      ok: true,
      value: {
        experimentalRawEvents: false,
        persistExtendedHistory: true,
        model: "gpt-5.4",
        serviceTier: "flex",
        cwd: "/tmp/project",
        approvalPolicy: "on-request",
        sandbox: "workspace-write",
        config: {
          provider: "codex",
        },
        serviceName: "Atelier",
        baseInstructions: "Base",
        developerInstructions: "Developer",
        personality: "helpful",
        ephemeral: true,
        dynamicTools: ["search"],
        mockExperimentalField: "mock",
      },
    });
  });
});
