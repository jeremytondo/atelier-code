import type {
  AgentAdapter,
  AgentTurnEvent,
} from "../agent-adapters/agent-adapter";
import { DomainError } from "../domain/errors";
import type {
  ThreadRecord,
  TurnRecord,
  UserInputRecord,
} from "../domain/models";
import {
  applyAgentMessageDelta,
  applyItemCompleted,
  applyItemStarted,
  applyPendingRequest,
  completeTurn,
} from "../domain/turn";
import {
  buildAgentMessageDelta,
  buildItemCompleted,
  buildItemStarted,
  buildTurnCompleted,
} from "../protocol/notification-builders";
import type { JsonRpcNotification } from "../protocol/types";
import type { AppServerStore } from "../store/store";
import {
  type SessionRecord,
  clearActiveTurn,
  setPendingRequest,
} from "./session-state";

export interface NotificationEmitter {
  emit<TParams>(
    notification: JsonRpcNotification<TParams>,
  ): Promise<void> | void;
}

export class RuntimeTurnRunner {
  constructor(
    private readonly store: AppServerStore,
    private readonly agentAdapter: AgentAdapter,
    private readonly ids: { next(prefix: string): string },
    private readonly clock: { now(): number },
  ) {}

  async run(
    session: SessionRecord,
    threadId: string,
    turnId: string,
    input: UserInputRecord[],
    notifications: NotificationEmitter,
  ): Promise<void> {
    const thread = this.requireThread(threadId);
    const turn = this.requireTurn(threadId, turnId);

    const agentStream = this.agentAdapter.streamTurn({
      thread,
      turn,
      input,
      createItemId: () => this.ids.next("item"),
    });

    for await (const event of agentStream) {
      await this.applyEvent(session, threadId, turnId, event, notifications);
    }
  }

  private async applyEvent(
    session: SessionRecord,
    threadId: string,
    turnId: string,
    event: AgentTurnEvent,
    notifications: NotificationEmitter,
  ): Promise<void> {
    const thread = this.requireThread(threadId);
    const turn = this.requireTurn(threadId, turnId);

    switch (event.type) {
      case "itemStarted": {
        const nextTurn = applyItemStarted(turn, event.item);
        this.store.saveTurn(threadId, nextTurn);
        await notifications.emit(
          buildItemStarted(threadId, turnId, event.item),
        );
        return;
      }
      case "pendingRequest": {
        const approvalId = this.ids.next("request");
        this.store.saveApproval({
          id: approvalId,
          threadId,
          turnId,
          itemId: event.itemId,
          kind: event.kind,
          state: "pending",
        });
        this.store.saveThread(applyPendingRequest(thread));
        setPendingRequest(session, approvalId);
        return;
      }
      case "agentMessageDelta": {
        const nextTurn = applyAgentMessageDelta(
          turn,
          event.itemId,
          event.delta,
        );
        this.store.saveTurn(threadId, nextTurn);
        await notifications.emit(
          buildAgentMessageDelta(threadId, turnId, event.itemId, event.delta),
        );
        return;
      }
      case "itemCompleted": {
        const nextTurn = applyItemCompleted(turn, event.item);
        this.store.saveTurn(threadId, nextTurn);
        await notifications.emit(
          buildItemCompleted(threadId, turnId, event.item),
        );
        return;
      }
      case "turnCompleted": {
        const completed = completeTurn(
          thread,
          turn,
          event.status,
          this.clock.now(),
        );
        this.store.saveTurn(threadId, completed.turn);
        this.store.saveThread(completed.thread);
        clearActiveTurn(session, turnId);
        await notifications.emit(buildTurnCompleted(threadId, completed.turn));
      }
    }
  }

  private requireThread(threadId: string): ThreadRecord {
    const thread = this.store.getThread(threadId);
    if (!thread) {
      throw new DomainError(
        "thread_not_found",
        `Thread ${threadId} was not found.`,
        {
          threadId,
        },
      );
    }

    return thread;
  }

  private requireTurn(threadId: string, turnId: string): TurnRecord {
    const turn = this.store.getTurn(threadId, turnId);
    if (!turn) {
      throw new DomainError("turn_not_found", `Turn ${turnId} was not found.`, {
        threadId,
        turnId,
      });
    }

    return turn;
  }
}
