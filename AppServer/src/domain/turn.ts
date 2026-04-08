import { DomainError } from "./errors";
import type {
  AgentMessageItemRecord,
  ThreadRecord,
  TurnErrorRecord,
  TurnRecord,
} from "./models";

export function applyItemStarted(
  turn: TurnRecord,
  item: AgentMessageItemRecord,
): TurnRecord {
  return {
    ...turn,
    items: [...turn.items, item],
  };
}

export function applyPendingRequest(thread: ThreadRecord): ThreadRecord {
  return {
    ...thread,
    status: {
      type: "active",
      activeFlags: ["turnInProgress", "approvalPending"],
    },
  };
}

export function applyAgentMessageDelta(
  turn: TurnRecord,
  itemId: string,
  delta: string,
): TurnRecord {
  const itemIndex = turn.items.findIndex(
    (candidate) => candidate.type === "agentMessage" && candidate.id === itemId,
  );
  if (itemIndex === -1) {
    throw new DomainError(
      "item_not_found",
      `Runtime attempted to stream delta for unknown item ${itemId}.`,
      {
        itemId,
      },
    );
  }

  const item = turn.items[itemIndex];
  if (!item || item.type !== "agentMessage") {
    throw new DomainError(
      "item_not_found",
      `Runtime attempted to stream delta for unknown item ${itemId}.`,
      {
        itemId,
      },
    );
  }

  const nextItems = [...turn.items];
  nextItems[itemIndex] = {
    ...item,
    text: item.text + delta,
  };

  return {
    ...turn,
    items: nextItems,
  };
}

export function applyItemCompleted(
  turn: TurnRecord,
  item: AgentMessageItemRecord,
): TurnRecord {
  const itemIndex = turn.items.findIndex(
    (candidate) => candidate.id === item.id,
  );
  if (itemIndex === -1) {
    throw new DomainError(
      "item_not_found",
      `Runtime completed unknown item ${item.id}.`,
      {
        itemId: item.id,
      },
    );
  }

  const nextItems = [...turn.items];
  nextItems[itemIndex] = item;

  return {
    ...turn,
    items: nextItems,
  };
}

export function completeTurn(
  thread: ThreadRecord,
  turn: TurnRecord,
  status: TurnRecord["status"],
  updatedAt: number,
): { thread: ThreadRecord; turn: TurnRecord } {
  return {
    thread: {
      ...thread,
      status: { type: "idle" },
      updatedAt,
    },
    turn: {
      ...turn,
      status,
    },
  };
}

export function failTurn(
  thread: ThreadRecord,
  turn: TurnRecord,
  error: TurnErrorRecord,
  updatedAt: number,
): { thread: ThreadRecord; turn: TurnRecord } {
  return {
    thread: {
      ...thread,
      status: { type: "systemError" },
      updatedAt,
    },
    turn: {
      ...turn,
      status: "failed",
      error,
    },
  };
}
