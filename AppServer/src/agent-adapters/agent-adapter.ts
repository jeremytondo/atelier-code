import type {
  AgentMessageItemRecord,
  ApprovalKindRecord,
  ThreadRecord,
  TurnRecord,
  UserInputRecord,
} from "../domain/models";

export type AgentTurnEvent =
  | { type: "itemStarted"; item: AgentMessageItemRecord }
  | { type: "pendingRequest"; itemId: string; kind: ApprovalKindRecord }
  | { type: "agentMessageDelta"; itemId: string; delta: string }
  | { type: "itemCompleted"; item: AgentMessageItemRecord }
  | { type: "turnCompleted"; status: TurnRecord["status"] };

export interface AgentTurnContext {
  thread: ThreadRecord;
  turn: TurnRecord;
  input: UserInputRecord[];
  createItemId(): string;
}

export interface AgentAdapter {
  streamTurn(context: AgentTurnContext): AsyncGenerator<AgentTurnEvent>;
}
