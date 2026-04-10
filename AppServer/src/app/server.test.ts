import { afterEach, describe, expect, test } from "bun:test";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { APP_SERVER_CONFIG_PATH_ENV } from "@/app/config";
import { createLogger } from "@/app/logger";
import {
  createAppServer,
  createConfiguredAppServer,
  type ShutdownSignal,
  type SignalHandler,
  type SignalRegistrar,
} from "@/app/server";

const temporaryDirectories: string[] = [];

afterEach(async () => {
  while (temporaryDirectories.length > 0) {
    const directory = temporaryDirectories.pop();

    if (directory !== undefined) {
      await rm(directory, { force: true, recursive: true });
    }
  }
});

describe("createAppServer", () => {
  test("bootstraps from the config file into an idle server", async () => {
    const tempDirectory = await createConfigDirectory();
    const server = await createAppServer({
      cwd: tempDirectory,
      env: {
        [APP_SERVER_CONFIG_PATH_ENV]: "appserver.config.json",
      },
      writeLog: () => {},
      signalRegistrar: createSignalRegistrar(),
    });

    expect(server.getState()).toBe("idle");
    expect(server.config.port).toBe(7331);
  });

  test("starts successfully", async () => {
    const tempDirectory = await createConfigDirectory();
    const server = await createAppServer({
      cwd: tempDirectory,
      env: {
        [APP_SERVER_CONFIG_PATH_ENV]: "appserver.config.json",
      },
      writeLog: () => {},
      signalRegistrar: createSignalRegistrar(),
    });

    await server.start();

    expect(server.getState()).toBe("started");
    expect(server.config.port).toBe(7331);
  });

  test("loads config in the high-level constructor while the configured constructor avoids config I/O", async () => {
    let readCount = 0;

    const bootstrappedServer = await createAppServer({
      cwd: "/unused",
      env: {
        [APP_SERVER_CONFIG_PATH_ENV]: "appserver.config.json",
      },
      readTextFile: async () => {
        readCount += 1;

        return JSON.stringify({
          port: 7331,
          databasePath: "./var/test.sqlite",
          logLevel: "info",
        });
      },
      writeLog: () => {},
      signalRegistrar: createSignalRegistrar(),
    });

    const configuredServer = createConfiguredAppServer({
      config: Object.freeze({
        configPath: "/tmp/appserver.config.json",
        port: 7444,
        databasePath: "./var/configured.sqlite",
        logLevel: "info",
      }),
      logger: createLogger({
        level: "info",
        write: () => {},
      }),
      signalRegistrar: createSignalRegistrar(),
    });

    expect(readCount).toBe(1);
    expect(bootstrappedServer.config.configPath).toBe("/unused/appserver.config.json");
    expect(configuredServer.config.port).toBe(7444);
    expect(configuredServer.getState()).toBe("idle");
  });
});

describe("AppServer lifecycle", () => {
  test("stops cleanly", async () => {
    const server = createConfiguredAppServer({
      config: createTestConfig(),
      logger: createSilentLogger(),
      signalRegistrar: createSignalRegistrar(),
    });

    await server.start();
    await server.stop("test-stop");

    expect(server.getState()).toBe("stopped");
  });

  test("makes stop idempotent", async () => {
    let stopCount = 0;
    const server = createConfiguredAppServer({
      config: createTestConfig(),
      logger: createSilentLogger(),
      signalRegistrar: createSignalRegistrar(),
      components: [
        {
          name: "fake-component",
          start: async () => {},
          stop: async () => {
            stopCount += 1;
          },
        },
      ],
    });

    await server.start();
    await Promise.all([server.stop("first"), server.stop("second")]);

    expect(stopCount).toBe(1);
    expect(server.getState()).toBe("stopped");
  });

  test("routes shutdown signals through the server lifecycle", async () => {
    let stopReason: string | undefined;
    const signalRegistrar = createSignalRegistrar();
    const server = createConfiguredAppServer({
      config: createTestConfig(),
      logger: createSilentLogger(),
      signalRegistrar,
      components: [
        {
          name: "fake-component",
          start: async () => {},
          stop: async (reason) => {
            stopReason = reason;
          },
        },
      ],
    });

    await server.start();
    signalRegistrar.emit("SIGTERM");
    await server.waitForStop();

    expect(stopReason).toBe("SIGTERM");
    expect(server.getState()).toBe("stopped");
  });

  test("resolves waitForStop after shutdown", async () => {
    const server = createConfiguredAppServer({
      config: createTestConfig(),
      logger: createSilentLogger(),
      signalRegistrar: createSignalRegistrar(),
    });
    let didResolve = false;

    await server.start();
    const waitForStop = server.waitForStop().then(() => {
      didResolve = true;
    });

    expect(didResolve).toBe(false);

    await server.stop("wait-for-stop");
    await waitForStop;

    expect(didResolve).toBe(true);
  });
});

type FakeSignalRegistrar = SignalRegistrar &
  Readonly<{
    emit: (signal: ShutdownSignal) => void;
  }>;

const createSignalRegistrar = (): FakeSignalRegistrar => {
  const handlers: Record<ShutdownSignal, SignalHandler[]> = {
    SIGINT: [],
    SIGTERM: [],
  };

  return {
    subscribe: (signal, handler) => {
      handlers[signal].push(handler);

      return () => {
        handlers[signal] = handlers[signal].filter((candidate) => candidate !== handler);
      };
    },
    emit: (signal) => {
      for (const handler of handlers[signal]) {
        handler();
      }
    },
  };
};

const createSilentLogger = () =>
  createLogger({
    level: "info",
    write: () => {},
  });

const createTestConfig = () =>
  Object.freeze({
    configPath: "/tmp/appserver.config.json",
    port: 7331,
    databasePath: "./var/test.sqlite",
    logLevel: "info" as const,
  });

const createConfigDirectory = async (): Promise<string> => {
  const directory = await mkdtemp(join(tmpdir(), "atelier-appserver-server-"));
  temporaryDirectories.push(directory);

  await writeFile(
    join(directory, "appserver.config.json"),
    JSON.stringify({
      port: 7331,
      databasePath: "./var/test.sqlite",
      logLevel: "info",
    }),
  );

  return directory;
};
