import { createAgentsFeature } from "@/agents";
import { createCodexAgentAdapter } from "@/agents/codex-adapter";
import {
  type AppServerConfig,
  type LoadAppServerConfigOptions,
  loadAppServerConfig,
} from "@/app/config";
import { createLogger, type Logger, type LogWriter } from "@/app/logger";
import { createAppProtocolRuntime, createAppTransportComponent } from "@/app/protocol";
import { createApprovalsFeaturePlaceholder } from "@/approvals";
import { getErrorMessage, type LifecycleComponent } from "@/core/shared";
import { createStoreBootstrap } from "@/core/store";
import { createThreadsFeaturePlaceholder } from "@/threads";
import { createTurnsFeaturePlaceholder } from "@/turns";
import { createSqliteWorkspacesStore, createWorkspacesFeature } from "@/workspaces";

export type AppServerState = "idle" | "starting" | "started" | "stopping" | "stopped";
export type ShutdownSignal = "SIGINT" | "SIGTERM";
export type SignalHandler = () => void;
export type Unsubscribe = () => void;

export type SignalRegistrar = Readonly<{
  subscribe: (signal: ShutdownSignal, handler: SignalHandler) => Unsubscribe;
}>;

export type AppServer = Readonly<{
  config: AppServerConfig;
  logger: Logger;
  getState: () => AppServerState;
  start: () => Promise<void>;
  stop: (reason?: string) => Promise<void>;
  waitForStop: () => Promise<void>;
}>;

export type CreateConfiguredAppServerOptions = Readonly<{
  config: AppServerConfig;
  logger?: Logger;
  now?: () => string;
  writeLog?: LogWriter;
  components?: readonly LifecycleComponent[];
  signalRegistrar?: SignalRegistrar;
}>;

export type CreateAppServerOptions = Readonly<
  LoadAppServerConfigOptions & {
    now?: () => string;
    writeLog?: LogWriter;
    components?: readonly LifecycleComponent[];
    signalRegistrar?: SignalRegistrar;
  }
>;

export const createAppServer = async (options: CreateAppServerOptions = {}): Promise<AppServer> => {
  const config = await loadAppServerConfig(options);

  return createConfiguredAppServer({
    config,
    now: options.now,
    writeLog: options.writeLog,
    components: options.components,
    signalRegistrar: options.signalRegistrar,
  });
};

export const createConfiguredAppServer = (options: CreateConfiguredAppServerOptions): AppServer => {
  const logger =
    options.logger ??
    createLogger({
      level: options.config.logLevel,
      now: options.now,
      write: options.writeLog,
    });
  const lifecycleLogger = logger.withContext({ component: "app-server" });
  const components = [...(options.components ?? createDefaultComponents(options.config, logger))];
  const signalRegistrar = options.signalRegistrar ?? processSignalRegistrar;

  let state: AppServerState = "idle";
  let startPromise: Promise<void> | null = null;
  let stopPromise: Promise<void> | null = null;
  let stopReason: string | null = null;
  let startedComponents: LifecycleComponent[] = [];
  let signalUnsubscribes: readonly Unsubscribe[] = [];
  const waitForStop = createDeferred();

  const registerSignalHandlers = (): void => {
    const subscriptions = (["SIGINT", "SIGTERM"] as const).map((signal) =>
      signalRegistrar.subscribe(signal, () => {
        lifecycleLogger.info("Shutdown signal received", { signal });
        void stop(signal).catch((error) => {
          lifecycleLogger.error("App Server stop failed", {
            reason: signal,
            error: getErrorMessage(error),
          });
        });
      }),
    );

    signalUnsubscribes = Object.freeze(subscriptions);
  };

  const unregisterSignalHandlers = (): void => {
    for (const unsubscribe of signalUnsubscribes) {
      unsubscribe();
    }

    signalUnsubscribes = Object.freeze([]);
  };

  const stopStartedComponents = async (reason: string): Promise<void> => {
    const stopErrors: unknown[] = [];

    for (const component of [...startedComponents].reverse()) {
      try {
        await component.stop(reason);
      } catch (error) {
        stopErrors.push(error);
      }
    }

    startedComponents = [];

    if (stopErrors.length === 1) {
      throw stopErrors[0];
    }

    if (stopErrors.length > 1) {
      throw new AggregateError(stopErrors, "App Server shutdown failed");
    }
  };

  const start = async (): Promise<void> => {
    if (state === "started") {
      return;
    }

    if (state === "stopping") {
      return stopPromise ?? Promise.resolve();
    }

    if (state === "stopped") {
      return;
    }

    if (startPromise !== null) {
      return startPromise;
    }

    state = "starting";
    startPromise = (async () => {
      lifecycleLogger.info("App Server starting", {
        port: options.config.port,
        databasePath: options.config.databasePath,
      });

      for (const component of components) {
        if (stopReason !== null) {
          return;
        }

        await component.start();
        startedComponents.push(component);
      }

      if (stopReason !== null) {
        return;
      }

      registerSignalHandlers();
      state = "started";
      lifecycleLogger.info("App Server started", {
        port: options.config.port,
        componentCount: components.length,
      });
    })();

    try {
      await startPromise;
    } catch (error) {
      unregisterSignalHandlers();
      try {
        await stopStartedComponents(stopReason ?? "startup-failed");
      } catch (rollbackError) {
        state = stopReason === null ? "idle" : "stopping";
        throw new AggregateError(
          [error, rollbackError],
          "App Server startup failed and rollback failed",
        );
      }

      state = stopReason === null ? "idle" : "stopping";
      throw error;
    } finally {
      startPromise = null;
    }
  };

  const stop = async (reason = "requested"): Promise<void> => {
    if (state === "stopped") {
      return;
    }

    if (stopPromise !== null) {
      return stopPromise;
    }

    stopReason = stopReason ?? reason;
    state = "stopping";
    unregisterSignalHandlers();
    stopPromise = (async () => {
      lifecycleLogger.info("App Server stopping", { reason: stopReason });

      let stopError: unknown = null;

      if (startPromise !== null) {
        try {
          await startPromise;
        } catch (error) {
          stopError = error;
        }
      }

      if (startedComponents.length > 0) {
        try {
          await stopStartedComponents(stopReason);
        } catch (error) {
          stopError =
            stopError === null
              ? error
              : new AggregateError([stopError, error], "App Server shutdown failed");
        }
      }

      state = "stopped";
      waitForStop.resolve();

      if (stopError !== null) {
        lifecycleLogger.error("App Server stopped with errors", {
          reason: stopReason,
          error: getErrorMessage(stopError),
        });
        throw stopError;
      }

      lifecycleLogger.info("App Server stopped", { reason: stopReason });
    })();

    try {
      await stopPromise;
    } finally {
      stopPromise = null;
    }
  };

  return Object.freeze({
    config: options.config,
    logger,
    getState: () => state,
    start,
    stop,
    waitForStop: () => waitForStop.promise,
  });
};

type Deferred = Readonly<{
  promise: Promise<void>;
  resolve: () => void;
}>;

const createDeferred = (): Deferred => {
  let isResolved = false;
  let resolvePromise: () => void = () => {};
  const promise = new Promise<void>((resolve) => {
    resolvePromise = () => {
      if (isResolved) {
        return;
      }

      isResolved = true;
      resolve();
    };
  });

  return {
    promise,
    resolve: resolvePromise,
  };
};

export const processSignalRegistrar: SignalRegistrar = Object.freeze({
  subscribe: (signal, handler) => {
    process.on(signal, handler);

    return () => {
      process.off(signal, handler);
    };
  },
});

const createDefaultComponents = (
  config: AppServerConfig,
  logger: Logger,
): readonly LifecycleComponent[] => {
  const storeBootstrap = createStoreBootstrap({
    config,
    logger: logger.withContext({ component: "core.store" }),
  });
  const appProtocolRuntime = createAppProtocolRuntime({
    logger,
  });
  const workspacesFeature = createWorkspacesFeature({
    logger: logger.withContext({ component: "feature.workspaces" }),
    registerMethod: appProtocolRuntime.registerMethod,
    store: createSqliteWorkspacesStore(storeBootstrap.getDatabase),
  });
  const agentsFeature = createAgentsFeature({
    config: config.agents,
    logger: logger.withContext({ component: "feature.agents" }),
    adapters: [
      createCodexAgentAdapter({
        logger: logger.withContext({ component: "agents.codex" }),
      }),
    ],
  });
  const transportComponent = createAppTransportComponent({
    config,
    logger,
    protocol: appProtocolRuntime,
    onConnectionClosed: [
      ({ connectionId }) => {
        workspacesFeature.handleConnectionClosed(connectionId);
      },
    ],
  });

  return Object.freeze([
    appProtocolRuntime.protocolComponent,
    storeBootstrap.lifecycle,
    agentsFeature.lifecycle,
    workspacesFeature.lifecycle,
    createThreadsFeaturePlaceholder(),
    createTurnsFeaturePlaceholder(),
    createApprovalsFeaturePlaceholder(),
    transportComponent,
  ]);
};
