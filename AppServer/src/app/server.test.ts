import { afterEach, describe, expect, test } from "bun:test";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:net";
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
    const port = await getAvailablePort();
    const tempDirectory = await createConfigDirectory(port);
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
    expect(server.config.port).toBe(port);
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

  test("finishes shutdown when stop is requested during startup", async () => {
    const events: string[] = [];
    const slowStart = createDeferredPromise<void>();
    const server = createConfiguredAppServer({
      config: createTestConfig(),
      logger: createSilentLogger(),
      signalRegistrar: createSignalRegistrar(),
      components: [
        {
          name: "slow-component",
          start: async () => {
            events.push("slow:start:begin");
            await slowStart.promise;
            events.push("slow:start:end");
          },
          stop: async (reason) => {
            events.push(`slow:stop:${reason}`);
          },
        },
        {
          name: "second-component",
          start: async () => {
            events.push("second:start");
          },
          stop: async (reason) => {
            events.push(`second:stop:${reason}`);
          },
        },
      ],
    });

    const startPromise = server.start();
    await Promise.resolve();

    const stopPromise = server.stop("manual");
    slowStart.resolve();

    await Promise.all([startPromise, stopPromise, server.waitForStop()]);

    expect(server.getState()).toBe("stopped");
    expect(events).toEqual(["slow:start:begin", "slow:start:end", "slow:stop:manual"]);
  });

  test("reaches a terminal state when component stop fails", async () => {
    const signalRegistrar = createSignalRegistrar();
    const server = createConfiguredAppServer({
      config: createTestConfig(),
      logger: createSilentLogger(),
      signalRegistrar,
      components: [
        {
          name: "failing-stop-component",
          start: async () => {},
          stop: async () => {
            throw new Error("stop failed");
          },
        },
      ],
    });

    await server.start();
    await expect(server.stop("manual")).rejects.toThrow("stop failed");
    await server.waitForStop();

    expect(server.getState()).toBe("stopped");
  });

  test("rolls back started components when startup fails partway through", async () => {
    const events: string[] = [];
    const server = createConfiguredAppServer({
      config: createTestConfig(),
      logger: createSilentLogger(),
      signalRegistrar: createSignalRegistrar(),
      components: [
        {
          name: "first-component",
          start: async () => {
            events.push("first:start");
          },
          stop: async (reason) => {
            events.push(`first:stop:${reason}`);
          },
        },
        {
          name: "failing-start-component",
          start: async () => {
            events.push("second:start");
            throw new Error("start failed");
          },
          stop: async () => {
            events.push("second:stop");
          },
        },
      ],
    });

    await expect(server.start()).rejects.toThrow("start failed");

    expect(server.getState()).toBe("idle");
    expect(events).toEqual(["first:start", "second:start", "first:stop:startup-failed"]);
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
    port: 0,
    databasePath: "./var/test.sqlite",
    logLevel: "info" as const,
  });

const createDeferredPromise = <T>() => {
  let resolvePromise: (value: T | PromiseLike<T>) => void = () => {};

  const promise = new Promise<T>((resolve) => {
    resolvePromise = resolve;
  });

  return {
    promise,
    resolve: (value: T) => {
      resolvePromise(value);
    },
  };
};

const createConfigDirectory = async (port = 7331): Promise<string> => {
  const directory = await mkdtemp(join(tmpdir(), "atelier-appserver-server-"));
  temporaryDirectories.push(directory);

  await writeFile(
    join(directory, "appserver.config.json"),
    JSON.stringify({
      port,
      databasePath: "./var/test.sqlite",
      logLevel: "info",
    }),
  );

  return directory;
};

const getAvailablePort = async (): Promise<number> => {
  const server = createServer();

  await new Promise<void>((resolve, reject) => {
    server.listen(0, "127.0.0.1", () => resolve());
    server.once("error", reject);
  });

  const address = server.address();

  if (address === null || typeof address === "string") {
    throw new Error("Expected a TCP address");
  }

  await new Promise<void>((resolve, reject) => {
    server.close((error) => {
      if (error !== undefined) {
        reject(error);
        return;
      }

      resolve();
    });
  });

  return address.port;
};
