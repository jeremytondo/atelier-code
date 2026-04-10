import { describe, expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { discoverExecutable } from "@/agents/executable-discovery";

describe("discoverExecutable", () => {
  test("uses the resolved environment path instead of the app-server process path", async () => {
    const temporaryDirectory = mkdtempSync(path.join(os.tmpdir(), "atelier-appserver-discovery-"));
    const executablePath = path.join(temporaryDirectory, "codex");

    try {
      writeFileSync(executablePath, "#!/bin/sh\nexit 0\n");
      chmodSync(executablePath, 0o755);

      const result = await discoverExecutable(
        {
          executableName: "codex",
        },
        {
          environment: {
            PATH: temporaryDirectory,
          },
          baseEnvironmentSource: "login_probe",
        },
      );

      expect(result).toEqual({
        executableName: "codex",
        status: "found",
        resolvedPath: executablePath,
        source: "path",
        baseEnvironmentSource: "login_probe",
        checkedPaths: [executablePath],
      });
    } finally {
      rmSync(temporaryDirectory, { recursive: true, force: true });
    }
  });

  test("prefers explicit environment overrides from the resolved environment", async () => {
    const temporaryDirectory = mkdtempSync(path.join(os.tmpdir(), "atelier-appserver-discovery-"));
    const executablePath = path.join(temporaryDirectory, "custom-codex");

    try {
      writeFileSync(executablePath, "#!/bin/sh\nexit 0\n");
      chmodSync(executablePath, 0o755);

      const result = await discoverExecutable(
        {
          executableName: "codex",
          overrideEnvironmentVariable: "ATELIERCODE_CODEX_PATH",
        },
        {
          environment: {
            ATELIERCODE_CODEX_PATH: executablePath,
            PATH: "/usr/bin:/bin",
          },
          baseEnvironmentSource: "fallback",
        },
      );

      expect(result).toEqual({
        executableName: "codex",
        status: "found",
        resolvedPath: executablePath,
        source: "environment",
        baseEnvironmentSource: "fallback",
        checkedPaths: [executablePath],
      });
    } finally {
      rmSync(temporaryDirectory, { recursive: true, force: true });
    }
  });

  test("ignores directories that merely have the execute bit set", async () => {
    const temporaryDirectory = mkdtempSync(path.join(os.tmpdir(), "atelier-appserver-discovery-"));
    const executableDirectory = path.join(temporaryDirectory, "codex");

    try {
      mkdirSync(executableDirectory);
      chmodSync(executableDirectory, 0o755);

      const result = await discoverExecutable(
        {
          executableName: "codex",
        },
        {
          environment: {
            PATH: temporaryDirectory,
          },
          baseEnvironmentSource: "login_probe",
        },
      );

      expect(result).toEqual({
        executableName: "codex",
        status: "missing",
        resolvedPath: null,
        source: "not-found",
        baseEnvironmentSource: "login_probe",
        checkedPaths: [executableDirectory],
      });
    } finally {
      rmSync(temporaryDirectory, { recursive: true, force: true });
    }
  });
});
