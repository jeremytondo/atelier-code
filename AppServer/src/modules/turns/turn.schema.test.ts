import { describe, expect, test } from "bun:test";

import { validateTurnStartParams } from "./turn.schema";

describe("turn/start validation", () => {
  test("requires a thread id", () => {
    expect(
      validateTurnStartParams({
        input: [],
      }),
    ).toEqual({
      ok: false,
      error: "turn/start params must include a non-empty threadId.",
    });
  });

  test("requires an input array", () => {
    expect(
      validateTurnStartParams({
        threadId: "thread-1",
      }),
    ).toEqual({
      ok: false,
      error: "turn/start params must include an input array.",
    });
  });

  test("rejects unsupported input items", () => {
    expect(
      validateTurnStartParams({
        threadId: "thread-1",
        input: [
          {
            type: "audio",
          },
        ],
      }),
    ).toEqual({
      ok: false,
      error: "Unsupported input type audio.",
    });
  });

  test("returns typed turn/start params for supported input items", () => {
    expect(
      validateTurnStartParams({
        threadId: "thread-1",
        input: [
          {
            type: "text",
            text: "Plan the work",
          },
          {
            type: "image",
            url: "https://example.com/image.png",
          },
          {
            type: "localImage",
            path: "/tmp/image.png",
          },
          {
            type: "skill",
            name: "github",
            path: "/tmp/github/SKILL.md",
          },
          {
            type: "mention",
            name: "repo",
            path: "app://repo",
          },
        ],
        cwd: "/tmp/project",
        approvalPolicy: "on-request",
        model: "gpt-5.4",
        serviceTier: "fast",
        effort: "high",
        personality: "helpful",
        summary: {
          mode: "auto",
        },
        outputSchema: {
          type: "object",
        },
        collaborationMode: {
          mode: "default",
        },
      }),
    ).toEqual({
      ok: true,
      value: {
        threadId: "thread-1",
        input: [
          {
            type: "text",
            text: "Plan the work",
            text_elements: [],
          },
          {
            type: "image",
            url: "https://example.com/image.png",
          },
          {
            type: "localImage",
            path: "/tmp/image.png",
          },
          {
            type: "skill",
            name: "github",
            path: "/tmp/github/SKILL.md",
          },
          {
            type: "mention",
            name: "repo",
            path: "app://repo",
          },
        ],
        cwd: "/tmp/project",
        approvalPolicy: "on-request",
        model: "gpt-5.4",
        serviceTier: "fast",
        effort: "high",
        personality: "helpful",
        summary: {
          mode: "auto",
        },
        outputSchema: {
          type: "object",
        },
        collaborationMode: {
          mode: "default",
        },
      },
    });
  });
});
