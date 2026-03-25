import { describe, expect, test } from "bun:test";

import type {
  AccountLoginPayload,
  AccountReadPayload,
  ApprovalResolvePayload,
  ThreadArchivePayload,
  ThreadForkPayload,
  ThreadListPayload,
  ThreadReadPayload,
  ThreadRollbackPayload,
  ThreadResumePayload,
  ThreadStartPayload,
  ThreadUnarchivePayload,
  TurnStartPayload,
} from "./protocol/types";
import { executeBridgeCommand } from "./index";
import type {
  CodexAccountReadResult,
  CodexClientAdapter,
  CodexLoginResult,
  CodexThreadForkResult,
  CodexThreadListResult,
  CodexThreadReadResult,
  CodexThreadResumeResult,
  CodexThreadRollbackResult,
  CodexThreadStartResult,
  CodexThreadUnarchiveResult,
  CodexTurnStartResult,
} from "./codex/codex-client";

describe("executeBridgeCommand", () => {
  test("emits direct thread and account result events", async () => {
    const client = new FakeCodexClient();

    const threadStarted = await executeBridgeCommand(client, {
      id: "req-thread",
      type: "thread.start",
      timestamp: new Date().toISOString(),
      provider: "codex",
      payload: {
        workspacePath: "/tmp/project",
        title: "Phase 3",
      },
    });
    const threadList = await executeBridgeCommand(client, {
      id: "req-list",
      type: "thread.list",
      timestamp: new Date().toISOString(),
      provider: "codex",
      payload: {
        workspacePath: "/tmp/project",
        limit: 10,
      },
    });
    const accountRead = await executeBridgeCommand(client, {
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

  test("emits a correlated turn started event for turn start commands", async () => {
    const client = new FakeCodexClient();

    const events = await executeBridgeCommand(client, {
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

    const readEvents = await executeBridgeCommand(client, {
      id: "req-read",
      type: "thread.read",
      timestamp: new Date().toISOString(),
      provider: "codex",
      threadID: "thread-1",
      payload: {},
    });
    const archiveEvents = await executeBridgeCommand(client, {
      id: "req-archive",
      type: "thread.archive",
      timestamp: new Date().toISOString(),
      provider: "codex",
      threadID: "thread-1",
      payload: {},
    });
    const unarchiveEvents = await executeBridgeCommand(client, {
      id: "req-unarchive",
      type: "thread.unarchive",
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
    expect(archiveEvents).toEqual([
      expect.objectContaining({
        type: "thread.archived",
        requestID: "req-archive",
        threadID: "thread-1",
      }),
    ]);
    expect(unarchiveEvents).toEqual([
      expect.objectContaining({
        type: "thread.started",
        requestID: "req-unarchive",
        threadID: "thread-1",
      }),
    ]);
  });

  test("emits an approval resolved event after forwarding an approval decision", async () => {
    const client = new FakeCodexClient();

    const events = await executeBridgeCommand(client, {
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

    const loginEvents = await executeBridgeCommand(client, {
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

    const events = await executeBridgeCommand(client, {
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
});

class FakeCodexClient implements CodexClientAdapter {
  async connect(): Promise<void> {}

  async disconnect(): Promise<void> {}

  async startThread(_requestID: string, payload: ThreadStartPayload): Promise<CodexThreadStartResult> {
    return {
      thread: {
        id: "thread-1",
        preview: payload.title ?? "Preview",
        updatedAt: 1_700_000_000,
        name: payload.title ?? null,
        status: { type: "idle" },
        turns: [],
      },
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
      },
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
      },
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
      },
    };
  }

  async archiveThread(
    _requestID: string,
    _threadID: string,
    _payload: ThreadArchivePayload,
  ): Promise<void> {}

  async unarchiveThread(
    _requestID: string,
    threadID: string,
    _payload: ThreadUnarchivePayload,
  ): Promise<CodexThreadUnarchiveResult> {
    return {
      thread: {
        id: threadID,
        preview: "Unarchived preview",
        updatedAt: 1_700_000_003,
        name: "Unarchived Thread",
        status: { type: "idle" },
        turns: [],
      },
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
      },
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
