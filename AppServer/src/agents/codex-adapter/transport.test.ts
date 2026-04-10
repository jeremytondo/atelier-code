import { describe, expect, test } from "bun:test";
import {
  CodexAppServerTransport,
  type CodexTransportDisconnectInfo,
  CodexTransportError,
  type CodexTransportEvent,
  type CodexTransportProcess,
} from "@/agents/codex-adapter/transport";

const JSON_ENCODER = new TextEncoder();
const JSON_DECODER = new TextDecoder();

describe("CodexAppServerTransport", () => {
  test("correlates responses while forwarding interleaved notifications", async () => {
    const process = new FakeCodexProcess();
    const events: CodexTransportEvent[] = [];
    const transport = new CodexAppServerTransport(
      {
        executable: foundExecutable(),
        environment: baseEnvironment(),
      },
      {
        spawnProcess: () => process,
      },
    );

    transport.subscribe((event) => {
      events.push(event);
    });

    await transport.connect();

    const firstResponse = transport.send<{ threadId: string }>({
      id: "req-1",
      method: "thread/list",
    });
    const secondResponse = transport.send<{ turnId: string }>({
      id: "req-2",
      method: "turn/start",
    });

    process.emitStdout(
      '{"id":"req-1","result":{"threadId":"thread-1"}}\n{"method":"turn/started","params":{"threadId":"thread-1","turn":{"id":"turn-1","items":[],"status":"inProgress","error":null}}}\n{"id":"req-2"',
    );
    process.emitStdout(',"result":{"turnId":"turn-1"}}\n');

    await expect(firstResponse).resolves.toEqual({ threadId: "thread-1" });
    await expect(secondResponse).resolves.toEqual({ turnId: "turn-1" });

    expect(process.writes).toEqual([
      '{"id":"req-1","method":"thread/list"}\n',
      '{"id":"req-2","method":"turn/start"}\n',
    ]);
    expect(events).toContainEqual({
      type: "notification",
      notification: {
        method: "turn/started",
        params: {
          threadId: "thread-1",
          turn: {
            id: "turn-1",
            items: [],
            status: "inProgress",
            error: null,
          },
        },
      },
    });
  });

  test("forwards provider-initiated requests and writes jsonl replies", async () => {
    const process = new FakeCodexProcess();
    const events: CodexTransportEvent[] = [];
    const transport = new CodexAppServerTransport(
      {
        executable: foundExecutable(),
        environment: baseEnvironment(),
      },
      {
        spawnProcess: () => process,
      },
    );

    transport.subscribe((event) => {
      events.push(event);
    });

    await transport.connect();

    process.emitStdout(
      '{"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1"}}\n',
    );
    await Bun.sleep(0);

    expect(events).toContainEqual({
      type: "serverRequest",
      request: {
        id: "approval-1",
        method: "item/commandExecution/requestApproval",
        params: {
          threadId: "thread-1",
          turnId: "turn-1",
          itemId: "item-1",
        },
      },
    });

    await transport.respond({
      id: "approval-1",
      result: "accept",
    });

    expect(process.writes).toEqual(['{"id":"approval-1","result":"accept"}\n']);
  });

  test("treats malformed provider output as a transport failure", async () => {
    const process = new FakeCodexProcess();
    const disconnects: CodexTransportDisconnectInfo[] = [];
    const transport = new CodexAppServerTransport(
      {
        executable: foundExecutable(),
        environment: baseEnvironment(),
      },
      {
        spawnProcess: () => process,
      },
    );

    transport.subscribe((event) => {
      if (event.type === "disconnect") {
        disconnects.push(event.disconnect);
      }
    });

    await transport.connect();

    const pendingResponse = transport.send({
      id: "req-1",
      method: "thread/list",
    });

    process.emitStdout("this-is-not-json\n");
    process.exit(1);

    await expect(pendingResponse).rejects.toBeInstanceOf(CodexTransportError);
    expect(disconnects).toContainEqual(
      expect.objectContaining({
        reason: "malformed_output",
      }),
    );
    expect(process.killed).toBeTrue();
  });

  test("times out a hung request and tears down the transport", async () => {
    const process = new FakeCodexProcess();
    const disconnects: CodexTransportDisconnectInfo[] = [];
    const transport = new CodexAppServerTransport(
      {
        executable: foundExecutable(),
        environment: baseEnvironment(),
      },
      {
        requestTimeoutMs: 10,
        spawnProcess: () => process,
      },
    );

    transport.subscribe((event) => {
      if (event.type === "disconnect") {
        disconnects.push(event.disconnect);
      }
    });

    await transport.connect();

    const pendingResponse = transport.send({
      id: "req-timeout",
      method: "thread/list",
    });

    await expect(pendingResponse).rejects.toMatchObject({
      code: "request_timeout",
    });
    expect(disconnects).toContainEqual(
      expect.objectContaining({
        reason: "request_timeout",
        detail: expect.objectContaining({
          requestId: "req-timeout",
          method: "thread/list",
          timeoutMs: 10,
        }),
      }),
    );
    expect(process.killed).toBeTrue();
  });
});

class FakeCodexProcess implements CodexTransportProcess {
  readonly writes: string[] = [];
  readonly exited: Promise<number>;
  readonly stdout: ReadableStream<Uint8Array>;
  readonly stderr: ReadableStream<Uint8Array>;
  readonly stdin;

  private readonly stdoutPipe = new TransformStream<Uint8Array, Uint8Array>();
  private readonly stderrPipe = new TransformStream<Uint8Array, Uint8Array>();
  private readonly stdoutWriter = this.stdoutPipe.writable.getWriter();
  private readonly stderrWriter = this.stderrPipe.writable.getWriter();
  private resolveExit!: (code: number) => void;
  private exitCode = 0;

  killed = false;
  closed = false;

  constructor() {
    this.stdout = this.stdoutPipe.readable;
    this.stderr = this.stderrPipe.readable;
    this.stdin = {
      write: async (chunk: Uint8Array): Promise<void> => {
        this.writes.push(JSON_DECODER.decode(chunk));
      },
      close: async (): Promise<void> => {
        this.closed = true;
      },
    };
    this.exited = new Promise<number>((resolve) => {
      this.resolveExit = resolve;
    });
  }

  emitStdout(text: string): void {
    void this.stdoutWriter.write(JSON_ENCODER.encode(text));
  }

  emitStderr(text: string): void {
    void this.stderrWriter.write(JSON_ENCODER.encode(text));
  }

  exit(code = 0): void {
    if (this.killed) {
      return;
    }

    this.exitCode = code;
    this.killed = true;
    void this.stdoutWriter.close();
    void this.stderrWriter.close();
    this.resolveExit(this.exitCode);
  }

  kill(): void {
    this.exit(1);
  }
}

const foundExecutable = () => ({
  executableName: "codex",
  status: "found" as const,
  resolvedPath: "/opt/homebrew/bin/codex",
  source: "path" as const,
  baseEnvironmentSource: "login_probe" as const,
  checkedPaths: ["/opt/homebrew/bin/codex"],
});

const baseEnvironment = () => ({
  PATH: "/usr/bin:/bin",
  HOME: "/Users/tester",
});
