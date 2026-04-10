import { describe, expect, test } from "bun:test";
import {
  BaseEnvironmentResolver,
  parseShellProbeOutput,
} from "@/agents/codex-adapter/base-environment";

const ENCODER = new TextEncoder();

describe("BaseEnvironmentResolver", () => {
  test("keeps a rich inherited environment without probing", async () => {
    let probeCount = 0;
    const resolver = new BaseEnvironmentResolver({
      inheritedEnvironment: {
        PATH: "/opt/homebrew/bin:/usr/bin:/bin",
        HOME: "/Users/tester",
        SHELL: "/bin/zsh",
      },
      probeEnvironment: async () => {
        probeCount += 1;
        return {};
      },
    });

    const resolved = await resolver.resolve();

    expect(resolved.diagnostics.source).toBe("inherited");
    expect(resolved.environment.PATH).toBe("/opt/homebrew/bin:/usr/bin:/bin");
    expect(probeCount).toBe(0);
  });

  test("probes a minimal inherited environment once and caches the result", async () => {
    let probeCount = 0;
    const resolver = new BaseEnvironmentResolver({
      inheritedEnvironment: {
        PATH: "/usr/bin:/bin",
        HOME: "/Users/tester",
        SHELL: "/bin/zsh",
      },
      probeEnvironment: async () => {
        probeCount += 1;
        return {
          PATH: "/opt/homebrew/bin:/usr/bin:/bin",
          HOME: "/Users/tester",
          SHELL: "/bin/zsh",
        };
      },
    });

    const firstResolution = await resolver.resolve();
    const secondResolution = await resolver.resolve();

    expect(firstResolution).toEqual(secondResolution);
    expect(firstResolution.diagnostics.source).toBe("login_probe");
    expect(firstResolution.environment.PATH).toBe("/opt/homebrew/bin:/usr/bin:/bin");
    expect(probeCount).toBe(1);
  });

  test("falls back to augmented path entries when probing fails", async () => {
    const resolver = new BaseEnvironmentResolver({
      inheritedEnvironment: {
        PATH: "/usr/bin:/bin",
        HOME: "/Users/tester",
        SHELL: "/bin/zsh",
      },
      probeEnvironment: async () => {
        throw new Error("shell timed out");
      },
    });

    const resolved = await resolver.resolve();

    expect(resolved.diagnostics.source).toBe("fallback");
    expect(resolved.diagnostics.probeError).toContain("shell timed out");
    expect(resolved.environment.PATH).toContain("/opt/homebrew/bin");
    expect(resolved.environment.PATH).toContain("/Users/tester/.cargo/bin");
  });
});

describe("parseShellProbeOutput", () => {
  test("ignores startup chatter outside the sentinel-wrapped environment payload", () => {
    const output = ENCODER.encode(
      [
        "Welcome to zsh!\n",
        "__ATELIER_APPSERVER_ENV_BEGIN_4c58d0e1__\0",
        "PATH=/opt/homebrew/bin:/usr/bin:/bin\0",
        "HOME=/Users/tester\0",
        "SHELL=/bin/zsh\0",
        "__ATELIER_APPSERVER_ENV_END_4c58d0e1__\0",
        "prompt> ",
      ].join(""),
    );

    expect(parseShellProbeOutput(output)).toEqual({
      PATH: "/opt/homebrew/bin:/usr/bin:/bin",
      HOME: "/Users/tester",
      SHELL: "/bin/zsh",
    });
  });
});
