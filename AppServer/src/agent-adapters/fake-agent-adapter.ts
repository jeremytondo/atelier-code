import type {
  AgentMessageItemRecord,
  ApprovalKindRecord,
  UserInputRecord,
} from "../domain/models";
import type {
  AgentAdapter,
  AgentTurnContext,
  AgentTurnEvent,
} from "./agent-adapter";

export interface FakeApprovalScript {
  kind: ApprovalKindRecord;
  pauseAfterRequest?: boolean;
}

export interface FakeAgentAdapterOptions {
  approvalScript?: FakeApprovalScript | null;
  deltaChunks?: string[];
  tickDelayMs?: number;
}

export class FakeAgentAdapter implements AgentAdapter {
  constructor(private readonly options: FakeAgentAdapterOptions = {}) {}

  async *streamTurn(context: AgentTurnContext): AsyncGenerator<AgentTurnEvent> {
    const itemId = context.createItemId();
    const completionText = buildAssistantResponse(context.input);
    const deltaChunks = this.options.deltaChunks ?? chunkText(completionText);

    const startedItem: AgentMessageItemRecord = {
      type: "agentMessage",
      id: itemId,
      text: "",
      phase: "final_answer",
    };

    await sleep(this.options.tickDelayMs ?? 5);
    yield { type: "itemStarted", item: startedItem };

    if (this.options.approvalScript) {
      await sleep(this.options.tickDelayMs ?? 5);
      yield {
        type: "pendingRequest",
        itemId,
        kind: this.options.approvalScript.kind,
      };

      if (this.options.approvalScript.pauseAfterRequest) {
        return;
      }
    }

    let aggregateText = "";
    for (const delta of deltaChunks) {
      await sleep(this.options.tickDelayMs ?? 5);
      aggregateText += delta;
      yield {
        type: "agentMessageDelta",
        itemId,
        delta,
      };
    }

    await sleep(this.options.tickDelayMs ?? 5);
    yield {
      type: "itemCompleted",
      item: {
        ...startedItem,
        text: aggregateText,
      },
    };

    await sleep(this.options.tickDelayMs ?? 5);
    yield {
      type: "turnCompleted",
      status: "completed",
    };
  }
}

function buildAssistantResponse(input: UserInputRecord[]): string {
  const latestTextInput = [...input]
    .reverse()
    .find(
      (candidate): candidate is Extract<UserInputRecord, { type: "text" }> =>
        candidate.type === "text",
    );

  if (!latestTextInput) {
    return "Fake agent adapter completed the turn.";
  }

  return `Fake agent adapter completed: ${latestTextInput.text}`;
}

function chunkText(text: string): string[] {
  if (text.length <= 8) {
    return [text];
  }

  const midpoint = Math.ceil(text.length / 2);
  return [text.slice(0, midpoint), text.slice(midpoint)];
}

async function sleep(durationMs: number): Promise<void> {
  await Bun.sleep(durationMs);
}
