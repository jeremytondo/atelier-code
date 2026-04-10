import type {
  CodexModel,
  CodexReasoningEffort,
  CodexThread,
  CodexThreadStatus,
  CodexTurn,
} from "@/agents/codex-adapter/protocol";
import type {
  AgentModelSummary,
  AgentReasoningEffort,
  AgentThreadExecutionStatus,
  AgentThreadSummary,
  AgentTurnStatus,
  AgentTurnSummary,
} from "@/agents/contracts";

export const mapCodexReasoningEffort = (
  value: CodexReasoningEffort | null | undefined,
): AgentReasoningEffort | undefined => value ?? undefined;

export const mapCodexModelSummary = (model: CodexModel): AgentModelSummary =>
  Object.freeze({
    id: model.id,
    model: model.model,
    displayName: model.displayName,
    hidden: model.hidden,
    defaultReasoningEffort: mapCodexReasoningEffort(model.defaultReasoningEffort),
    supportedReasoningEfforts: model.supportedReasoningEfforts.map((effort) =>
      Object.freeze({
        reasoningEffort: effort.reasoningEffort,
        description: effort.description,
      }),
    ),
    inputModalities: model.inputModalities ? [...model.inputModalities] : undefined,
    supportsPersonality: model.supportsPersonality,
    isDefault: model.isDefault,
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
  }
};

export const mapCodexThreadSummary = (
  thread: CodexThread,
  options: { archived?: boolean } = {},
): AgentThreadSummary =>
  Object.freeze({
    id: thread.id,
    preview: thread.preview,
    updatedAt: new Date(Math.max(0, thread.updatedAt) * 1_000).toISOString(),
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
  }
};

export const mapCodexTurnSummary = (turn: CodexTurn): AgentTurnSummary =>
  Object.freeze({
    id: turn.id,
    status: mapCodexTurnStatus(turn),
  });
