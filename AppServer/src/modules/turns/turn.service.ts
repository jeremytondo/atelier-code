import { toProtocolTurn } from "../../core/protocol/serializers";
import type {
  TurnStartParams,
  TurnStartResult,
} from "../../core/protocol/types";
import type {
  ThreadRecord,
  TurnRecord,
  WorkspaceRecord,
} from "../../core/shared/models";
import type { AppServerStore } from "../../core/store/store";
import {
  applyTurnStartOverrides,
  assertNoActiveTurn,
  assertThreadBelongsToWorkspace,
  startTurnRecord,
} from "../threads/thread.entity";
import { requireThread } from "../threads/thread.service";
import type { WorkspacePathAccess } from "../workspaces/workspace.paths";
import { requireDirectoryPath } from "../workspaces/workspace.service";

interface IdGenerator {
  next(prefix: string): string;
}

interface Clock {
  now(): number;
}

export interface StartTurnInput {
  store: Pick<AppServerStore, "getThread">;
  workspace: WorkspaceRecord;
  params: TurnStartParams;
  workspacePaths: WorkspacePathAccess;
  ids: IdGenerator;
  clock: Clock;
}

export function startTurn(input: StartTurnInput): {
  thread: ThreadRecord;
  turn: TurnRecord;
  result: TurnStartResult;
} {
  const thread = requireThread(input.store, input.params.threadId);
  assertThreadBelongsToWorkspace(thread, input.workspace);
  assertNoActiveTurn(thread);

  const resolvedCwd =
    input.params.cwd === undefined || input.params.cwd === null
      ? input.params.cwd
      : requireDirectoryPath(
          input.workspacePaths,
          input.params.cwd,
          "invalid_turn_cwd",
          "turn/start requires cwd to reference an existing directory when provided.",
        );

  const nextThread = applyTurnStartOverrides(thread, {
    cwd: resolvedCwd,
    model: input.params.model,
    serviceTier: input.params.serviceTier,
    approvalPolicy: input.params.approvalPolicy,
    effort: input.params.effort,
  });

  const startedTurn = startTurnRecord(nextThread, {
    turnId: input.ids.next("turn"),
    userItemId: input.ids.next("item"),
    input: input.params.input,
    now: input.clock.now(),
  });

  return {
    thread: startedTurn.thread,
    turn: startedTurn.turn,
    result: {
      turn: toProtocolTurn(startedTurn.turn),
    },
  };
}
