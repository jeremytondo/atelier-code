import { DomainError } from "../../core/shared/errors";
import type {
  ApprovalPolicyRecord,
  ItemRecord,
  ReasoningEffortRecord,
  SandboxModeRecord,
  ServiceTierRecord,
  ThreadRecord,
  TurnRecord,
  UserInputRecord,
  WorkspaceRecord,
} from "../../core/shared/models";

export interface CreateThreadRecordInput {
  id: string;
  workspaceId: string;
  cwd: string;
  now: number;
  ephemeral: boolean;
  model: string;
  modelProvider: string;
  serviceTier: ServiceTierRecord | null;
  approvalPolicy: ApprovalPolicyRecord;
  sandboxMode: SandboxModeRecord;
  reasoningEffort: ReasoningEffortRecord | null;
}

export interface TurnStartOverrides {
  cwd?: string | null | undefined;
  model?: string | null | undefined;
  serviceTier?: ServiceTierRecord | null | undefined;
  approvalPolicy?: ApprovalPolicyRecord | null | undefined;
  effort?: ReasoningEffortRecord | null | undefined;
}

export interface StartTurnRecordInput {
  turnId: string;
  userItemId: string;
  input: UserInputRecord[];
  now: number;
}

export function createThreadRecord(
  input: CreateThreadRecordInput,
): ThreadRecord {
  return {
    id: input.id,
    workspaceId: input.workspaceId,
    preview: "New thread",
    ephemeral: input.ephemeral,
    createdAt: input.now,
    updatedAt: input.now,
    status: { type: "idle" },
    cwd: input.cwd,
    model: input.model,
    modelProvider: input.modelProvider,
    serviceTier: input.serviceTier,
    approvalPolicy: input.approvalPolicy,
    sandboxMode: input.sandboxMode,
    reasoningEffort: input.reasoningEffort,
    name: null,
    turns: [],
  };
}

export function assertThreadBelongsToWorkspace(
  thread: ThreadRecord,
  workspace: WorkspaceRecord,
): void {
  if (thread.workspaceId !== workspace.id) {
    throw new DomainError(
      "thread_not_in_workspace",
      `Thread ${thread.id} does not belong to the opened workspace.`,
      {
        threadId: thread.id,
        workspaceId: workspace.id,
      },
    );
  }
}

export function assertNoActiveTurn(thread: ThreadRecord): void {
  const activeTurn = thread.turns.find(
    (candidate) => candidate.status === "inProgress",
  );
  if (activeTurn) {
    throw new DomainError(
      "turn_already_active",
      `Thread ${thread.id} already has an active turn.`,
      {
        threadId: thread.id,
        turnId: activeTurn.id,
      },
    );
  }
}

export function applyTurnStartOverrides(
  thread: ThreadRecord,
  overrides: TurnStartOverrides,
): ThreadRecord {
  let nextThread = thread;

  if (overrides.cwd !== undefined && overrides.cwd !== null) {
    nextThread = {
      ...nextThread,
      cwd: overrides.cwd,
    };
  }

  if (overrides.model !== undefined && overrides.model !== null) {
    nextThread = {
      ...nextThread,
      model: overrides.model,
    };
  }

  if (overrides.serviceTier !== undefined) {
    nextThread = {
      ...nextThread,
      serviceTier: overrides.serviceTier,
    };
  }

  if (
    overrides.approvalPolicy !== undefined &&
    overrides.approvalPolicy !== null
  ) {
    nextThread = {
      ...nextThread,
      approvalPolicy: overrides.approvalPolicy,
    };
  }

  if (overrides.effort !== undefined) {
    nextThread = {
      ...nextThread,
      reasoningEffort: overrides.effort,
    };
  }

  return nextThread;
}

export function startTurnRecord(
  thread: ThreadRecord,
  input: StartTurnRecordInput,
): { thread: ThreadRecord; turn: TurnRecord } {
  const userItem: ItemRecord = {
    type: "userMessage",
    id: input.userItemId,
    content: input.input,
  };
  const turn: TurnRecord = {
    id: input.turnId,
    items: [userItem],
    status: "inProgress",
    error: null,
  };

  const nextThread: ThreadRecord = {
    ...thread,
    preview: previewFromInput(input.input),
    updatedAt: input.now,
    status: { type: "active", activeFlags: ["turnInProgress"] },
    turns: [...thread.turns, turn],
  };

  return {
    thread: nextThread,
    turn,
  };
}

function previewFromInput(input: UserInputRecord[]): string {
  const latestText = [...input]
    .reverse()
    .find(
      (candidate): candidate is Extract<UserInputRecord, { type: "text" }> =>
        candidate.type === "text",
    );

  return latestText?.text ?? "New turn";
}
