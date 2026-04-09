import type { ItemRecord, ThreadRecord, TurnRecord } from "../domain/models";
import { toProtocolThread, toProtocolTurn } from "./serializers";
import type {
  AgentMessageDeltaNotification,
  ItemCompletedNotification,
  ItemStartedNotification,
  JsonRpcNotification,
  ThreadStartedNotification,
  TurnCompletedNotification,
  TurnStartedNotification,
} from "./types";

export function buildThreadStarted(
  thread: ThreadRecord,
): JsonRpcNotification<ThreadStartedNotification> {
  return {
    method: "thread/started",
    params: {
      thread: toProtocolThread(thread),
    },
  };
}

export function buildTurnStarted(
  threadId: string,
  turn: TurnRecord,
): JsonRpcNotification<TurnStartedNotification> {
  return {
    method: "turn/started",
    params: {
      threadId,
      turn: toProtocolTurn(turn),
    },
  };
}

export function buildItemStarted(
  threadId: string,
  turnId: string,
  item: ItemRecord,
): JsonRpcNotification<ItemStartedNotification> {
  return {
    method: "item/started",
    params: {
      threadId,
      turnId,
      item,
    },
  };
}

export function buildAgentMessageDelta(
  threadId: string,
  turnId: string,
  itemId: string,
  delta: string,
): JsonRpcNotification<AgentMessageDeltaNotification> {
  return {
    method: "item/agentMessage/delta",
    params: {
      threadId,
      turnId,
      itemId,
      delta,
    },
  };
}

export function buildItemCompleted(
  threadId: string,
  turnId: string,
  item: ItemRecord,
): JsonRpcNotification<ItemCompletedNotification> {
  return {
    method: "item/completed",
    params: {
      threadId,
      turnId,
      item,
    },
  };
}

export function buildTurnCompleted(
  threadId: string,
  turn: TurnRecord,
): JsonRpcNotification<TurnCompletedNotification> {
  return {
    method: "turn/completed",
    params: {
      threadId,
      turn: toProtocolTurn(turn),
    },
  };
}
