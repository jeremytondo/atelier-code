import { createServer } from "node:net";

import {
  CodexAppServerTransport,
  CodexTransportError,
  type CodexTransportDisconnectReason,
} from "./codex/codex-transport";
import {
  CODEX_PROVIDER_CAPABILITIES,
  CODEX_PROVIDER_ID,
  CodexClient,
  type CodexClientAdapter,
} from "./codex/codex-client";
import {
  DefaultCodexEventMapper,
  buildThreadStartedEvent,
  buildThreadSummary,
} from "./codex/codex-event-mapper";
import { discoverCodexExecutable } from "./discovery/executable";
import {
  BaseEnvironmentResolver,
  type ResolvedBaseEnvironment,
} from "./environment/base-environment";
import type {
  AccountLoginResultEvent,
  AuthChangedEvent,
  BridgeCommand,
  BridgeEnvironmentDiagnostics,
  BridgeEvent,
  BridgeHealthReport,
  BridgeRuntimeStartupRecord,
  BridgeStartupError,
  ErrorEvent,
  HelloEnvelope,
  ModelListResultEvent,
  RateLimitUpdatedEvent,
  ProviderHealth,
  ProviderStatusEvent,
  ProviderSummary,
  ThreadListResultEvent,
  ThreadStartedEvent,
  WelcomeEnvelope,
} from "./protocol/types";
import {
  BRIDGE_PROTOCOL_VERSION,
  SUPPORTED_BRIDGE_PROTOCOL_VERSIONS,
  negotiateBridgeProtocolVersion,
} from "./protocol/version";

const BRIDGE_VERSION = "0.1.0";
const HEALTHCHECK_FLAG = "--healthcheck";
const WEBSOCKET_HOST = "127.0.0.1";
const baseEnvironmentResolver = new BaseEnvironmentResolver();

interface BridgeSocketData {
  sessionID: string;
  handshakeComplete: boolean;
  providerRegistrationsByID: Record<string, BridgeProviderRegistration>;
  providerConnectionsByID: Record<string, ConnectedBridgeProvider>;
}

interface CodexProviderRuntimeContext {
  baseEnvironment: ResolvedBaseEnvironment;
  executable: Awaited<ReturnType<typeof discoverCodexExecutable>>;
}

interface ProviderRuntimeDiagnostics {
  executablePath?: string;
  environment?: BridgeEnvironmentDiagnostics;
}

interface BridgeProviderRegistration {
  summary: ProviderSummary;
  diagnostics: ProviderRuntimeDiagnostics;
  connect(): Promise<ConnectedBridgeProvider>;
}

interface ConnectedBridgeProvider {
  providerID: string;
  transport: CodexAppServerTransport;
  client: CodexClientAdapter;
  eventMapper: DefaultCodexEventMapper;
  unsubscribeTransport: (() => void) | null;
}

if (import.meta.main) {
  await main();
}

async function main(): Promise<void> {
  const argumentsList = process.argv.slice(2);

  if (argumentsList.length === 1 && argumentsList[0] === HEALTHCHECK_FLAG) {
    const report = await buildHealthReport();
    process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
    return;
  }

  const preferredPort = parsePreferredPort(process.env.ATELIERCODE_BRIDGE_PORT);
  await startRuntimeServer(preferredPort);
}

async function startRuntimeServer(port: number): Promise<void> {
  const sessions = new Set<BridgeSocketData>();
  const runtimePort = await resolveRuntimePort(port);

  const server = Bun.serve<BridgeSocketData>({
    hostname: WEBSOCKET_HOST,
    port: runtimePort,
    fetch(request, runtimeServer) {
      const upgradeSucceeded = runtimeServer.upgrade(request, {
        data: {
          sessionID: crypto.randomUUID(),
          handshakeComplete: false,
          providerRegistrationsByID: {},
          providerConnectionsByID: {},
        },
      });

      if (upgradeSucceeded) {
        return undefined;
      }

      return new Response("Expected WebSocket upgrade.", { status: 426 });
    },
    websocket: {
      open(socket) {
        sessions.add(socket.data);
      },
      async message(socket, rawMessage) {
        await handleSocketMessage(socket, rawMessage);
      },
      async close(socket) {
        sessions.delete(socket.data);
        await disconnectSocketTransport(socket, "app_socket_disconnected");
      },
    },
  });

  const boundPort = server.port;
  if (boundPort === undefined) {
    throw new Error("Bridge WebSocket server did not report its listening port.");
  }

  const startupRecord: BridgeRuntimeStartupRecord = {
    recordType: "bridge.startup",
    bridgeVersion: BRIDGE_VERSION,
    protocolVersion: BRIDGE_PROTOCOL_VERSION,
    transport: "websocket",
    host: WEBSOCKET_HOST,
    port: boundPort,
    pid: process.pid,
    startedAt: new Date().toISOString(),
  };

  process.stdout.write(`${JSON.stringify(startupRecord)}\n`);

  registerShutdownHandlers(server, sessions);
}

function registerShutdownHandlers(
  server: Bun.Server<BridgeSocketData>,
  sessions: Set<BridgeSocketData>,
): void {
  const shutdown = async (): Promise<void> => {
    process.off("SIGINT", handleSignal);
    process.off("SIGTERM", handleSignal);

    for (const session of sessions) {
      for (const provider of Object.values(session.providerConnectionsByID)) {
        provider.unsubscribeTransport?.();
        await provider.transport.disconnect("requested_disconnect");
      }
    }

    server.stop(true);
  };

  const handleSignal = (): void => {
    void shutdown();
  };

  process.on("SIGINT", handleSignal);
  process.on("SIGTERM", handleSignal);
}

async function handleSocketMessage(
  socket: Bun.ServerWebSocket<BridgeSocketData>,
  rawMessage: string | Buffer | Uint8Array | ArrayBuffer | Buffer[],
): Promise<void> {
  const decodedMessage = decodeSocketMessage(rawMessage);
  if (decodedMessage === null) {
    sendBridgeMessage(
      socket,
      buildErrorEvent("invalid_message", "Bridge received a non-text WebSocket frame."),
    );
    return;
  }

  let parsedMessage: unknown;

  try {
    parsedMessage = JSON.parse(decodedMessage);
  } catch {
    sendBridgeMessage(
      socket,
      buildErrorEvent("invalid_message", "Bridge received malformed JSON."),
    );
    return;
  }

  if (!isPlainObject(parsedMessage) || typeof parsedMessage.type !== "string") {
    sendBridgeMessage(
      socket,
      buildErrorEvent("invalid_message", "Bridge messages must be JSON objects with a string type."),
    );
    return;
  }

  if (!socket.data.handshakeComplete) {
    if (parsedMessage.type !== "hello") {
      sendBridgeMessage(
        socket,
        buildErrorEvent(
          "handshake_required",
          "The first app message on a bridge connection must be hello.",
          extractRequestID(parsedMessage),
        ),
      );
      return;
    }

    await completeHandshake(socket, parsedMessage);
    return;
  }

  if (parsedMessage.type === "hello") {
    sendBridgeMessage(
      socket,
      buildErrorEvent("unexpected_hello", "Bridge handshake has already completed."),
    );
    return;
  }

  if (!isBridgeCommandEnvelope(parsedMessage)) {
    sendBridgeMessage(
      socket,
      buildErrorEvent(
        "unsupported_message_type",
        `Bridge does not recognize message type ${parsedMessage.type}.`,
        extractRequestID(parsedMessage),
      ),
    );
    return;
  }

  const events = await executeBridgeCommand(
    socket.data.providerConnectionsByID,
    parsedMessage as BridgeCommand,
  );
  sendBridgeEvents(socket, events);
}

async function completeHandshake(
  socket: Bun.ServerWebSocket<BridgeSocketData>,
  candidateMessage: Record<string, unknown>,
): Promise<void> {
  if (!isHelloEnvelope(candidateMessage)) {
    sendBridgeMessage(
      socket,
      buildErrorEvent("invalid_message", "Bridge hello payload is malformed."),
    );
    return;
  }

  const compatibility = negotiateBridgeProtocolVersion(
    candidateMessage.payload.protocolVersion,
    candidateMessage.payload.supportedProtocolVersions,
  );

  if (!compatibility.isCompatible) {
    sendBridgeMessage(
      socket,
      buildErrorEvent(
        compatibility.error.code,
        compatibility.error.message,
        candidateMessage.id,
        undefined,
        {
          supportedProtocolVersions: compatibility.supportedVersions,
        },
      ),
    );
    socket.close(1002, "Unsupported bridge protocol version.");
    return;
  }

  const providerRegistrations = await resolveProviderRegistrations();
  socket.data.providerRegistrationsByID = Object.fromEntries(
    providerRegistrations.map((registration) => [registration.summary.id, registration]),
  );

  const welcome = buildWelcomeEnvelope(
    candidateMessage.id,
    socket.data.sessionID,
    compatibility.negotiatedVersion,
    providerRegistrations.map((registration) => registration.summary),
    providerRegistrations[0]?.diagnostics.environment ?? {
      source: "fallback",
      shellPath: process.env.SHELL ?? "",
      probeError: null,
      pathDirectoryCount: 0,
      homeDirectory: process.env.HOME ?? null,
    },
  );

  socket.data.handshakeComplete = true;
  sendBridgeMessage(socket, welcome);

  void connectProvidersForSocket(socket);
}

async function connectProvidersForSocket(
  socket: Bun.ServerWebSocket<BridgeSocketData>,
): Promise<void> {
  if (!socket.data.handshakeComplete) {
    return;
  }

  for (const providerRegistration of Object.values(socket.data.providerRegistrationsByID)) {
    await connectProviderForSocket(socket, providerRegistration);
  }
}

async function connectProviderForSocket(
  socket: Bun.ServerWebSocket<BridgeSocketData>,
  providerRegistration: BridgeProviderRegistration,
): Promise<void> {
  const providerID = providerRegistration.summary.id;
  sendBridgeMessage(
    socket,
    buildProviderStatusEvent(
      providerID,
      "starting",
      `Starting ${providerRegistration.summary.displayName} provider transport.`,
      providerRegistration.diagnostics,
    ),
  );

  try {
    const provider = await providerRegistration.connect();
    socket.data.providerConnectionsByID[providerID] = provider;
    provider.unsubscribeTransport = provider.transport.subscribe((event) => {
      if (event.type === "notification") {
        sendBridgeEvents(socket, provider.eventMapper.mapNotification(event.notification));
        return;
      }

      if (event.type === "serverRequest") {
        sendBridgeEvents(socket, provider.eventMapper.mapServerRequest(event.request));
        return;
      }

      delete socket.data.providerConnectionsByID[providerID];
      provider.unsubscribeTransport?.();
      provider.unsubscribeTransport = null;

      if (!socket.data.handshakeComplete) {
        return;
      }

      const status = mapDisconnectReasonToProviderStatus(event.disconnect.reason);
      sendBridgeMessage(
        socket,
        buildProviderStatusEvent(
          providerID,
          status,
          event.disconnect.message,
          providerRegistration.diagnostics,
        ),
      );

      if (status === "error" || status === "degraded") {
        sendBridgeMessage(
          socket,
          buildErrorEvent(
            event.disconnect.reason,
            event.disconnect.message,
            undefined,
            providerID,
            {
              ...(event.disconnect.detail ?? {}),
              executablePath: providerRegistration.diagnostics.executablePath,
              environment: providerRegistration.diagnostics.environment,
            },
          ),
        );
      }
    });

    await provider.client.connect();
    sendBridgeMessage(
      socket,
      buildProviderStatusEvent(
        providerID,
        "ready",
        `${providerRegistration.summary.displayName} transport is connected and ready.`,
        providerRegistration.diagnostics,
      ),
    );
  } catch (error) {
    delete socket.data.providerConnectionsByID[providerID];

    const message =
      error instanceof Error
        ? error.message
        : `Bridge failed to start the ${providerRegistration.summary.displayName} provider transport.`;
    const detail =
      error instanceof CodexTransportError
        ? error.detail
        : {
            error: String(error),
          };
    sendBridgeMessage(
      socket,
      buildProviderStatusEvent(providerID, "error", message, providerRegistration.diagnostics),
    );
    sendBridgeMessage(
      socket,
      buildErrorEvent(
        error instanceof CodexTransportError ? error.code : "startup_failed",
        message,
        undefined,
        providerID,
        {
          ...(detail ?? {}),
          executablePath: providerRegistration.diagnostics.executablePath,
          environment: providerRegistration.diagnostics.environment,
        },
      ),
    );
  }
}

async function resolveProviderRegistrations(): Promise<BridgeProviderRegistration[]> {
  const codexRuntimeContext = await resolveCodexProviderRuntimeContext();
  const summary: ProviderSummary = {
    id: CODEX_PROVIDER_ID,
    displayName: "Codex",
    status: codexRuntimeContext.executable.status === "found" ? "available" : "degraded",
    capabilities: CODEX_PROVIDER_CAPABILITIES,
  };
  const diagnostics: ProviderRuntimeDiagnostics = {
    executablePath: codexRuntimeContext.executable.resolvedPath ?? undefined,
    environment: codexRuntimeContext.baseEnvironment.diagnostics,
  };

  return [
    {
      summary,
      diagnostics,
      connect: async () => {
        if (
          codexRuntimeContext.executable.status !== "found" ||
          codexRuntimeContext.executable.resolvedPath === null
        ) {
          throw new CodexTransportError(
            "provider_executable_missing",
            "Codex executable is unavailable; provider transport cannot start.",
            {
              checkedPaths: codexRuntimeContext.executable.checkedPaths,
              source: codexRuntimeContext.executable.source,
              baseEnvironmentSource: codexRuntimeContext.executable.baseEnvironmentSource,
              environment: codexRuntimeContext.baseEnvironment.diagnostics,
            },
          );
        }

        const transport = new CodexAppServerTransport({
          executable: codexRuntimeContext.executable,
          environment: codexRuntimeContext.baseEnvironment.environment,
        });

        return {
          providerID: CODEX_PROVIDER_ID,
          transport,
          client: new CodexClient(transport),
          eventMapper: new DefaultCodexEventMapper(),
          unsubscribeTransport: null,
        };
      },
    },
  ];
}

async function resolveCodexProviderRuntimeContext(): Promise<CodexProviderRuntimeContext> {
  const baseEnvironment = await baseEnvironmentResolver.resolve();
  const executable = await discoverCodexExecutable({
    environment: baseEnvironment.environment,
    baseEnvironmentSource: baseEnvironment.diagnostics.source,
  });

  return {
    baseEnvironment,
    executable,
  };
}

async function disconnectSocketTransport(
  socket: Bun.ServerWebSocket<BridgeSocketData>,
  reason: CodexTransportDisconnectReason,
): Promise<void> {
  const providers = Object.values(socket.data.providerConnectionsByID);
  socket.data.providerConnectionsByID = {};

  for (const provider of providers) {
    provider.unsubscribeTransport?.();
    provider.unsubscribeTransport = null;
    await provider.transport.disconnect(reason);
  }
}

async function buildHealthReport(): Promise<BridgeHealthReport> {
  const codexRuntimeContext = await resolveCodexProviderRuntimeContext();
  const codexExecutable = codexRuntimeContext.executable;
  const codexProvider: ProviderHealth = {
    provider: CODEX_PROVIDER_ID,
    status: codexExecutable.status === "found" ? "available" : "degraded",
    detail:
      codexExecutable.status === "found"
        ? `Codex executable discovered at ${codexExecutable.resolvedPath}.`
        : "Codex executable was not found. Bridge transport stays unavailable until Codex is installed or configured.",
    capabilities: CODEX_PROVIDER_CAPABILITIES,
    executable: codexExecutable,
    environment: codexRuntimeContext.baseEnvironment.diagnostics,
  };

  const errors: BridgeStartupError[] =
    codexExecutable.status === "found"
      ? []
      : [
          {
            code: "provider_executable_missing",
            message: "Codex executable was not found during bridge startup discovery.",
            recoverySuggestion:
              "Install Codex or set ATELIERCODE_CODEX_PATH to a valid executable before launching the bridge.",
          },
        ];

  return {
    bridgeVersion: BRIDGE_VERSION,
    protocolVersion: BRIDGE_PROTOCOL_VERSION,
    status: errors.length === 0 ? "ok" : "degraded",
    generatedAt: new Date().toISOString(),
    providers: [codexProvider],
    errors,
  };
}

export function buildWelcomeEnvelope(
  requestID: string,
  sessionID: string,
  protocolVersion: number,
  providers: ProviderSummary[],
  environment: BridgeEnvironmentDiagnostics,
): WelcomeEnvelope {
  return {
    type: "welcome",
    timestamp: new Date().toISOString(),
    requestID,
    payload: {
      bridgeVersion: BRIDGE_VERSION,
      protocolVersion,
      supportedProtocolVersions: SUPPORTED_BRIDGE_PROTOCOL_VERSIONS,
      sessionID,
      transport: "websocket",
      providers,
      environment,
    },
  };
}

export function buildProviderStatusEvent(
  providerID: string,
  status: ProviderStatusEvent["payload"]["status"],
  detail: string,
  diagnostics?: ProviderRuntimeDiagnostics,
): ProviderStatusEvent {
  return {
    type: "provider.status",
    timestamp: new Date().toISOString(),
    provider: providerID,
    payload: {
      status,
      detail,
      ...(diagnostics?.executablePath ? { executablePath: diagnostics.executablePath } : {}),
      ...(diagnostics?.environment ? { environment: diagnostics.environment } : {}),
    },
  };
}

function buildErrorEvent(
  code: string,
  message: string,
  requestID?: string,
  provider?: string,
  detail?: Record<string, unknown>,
): ErrorEvent {
  return {
    type: "error",
    timestamp: new Date().toISOString(),
    requestID,
    provider,
    payload: {
      code,
      message,
      retryable: false,
      detail,
    },
  };
}

function sendBridgeMessage(
  socket: Bun.ServerWebSocket<BridgeSocketData>,
  message: ErrorEvent | ProviderStatusEvent | WelcomeEnvelope | BridgeEvent,
): void {
  socket.send(JSON.stringify(message));
}

function sendBridgeEvents(
  socket: Bun.ServerWebSocket<BridgeSocketData>,
  events: BridgeEvent[],
): void {
  for (const event of events) {
    sendBridgeMessage(socket, event);
  }
}

function mapDisconnectReasonToProviderStatus(
  reason: CodexTransportDisconnectReason,
): ProviderStatusEvent["payload"]["status"] {
  switch (reason) {
    case "requested_disconnect":
    case "app_socket_disconnected":
      return "disconnected";
    case "provider_executable_missing":
    case "startup_failed":
    case "malformed_output":
      return "error";
    case "process_exited":
      return "degraded";
  }
}

function parsePreferredPort(candidatePort: string | undefined): number {
  if (candidatePort === undefined) {
    return 0;
  }

  const parsedPort = Number.parseInt(candidatePort, 10);
  if (!Number.isInteger(parsedPort) || parsedPort < 0 || parsedPort > 65_535) {
    return 0;
  }

  return parsedPort;
}

async function resolveRuntimePort(preferredPort: number): Promise<number> {
  if (preferredPort !== 0) {
    return preferredPort;
  }

  return new Promise<number>((resolve, reject) => {
    const probeServer = createServer();

    probeServer.once("error", reject);
    probeServer.listen(0, WEBSOCKET_HOST, () => {
      const address = probeServer.address();
      if (address === null || typeof address === "string") {
        reject(new Error("Unable to determine an ephemeral loopback port for the bridge."));
        void probeServer.close();
        return;
      }

      const { port } = address;
      probeServer.close((closeError) => {
        if (closeError) {
          reject(closeError);
          return;
        }

        resolve(port);
      });
    });
  });
}

function decodeSocketMessage(
  rawMessage: string | Buffer | Uint8Array | ArrayBuffer | Buffer[],
): string | null {
  if (typeof rawMessage === "string") {
    return rawMessage;
  }

  if (rawMessage instanceof ArrayBuffer) {
    return new TextDecoder().decode(rawMessage);
  }

  if (rawMessage instanceof Uint8Array) {
    return new TextDecoder().decode(rawMessage);
  }

  if (Array.isArray(rawMessage)) {
    const chunks = rawMessage.map((chunk) =>
      typeof chunk === "string" ? chunk : new TextDecoder().decode(chunk),
    );
    return chunks.join("");
  }

  return null;
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isHelloEnvelope(
  candidateMessage: Record<string, unknown>,
): candidateMessage is Record<string, unknown> & HelloEnvelope {
  return (
    typeof candidateMessage.id === "string" &&
    candidateMessage.type === "hello" &&
    isPlainObject(candidateMessage.payload) &&
    typeof candidateMessage.payload.appVersion === "string" &&
    typeof candidateMessage.payload.clientName === "string" &&
    typeof candidateMessage.payload.protocolVersion === "number" &&
    (candidateMessage.payload.supportedProtocolVersions === undefined ||
      (Array.isArray(candidateMessage.payload.supportedProtocolVersions) &&
        candidateMessage.payload.supportedProtocolVersions.every(
          (version) => typeof version === "number",
        )))
  );
}

function isBridgeCommandEnvelope(
  candidateMessage: Record<string, unknown>,
): candidateMessage is { type: string; id: string } {
  return typeof candidateMessage.type === "string" && typeof candidateMessage.id === "string";
}

function extractRequestID(candidateMessage: Record<string, unknown>): string | undefined {
  return typeof candidateMessage.id === "string" ? candidateMessage.id : undefined;
}

export async function executeBridgeCommand(
  providerConnectionsByID: Readonly<Record<string, ConnectedBridgeProvider | undefined>>,
  command: BridgeCommand,
): Promise<BridgeEvent[]> {
  const providerConnection = providerConnectionsByID[command.provider];
  if (providerConnection === undefined) {
    return [
      buildErrorEvent(
        "provider_not_ready",
        `${command.provider} transport is not connected yet.`,
        command.id,
        command.provider,
      ),
    ];
  }

  const client = providerConnection.client;

  try {
    switch (command.type) {
      case "model.list": {
        const result = await client.listModels(command.id, command.payload);
        const event: ModelListResultEvent = {
          type: "model.list.result",
          timestamp: new Date().toISOString(),
          provider: client.providerID,
          requestID: command.id,
          payload: {
            models: result.models,
          },
        };
        return [event];
      }
      case "thread.start": {
        const result = await client.startThread(command.id, command.payload);
        return [buildThreadStartedEvent(command.id, result.thread, client.providerID)];
      }
      case "thread.resume": {
        const result = await client.resumeThread(command.id, command.threadID, command.payload);
        return [buildThreadStartedEvent(command.id, result.thread, client.providerID)];
      }
      case "thread.list": {
        const result = await client.listThreads(command.id, command.payload);
        const event: ThreadListResultEvent = {
          type: "thread.list.result",
          timestamp: new Date().toISOString(),
          provider: client.providerID,
          requestID: command.id,
          payload: {
            threads: result.threads.map((thread) => buildThreadSummary(thread, client.providerID)),
            nextCursor: result.nextCursor,
          },
        };
        return [event];
      }
      case "thread.read": {
        const result = await client.readThread(command.id, command.threadID, command.payload);
        return [buildThreadStartedEvent(command.id, result.thread, client.providerID)];
      }
      case "thread.fork": {
        const result = await client.forkThread(command.id, command.threadID, command.payload);
        return [buildThreadStartedEvent(command.id, result.thread, client.providerID)];
      }
      case "thread.rename": {
        const result = await client.renameThread(command.id, command.threadID, command.payload);
        return [buildThreadStartedEvent(command.id, result.thread, client.providerID)];
      }
      case "thread.rollback": {
        const result = await client.rollbackThread(command.id, command.threadID, command.payload);
        return [buildThreadStartedEvent(command.id, result.thread, client.providerID)];
      }
      case "turn.start": {
        const result = await client.startTurn(command.id, command.threadID, command.payload);
        return [
          {
            type: "turn.started",
            timestamp: new Date().toISOString(),
            provider: client.providerID,
            requestID: command.id,
            threadID: command.threadID,
            turnID: result.turnID,
            payload: {
              status: "in_progress",
            },
          },
        ];
      }
      case "turn.cancel":
        await client.cancelTurn(command.id, command.threadID, command.turnID);
        return [];
      case "approval.resolve":
        await client.resolveApproval(command.payload.approvalID, command.payload);
        return [
          {
            type: "approval.resolved",
            timestamp: new Date().toISOString(),
            provider: client.providerID,
            requestID: command.id,
            threadID: command.threadID,
            turnID: command.turnID,
            payload: {
              approvalID: command.payload.approvalID,
              resolution: command.payload.resolution,
            },
          },
        ];
      case "account.read": {
        const result = await client.readAccount(command.id, command.payload);
        return buildAccountEvents(command.id, client.providerID, result);
      }
      case "account.login": {
        const result = await client.login(command.id, command.payload);
        const loginEvent: AccountLoginResultEvent = {
          type: "account.login.result",
          timestamp: new Date().toISOString(),
          provider: client.providerID,
          requestID: command.id,
          payload: {
            method: result.type,
            authURL: result.authURL,
            loginID: result.loginID,
          },
        };

        if (result.authURL) {
          return [loginEvent];
        }

        const account = await client.readAccount(`${command.id}:account`, {});
        return [loginEvent, ...buildAccountEvents(command.id, client.providerID, account)];
      }
      case "account.logout":
        await client.logout(command.id);
        return [
          {
            type: "auth.changed",
            timestamp: new Date().toISOString(),
            provider: client.providerID,
            requestID: command.id,
            payload: {
              state: "signed_out",
              account: null,
            },
          },
        ];
    }
  } catch (error) {
    const detail =
      error instanceof CodexTransportError
        ? error.detail
        : {
            error: error instanceof Error ? error.message : String(error),
          };

    return [
      buildErrorEvent(
        error instanceof CodexTransportError ? error.code : "provider_command_failed",
        error instanceof Error ? error.message : "Bridge command failed against Codex.",
        command.id,
        client.providerID,
        detail,
      ),
    ];
  }
}

function buildAccountEvents(
  requestID: string,
  providerID: string,
  result: {
    account: {
      type: "apiKey" | "chatgpt";
      email?: string;
      planType?: string;
    } | null;
    requiresOpenAIAuth: boolean;
    rateLimits: {
      limitId: string | null;
      limitName: string | null;
      primary: { usedPercent: number; windowDurationMins: number | null; resetsAt: number | null } | null;
      secondary: { usedPercent: number; windowDurationMins: number | null; resetsAt: number | null } | null;
      planType: string | null;
    } | null;
  },
): BridgeEvent[] {
  const authEvent: AuthChangedEvent = {
    type: "auth.changed",
    timestamp: new Date().toISOString(),
    provider: providerID,
    requestID,
    payload: result.account
      ? {
          state: "signed_in",
          account: {
            displayName:
              result.account.type === "chatgpt"
                ? result.account.email ?? `chatgpt${result.account.planType ? ` (${result.account.planType})` : ""}`
                : "API Key",
            email: result.account.email,
          },
        }
      : {
          state: result.requiresOpenAIAuth ? "signed_out" : "unknown",
          account: null,
        },
  };

  if (result.rateLimits === null) {
    return [authEvent];
  }

  const buckets: RateLimitUpdatedEvent["payload"]["buckets"] = [];

  if (result.rateLimits.primary !== null) {
    buckets.push({
      id: `${result.rateLimits.limitId ?? "primary"}:primary`,
      kind: "requests",
      resetAt:
        result.rateLimits.primary.resetsAt !== null
          ? new Date(result.rateLimits.primary.resetsAt * 1_000).toISOString()
          : undefined,
      detail: `${result.rateLimits.limitName ?? "primary"}: ${result.rateLimits.primary.usedPercent}% used`,
    });
  }

  if (result.rateLimits.secondary !== null) {
    buckets.push({
      id: `${result.rateLimits.limitId ?? "secondary"}:secondary`,
      kind: "tokens",
      resetAt:
        result.rateLimits.secondary.resetsAt !== null
          ? new Date(result.rateLimits.secondary.resetsAt * 1_000).toISOString()
          : undefined,
      detail: `${result.rateLimits.limitName ?? "secondary"}: ${result.rateLimits.secondary.usedPercent}% used`,
    });
  }

  const rateLimitEvent: RateLimitUpdatedEvent = {
    type: "rateLimit.updated",
    timestamp: new Date().toISOString(),
    provider: providerID,
    requestID,
    payload: {
      buckets,
    },
  };

  return buckets.length > 0 ? [authEvent, rateLimitEvent] : [authEvent];
}
