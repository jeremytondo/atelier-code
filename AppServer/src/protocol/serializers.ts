import type { ThreadRecord, TurnRecord } from "../domain/models";
import type { ProtocolThread, ProtocolTurn } from "./types";

export function toProtocolThread(thread: ThreadRecord): ProtocolThread {
  return {
    id: thread.id,
    workspaceId: thread.workspaceId,
    preview: thread.preview,
    createdAt: thread.createdAt,
    updatedAt: thread.updatedAt,
    status: thread.status,
    cwd: thread.cwd,
    modelProvider: thread.modelProvider,
    name: thread.name,
    turns: [],
  };
}

export function toProtocolTurn(turn: TurnRecord): ProtocolTurn {
  return {
    id: turn.id,
    items: [],
    status: turn.status,
    error: turn.error,
  };
}
