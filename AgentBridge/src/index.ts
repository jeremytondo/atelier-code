import { createServer } from "node:net";

import {
  CodexAppServerTransport,
  CodexTransportError,
  type CodexTransportDisconnectReason,
} from "./codex/codex-transport";
import { discoverCodexExecutable } from "./discovery/executable";
import type {
  BridgeHealthReport,
  BridgeRuntimeStartupRecord,
  BridgeStartupError,
  ErrorEvent,
  HelloEnvelope,
  ProviderHealth,
  ProviderStatusEvent,
  ProviderSummary,
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

interface BridgeSocketData {
  sessionID: string;
  handshakeComplete: boolean;
  transport: CodexAppServerTransport | null;
  unsubscribeTransport: (() => void) | null;
}

await main();

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
          transport: null,
          unsubscribeTransport: null,
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
      session.unsubscribeTransport?.();
      await session.transport?.disconnect("requested_disconnect");
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

  sendBridgeMessage(
    socket,
    buildErrorEvent(
      "command_not_implemented",
      `Bridge command ${parsedMessage.type} is not implemented until phase 3 lands.`,
      parsedMessage.id,
      "codex",
      {
        bridgePhase: 2,
      },
    ),
  );
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

  const codexExecutable = await discoverCodexExecutable();
  const providers: ProviderSummary[] = [
    {
      id: "codex",
      displayName: "Codex",
      status: codexExecutable.status === "found" ? "available" : "degraded",
    },
  ];

  const welcome: WelcomeEnvelope = {
    type: "welcome",
    timestamp: new Date().toISOString(),
    requestID: candidateMessage.id,
    payload: {
      bridgeVersion: BRIDGE_VERSION,
      protocolVersion: compatibility.negotiatedVersion,
      supportedProtocolVersions: SUPPORTED_BRIDGE_PROTOCOL_VERSIONS,
      sessionID: socket.data.sessionID,
      transport: "websocket",
      providers,
    },
  };

  socket.data.handshakeComplete = true;
  sendBridgeMessage(socket, welcome);

  void connectTransportForSocket(socket, codexExecutable.status === "found");
}

async function connectTransportForSocket(
  socket: Bun.ServerWebSocket<BridgeSocketData>,
  codexAvailable: boolean,
): Promise<void> {
  if (!socket.data.handshakeComplete) {
    return;
  }

  if (!codexAvailable) {
    sendBridgeMessage(
      socket,
      buildProviderStatusEvent("error", "Codex executable is unavailable; provider transport cannot start."),
    );
    return;
  }

  const transport = new CodexAppServerTransport();
  socket.data.transport = transport;
  socket.data.unsubscribeTransport = transport.subscribe((event) => {
    if (event.type !== "disconnect") {
      return;
    }

    socket.data.transport = null;
    socket.data.unsubscribeTransport = null;

    if (!socket.data.handshakeComplete) {
      return;
    }

    const status = mapDisconnectReasonToProviderStatus(event.disconnect.reason);
    sendBridgeMessage(socket, buildProviderStatusEvent(status, event.disconnect.message));

    if (status === "error" || status === "degraded") {
      sendBridgeMessage(
        socket,
        buildErrorEvent(
          event.disconnect.reason,
          event.disconnect.message,
          undefined,
          "codex",
          event.disconnect.detail,
        ),
      );
    }
  });

  sendBridgeMessage(
    socket,
    buildProviderStatusEvent("starting", "Starting codex app-server transport."),
  );

  try {
    await transport.connect();
    sendBridgeMessage(
      socket,
      buildProviderStatusEvent("ready", "Codex transport is connected and ready for phase 3 command mapping."),
    );
  } catch (error) {
    socket.data.transport = null;
    socket.data.unsubscribeTransport?.();
    socket.data.unsubscribeTransport = null;

    const message =
      error instanceof Error ? error.message : "Bridge failed to start the codex provider transport.";
    const detail =
      error instanceof CodexTransportError
        ? error.detail
        : {
            error: String(error),
          };

    sendBridgeMessage(socket, buildProviderStatusEvent("error", message));
    sendBridgeMessage(
      socket,
      buildErrorEvent(
        error instanceof CodexTransportError ? error.code : "startup_failed",
        message,
        undefined,
        "codex",
        detail,
      ),
    );
  }
}

async function disconnectSocketTransport(
  socket: Bun.ServerWebSocket<BridgeSocketData>,
  reason: CodexTransportDisconnectReason,
): Promise<void> {
  const { transport, unsubscribeTransport } = socket.data;
  socket.data.transport = null;
  socket.data.unsubscribeTransport = null;

  unsubscribeTransport?.();
  await transport?.disconnect(reason);
}

async function buildHealthReport(): Promise<BridgeHealthReport> {
  const codexExecutable = await discoverCodexExecutable();
  const codexProvider: ProviderHealth = {
    provider: "codex",
    status: codexExecutable.status === "found" ? "available" : "degraded",
    detail:
      codexExecutable.status === "found"
        ? `Codex executable discovered at ${codexExecutable.resolvedPath}.`
        : "Codex executable was not found. Bridge transport stays unavailable until Codex is installed or configured.",
    executable: codexExecutable,
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

function buildProviderStatusEvent(
  status: ProviderStatusEvent["payload"]["status"],
  detail: string,
): ProviderStatusEvent {
  return {
    type: "provider.status",
    timestamp: new Date().toISOString(),
    provider: "codex",
    payload: {
      status,
      detail,
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
  message: ErrorEvent | ProviderStatusEvent | WelcomeEnvelope,
): void {
  socket.send(JSON.stringify(message));
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
