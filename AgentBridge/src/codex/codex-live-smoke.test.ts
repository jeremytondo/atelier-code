import { describe, expect, test } from "bun:test";

import { discoverCodexExecutable } from "../discovery/executable";
import { BaseEnvironmentResolver } from "../environment/base-environment";
import { CodexRawClient } from "./codex-raw-client";
import { CodexAppServerTransport } from "./codex-transport";

const liveSmokeEnabled = process.env.ATELIERCODE_LIVE_CODEX_SMOKE === "1";

describe.if(liveSmokeEnabled)("Codex live smoke", () => {
  test("runs initialize -> initialized -> thread/start -> turn/start against codex app-server", async () => {
    const baseEnvironment = await new BaseEnvironmentResolver().resolve();
    const executable = await discoverCodexExecutable({
      environment: baseEnvironment.environment,
      baseEnvironmentSource: baseEnvironment.diagnostics.source,
    });

    expect(executable.status).toBe("found");
    expect(executable.resolvedPath).not.toBeNull();

    if (executable.status !== "found" || executable.resolvedPath === null) {
      throw new Error("Codex executable could not be resolved for the live smoke test.");
    }

    const transport = new CodexAppServerTransport({
      executable,
      environment: baseEnvironment.environment,
    });
    const rawClient = new CodexRawClient(transport);

    try {
      await rawClient.connect();

      const account = await rawClient.readAccount("smoke-account", {
        refreshToken: false,
      });

      if (account.account === null && account.requiresOpenaiAuth === true) {
        throw new Error(
          "Codex auth is required before running the live smoke test. Sign in locally, then rerun with ATELIERCODE_LIVE_CODEX_SMOKE=1.",
        );
      }

      const threadStart = await rawClient.threadStart("smoke-thread-start", {
        cwd: process.cwd(),
        approvalPolicy: "on-request",
        sandbox: "workspace-write",
        experimentalRawEvents: false,
        persistExtendedHistory: true,
      });

      expect(threadStart.thread.id.length).toBeGreaterThan(0);

      const turnStart = await rawClient.turnStart("smoke-turn-start", {
        threadId: threadStart.thread.id,
        input: [
          {
            type: "text",
            text: "Reply with exactly OK.",
            text_elements: [],
          },
        ],
        summary: "none",
      });

      expect(turnStart.turn.id.length).toBeGreaterThan(0);
    } finally {
      await rawClient.disconnect();
    }
  }, 120_000);
});
