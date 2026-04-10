import { afterEach, describe, expect, test } from "bun:test";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  APP_SERVER_CONFIG_PATH_ENV,
  APP_SERVER_DATABASE_PATH_ENV,
  APP_SERVER_LOG_LEVEL_ENV,
  APP_SERVER_PORT_ENV,
  loadAppServerConfig,
} from "@/app/config";
import { ConfigParseStartupError, ConfigValidationStartupError } from "@/core/shared";

const temporaryDirectories: string[] = [];

afterEach(async () => {
  while (temporaryDirectories.length > 0) {
    const directory = temporaryDirectories.pop();

    if (directory !== undefined) {
      await rm(directory, { force: true, recursive: true });
    }
  }
});

describe("loadAppServerConfig", () => {
  test("loads a valid configuration file", async () => {
    const tempDirectory = await createTempDirectory();
    const configPath = join(tempDirectory, "appserver.config.json");

    await writeFile(
      configPath,
      JSON.stringify({
        port: 7331,
        databasePath: "./var/test.sqlite",
        logLevel: "info",
      }),
    );

    const config = await loadAppServerConfig({
      cwd: tempDirectory,
      env: {
        [APP_SERVER_CONFIG_PATH_ENV]: "appserver.config.json",
      },
    });

    expect(config).toEqual({
      configPath,
      port: 7331,
      databasePath: "./var/test.sqlite",
      logLevel: "info",
    });
  });

  test("applies supported environment overrides after reading the file", async () => {
    const tempDirectory = await createTempDirectory();
    const configPath = join(tempDirectory, "appserver.config.json");

    await writeFile(
      configPath,
      JSON.stringify({
        port: 7000,
        databasePath: "./var/original.sqlite",
        logLevel: "info",
      }),
    );

    const config = await loadAppServerConfig({
      cwd: tempDirectory,
      env: {
        [APP_SERVER_CONFIG_PATH_ENV]: "appserver.config.json",
        [APP_SERVER_PORT_ENV]: "9000",
        [APP_SERVER_DATABASE_PATH_ENV]: "./var/override.sqlite",
        [APP_SERVER_LOG_LEVEL_ENV]: "debug",
      },
    });

    expect(config).toEqual({
      configPath,
      port: 9000,
      databasePath: "./var/override.sqlite",
      logLevel: "debug",
    });
  });

  test("fails with a parse startup error for malformed JSON", async () => {
    const tempDirectory = await createTempDirectory();
    const configPath = join(tempDirectory, "appserver.config.json");

    await writeFile(configPath, "{");

    await expect(
      loadAppServerConfig({
        cwd: tempDirectory,
        env: {
          [APP_SERVER_CONFIG_PATH_ENV]: "appserver.config.json",
        },
      }),
    ).rejects.toBeInstanceOf(ConfigParseStartupError);
  });

  test("fails with a validation startup error for schema-invalid config", async () => {
    const tempDirectory = await createTempDirectory();
    const configPath = join(tempDirectory, "appserver.config.json");

    await writeFile(
      configPath,
      JSON.stringify({
        port: 0,
        databasePath: "",
        logLevel: "loud",
      }),
    );

    await expect(
      loadAppServerConfig({
        cwd: tempDirectory,
        env: {
          [APP_SERVER_CONFIG_PATH_ENV]: "appserver.config.json",
        },
      }),
    ).rejects.toBeInstanceOf(ConfigValidationStartupError);
  });
});

const createTempDirectory = async (): Promise<string> => {
  const directory = await mkdtemp(join(tmpdir(), "atelier-appserver-config-"));
  temporaryDirectories.push(directory);

  return directory;
};
