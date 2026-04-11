import type {
  CodexModel,
  CodexThread,
  CodexThreadStatus,
  CodexTurn,
} from "@/agents/codex-adapter/protocol";
import type {
  AgentModelSummary,
  AgentThread,
  AgentThreadExecutionStatus,
  AgentThreadSummary,
  AgentTurnStatus,
  AgentTurnSummary,
} from "@/agents/contracts";

export const mapCodexModelSummary = (model: CodexModel): AgentModelSummary =>
  Object.freeze({
    id: model.id,
    model: model.model,
    displayName: model.displayName,
    hidden: model.hidden,
    defaultReasoningEffort: model.defaultReasoningEffort ?? undefined,
    supportedReasoningEfforts: model.supportedReasoningEfforts.map((effort) =>
      Object.freeze({
        reasoningEffort: effort.reasoningEffort,
        description: effort.description,
      }),
    ),
    inputModalities: model.inputModalities ? [...model.inputModalities] : undefined,
    supportsPersonality: model.supportsPersonality,
    isDefault: model.isDefault === true,
  });

export const mapCodexThreadStatus = (status: CodexThreadStatus): AgentThreadExecutionStatus => {
  switch (status.type) {
    case "notLoaded":
      return Object.freeze({ type: "notLoaded" });
    case "idle":
      return Object.freeze({ type: "idle" });
    case "systemError":
      return Object.freeze({
        type: "systemError",
        ...(status.error?.message ? { message: status.error.message } : {}),
      });
    case "active":
      return Object.freeze({
        type: "active",
        activeFlags: [...status.activeFlags],
      });
    default:
      return assertNever(status);
  }
};

export const mapCodexThreadSummary = (
  thread: CodexThread,
  options: { archived?: boolean } = {},
): AgentThreadSummary => mapAgentThreadSummary(mapCodexThread(thread, options));

export const mapCodexThread = (
  thread: CodexThread,
  options: { archived?: boolean } = {},
): AgentThread =>
  Object.freeze({
    id: thread.id,
    preview: thread.preview,
    createdAt: new Date(Math.max(0, thread.createdAt) * 1_000).toISOString(),
    updatedAt: new Date(Math.max(0, thread.updatedAt) * 1_000).toISOString(),
    workspacePath: thread.cwd,
    name: thread.name,
    archived: options.archived ?? false,
    status: mapCodexThreadStatus(thread.status),
  });

export const mapCodexTurnStatus = (turn: CodexTurn): AgentTurnStatus => {
  switch (turn.status) {
    case "completed":
      return Object.freeze({ type: "completed" });
    case "interrupted":
      return Object.freeze({ type: "interrupted" });
    case "failed":
      return Object.freeze({
        type: "failed",
        ...(turn.error?.message ? { message: turn.error.message } : {}),
      });
    case "inProgress":
      return Object.freeze({ type: "inProgress" });
    default:
      return assertNever(turn.status);
  }
};

export const mapCodexTurnSummary = (turn: CodexTurn): AgentTurnSummary =>
  Object.freeze({
    id: turn.id,
    status: mapCodexTurnStatus(turn),
  });

const mapAgentThreadSummary = (thread: AgentThread): AgentThreadSummary =>
  Object.freeze({
    id: thread.id,
    preview: thread.preview,
    updatedAt: thread.updatedAt,
    name: thread.name,
    archived: thread.archived,
    status: thread.status,
  });

const assertNever = (value: never): never => {
  throw new Error(`Unhandled Codex mapping variant: ${JSON.stringify(value)}`);
};
