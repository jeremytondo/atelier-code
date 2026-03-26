import { describe, expect, test } from "bun:test";

import { CodexClient } from "./codex-client";
import type {
  CodexTransport,
  CodexTransportEvent,
  CodexTransportRequest,
  CodexTransportResponse,
} from "./codex-transport";

describe("CodexClient", () => {
  test("initializes once and maps thread start plus naming", async () => {
    const transport = new FakeTransport([
      { userAgent: "Codex/Test" },
      {
        thread: {
          id: "thread-1",
          preview: "Preview text",
          updatedAt: 1_700_000_000,
          name: null,
        },
      },
      {},
    ]);
    const client = new CodexClient(transport);

    await client.connect();
    await client.connect();

    const result = await client.startThread("req-1", {
      workspacePath: "/tmp/project",
      title: "New Thread",
    });

    expect(result.thread).toEqual({
      id: "thread-1",
      preview: "Preview text",
      updatedAt: 1_700_000_000,
      name: "New Thread",
      status: undefined,
      turns: [],
      archived: false,
    });
    expect(transport.sent).toEqual([
      {
        id: "ateliercode-initialize",
        method: "initialize",
        params: {
          clientInfo: {
            name: "AtelierCode AgentBridge",
            version: "0.1.0",
          },
          capabilities: {
            experimentalApi: true,
          },
        },
      },
      {
        id: "req-1",
        method: "thread/start",
        params: {
          cwd: "/tmp/project",
          experimentalRawEvents: false,
          persistExtendedHistory: true,
        },
      },
      {
        id: "req-1:set-name",
        method: "thread/name/set",
        params: {
          threadId: "thread-1",
          name: "New Thread",
        },
      },
    ]);
  });

  test("renames a thread and rereads it for the updated summary", async () => {
    const transport = new FakeTransport([
      { userAgent: "Codex/Test" },
      {},
      {
        thread: {
          id: "thread-1",
          preview: "Renamed preview",
          updatedAt: 1_700_000_010,
          name: "Renamed Thread",
        },
      },
    ]);
    const client = new CodexClient(transport);

    await client.connect();
    const result = await client.renameThread("req-rename", "thread-1", {
      title: "  Renamed Thread  ",
    });

    expect(result.thread).toEqual({
      id: "thread-1",
      preview: "Renamed preview",
      updatedAt: 1_700_000_010,
      name: "Renamed Thread",
      status: undefined,
      turns: [],
      archived: false,
    });
    expect(transport.sent.slice(1)).toEqual([
      {
        id: "req-rename:set-name",
        method: "thread/name/set",
        params: {
          threadId: "thread-1",
          name: "Renamed Thread",
        },
      },
      {
        id: "req-rename",
        method: "thread/read",
        params: {
          threadId: "thread-1",
        },
      },
    ]);
  });

  test("maps turn interruption approval resolution and account reads", async () => {
    const transport = new FakeTransport([
      { userAgent: "Codex/Test" },
      { turn: { id: "turn-1" } },
      {},
      {
        account: {
          type: "chatgpt",
          email: "person@example.com",
          planType: "pro",
        },
        requiresOpenaiAuth: false,
      },
      {
        rateLimits: {
          limitId: "limit-1",
          limitName: "Requests",
          primary: {
            usedPercent: 42,
            windowDurationMins: 60,
            resetsAt: 1_700_000_100,
          },
          secondary: null,
          credits: null,
          planType: "pro",
        },
      },
    ]);
    const client = new CodexClient(transport);

    await client.connect();
    const turn = await client.startTurn("req-turn", "thread-1", {
      prompt: "Ship it",
      configuration: {
        cwd: "/tmp/project",
        approvalPolicy: "on-request",
        sandboxPolicy: "workspace-write",
        reasoningEffort: "high",
        summaryMode: "concise",
        environment: {
          FOO: "bar",
        },
      },
    });
    await client.cancelTurn("req-cancel", "thread-1", "turn-1");
    await client.resolveApproval("approval-1", {
      approvalID: "approval-1",
      resolution: "approved",
    });
    const account = await client.readAccount("req-account", {});

    expect(turn.turnID).toBe("turn-1");
    expect(account.account).toEqual({
      type: "chatgpt",
      email: "person@example.com",
      planType: "pro",
    });
    expect(account.rateLimits?.primary?.usedPercent).toBe(42);
    expect(transport.sent.slice(1)).toEqual([
      {
        id: "req-turn",
        method: "turn/start",
        params: {
          threadId: "thread-1",
          input: [
            {
              type: "text",
              text: "Ship it",
              text_elements: [],
            },
          ],
          cwd: "/tmp/project",
          model: undefined,
          approvalPolicy: "on-request",
          sandboxPolicy: {
            type: "workspaceWrite",
            writableRoots: ["/tmp/project"],
            readOnlyAccess: {
              type: "fullAccess",
            },
            networkAccess: false,
            excludeTmpdirEnvVar: false,
            excludeSlashTmp: false,
          },
          effort: "high",
          summary: "concise",
          env: {
            FOO: "bar",
          },
        },
      },
      {
        id: "req-cancel",
        method: "turn/interrupt",
        params: {
          threadId: "thread-1",
          turnId: "turn-1",
        },
      },
      {
        id: "req-account",
        method: "account/read",
        params: {},
      },
      {
        id: "req-account:rate-limits",
        method: "account/rateLimits/read",
      },
    ]);
    expect(transport.responded).toEqual([
      {
        id: "approval-1",
        result: {
          decision: "accept",
        },
      },
    ]);
  });

  test("maps archive include filter to an omitted Codex archived param", async () => {
    const transport = new FakeTransport([
      { userAgent: "Codex/Test" },
      {
        data: [],
        nextCursor: null,
      },
    ]);
    const client = new CodexClient(transport);

    await client.connect();
    await client.listThreads("req-list", {
      workspacePath: "/tmp/project",
      archived: "include",
    });

    expect(transport.sent[1]).toEqual({
      id: "req-list",
      method: "thread/list",
      params: {
        cursor: undefined,
        limit: undefined,
        archived: undefined,
        cwd: "/tmp/project",
      },
    });
  });
});

class FakeTransport implements CodexTransport {
  readonly sent: CodexTransportRequest[] = [];
  readonly responded: CodexTransportResponse[] = [];

  private responseIndex = 0;

  constructor(private readonly responses: unknown[]) {}

  async connect(): Promise<void> {}

  async disconnect(): Promise<void> {}

  async send<TResult = unknown>(request: CodexTransportRequest): Promise<TResult> {
    this.sent.push(request);
    const response = this.responses[this.responseIndex];
    this.responseIndex += 1;
    return response as TResult;
  }

  async respond(response: CodexTransportResponse): Promise<void> {
    this.responded.push(response);
  }

  subscribe(_listener: (event: CodexTransportEvent) => void): () => void {
    return () => undefined;
  }
}
