import { describe, expect, test } from "bun:test";

import type { DomainError } from "./errors";
import {
  applyTurnStartOverrides,
  assertNoActiveTurn,
  assertThreadBelongsToWorkspace,
  createThreadRecord,
  startTurnRecord,
} from "./thread";

describe("thread lifecycle", () => {
  test("creates thread records with stable defaults", () => {
    expect(
      createThreadRecord({
        id: "thread-1",
        workspaceId: "workspace-1",
        cwd: "/tmp/project",
        now: 123,
        model: "fake-codex-phase-1",
        modelProvider: "fake-codex",
        serviceTier: null,
        approvalPolicy: "on-request",
        sandboxMode: "workspace-write",
        reasoningEffort: null,
      }),
    ).toEqual({
      id: "thread-1",
      workspaceId: "workspace-1",
      preview: "New thread",
      createdAt: 123,
      updatedAt: 123,
      status: { type: "idle" },
      cwd: "/tmp/project",
      model: "fake-codex-phase-1",
      modelProvider: "fake-codex",
      serviceTier: null,
      approvalPolicy: "on-request",
      sandboxMode: "workspace-write",
      reasoningEffort: null,
      name: null,
      turns: [],
    });
  });

  test("enforces workspace ownership", () => {
    const thread = createThreadRecord({
      id: "thread-1",
      workspaceId: "workspace-1",
      cwd: "/tmp/project",
      now: 123,
      model: "fake-codex-phase-1",
      modelProvider: "fake-codex",
      serviceTier: null,
      approvalPolicy: "on-request",
      sandboxMode: "workspace-write",
      reasoningEffort: null,
    });

    expect(() =>
      assertThreadBelongsToWorkspace(thread, {
        id: "workspace-2",
        path: "/tmp/other",
        createdAt: 123,
        updatedAt: 123,
      }),
    ).toThrow(
      expect.objectContaining({
        code: "thread_not_in_workspace",
      }) satisfies Partial<DomainError>,
    );
  });

  test("enforces one active turn at a time", () => {
    const thread = {
      ...createThreadRecord({
        id: "thread-1",
        workspaceId: "workspace-1",
        cwd: "/tmp/project",
        now: 123,
        model: "fake-codex-phase-1",
        modelProvider: "fake-codex",
        serviceTier: null,
        approvalPolicy: "on-request",
        sandboxMode: "workspace-write",
        reasoningEffort: null,
      }),
      turns: [
        {
          id: "turn-1",
          items: [],
          status: "inProgress" as const,
          error: null,
        },
      ],
    };

    expect(() => assertNoActiveTurn(thread)).toThrow(
      expect.objectContaining({
        code: "turn_already_active",
      }) satisfies Partial<DomainError>,
    );
  });

  test("applies turn overrides and starts a turn with preview updates", () => {
    const baseThread = createThreadRecord({
      id: "thread-1",
      workspaceId: "workspace-1",
      cwd: "/tmp/project",
      now: 123,
      model: "fake-codex-phase-1",
      modelProvider: "fake-codex",
      serviceTier: null,
      approvalPolicy: "on-request",
      sandboxMode: "workspace-write",
      reasoningEffort: null,
    });

    const overridden = applyTurnStartOverrides(baseThread, {
      cwd: "/tmp/next",
      model: "gpt-5.4",
      serviceTier: "fast",
      approvalPolicy: "never",
      effort: "high",
    });
    const started = startTurnRecord(overridden, {
      turnId: "turn-1",
      userItemId: "item-1",
      input: [
        {
          type: "text",
          text: "Ship phase 1",
          text_elements: [],
        },
      ],
      now: 456,
    });

    expect(baseThread.cwd).toBe("/tmp/project");
    expect(started.thread).toEqual({
      ...overridden,
      preview: "Ship phase 1",
      updatedAt: 456,
      status: { type: "active", activeFlags: ["turnInProgress"] },
      turns: [started.turn],
    });
    expect(started.turn).toEqual({
      id: "turn-1",
      items: [
        {
          type: "userMessage",
          id: "item-1",
          content: [
            {
              type: "text",
              text: "Ship phase 1",
              text_elements: [],
            },
          ],
        },
      ],
      status: "inProgress",
      error: null,
    });
  });
});
