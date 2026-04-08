import type { ThreadRecord, TurnRecord } from "../domain/models";
import { SERVER_VERSION } from "../server/server-metadata";
import type {
  ProtocolItem,
  ProtocolThread,
  ProtocolTurn,
  ProtocolTurnError,
} from "./types";

export interface SerializeThreadOptions {
  includeTurns?: boolean;
}

export interface SerializeTurnOptions {
  includeItems?: boolean;
}

export function toProtocolThread(
  thread: ThreadRecord,
  options: SerializeThreadOptions = {},
): ProtocolThread {
  return {
    id: thread.id,
    preview: thread.preview,
    ephemeral: thread.ephemeral,
    modelProvider: thread.modelProvider,
    createdAt: thread.createdAt,
    updatedAt: thread.updatedAt,
    status: thread.status,
    path: null,
    cwd: thread.cwd,
    cliVersion: SERVER_VERSION,
    source: "appServer",
    agentNickname: null,
    agentRole: null,
    gitInfo: null,
    name: thread.name,
    workspaceId: thread.workspaceId,
    turns: options.includeTurns
      ? thread.turns.map((turn) => toProtocolTurn(turn, { includeItems: true }))
      : [],
  };
}

export function toProtocolTurn(
  turn: TurnRecord,
  options: SerializeTurnOptions = {},
): ProtocolTurn {
  return {
    id: turn.id,
    items: options.includeItems ? ([...turn.items] as ProtocolItem[]) : [],
    status: turn.status,
    error: toProtocolTurnError(turn.error),
  };
}

function toProtocolTurnError(
  error: TurnRecord["error"],
): ProtocolTurnError | null {
  if (error === null) {
    return null;
  }

  return {
    message: error.message,
    codexErrorInfo: null,
    additionalDetails: error.additionalDetails,
  };
}
