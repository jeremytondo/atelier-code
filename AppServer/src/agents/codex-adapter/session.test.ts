import { afterEach, describe, expect, test } from "bun:test";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { createCodexAgentSession } from "@/agents/codex-adapter/session";
import {
  type CodexTransport,
  CodexTransportError,
  type CodexTransportEvent,
  type CodexTransportNotification,
  type CodexTransportRequest,
  type CodexTransportResponse,
} from "@/agents/codex-adapter/transport";
import { BaseEnvironmentResolver } from "@/agents/environment";
import { createSilentLogger } from "@/test-support/logger";

const temporaryDirectories: string[] = [];

afterEach(() => {
  while (temporaryDirectories.length > 0) {
    const directory = temporaryDirectories.pop();
    if (directory !== undefined) {
      rmSync(directory, { recursive: true, force: true });
    }
  }
});

describe("createCodexAgentSession", () => {
  test("connects once, initializes once, and maps model/list results", async () => {
    const executablePath = createFakeExecutable();
    const transport = new FakeTransport([
      { userAgent: "Codex/Test" },
      {
        data: [
          {
            id: "gpt-5.4",
            model: "gpt-5.4",
            upgrade: null,
            upgradeInfo: null,
            availabilityNux: null,
            displayName: "GPT-5.4",
            description: "Latest model",
            hidden: false,
            supportedReasoningEfforts: [
              {
                reasoningEffort: "high",
                description: "More reasoning",
              },
            ],
            defaultReasoningEffort: "medium",
            inputModalities: ["text"],
            supportsPersonality: true,
            isDefault: true,
          },
        ],
        nextCursor: null,
      },
      {
        data: [],
        nextCursor: null,
      },
    ]);

    const sessionResult = await createCodexAgentSession({
      agentId: "codex",
      config: {
        id: "codex",
        provider: "codex",
      },
      logger: createSilentLogger(),
      transport,
      environmentResolver: new BaseEnvironmentResolver({
        inheritedEnvironment: {
          ATELIERCODE_CODEX_PATH: executablePath,
          PATH: path.dirname(executablePath),
          HOME: "/Users/tester",
          SHELL: "/bin/zsh",
        },
      }),
    });

    expect(sessionResult.ok).toBe(true);
    if (!sessionResult.ok) {
      throw new Error("Expected the Codex session to be created.");
    }

    const firstModels = await sessionResult.data.listModels("req-models-1", {
      limit: 20,
      includeHidden: false,
    });
    const secondModels = await sessionResult.data.listModels("req-models-2", {});

    expect(transport.connectCount).toBe(1);
    expect(transport.sent).toEqual([
      {
        id: "atelier-appserver-initialize",
        method: "initialize",
        params: {
          clientInfo: {
            name: "AtelierCode App Server",
            title: null,
            version: "0.1.0",
          },
          capabilities: {
            experimentalApi: true,
          },
        },
      },
      {
        id: "req-models-1",
        method: "model/list",
        params: {
          limit: 20,
          includeHidden: undefined,
        },
      },
      {
        id: "req-models-2",
        method: "model/list",
        params: {
          limit: undefined,
          includeHidden: undefined,
        },
      },
    ]);
    expect(transport.notified).toEqual([{ method: "initialized" }]);
    expect(firstModels).toEqual({
      ok: true,
      data: {
        models: [
          {
            id: "gpt-5.4",
            model: "gpt-5.4",
            displayName: "GPT-5.4",
            hidden: false,
            defaultReasoningEffort: "medium",
            supportedReasoningEfforts: [
              {
                reasoningEffort: "high",
                description: "More reasoning",
              },
            ],
            inputModalities: ["text"],
            supportsPersonality: true,
            isDefault: true,
          },
        ],
        nextCursor: null,
      },
    });
    expect(secondModels).toEqual({
      ok: true,
      data: {
        models: [],
        nextCursor: null,
      },
    });
  });

  test("translates approval requests and resolves them through provider responses", async () => {
    const executablePath = createFakeExecutable();
    const transport = new FakeTransport([{ userAgent: "Codex/Test" }]);
    const sessionResult = await createCodexAgentSession({
      agentId: "codex",
      config: {
        id: "codex",
        provider: "codex",
      },
      logger: createSilentLogger(),
      transport,
      environmentResolver: new BaseEnvironmentResolver({
        inheritedEnvironment: {
          ATELIERCODE_CODEX_PATH: executablePath,
          PATH: path.dirname(executablePath),
          HOME: "/Users/tester",
          SHELL: "/bin/zsh",
        },
      }),
    });

    expect(sessionResult.ok).toBe(true);
    if (!sessionResult.ok) {
      throw new Error("Expected the Codex session to be created.");
    }

    const notifications: unknown[] = [];
    sessionResult.data.subscribe((notification) => {
      notifications.push(notification);
    });

    await sessionResult.data.listModels("req-init", {});

    transport.emit({
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

    const resolveResult = await sessionResult.data.resolveApproval({
      requestId: "approval-1",
      resolution: "approved",
    });

    transport.emit({
      type: "notification",
      notification: {
        method: "serverRequest/resolved",
        params: {
          threadId: "thread-1",
          requestId: "approval-1",
        },
      },
    });

    expect(resolveResult).toEqual({
      ok: true,
      data: {
        requestId: "approval-1",
        resolution: "approved",
      },
    });
    expect(transport.responded).toEqual([
      {
        id: "approval-1",
        result: "accept",
      },
    ]);
    expect(notifications).toContainEqual(
      expect.objectContaining({
        type: "approval",
        event: "requested",
        requestId: "approval-1",
      }),
    );
    expect(notifications).toContainEqual(
      expect.objectContaining({
        type: "approval",
        event: "resolved",
        requestId: "approval-1",
        resolution: "approved",
      }),
    );
  });

  test("does not mark the session ready when transport disconnects during initialized notification", async () => {
    const executablePath = createFakeExecutable();
    const transport = new FakeTransport([{ userAgent: "Codex/Test" }], {
      onNotify: (notification, fakeTransport) => {
        if (notification.method !== "initialized") {
          return;
        }

        fakeTransport.emit({
          type: "disconnect",
          disconnect: {
            reason: "process_exited",
            message: "codex app-server exited while the transport was active.",
          },
        });
      },
    });
    const sessionResult = await createCodexAgentSession({
      agentId: "codex",
      config: {
        id: "codex",
        provider: "codex",
      },
      logger: createSilentLogger(),
      transport,
      environmentResolver: new BaseEnvironmentResolver({
        inheritedEnvironment: {
          ATELIERCODE_CODEX_PATH: executablePath,
          PATH: path.dirname(executablePath),
          HOME: "/Users/tester",
          SHELL: "/bin/zsh",
        },
      }),
    });

    expect(sessionResult.ok).toBe(true);
    if (!sessionResult.ok) {
      throw new Error("Expected the Codex session to be created.");
    }

    const initializationResult = await sessionResult.data.listModels("req-init", {});

    expect(initializationResult).toMatchObject({
      ok: false,
      error: {
        type: "sessionUnavailable",
        agentId: "codex",
        provider: "codex",
        code: "disconnected",
        message: "codex app-server exited while the transport was active.",
        executable: {
          executableName: "codex",
          resolvedPath: executablePath,
        },
        environment: {
          source: "login_probe",
        },
      },
    });
    expect(sessionResult.data.getState()).toBe("disconnected");
  });
});

type FakeTransportOptions = Readonly<{
  onNotify?: (notification: CodexTransportNotification, transport: FakeTransport) => void;
}>;

class FakeTransport implements CodexTransport {
  readonly sent: CodexTransportRequest[] = [];
  readonly notified: CodexTransportNotification[] = [];
  readonly responded: CodexTransportResponse[] = [];
  connectCount = 0;

  private readonly listeners = new Set<(event: CodexTransportEvent) => void>();
  private disconnected = false;

  constructor(
    private readonly responses: unknown[] = [],
    private readonly options: FakeTransportOptions = {},
  ) {}

  async connect(): Promise<void> {
    this.connectCount += 1;
    this.disconnected = false;
  }

  async disconnect(): Promise<void> {
    this.disconnected = true;
  }

  async send<TResult = unknown>(request: CodexTransportRequest): Promise<TResult> {
    if (this.disconnected) {
      throw new CodexTransportError("process_exited", "Codex transport is not connected.");
    }

    this.sent.push(request);
    const response = this.responses.shift();
    return response as TResult;
  }

  async notify(notification: CodexTransportNotification): Promise<void> {
    if (this.disconnected) {
      throw new CodexTransportError("process_exited", "Codex transport is not connected.");
    }

    this.notified.push(notification);
    this.options.onNotify?.(notification, this);
  }

  async respond(response: CodexTransportResponse): Promise<void> {
    if (this.disconnected) {
      throw new CodexTransportError("process_exited", "Codex transport is not connected.");
    }

    this.responded.push(response);
  }

  subscribe(listener: (event: CodexTransportEvent) => void): () => void {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  }

  emit(event: CodexTransportEvent): void {
    if (event.type === "disconnect") {
      this.disconnected = true;
    }

    for (const listener of this.listeners) {
      listener(event);
    }
  }
}

const createFakeExecutable = (): string => {
  const directory = mkdtempSync(path.join(os.tmpdir(), "atelier-appserver-codex-session-"));
  temporaryDirectories.push(directory);
  const executablePath = path.join(directory, "codex");
  writeFileSync(executablePath, "#!/bin/sh\nexit 0\n");
  chmodSync(executablePath, 0o755);
  return executablePath;
};
