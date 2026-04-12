import { err, ok, type Result } from "@/core/shared";
import type { Turn, TurnItem } from "@/turns/schemas";

export type ActiveTurnConflictError = Readonly<{
  type: "activeTurnConflict";
  threadId: string;
  activeTurnId?: string;
  message: string;
}>;

export type ActiveTurnItemState = Readonly<{
  item?: TurnItem;
  messageText: string;
  reasoningText: string;
  reasoningSummaryText: string;
  commandOutput: string;
  toolProgress: readonly string[];
}>;

export type ActiveTurnSnapshot = Readonly<{
  threadId: string;
  turn?: Turn;
  items: readonly ActiveTurnItemState[];
}>;

export type ActiveTurnRegistry = Readonly<{
  reserveThread: (
    threadId: string,
  ) => Result<Readonly<{ release: () => void }>, ActiveTurnConflictError>;
  startTurn: (input: Readonly<{ threadId: string; turn: Turn }>) => void;
  recordTurnCompleted: (input: Readonly<{ threadId: string; turn: Turn }>) => void;
  recordItemStarted: (
    input: Readonly<{ threadId: string; turnId: string; item: TurnItem }>,
  ) => void;
  recordItemCompleted: (
    input: Readonly<{ threadId: string; turnId: string; item: TurnItem }>,
  ) => void;
  appendMessageText: (
    input: Readonly<{ threadId: string; turnId: string; itemId: string; delta: string }>,
  ) => void;
  appendReasoningText: (
    input: Readonly<{ threadId: string; turnId: string; itemId: string; delta: string }>,
  ) => void;
  appendReasoningSummaryText: (
    input: Readonly<{ threadId: string; turnId: string; itemId: string; delta: string }>,
  ) => void;
  appendCommandOutput: (
    input: Readonly<{ threadId: string; turnId: string; itemId: string; delta: string }>,
  ) => void;
  appendToolProgress: (
    input: Readonly<{ threadId: string; turnId: string; itemId: string; message: string }>,
  ) => void;
  getActiveTurn: (threadId: string) => ActiveTurnSnapshot | undefined;
  clearThread: (threadId: string) => ActiveTurnSnapshot | undefined;
  clearAll: () => void;
}>;

type MutableActiveTurnItemState = {
  item?: TurnItem;
  messageText: string;
  reasoningText: string;
  reasoningSummaryText: string;
  commandOutput: string;
  toolProgress: string[];
};

type MutableActiveTurnState = {
  turn?: Turn;
  itemsById: Map<string, MutableActiveTurnItemState>;
};

export const createActiveTurnRegistry = (): ActiveTurnRegistry => {
  const statesByThreadId = new Map<string, MutableActiveTurnState>();

  const getOrCreateThreadState = (threadId: string): MutableActiveTurnState => {
    const existing = statesByThreadId.get(threadId);

    if (existing !== undefined) {
      return existing;
    }

    const state: MutableActiveTurnState = {
      itemsById: new Map(),
    };
    statesByThreadId.set(threadId, state);
    return state;
  };

  const ensureObservedTurn = (threadId: string, turnId: string): MutableActiveTurnState => {
    const state = getOrCreateThreadState(threadId);

    if (state.turn?.id !== turnId) {
      state.turn = Object.freeze({
        id: turnId,
        status: Object.freeze({ type: "inProgress" as const }),
      });
      state.itemsById.clear();
    }

    return state;
  };

  const getOrCreateItemState = (
    threadId: string,
    turnId: string,
    itemId: string,
  ): MutableActiveTurnItemState => {
    const state = ensureObservedTurn(threadId, turnId);
    const existing = state.itemsById.get(itemId);

    if (existing !== undefined) {
      return existing;
    }

    const itemState: MutableActiveTurnItemState = {
      messageText: "",
      reasoningText: "",
      reasoningSummaryText: "",
      commandOutput: "",
      toolProgress: [],
    };
    state.itemsById.set(itemId, itemState);
    return itemState;
  };

  const toSnapshot = (threadId: string, state: MutableActiveTurnState): ActiveTurnSnapshot =>
    Object.freeze({
      threadId,
      ...(state.turn !== undefined ? { turn: state.turn } : {}),
      items: [...state.itemsById.values()].map((item) =>
        Object.freeze({
          ...(item.item !== undefined ? { item: item.item } : {}),
          messageText: item.messageText,
          reasoningText: item.reasoningText,
          reasoningSummaryText: item.reasoningSummaryText,
          commandOutput: item.commandOutput,
          toolProgress: Object.freeze([...item.toolProgress]),
        }),
      ),
    });

  return Object.freeze({
    reserveThread: (threadId) => {
      const existing = statesByThreadId.get(threadId);

      if (existing !== undefined) {
        return err({
          type: "activeTurnConflict",
          threadId,
          ...(existing.turn !== undefined ? { activeTurnId: existing.turn.id } : {}),
          message: "Thread already has an active turn.",
        });
      }

      const state: MutableActiveTurnState = {
        itemsById: new Map(),
      };
      statesByThreadId.set(threadId, state);

      return ok(
        Object.freeze({
          release: () => {
            const current = statesByThreadId.get(threadId);

            if (current === state && current.turn === undefined) {
              statesByThreadId.delete(threadId);
            }
          },
        }),
      );
    },
    startTurn: ({ threadId, turn }) => {
      const state = getOrCreateThreadState(threadId);
      state.turn = turn;
    },
    recordTurnCompleted: ({ threadId, turn }) => {
      const state = ensureObservedTurn(threadId, turn.id);
      state.turn = turn;
    },
    recordItemStarted: ({ threadId, turnId, item }) => {
      const itemState = getOrCreateItemState(threadId, turnId, item.id);
      itemState.item = item;
    },
    recordItemCompleted: ({ threadId, turnId, item }) => {
      const itemState = getOrCreateItemState(threadId, turnId, item.id);
      itemState.item = item;
    },
    appendMessageText: ({ threadId, turnId, itemId, delta }) => {
      getOrCreateItemState(threadId, turnId, itemId).messageText += delta;
    },
    appendReasoningText: ({ threadId, turnId, itemId, delta }) => {
      getOrCreateItemState(threadId, turnId, itemId).reasoningText += delta;
    },
    appendReasoningSummaryText: ({ threadId, turnId, itemId, delta }) => {
      getOrCreateItemState(threadId, turnId, itemId).reasoningSummaryText += delta;
    },
    appendCommandOutput: ({ threadId, turnId, itemId, delta }) => {
      getOrCreateItemState(threadId, turnId, itemId).commandOutput += delta;
    },
    appendToolProgress: ({ threadId, turnId, itemId, message }) => {
      getOrCreateItemState(threadId, turnId, itemId).toolProgress.push(message);
    },
    getActiveTurn: (threadId) => {
      const state = statesByThreadId.get(threadId);
      return state === undefined ? undefined : toSnapshot(threadId, state);
    },
    clearThread: (threadId) => {
      const state = statesByThreadId.get(threadId);

      if (state === undefined) {
        return undefined;
      }

      statesByThreadId.delete(threadId);
      return toSnapshot(threadId, state);
    },
    clearAll: () => {
      statesByThreadId.clear();
    },
  });
};
