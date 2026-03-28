import { describe, expect, test } from "bun:test";

import type {
  AccountLoginPayload,
  AccountReadPayload,
  ApprovalResolvePayload,
  BridgeEnvironmentDiagnostics,
  ModelListPayload,
  ThreadForkPayload,
  ThreadListPayload,
  ThreadRenamePayload,
  ThreadReadPayload,
  ThreadRollbackPayload,
  ThreadResumePayload,
  ThreadStartPayload,
  TurnStartPayload,
} from "./protocol/types";
import {
  buildProviderStatusEvent,
  buildWelcomeEnvelope,
  executeBridgeCommand,
} from "./index";
import { CODEX_PROVIDER_CAPABILITIES, CODEX_PROVIDER_ID } from "./codex/codex-client";
import type {
  CodexAccountReadResult,
  CodexClientAdapter,
  CodexLoginResult,
  CodexModelListResult,
  CodexThreadForkResult,
  CodexThreadListResult,
  CodexThreadRenameResult,
  CodexThreadReadResult,
  CodexThreadResumeResult,
  CodexThreadRollbackResult,
  CodexThreadStartResult,
  CodexTurnStartResult,
} from "./codex/codex-client";

describe("executeBridgeCommand", () => {
  test("emits direct thread and account result events", async () => {
    const client = new FakeCodexClient();

    const threadStarted = await executeBridgeCommand(connectedProviders(client), {
      id: "req-thread",
      type: "thread.start",
      timestamp: new Date().toISOString(),
      provider: "codex",
      payload: {
        workspacePath: "/tmp/project",
        title: "Phase 3",
      },
    });
    const threadList = await executeBridgeCommand(connectedProviders(client), {
      id: "req-list",
      type: "thread.list",
      timestamp: new Date().toISOString(),
      provider: "codex",
      payload: {
        workspacePath: "/tmp/project",
        limit: 10,
      },
    });
    const accountRead = await executeBridgeCommand(connectedProviders(client), {
      id: "req-account",
      type: "account.read",
      timestamp: new Date().toISOString(),
      provider: "codex",
      payload: {},
    });

    expect(threadStarted[0]).toEqual(
      expect.objectContaining({
        type: "thread.started",
        requestID: "req-thread",
        threadID: "thread-1",
        payload: {
          thread: expect.objectContaining({
            id: "thread-1",
            title: "Phase 3",
          }),
        },
      }),
    );
    expect(threadList[0]).toEqual(
      expect.objectContaining({
        type: "thread.list.result",
        requestID: "req-list",
        payload: {
          threads: [
            expect.objectContaining({
              id: "thread-1",
            }),
          ],
          nextCursor: "cursor-2",
        },
      }),
    );
    expect(accountRead).toEqual([
      expect.objectContaining({
        type: "auth.changed",
        requestID: "req-account",
      }),
      expect.objectContaining({
        type: "rateLimit.updated",
        requestID: "req-account",
      }),
    ]);
  });

  test("emits a model list result event for model discovery", async () => {
    const client = new FakeCodexClient();

    const events = await executeBridgeCommand(connectedProviders(client), {
      id: "req-models",
      type: "model.list",
      timestamp: new Date().toISOString(),
      provider: "codex",
      payload: {
        limit: 20,
        includeHidden: false,
      },
    });

    expect(events).toEqual([
      expect.objectContaining({
        type: "model.list.result",
        requestID: "req-models",
        payload: {
          models: [
            expect.objectContaining({
              id: "gpt-5.4",
              displayName: "GPT-5.4",
              isDefault: true,
            }),
          ],
        },
      }),
    ]);
  });

  test("emits a correlated turn started event for turn start commands", async () => {
    const client = new FakeCodexClient();

    const events = await executeBridgeCommand(connectedProviders(client), {
      id: "req-turn",
      type: "turn.start",
      timestamp: new Date().toISOString(),
      provider: "codex",
      threadID: "thread-1",
      payload: {
        prompt: "Ship it",
      },
    });

    expect(events).toEqual([
      expect.objectContaining({
        type: "turn.started",
        requestID: "req-turn",
        threadID: "thread-1",
        turnID: "turn-1",
      }),
    ]);
  });

  test("emits direct thread management events", async () => {
    const client = new FakeCodexClient();

    const readEvents = await executeBridgeCommand(connectedProviders(client), {
      id: "req-read",
      type: "thread.read",
      timestamp: new Date().toISOString(),
      provider: "codex",
      threadID: "thread-1",
      payload: {},
    });

    expect(readEvents).toEqual([
      expect.objectContaining({
        type: "thread.started",
        requestID: "req-read",
        threadID: "thread-1",
      }),
    ]);

    const renameEvents = await executeBridgeCommand(connectedProviders(client), {
      id: "req-rename",
      type: "thread.rename",
      timestamp: new Date().toISOString(),
      provider: "codex",
      threadID: "thread-1",
      payload: {
        title: "Renamed Thread",
      },
    });

    expect(renameEvents).toEqual([
      expect.objectContaining({
        type: "thread.started",
        requestID: "req-rename",
        threadID: "thread-1",
        payload: expect.objectContaining({
          thread: expect.objectContaining({
            title: "Renamed Thread",
          }),
        }),
      }),
    ]);
  });

  test("emits an approval resolved event after forwarding an approval decision", async () => {
    const client = new FakeCodexClient();

    const events = await executeBridgeCommand(connectedProviders(client), {
      id: "req-approval",
      type: "approval.resolve",
      timestamp: new Date().toISOString(),
      provider: "codex",
      threadID: "thread-1",
      turnID: "turn-1",
      payload: {
        approvalID: "approval-1",
        resolution: "approved",
      },
    });

    expect(events).toEqual([
      expect.objectContaining({
        type: "approval.resolved",
        requestID: "req-approval",
        threadID: "thread-1",
        turnID: "turn-1",
        payload: {
          approvalID: "approval-1",
          resolution: "approved",
        },
      }),
    ]);
  });

  test("preserves browser login handoff details in account login result events", async () => {
    const client = new FakeCodexClient();

    const loginEvents = await executeBridgeCommand(connectedProviders(client), {
      id: "req-login",
      type: "account.login",
      timestamp: new Date().toISOString(),
      provider: "codex",
      payload: {
        method: "chatgpt",
      },
    });

    expect(loginEvents).toEqual([
      expect.objectContaining({
        type: "account.login.result",
        requestID: "req-login",
        payload: {
          method: "chatgpt",
          authURL: "https://example.com",
          loginID: "login-1",
        },
      }),
    ]);
  });

  test("surfaces client failures as bridge errors", async () => {
    const client = new FailingCodexClient();

    const events = await executeBridgeCommand(connectedProviders(client), {
      id: "req-list",
      type: "thread.list",
      timestamp: new Date().toISOString(),
      provider: "codex",
      payload: {
        workspacePath: "/tmp/project",
      },
    });

    expect(events).toEqual([
      expect.objectContaining({
        type: "error",
        requestID: "req-list",
        payload: expect.objectContaining({
          code: "provider_command_failed",
        }),
      }),
    ]);
  });

  test("dispatches direct command results using the requested provider identity", async () => {
    const client = new FakeCodexClient("other");

    const events = await executeBridgeCommand(connectedProviders(client), {
      id: "req-thread",
      type: "thread.start",
      timestamp: new Date().toISOString(),
      provider: "other",
      payload: {
        workspacePath: "/tmp/project",
        title: "Other Provider",
      },
    });

    expect(events).toEqual([
      expect.objectContaining({
        type: "thread.started",
        provider: "other",
        payload: expect.objectContaining({
          thread: expect.objectContaining({
            providerID: "other",
          }),
        }),
      }),
    ]);
  });

  test("returns a provider-not-ready error when the requested provider is disconnected", async () => {
    const events = await executeBridgeCommand({}, {
      id: "req-thread",
      type: "thread.start",
      timestamp: new Date().toISOString(),
      provider: "codex",
      payload: {
        workspacePath: "/tmp/project",
      },
    });

    expect(events).toEqual([
      expect.objectContaining({
        type: "error",
        requestID: "req-thread",
        provider: "codex",
        payload: expect.objectContaining({
          code: "provider_not_ready",
        }),
      }),
    ]);
  });
});

describe("bridge startup diagnostics", () => {
  test("includes environment diagnostics in welcome payloads", () => {
    const environment: BridgeEnvironmentDiagnostics = {
      source: "login_probe",
      shellPath: "/bin/zsh",
      probeError: null,
      pathDirectoryCount: 6,
      homeDirectory: "/Users/tester",
    };

    const welcome = buildWelcomeEnvelope(
      "hello-1",
      "session-1",
      1,
      [
        {
          id: "codex",
          displayName: "Codex",
          status: "available",
          capabilities: CODEX_PROVIDER_CAPABILITIES,
        },
      ],
      environment,
    );

    expect(welcome).toEqual(
      expect.objectContaining({
        type: "welcome",
        requestID: "hello-1",
        payload: expect.objectContaining({
          sessionID: "session-1",
          environment,
        }),
      }),
    );
  });

  test("includes executable and environment diagnostics in provider status events", () => {
    const status = buildProviderStatusEvent("codex", "ready", "Codex is ready.", {
      executablePath: "/opt/homebrew/bin/codex",
      environment: {
        source: "fallback",
        shellPath: "/bin/zsh",
        probeError: "timed out",
        pathDirectoryCount: 3,
        homeDirectory: "/Users/tester",
      },
    });

    expect(status).toEqual(
      expect.objectContaining({
        type: "provider.status",
        payload: {
          status: "ready",
          detail: "Codex is ready.",
          executablePath: "/opt/homebrew/bin/codex",
          environment: {
            source: "fallback",
            shellPath: "/bin/zsh",
            probeError: "timed out",
            pathDirectoryCount: 3,
            homeDirectory: "/Users/tester",
          },
        },
      }),
    );
  });
});

class FakeCodexClient implements CodexClientAdapter {
  readonly providerID: string;
  readonly capabilities = CODEX_PROVIDER_CAPABILITIES;

  constructor(providerID = CODEX_PROVIDER_ID) {
    this.providerID = providerID;
  }

  async connect(): Promise<void> {}

  async disconnect(): Promise<void> {}

  async listModels(_requestID: string, _payload: ModelListPayload): Promise<CodexModelListResult> {
    return {
      models: [
        {
          id: "gpt-5.4",
          model: "gpt-5.4",
          displayName: "GPT-5.4",
          hidden: false,
          defaultReasoningEffort: "medium",
          supportedReasoningEfforts: [
            { reasoningEffort: "low", description: "Lower latency" },
            { reasoningEffort: "medium", description: "Balanced" },
            { reasoningEffort: "high", description: "More reasoning" },
          ],
          inputModalities: ["text", "image"],
          supportsPersonality: true,
          isDefault: true,
        },
      ],
    };
  }

  async startThread(_requestID: string, payload: ThreadStartPayload): Promise<CodexThreadStartResult> {
    return {
      thread: {
        id: "thread-1",
        preview: payload.title ?? "Preview",
        updatedAt: 1_700_000_000,
        name: payload.title ?? null,
        status: { type: "idle" },
        turns: [],
        archived: false,
      },
      defaults: null,
    };
  }

  async resumeThread(
    _requestID: string,
    threadID: string,
    _payload: ThreadResumePayload,
  ): Promise<CodexThreadResumeResult> {
    return {
      thread: {
        id: threadID,
        preview: "Preview",
        updatedAt: 1_700_000_000,
        name: "Resumed",
        status: { type: "idle" },
        turns: [],
        archived: false,
      },
      defaults: null,
    };
  }

  async readThread(
    _requestID: string,
    threadID: string,
    _payload: ThreadReadPayload,
  ): Promise<CodexThreadReadResult> {
    return {
      thread: {
        id: threadID,
        preview: "Read preview",
        updatedAt: 1_700_000_001,
        name: "Read Thread",
        status: { type: "idle" },
        turns: [],
        archived: false,
      },
      defaults: null,
    };
  }

  async forkThread(
    _requestID: string,
    threadID: string,
    _payload: ThreadForkPayload,
  ): Promise<CodexThreadForkResult> {
    return {
      thread: {
        id: `${threadID}-fork`,
        preview: "Fork preview",
        updatedAt: 1_700_000_002,
        name: "Forked Thread",
        status: { type: "idle" },
        turns: [],
        archived: false,
      },
      defaults: null,
    };
  }

  async renameThread(
    _requestID: string,
    threadID: string,
    payload: ThreadRenamePayload,
  ): Promise<CodexThreadRenameResult> {
    return {
      thread: {
        id: threadID,
        preview: "Renamed preview",
        updatedAt: 1_700_000_005,
        name: payload.title,
        status: { type: "idle" },
        turns: [],
        archived: false,
      },
      defaults: null,
    };
  }

  async rollbackThread(
    _requestID: string,
    threadID: string,
    _payload: ThreadRollbackPayload,
  ): Promise<CodexThreadRollbackResult> {
    return {
      thread: {
        id: threadID,
        preview: "Rolled back preview",
        updatedAt: 1_700_000_004,
        name: "Rolled Back Thread",
        status: { type: "idle" },
        turns: [],
        archived: false,
      },
      defaults: null,
    };
  }

  async listThreads(_requestID: string, _payload: ThreadListPayload): Promise<CodexThreadListResult> {
    return {
      threads: [
        {
          id: "thread-1",
          preview: "Preview",
          updatedAt: 1_700_000_000,
          name: "Phase 3",
          status: { type: "idle" },
          turns: [],
          archived: false,
        },
      ],
      nextCursor: "cursor-2",
    };
  }

  async startTurn(
    _requestID: string,
    _threadID: string,
    _payload: TurnStartPayload,
  ): Promise<CodexTurnStartResult> {
    return { turnID: "turn-1" };
  }

  async cancelTurn(_requestID: string, _threadID: string, _turnID: string): Promise<void> {}

  async resolveApproval(_approvalID: string, _payload: ApprovalResolvePayload): Promise<void> {}

  async readAccount(
    _requestID: string,
    _payload: AccountReadPayload,
  ): Promise<CodexAccountReadResult> {
    return {
      account: {
        type: "chatgpt",
        email: "person@example.com",
        planType: "pro",
      },
      requiresOpenAIAuth: false,
      rateLimits: {
        limitId: "requests",
        limitName: "Requests",
        primary: {
          usedPercent: 10,
          windowDurationMins: 60,
          resetsAt: 1_700_000_100,
        },
        secondary: null,
        credits: null,
        planType: "pro",
      },
    };
  }

  async login(_requestID: string, _payload: AccountLoginPayload): Promise<CodexLoginResult> {
    return { type: "chatgpt", authURL: "https://example.com", loginID: "login-1" };
  }

  async logout(_requestID: string): Promise<void> {}
}

class FailingCodexClient extends FakeCodexClient {
  override async listThreads(): Promise<CodexThreadListResult> {
    throw new Error("boom");
  }
}

function connectedProviders(client: CodexClientAdapter): Parameters<typeof executeBridgeCommand>[0] {
  return {
    [client.providerID]: {
      client,
    },
  } as Parameters<typeof executeBridgeCommand>[0];
}
