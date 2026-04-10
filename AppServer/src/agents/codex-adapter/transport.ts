import type { AgentDisconnectReason, AgentExecutableDiscovery } from "@/agents/contracts";

const JSON_LINE_ENCODER = new TextEncoder();
const STDERR_TAIL_LIMIT = 4_096;
const GRACEFUL_SHUTDOWN_TIMEOUT_MS = 250;
const DEFAULT_REQUEST_TIMEOUT_MS = 30_000;

export type CodexTransportRequestId = string | number;

export type CodexTransportRequest<TParams = unknown> = Readonly<{
  id: CodexTransportRequestId;
  method: string;
  params?: TParams;
}>;

export type CodexTransportNotification<TParams = unknown> = Readonly<{
  method: string;
  params?: TParams;
}>;

export type CodexTransportServerRequest<TParams = unknown> = CodexTransportRequest<TParams>;

export type CodexTransportSuccessResponse<TResult = unknown> = Readonly<{
  id: CodexTransportRequestId;
  result: TResult;
}>;

export type CodexTransportErrorObject = Readonly<{
  code: number;
  message: string;
  data?: unknown;
}>;

export type CodexTransportErrorResponse = Readonly<{
  id: CodexTransportRequestId;
  error: CodexTransportErrorObject;
}>;

export type CodexTransportResponse<TResult = unknown> =
  | CodexTransportSuccessResponse<TResult>
  | CodexTransportErrorResponse;

export type CodexTransportDisconnectInfo = Readonly<{
  reason: AgentDisconnectReason;
  message: string;
  exitCode?: number | null;
  detail?: Record<string, unknown>;
}>;

export type CodexTransportEvent =
  | Readonly<{
      type: "notification";
      notification: CodexTransportNotification;
    }>
  | Readonly<{
      type: "serverRequest";
      request: CodexTransportServerRequest;
    }>
  | Readonly<{
      type: "disconnect";
      disconnect: CodexTransportDisconnectInfo;
    }>;

export type CodexTransportInput = Readonly<{
  write: (chunk: Uint8Array) => Promise<void>;
  close: () => Promise<void>;
}>;

export type CodexTransportProcess = Readonly<{
  stdin: CodexTransportInput;
  stdout: ReadableStream<Uint8Array>;
  stderr: ReadableStream<Uint8Array>;
  exited: Promise<number>;
  kill: () => void;
}>;

export type CodexTransportDependencies = Readonly<{
  requestTimeoutMs?: number;
  spawnProcess?: (
    executablePath: string,
    environment: Readonly<Record<string, string>>,
  ) => CodexTransportProcess;
}>;

export type CodexTransportStartupContext = Readonly<{
  executable: AgentExecutableDiscovery;
  environment: Readonly<Record<string, string>>;
}>;

export type CodexTransport = Readonly<{
  connect: () => Promise<void>;
  disconnect: (reason?: AgentDisconnectReason) => Promise<void>;
  send: <TResult = unknown>(request: CodexTransportRequest) => Promise<TResult>;
  notify: (notification: CodexTransportNotification) => Promise<void>;
  respond: (response: CodexTransportResponse) => Promise<void>;
  subscribe: (listener: (event: CodexTransportEvent) => void) => () => void;
}>;

type PendingRequest = Readonly<{
  resolve: (value: unknown) => void;
  reject: (error: unknown) => void;
}>;

export class CodexTransportError extends Error {
  constructor(
    readonly code: AgentDisconnectReason,
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
    readonly requestId: CodexTransportRequestId,
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
      requestTimeoutMs: dependencies.requestTimeoutMs ?? DEFAULT_REQUEST_TIMEOUT_MS,
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

  async disconnect(reason: AgentDisconnectReason = "requested_disconnect"): Promise<void> {
    if (this.process === null) {
      return;
    }

    const process = this.process;
    const writer = process.stdin;
    this.finalizeDisconnect(buildDisconnectInfo(reason, null, this.stderrTail));

    try {
      await writer.close();
    } catch {
      process.kill();
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
      throw new CodexTransportError("process_exited", "Codex transport is not connected.");
    }

    const requestKey = requestIdKey(request.id);
    if (this.pendingRequests.has(requestKey)) {
      throw new CodexTransportError(
        "startup_failed",
        `Request ${String(request.id)} is already in flight.`,
      );
    }

    this.hasWrittenRequest = true;
    const responsePromise = new Promise<unknown>((resolve, reject) => {
      this.pendingRequests.set(requestKey, { resolve, reject });
    });

    try {
      await this.process.stdin.write(encodeJsonLine(request));
    } catch (error) {
      this.pendingRequests.delete(requestKey);
      this.finalizeDisconnect(
        buildDisconnectInfo("process_exited", null, this.stderrTail, {
          requestId: request.id,
          writeFailed: true,
        }),
      );
      throw new CodexTransportError(
        "process_exited",
        "Failed to write request to codex app-server.",
        { requestId: request.id },
        error,
      );
    }

    return Promise.race([
      responsePromise as Promise<TResult>,
      this.createRequestTimeoutPromise<TResult>(request, requestKey, responsePromise),
    ]);
  }

  async respond(response: CodexTransportResponse): Promise<void> {
    if (this.process === null) {
      throw new CodexTransportError("process_exited", "Codex transport is not connected.");
    }

    try {
      await this.process.stdin.write(encodeJsonLine(response));
      this.pendingServerRequests.delete(requestIdKey(response.id));
    } catch (error) {
      this.finalizeDisconnect(
        buildDisconnectInfo("process_exited", null, this.stderrTail, {
          requestId: response.id,
          writeFailed: true,
        }),
      );
      throw new CodexTransportError(
        "process_exited",
        "Failed to write a server-request response to codex app-server.",
        { requestId: response.id },
        error,
      );
    }
  }

  async notify(notification: CodexTransportNotification): Promise<void> {
    if (this.process === null) {
      throw new CodexTransportError("process_exited", "Codex transport is not connected.");
    }

    try {
      await this.process.stdin.write(encodeJsonLine(notification));
    } catch (error) {
      this.finalizeDisconnect(
        buildDisconnectInfo("process_exited", null, this.stderrTail, {
          method: notification.method,
          writeFailed: true,
        }),
      );
      throw new CodexTransportError(
        "process_exited",
        "Failed to write a notification to codex app-server.",
        { method: notification.method },
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
      message = JSON.parse(line) as unknown;
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
      const serverRequest = {
        id: message.id,
        method: message.method,
        params: message.params,
      };
      this.pendingServerRequests.set(requestIdKey(serverRequest.id), serverRequest);
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
      const pendingRequest = this.pendingRequests.get(requestIdKey(message.id));
      if (pendingRequest === undefined) {
        this.finalizeDisconnect(
          buildDisconnectInfo("malformed_output", null, this.stderrTail, {
            detail: "unknown_response_id",
            requestId: message.id,
          }),
        );
        this.process?.kill();
        return;
      }

      this.pendingRequests.delete(requestIdKey(message.id));
      pendingRequest.resolve(message.result);
      return;
    }

    if (isInboundErrorResponse(message)) {
      const pendingRequest = this.pendingRequests.get(requestIdKey(message.id));
      if (pendingRequest === undefined) {
        this.finalizeDisconnect(
          buildDisconnectInfo("malformed_output", null, this.stderrTail, {
            detail: "unknown_error_response_id",
            requestId: message.id,
          }),
        );
        this.process?.kill();
        return;
      }

      this.pendingRequests.delete(requestIdKey(message.id));
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

    const reason =
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

  private createRequestTimeoutPromise<TResult>(
    request: CodexTransportRequest,
    requestKey: string,
    responsePromise: Promise<unknown>,
  ): Promise<TResult> {
    return new Promise<TResult>((_, reject) => {
      const timer = setTimeout(() => {
        if (!this.pendingRequests.has(requestKey) || this.finalized) {
          return;
        }

        const process = this.process;
        const disconnect = buildDisconnectInfo("request_timeout", null, this.stderrTail, {
          requestId: request.id,
          method: request.method,
          timeoutMs: this.dependencies.requestTimeoutMs,
        });

        this.finalizeDisconnect(disconnect);
        process?.kill();
        reject(new CodexTransportError(disconnect.reason, disconnect.message, disconnect.detail));
      }, this.dependencies.requestTimeoutMs);

      void responsePromise.then(
        () => {
          clearTimeout(timer);
        },
        () => {
          clearTimeout(timer);
        },
      );
    });
  }
}

const spawnCodexProcess = (
  executablePath: string,
  environment: Readonly<Record<string, string>>,
): CodexTransportProcess => {
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
};

const encodeJsonLine = (payload: unknown): Uint8Array =>
  JSON_LINE_ENCODER.encode(`${JSON.stringify(payload)}\n`);

const requestIdKey = (requestId: CodexTransportRequestId): string =>
  `${typeof requestId}:${String(requestId)}`;

const buildDisconnectInfo = (
  reason: AgentDisconnectReason,
  exitCode: number | null,
  stderrTail: string,
  detail?: Record<string, unknown>,
): CodexTransportDisconnectInfo => {
  const stderr = stderrTail.trim();
  const mergedDetail = {
    ...(detail ?? {}),
    ...(stderr.length > 0 ? { stderr } : {}),
  };

  const messageByReason: Record<AgentDisconnectReason, string> = {
    requested_disconnect: "Codex transport was disconnected by the App Server.",
    app_socket_disconnected: "Codex transport was disconnected because the app socket closed.",
    provider_executable_missing: "Codex executable was not available for transport startup.",
    startup_failed: "codex app-server exited before the transport became usable.",
    process_exited: "codex app-server exited while the transport was active.",
    request_timeout: "codex app-server did not respond before the request timeout expired.",
    malformed_output: "codex app-server emitted malformed JSONL output.",
  };

  return {
    reason,
    message: messageByReason[reason],
    exitCode,
    detail: Object.keys(mergedDetail).length > 0 ? mergedDetail : undefined,
  };
};

const isPlainObject = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

const isRequestId = (value: unknown): value is CodexTransportRequestId =>
  typeof value === "string" || Number.isInteger(value);

const isInboundNotification = (
  value: Record<string, unknown>,
): value is Record<string, unknown> & CodexTransportNotification =>
  typeof value.method === "string" && !("id" in value);

const isInboundRequest = (
  value: Record<string, unknown>,
): value is Record<string, unknown> & CodexTransportServerRequest =>
  typeof value.method === "string" && isRequestId(value.id);

const isInboundSuccessResponse = (
  value: Record<string, unknown>,
): value is Record<string, unknown> & CodexTransportSuccessResponse =>
  isRequestId(value.id) && "result" in value && !("method" in value) && !("error" in value);

const isInboundErrorResponse = (
  value: Record<string, unknown>,
): value is Record<string, unknown> & CodexTransportErrorResponse => {
  if (!isRequestId(value.id) || "method" in value || !isPlainObject(value.error)) {
    return false;
  }

  return typeof value.error.code === "number" && typeof value.error.message === "string";
};
