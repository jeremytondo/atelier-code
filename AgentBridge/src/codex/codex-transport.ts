import type { ExecutableDiscoveryResult } from "../protocol/types";

const JSON_LINE_ENCODER = new TextEncoder();
const STDERR_TAIL_LIMIT = 4_096;
const GRACEFUL_SHUTDOWN_TIMEOUT_MS = 250;

export type CodexTransportRequestID = string | number;
export type CodexTransportDisconnectReason =
  | "requested_disconnect"
  | "app_socket_disconnected"
  | "provider_executable_missing"
  | "startup_failed"
  | "process_exited"
  | "malformed_output";

export interface CodexTransportRequest<TParams = unknown> {
  id: CodexTransportRequestID;
  method: string;
  params?: TParams;
}

export interface CodexTransportNotification<TParams = unknown> {
  method: string;
  params?: TParams;
}

export interface CodexTransportServerRequest<TParams = unknown> extends CodexTransportRequest<TParams> {}

export interface CodexTransportSuccessResponse<TResult = unknown> {
  id: CodexTransportRequestID;
  result: TResult;
}

export interface CodexTransportErrorObject {
  code: number;
  message: string;
  data?: unknown;
}

export interface CodexTransportErrorResponse {
  id: CodexTransportRequestID;
  error: CodexTransportErrorObject;
}

export type CodexTransportResponse<TResult = unknown> =
  | CodexTransportSuccessResponse<TResult>
  | CodexTransportErrorResponse;

export interface CodexTransportDisconnectInfo {
  reason: CodexTransportDisconnectReason;
  message: string;
  exitCode?: number | null;
  detail?: Record<string, unknown>;
}

export type CodexTransportEvent =
  | {
      type: "notification";
      notification: CodexTransportNotification;
    }
  | {
      type: "serverRequest";
      request: CodexTransportServerRequest;
    }
  | {
      type: "disconnect";
      disconnect: CodexTransportDisconnectInfo;
    };

export interface CodexTransportProcess {
  stdin: CodexTransportInput;
  stdout: ReadableStream<Uint8Array>;
  stderr: ReadableStream<Uint8Array>;
  exited: Promise<number>;
  kill(): void;
}

export interface CodexTransportInput {
  write(chunk: Uint8Array): Promise<void>;
  close(): Promise<void>;
}

export interface CodexTransportDependencies {
  spawnProcess?: (
    executablePath: string,
    environment: Readonly<Record<string, string>>,
  ) => CodexTransportProcess;
}

export interface CodexTransportStartupContext {
  executable: ExecutableDiscoveryResult;
  environment: Readonly<Record<string, string>>;
}

export interface CodexTransport {
  connect(): Promise<void>;
  disconnect(reason?: CodexTransportDisconnectReason): Promise<void>;
  send<TResult = unknown>(request: CodexTransportRequest): Promise<TResult>;
  respond(response: CodexTransportResponse): Promise<void>;
  subscribe(listener: (event: CodexTransportEvent) => void): () => void;
}

interface PendingRequest {
  reject: (error: unknown) => void;
  resolve: (value: any) => void;
}

export class CodexTransportError extends Error {
  constructor(
    readonly code: CodexTransportDisconnectReason,
    message: string,
    readonly detail?: Record<string, unknown>,
    readonly cause?: unknown,
  ) {
    super(message);
    this.name = "CodexTransportError";
  }
}

export class CodexTransportRemoteError extends Error {
  constructor(
    readonly requestID: CodexTransportRequestID,
    readonly code: number,
    message: string,
    readonly data?: unknown,
  ) {
    super(message);
    this.name = "CodexTransportRemoteError";
  }
}

export class CodexAppServerTransport implements CodexTransport {
  private readonly dependencies: Required<CodexTransportDependencies>;
  private readonly listeners = new Set<(event: CodexTransportEvent) => void>();
  private readonly pendingRequests = new Map<string, PendingRequest>();
  private readonly pendingServerRequests = new Map<string, CodexTransportServerRequest>();

  private process: CodexTransportProcess | null = null;
  private stdoutBuffer = "";
  private stderrTail = "";
  private sawProviderOutput = false;
  private hasWrittenRequest = false;
  private finalized = false;

  constructor(
    private readonly startupContext: CodexTransportStartupContext,
    dependencies: CodexTransportDependencies = {},
  ) {
    this.dependencies = {
      spawnProcess: dependencies.spawnProcess ?? spawnCodexProcess,
    };
  }

  subscribe(listener: (event: CodexTransportEvent) => void): () => void {
    this.listeners.add(listener);

    return () => {
      this.listeners.delete(listener);
    };
  }

  async connect(): Promise<void> {
    if (this.process !== null) {
      return;
    }

    const executable = this.startupContext.executable;
    if (executable.status !== "found" || executable.resolvedPath === null) {
      throw new CodexTransportError(
        "provider_executable_missing",
        "Codex executable was not found before starting codex app-server.",
        {
          checkedPaths: executable.checkedPaths,
          source: executable.source,
          baseEnvironmentSource: executable.baseEnvironmentSource,
        },
      );
    }

    this.resetRuntimeState();

    try {
      this.process = this.dependencies.spawnProcess(
        executable.resolvedPath,
        this.startupContext.environment,
      );
    } catch (error) {
      this.process = null;
      throw new CodexTransportError(
        "startup_failed",
        `Unable to start codex app-server from ${executable.resolvedPath}.`,
        {
          executablePath: executable.resolvedPath,
          baseEnvironmentSource: executable.baseEnvironmentSource,
        },
        error,
      );
    }

    void this.readStdout(this.process.stdout);
    void this.readStderr(this.process.stderr);
    void this.watchProcessExit(this.process.exited);
  }

  async disconnect(reason: CodexTransportDisconnectReason = "requested_disconnect"): Promise<void> {
    if (this.process === null) {
      return;
    }

    const process = this.process;
    const writer = this.process.stdin;
    const disconnectInfo = buildDisconnectInfo(reason, null, this.stderrTail);

    this.finalizeDisconnect(disconnectInfo);

    if (writer !== null) {
      try {
        await writer.close();
      } catch {
        process.kill();
      }
    }

    const shutdownOutcome = await Promise.race([
      process.exited.then(() => "exited" as const),
      Bun.sleep(GRACEFUL_SHUTDOWN_TIMEOUT_MS).then(() => "timeout" as const),
    ]);

    if (shutdownOutcome === "timeout") {
      process.kill();
      await process.exited.catch(() => undefined);
    }
  }

  async send<TResult = unknown>(request: CodexTransportRequest): Promise<TResult> {
    if (this.process === null) {
      throw new CodexTransportError(
        "process_exited",
        "Codex transport is not connected.",
      );
    }

    const requestKey = requestIDKey(request.id);
    if (this.pendingRequests.has(requestKey)) {
      throw new CodexTransportError(
        "startup_failed",
        `Request ${String(request.id)} is already in flight.`,
      );
    }

    const encodedLine = encodeJSONLine(request);
    this.hasWrittenRequest = true;

    const responsePromise = new Promise<TResult>((resolve, reject) => {
      this.pendingRequests.set(requestKey, { resolve, reject });
    });

    try {
      await this.process.stdin.write(encodedLine);
    } catch (error) {
      this.pendingRequests.delete(requestKey);
      const transportError = new CodexTransportError(
        "process_exited",
        "Failed to write request to codex app-server.",
        {
          requestID: request.id,
        },
        error,
      );
      this.finalizeDisconnect(
        buildDisconnectInfo("process_exited", null, this.stderrTail, {
          requestID: request.id,
          writeFailed: true,
        }),
      );
      throw transportError;
    }

    return responsePromise;
  }

  async respond(response: CodexTransportResponse): Promise<void> {
    if (this.process === null) {
      throw new CodexTransportError(
        "process_exited",
        "Codex transport is not connected.",
      );
    }

    this.pendingServerRequests.delete(requestIDKey(response.id));

    try {
      await this.process.stdin.write(encodeJSONLine(response));
    } catch (error) {
      this.finalizeDisconnect(
        buildDisconnectInfo("process_exited", null, this.stderrTail, {
          requestID: response.id,
          writeFailed: true,
        }),
      );
      throw new CodexTransportError(
        "process_exited",
        "Failed to write a server-request response to codex app-server.",
        {
          requestID: response.id,
        },
        error,
      );
    }
  }

  private async readStdout(stdout: ReadableStream<Uint8Array>): Promise<void> {
    const reader = stdout.getReader();
    const decoder = new TextDecoder();

    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) {
          break;
        }

        this.sawProviderOutput = true;
        this.consumeStdoutText(decoder.decode(value, { stream: true }));
      }

      this.consumeStdoutText(decoder.decode());

      if (this.stdoutBuffer.trim().length > 0) {
        this.finalizeDisconnect(
          buildDisconnectInfo("malformed_output", null, this.stderrTail, {
            bufferedOutput: this.stdoutBuffer,
          }),
        );
      }
    } catch (error) {
      this.finalizeDisconnect(
        buildDisconnectInfo("malformed_output", null, this.stderrTail, {
          detail: "stdout_read_failed",
          error: error instanceof Error ? error.message : String(error),
        }),
      );
    } finally {
      reader.releaseLock();
    }
  }

  private async readStderr(stderr: ReadableStream<Uint8Array>): Promise<void> {
    const reader = stderr.getReader();
    const decoder = new TextDecoder();

    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) {
          break;
        }

        this.captureStderr(decoder.decode(value, { stream: true }));
      }

      this.captureStderr(decoder.decode());
    } finally {
      reader.releaseLock();
    }
  }

  private consumeStdoutText(chunk: string): void {
    this.stdoutBuffer += chunk;

    while (true) {
      const newlineIndex = this.stdoutBuffer.indexOf("\n");
      if (newlineIndex < 0) {
        break;
      }

      const line = this.stdoutBuffer.slice(0, newlineIndex).trim();
      this.stdoutBuffer = this.stdoutBuffer.slice(newlineIndex + 1);

      if (line.length === 0) {
        continue;
      }

      this.handleProviderLine(line);
    }
  }

  private handleProviderLine(line: string): void {
    let message: unknown;

    try {
      message = JSON.parse(line);
    } catch {
      this.finalizeDisconnect(
        buildDisconnectInfo("malformed_output", null, this.stderrTail, {
          line,
          detail: "json_parse_failed",
        }),
      );
      this.process?.kill();
      return;
    }

    if (!isPlainObject(message)) {
      this.finalizeDisconnect(
        buildDisconnectInfo("malformed_output", null, this.stderrTail, {
          line,
          detail: "json_message_not_object",
        }),
      );
      this.process?.kill();
      return;
    }

    if (isInboundRequest(message)) {
      const serverRequest: CodexTransportServerRequest = {
        id: message.id,
        method: message.method,
        params: message.params,
      };
      this.pendingServerRequests.set(requestIDKey(serverRequest.id), serverRequest);
      this.emit({
        type: "serverRequest",
        request: serverRequest,
      });
      return;
    }

    if (isInboundNotification(message)) {
      this.emit({
        type: "notification",
        notification: {
          method: message.method,
          params: message.params,
        },
      });
      return;
    }

    if (isInboundSuccessResponse(message)) {
      const requestKey = requestIDKey(message.id);
      const pendingRequest = this.pendingRequests.get(requestKey);

      if (!pendingRequest) {
        this.finalizeDisconnect(
          buildDisconnectInfo("malformed_output", null, this.stderrTail, {
            detail: "unknown_response_id",
            requestID: message.id,
          }),
        );
        this.process?.kill();
        return;
      }

      this.pendingRequests.delete(requestKey);
      pendingRequest.resolve(message.result);
      return;
    }

    if (isInboundErrorResponse(message)) {
      const requestKey = requestIDKey(message.id);
      const pendingRequest = this.pendingRequests.get(requestKey);

      if (!pendingRequest) {
        this.finalizeDisconnect(
          buildDisconnectInfo("malformed_output", null, this.stderrTail, {
            detail: "unknown_error_response_id",
            requestID: message.id,
          }),
        );
        this.process?.kill();
        return;
      }

      this.pendingRequests.delete(requestKey);
      pendingRequest.reject(
        new CodexTransportRemoteError(
          message.id,
          message.error.code,
          message.error.message,
          message.error.data,
        ),
      );
      return;
    }

    this.finalizeDisconnect(
      buildDisconnectInfo("malformed_output", null, this.stderrTail, {
        detail: "unrecognized_message_shape",
        line,
      }),
    );
    this.process?.kill();
  }

  private async watchProcessExit(exited: Promise<number>): Promise<void> {
    let exitCode: number;

    try {
      exitCode = await exited;
    } catch (error) {
      this.finalizeDisconnect(
        buildDisconnectInfo("process_exited", null, this.stderrTail, {
          detail: "process_wait_failed",
          error: error instanceof Error ? error.message : String(error),
        }),
      );
      return;
    }

    if (this.finalized) {
      return;
    }

    const reason: CodexTransportDisconnectReason =
      !this.sawProviderOutput && !this.hasWrittenRequest ? "startup_failed" : "process_exited";

    this.finalizeDisconnect(buildDisconnectInfo(reason, exitCode, this.stderrTail));
  }

  private finalizeDisconnect(disconnect: CodexTransportDisconnectInfo): void {
    if (this.finalized) {
      return;
    }

    this.finalized = true;

    const transportError = new CodexTransportError(
      disconnect.reason,
      disconnect.message,
      disconnect.detail,
    );

    for (const pendingRequest of this.pendingRequests.values()) {
      pendingRequest.reject(transportError);
    }

    this.pendingRequests.clear();
    this.pendingServerRequests.clear();
    this.process = null;
    this.stdoutBuffer = "";
    this.emit({
      type: "disconnect",
      disconnect,
    });
  }

  private captureStderr(chunk: string): void {
    if (chunk.length === 0) {
      return;
    }

    const combined = `${this.stderrTail}${chunk}`;
    this.stderrTail =
      combined.length > STDERR_TAIL_LIMIT
        ? combined.slice(combined.length - STDERR_TAIL_LIMIT)
        : combined;
  }

  private emit(event: CodexTransportEvent): void {
    for (const listener of this.listeners) {
      listener(event);
    }
  }

  private resetRuntimeState(): void {
    this.finalized = false;
    this.stdoutBuffer = "";
    this.stderrTail = "";
    this.sawProviderOutput = false;
    this.hasWrittenRequest = false;
    this.pendingRequests.clear();
    this.pendingServerRequests.clear();
  }
}

function spawnCodexProcess(
  executablePath: string,
  environment: Readonly<Record<string, string>>,
): CodexTransportProcess {
  const subprocess = Bun.spawn([executablePath, "app-server"], {
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
    env: environment,
  });

  if (subprocess.stdin === null || subprocess.stdout === null || subprocess.stderr === null) {
    subprocess.kill();
    throw new Error("codex app-server did not start with piped stdio.");
  }

  return {
    stdin: {
      write: async (chunk) => {
        subprocess.stdin.write(chunk);
      },
      close: async () => {
        subprocess.stdin.end();
      },
    },
    stdout: subprocess.stdout,
    stderr: subprocess.stderr,
    exited: subprocess.exited,
    kill: () => subprocess.kill(),
  };
}

function encodeJSONLine(payload: unknown): Uint8Array {
  return JSON_LINE_ENCODER.encode(`${JSON.stringify(payload)}\n`);
}

function requestIDKey(requestID: CodexTransportRequestID): string {
  return `${typeof requestID}:${String(requestID)}`;
}

function buildDisconnectInfo(
  reason: CodexTransportDisconnectReason,
  exitCode: number | null,
  stderrTail: string,
  detail?: Record<string, unknown>,
): CodexTransportDisconnectInfo {
  const stderr = stderrTail.trim();
  const mergedDetail = {
    ...(detail ?? {}),
    ...(stderr.length > 0 ? { stderr } : {}),
  };

  const messageByReason: Record<CodexTransportDisconnectReason, string> = {
    requested_disconnect: "Codex transport was disconnected by the bridge.",
    app_socket_disconnected: "Codex transport was disconnected because the app socket closed.",
    provider_executable_missing: "Codex executable was not available for transport startup.",
    startup_failed: "codex app-server exited before the transport became usable.",
    process_exited: "codex app-server exited while the transport was active.",
    malformed_output: "codex app-server emitted malformed JSONL output.",
  };

  return {
    reason,
    message: messageByReason[reason],
    exitCode,
    detail: Object.keys(mergedDetail).length > 0 ? mergedDetail : undefined,
  };
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isRequestID(value: unknown): value is CodexTransportRequestID {
  return typeof value === "string" || Number.isInteger(value);
}

function isInboundNotification(
  value: Record<string, unknown>,
): value is Record<string, unknown> & CodexTransportNotification {
  return typeof value.method === "string" && !("id" in value);
}

function isInboundRequest(
  value: Record<string, unknown>,
): value is Record<string, unknown> & CodexTransportServerRequest {
  return typeof value.method === "string" && isRequestID(value.id);
}

function isInboundSuccessResponse(
  value: Record<string, unknown>,
): value is Record<string, unknown> & CodexTransportSuccessResponse {
  return isRequestID(value.id) && "result" in value && !("method" in value) && !("error" in value);
}

function isInboundErrorResponse(
  value: Record<string, unknown>,
): value is Record<string, unknown> & CodexTransportErrorResponse {
  if (!isRequestID(value.id) || "method" in value || !isPlainObject(value.error)) {
    return false;
  }

  return typeof value.error.code === "number" && typeof value.error.message === "string";
}
