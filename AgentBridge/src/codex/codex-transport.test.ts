import { describe, expect, test } from "bun:test";

import {
  CodexAppServerTransport,
  CodexTransportError,
  type CodexTransportDisconnectInfo,
  type CodexTransportEvent,
  type CodexTransportProcess,
} from "./codex-transport";

const JSON_ENCODER = new TextEncoder();
const JSON_DECODER = new TextDecoder();

describe("CodexAppServerTransport", () => {
  test("correlates responses while forwarding interleaved notifications", async () => {
    const process = new FakeCodexProcess();
    const events: CodexTransportEvent[] = [];
    const transport = new CodexAppServerTransport({
      discoverExecutable: async () => foundExecutable(),
      spawnProcess: () => process,
    });

    transport.subscribe((event) => {
      events.push(event);
    });

    await transport.connect();

    const firstResponse = transport.send<{ threadID: string }>({
      id: "req-1",
      method: "thread/list",
    });
    const secondResponse = transport.send<{ turnID: string }>({
      id: "req-2",
      method: "turn/start",
    });

    process.emitStdout(
      '{"id":"req-1","result":{"threadID":"thread-1"}}\n{"method":"turn/started","params":{"threadId":"thread-1","turnId":"turn-1"}}\n{"id":"req-2"',
    );
    process.emitStdout(',"result":{"turnID":"turn-1"}}\n');

    await expect(firstResponse).resolves.toEqual({ threadID: "thread-1" });
    await expect(secondResponse).resolves.toEqual({ turnID: "turn-1" });

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
          turnId: "turn-1",
        },
      },
    });
  });

  test("forwards provider-initiated requests and writes JSONL replies", async () => {
    const process = new FakeCodexProcess();
    const events: CodexTransportEvent[] = [];
    const transport = new CodexAppServerTransport({
      discoverExecutable: async () => foundExecutable(),
      spawnProcess: () => process,
    });

    transport.subscribe((event) => {
      events.push(event);
    });

    await transport.connect();

    process.emitStdout(
      '{"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"command":["git","status"]}}\n',
    );
    await Bun.sleep(0);

    expect(events).toContainEqual({
      type: "serverRequest",
      request: {
        id: "approval-1",
        method: "item/commandExecution/requestApproval",
        params: {
          command: ["git", "status"],
        },
      },
    });

    await transport.respond({
      id: "approval-1",
      result: {
        decision: "approved",
      },
    });

    expect(process.writes).toEqual([
      '{"id":"approval-1","result":{"decision":"approved"}}\n',
    ]);
  });

  test("treats malformed provider output as a transport failure", async () => {
    const process = new FakeCodexProcess();
    const disconnects: CodexTransportDisconnectInfo[] = [];
    const transport = new CodexAppServerTransport({
      discoverExecutable: async () => foundExecutable(),
      spawnProcess: () => process,
    });

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
});

class FakeCodexProcess implements CodexTransportProcess {
  readonly writes: string[] = [];
  readonly exited: Promise<number>;
  private readonly stdoutPipe = new TransformStream<Uint8Array, Uint8Array>();
  private readonly stderrPipe = new TransformStream<Uint8Array, Uint8Array>();
  private readonly stdoutWriter = this.stdoutPipe.writable.getWriter();
  private readonly stderrWriter = this.stderrPipe.writable.getWriter();

  readonly stdin = {
    write: async (chunk: Uint8Array): Promise<void> => {
      this.writes.push(JSON_DECODER.decode(chunk));
    },
    close: async (): Promise<void> => {
      this.closed = true;
    },
  };

  readonly stdout = this.stdoutPipe.readable;
  readonly stderr = this.stderrPipe.readable;

  killed = false;
  closed = false;

  private exitCode = 0;
  private resolveExit!: (code: number) => void;

  constructor() {
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

function foundExecutable() {
  return {
    executableName: "codex",
    status: "found" as const,
    resolvedPath: "/opt/homebrew/bin/codex",
    source: "path" as const,
    checkedPaths: ["/opt/homebrew/bin/codex"],
  };
}
