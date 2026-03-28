import type {
  ApprovalRequestedEvent,
  ApprovalRequestedPayload,
  BridgeEvent,
  ConversationMessage,
  DiffFileSummary,
  ErrorEvent,
  PlanStep,
  RateLimitBucket,
  ThreadArchivedEvent,
  ThreadStartedEvent,
  ThreadSummary,
  ThreadUnarchivedEvent,
} from "../protocol/types";
import type { CodexTransportNotification, CodexTransportServerRequest } from "./codex-transport";
import { CODEX_PROVIDER_ID } from "./codex-client";

export interface CodexEventMapper {
  mapNotification(notification: CodexTransportNotification): BridgeEvent[];
  mapServerRequest(request: CodexTransportServerRequest): BridgeEvent[];
}

export class DefaultCodexEventMapper implements CodexEventMapper {
  mapNotification(notification: CodexTransportNotification): BridgeEvent[] {
    if (!isPlainObject(notification) || typeof notification.method !== "string") {
      return [
        buildErrorEvent(
          "malformed_provider_notification",
          "Codex emitted a malformed notification envelope.",
        ),
      ];
    }

    const timestamp = new Date().toISOString();
    const params = isPlainObject(notification.params) ? notification.params : null;

    switch (notification.method) {
      case "turn/started":
        return params && typeof params.threadId === "string" && isPlainObject(params.turn) && typeof params.turn.id === "string"
          ? [
              {
                type: "turn.started",
                timestamp,
                provider: "codex",
                threadID: params.threadId,
                turnID: params.turn.id,
                requestID: params.turn.id,
                payload: {
                  status: "in_progress",
                },
              },
            ]
          : [malformedNotificationError(notification.method)];
      case "turn/completed":
        return mapTurnCompletedNotification(params, timestamp, notification.method);
      case "item/agentMessage/delta":
        return params &&
          typeof params.threadId === "string" &&
          typeof params.turnId === "string" &&
          typeof params.itemId === "string" &&
          typeof params.delta === "string"
          ? [
              {
                type: "message.delta",
                timestamp,
                provider: "codex",
                threadID: params.threadId,
                turnID: params.turnId,
                itemID: params.itemId,
                payload: {
                  messageID: params.itemId,
                  delta: params.delta,
                },
              },
            ]
          : [malformedNotificationError(notification.method)];
      case "item/reasoning/summaryTextDelta":
      case "item/reasoning/textDelta":
        return params &&
          typeof params.threadId === "string" &&
          typeof params.turnId === "string" &&
          typeof params.itemId === "string" &&
          typeof params.delta === "string"
          ? [
              {
                type: "thinking.delta",
                timestamp,
                provider: "codex",
                threadID: params.threadId,
                turnID: params.turnId,
                itemID: params.itemId,
                payload: {
                  delta: params.delta,
                },
              },
            ]
          : [malformedNotificationError(notification.method)];
      case "item/started":
        return mapItemStartedNotification(params, timestamp);
      case "item/completed":
        return mapItemCompletedNotification(params, timestamp);
      case "item/commandExecution/outputDelta":
        return params &&
          typeof params.threadId === "string" &&
          typeof params.turnId === "string" &&
          typeof params.itemId === "string" &&
          typeof params.delta === "string"
          ? [
              {
                type: "tool.output",
                timestamp,
                provider: "codex",
                threadID: params.threadId,
                turnID: params.turnId,
                activityID: params.itemId,
                payload: {
                  stream: "combined",
                  delta: params.delta,
                },
              },
            ]
          : [malformedNotificationError(notification.method)];
      case "item/mcpToolCall/progress":
        return params &&
          typeof params.threadId === "string" &&
          typeof params.turnId === "string" &&
          typeof params.itemId === "string" &&
          typeof params.message === "string"
          ? [
              {
                type: "tool.output",
                timestamp,
                provider: "codex",
                threadID: params.threadId,
                turnID: params.turnId,
                activityID: params.itemId,
                payload: {
                  stream: "combined",
                  delta: params.message,
                },
              },
            ]
          : [malformedNotificationError(notification.method)];
      case "turn/diff/updated":
        return params &&
          typeof params.threadId === "string" &&
          typeof params.turnId === "string" &&
          typeof params.diff === "string"
          ? [
              {
                type: "diff.updated",
                timestamp,
                provider: "codex",
                threadID: params.threadId,
                turnID: params.turnId,
                payload: {
                  summary: summarizeFiles(extractDiffFileSummaries(params.diff)),
                  files: extractDiffFileSummaries(params.diff),
                },
              },
            ]
          : [malformedNotificationError(notification.method)];
      case "turn/plan/updated":
        return params &&
          typeof params.threadId === "string" &&
          typeof params.turnId === "string" &&
          Array.isArray(params.plan)
          ? [
              {
                type: "plan.updated",
                timestamp,
                provider: "codex",
                threadID: params.threadId,
                turnID: params.turnId,
                payload: {
                  summary: typeof params.explanation === "string" ? params.explanation : undefined,
                  steps: params.plan.flatMap((step, index) => toPlanStep(step, index)),
                },
              },
            ]
          : [malformedNotificationError(notification.method)];
      case "account/updated":
        return mapAccountUpdatedNotification(params, timestamp, notification.method);
      case "account/rateLimits/updated":
        return params ? mapRateLimitsUpdatedNotification(params, timestamp, notification.method) : [malformedNotificationError(notification.method)];
      case "error":
        return params && typeof params.message === "string"
          ? [
              buildErrorEvent(
                  typeof params.code === "string" ? params.code : "provider_error",
                params.message,
                undefined,
                params,
              ),
            ]
          : [malformedNotificationError(notification.method)];
      case "thread/started":
        return params && isPlainObject(params.thread)
          ? [buildThreadStartedEvent(undefined, toCodexThreadForEvent(params.thread))]
          : [malformedNotificationError(notification.method)];
      case "thread/archived":
        return params && typeof params.threadId === "string"
          ? [buildThreadArchivedEvent(params.threadId)]
          : [malformedNotificationError(notification.method)];
      case "thread/unarchived":
        return params && typeof params.threadId === "string"
          ? [buildThreadUnarchivedEvent(params.threadId)]
          : [malformedNotificationError(notification.method)];
      default:
        return [];
    }
  }

  mapServerRequest(request: CodexTransportServerRequest): BridgeEvent[] {
    if (!isPlainObject(request) || typeof request.method !== "string") {
      return [
        buildErrorEvent(
          "malformed_provider_request",
          "Codex emitted a malformed server request envelope.",
        ),
      ];
    }

    const timestamp = new Date().toISOString();
    const params = isPlainObject(request.params) ? request.params : null;

    switch (request.method) {
      case "item/commandExecution/requestApproval":
        return params ? [buildCommandApprovalEvent(request.id, params, timestamp)] : [malformedProviderRequestError(request.method)];
      case "item/fileChange/requestApproval":
        return params ? [buildFileChangeApprovalEvent(request.id, params, timestamp)] : [malformedProviderRequestError(request.method)];
      default:
        return [
          buildErrorEvent(
            "unsupported_provider_request",
            `Codex server request ${request.method} is not supported by the bridge yet.`,
            undefined,
            {
              method: request.method,
            },
          ),
        ];
    }
  }
}

export function buildThreadSummary(thread: {
  id: string;
  preview: string;
  updatedAt: number;
  name: string | null;
  status?: unknown;
  turns?: unknown[];
  archived?: boolean;
}): ThreadSummary {
  return {
    id: thread.id,
    providerID: CODEX_PROVIDER_ID,
    title: thread.name ?? fallbackThreadTitle(thread.preview, thread.id),
    previewText: thread.preview,
    updatedAt: new Date(Math.max(0, thread.updatedAt) * 1_000).toISOString(),
    archived: thread.archived === true,
    running: threadStatusToRunning(thread.status),
    errorMessage: threadStatusToErrorMessage(thread.status),
    messages: extractTranscriptMessages(thread.turns ?? []),
  };
}

export function buildThreadStartedEvent(
  requestID: string | undefined,
  thread: {
    id: string;
    preview: string;
    updatedAt: number;
    name: string | null;
    status?: unknown;
    turns?: unknown[];
    archived?: boolean;
  },
): ThreadStartedEvent {
  return {
    type: "thread.started",
    timestamp: new Date().toISOString(),
    provider: "codex",
    requestID,
    threadID: thread.id,
    payload: {
      thread: buildThreadSummary(thread),
    },
  };
}

export function buildThreadArchivedEvent(threadID: string, requestID?: string): ThreadArchivedEvent {
  return {
    type: "thread.archived",
    timestamp: new Date().toISOString(),
    provider: "codex",
    requestID,
    threadID,
    payload: {
      threadID,
    },
  };
}

export function buildThreadUnarchivedEvent(threadID: string, requestID?: string): ThreadUnarchivedEvent {
  return {
    type: "thread.unarchived",
    timestamp: new Date().toISOString(),
    provider: "codex",
    requestID,
    threadID,
    payload: {
      threadID,
    },
  };
}

function mapTurnCompletedNotification(
  params: Record<string, unknown> | null,
  timestamp: string,
  method: string,
): BridgeEvent[] {
  if (
    !params ||
    typeof params.threadId !== "string" ||
    !isPlainObject(params.turn) ||
    typeof params.turn.id !== "string" ||
    typeof params.turn.status !== "string"
  ) {
    return [malformedNotificationError(method)];
  }

  const detail =
    isPlainObject(params.turn.error) && typeof params.turn.error.message === "string"
      ? params.turn.error.message
      : undefined;

  return [
    {
      type: "turn.completed",
      timestamp,
      provider: "codex",
      threadID: params.threadId,
      turnID: params.turn.id,
      payload: {
        status: mapTurnStatus(params.turn.status),
        detail,
      },
    },
  ];
}

function mapItemStartedNotification(
  params: Record<string, unknown> | null,
  timestamp: string,
): BridgeEvent[] {
  if (
    !params ||
    typeof params.threadId !== "string" ||
    typeof params.turnId !== "string" ||
    !isPlainObject(params.item) ||
    typeof params.item.type !== "string" ||
    typeof params.item.id !== "string"
  ) {
    return [malformedNotificationError("item/started")];
  }

  switch (params.item.type) {
    case "commandExecution":
      return [
        {
          type: "tool.started",
          timestamp,
          provider: "codex",
          threadID: params.threadId,
          turnID: params.turnId,
          activityID: params.item.id,
          payload: {
            kind: "command",
            title:
              typeof params.item.command === "string" && params.item.command.length > 0
                ? params.item.command
                : "Command Execution",
            detail:
              typeof params.item.cwd === "string" && params.item.cwd.length > 0
                ? params.item.cwd
                : undefined,
            command: typeof params.item.command === "string" ? params.item.command : undefined,
            workingDirectory: typeof params.item.cwd === "string" ? params.item.cwd : undefined,
          },
        },
      ];
    case "fileChange": {
      const files = extractFileSummariesFromChanges(params.item.changes);
      return [
        {
          type: "fileChange.started",
          timestamp,
          provider: "codex",
          threadID: params.threadId,
          turnID: params.turnId,
          activityID: params.item.id,
          payload: {
            title: summarizeFiles(files),
            detail: files.map((file) => file.path).join(", "),
            files,
          },
        },
      ];
    }
    case "mcpToolCall":
      return [
        {
          type: "tool.started",
          timestamp,
          provider: "codex",
          threadID: params.threadId,
          turnID: params.turnId,
          activityID: params.item.id,
          payload: {
            kind: "mcp",
            title:
              typeof params.item.tool === "string"
                ? `${params.item.server ?? "MCP"}: ${params.item.tool}`
                : "MCP Tool Call",
          },
        },
      ];
    case "dynamicToolCall":
      return [
        {
          type: "tool.started",
          timestamp,
          provider: "codex",
          threadID: params.threadId,
          turnID: params.turnId,
          activityID: params.item.id,
          payload: {
            kind: "other",
            title: typeof params.item.tool === "string" ? params.item.tool : "Tool Call",
          },
        },
      ];
    case "webSearch":
      return [
        {
          type: "tool.started",
          timestamp,
          provider: "codex",
          threadID: params.threadId,
          turnID: params.turnId,
          activityID: params.item.id,
          payload: {
            kind: "webSearch",
            title:
              typeof params.item.query === "string" && params.item.query.length > 0
                ? `Web search: ${params.item.query}`
                : "Web Search",
          },
        },
      ];
    default:
      return [];
  }
}

function mapItemCompletedNotification(
  params: Record<string, unknown> | null,
  timestamp: string,
): BridgeEvent[] {
  if (
    !params ||
    typeof params.threadId !== "string" ||
    typeof params.turnId !== "string" ||
    !isPlainObject(params.item) ||
    typeof params.item.type !== "string" ||
    typeof params.item.id !== "string"
  ) {
    return [malformedNotificationError("item/completed")];
  }

  switch (params.item.type) {
    case "commandExecution":
      return [
        {
          type: "tool.completed",
          timestamp,
          provider: "codex",
          threadID: params.threadId,
          turnID: params.turnId,
          activityID: params.item.id,
          payload: {
            status: mapActivityStatus(params.item.status),
            detail: describeCommandCompletion(params.item),
            exitCode: typeof params.item.exitCode === "number" ? params.item.exitCode : null,
          },
        },
      ];
    case "fileChange": {
      const files = extractFileSummariesFromChanges(params.item.changes);
      return [
        {
          type: "fileChange.completed",
          timestamp,
          provider: "codex",
          threadID: params.threadId,
          turnID: params.turnId,
          activityID: params.item.id,
          payload: {
            status: mapActivityStatus(params.item.status),
            detail: summarizeFiles(files),
            files,
          },
        },
      ];
    }
    case "mcpToolCall":
    case "dynamicToolCall":
    case "webSearch":
      return [
        {
          type: "tool.completed",
          timestamp,
          provider: "codex",
          threadID: params.threadId,
          turnID: params.turnId,
          activityID: params.item.id,
          payload: {
            status: mapActivityStatus(params.item.status),
          },
        },
      ];
    default:
      return [];
  }
}

function mapAccountUpdatedNotification(
  params: Record<string, unknown> | null,
  timestamp: string,
  method: string,
): BridgeEvent[] {
  if (!params) {
    return [malformedNotificationError(method)];
  }

  const accountDescription = buildAccountDescription(params);

  return [
    {
      type: "auth.changed",
      timestamp,
      provider: "codex",
      payload: accountDescription
        ? {
            state: "signed_in",
            account: {
              displayName: accountDescription,
            },
          }
        : {
            state: "signed_out",
            account: null,
          },
    },
  ];
}

function mapRateLimitsUpdatedNotification(
  params: Record<string, unknown>,
  timestamp: string,
  method: string,
): BridgeEvent[] {
  const buckets = toRateLimitBuckets(params.rateLimits);
  if (buckets === null) {
    return [malformedNotificationError(method)];
  }

  return [
    {
      type: "rateLimit.updated",
      timestamp,
      provider: "codex",
      payload: {
        buckets,
      },
    },
  ];
}

function buildCommandApprovalEvent(
  requestID: string | number,
  params: Record<string, unknown>,
  timestamp: string,
): ApprovalRequestedEvent {
  const detailParts = [
    typeof params.reason === "string" && params.reason.length > 0 ? params.reason : null,
    typeof params.command === "string" && params.command.length > 0 ? params.command : null,
    typeof params.cwd === "string" && params.cwd.length > 0 ? `cwd: ${params.cwd}` : null,
  ].filter((value): value is string => value !== null);

  const payload: ApprovalRequestedPayload = {
    approvalID: String(requestID),
    kind: "command",
    title:
      typeof params.command === "string" && params.command.length > 0
        ? params.command
        : "Approve command execution",
    detail: detailParts.join("\n"),
    command:
      typeof params.command === "string"
        ? {
            command: params.command,
            workingDirectory: typeof params.cwd === "string" ? params.cwd : undefined,
          }
        : undefined,
    riskLevel:
      params.networkApprovalContext !== undefined || params.additionalPermissions !== undefined
        ? "high"
        : "medium",
  };

  return {
    type: "approval.requested",
    timestamp,
    provider: "codex",
    threadID: typeof params.threadId === "string" ? params.threadId : "",
    turnID: typeof params.turnId === "string" ? params.turnId : "",
    payload,
  };
}

function buildFileChangeApprovalEvent(
  requestID: string | number,
  params: Record<string, unknown>,
  timestamp: string,
): ApprovalRequestedEvent {
  const detailParts = [
    typeof params.reason === "string" && params.reason.length > 0 ? params.reason : null,
    typeof params.grantRoot === "string" && params.grantRoot.length > 0
      ? `grant root: ${params.grantRoot}`
      : null,
  ].filter((value): value is string => value !== null);

  return {
    type: "approval.requested",
    timestamp,
    provider: "codex",
    threadID: typeof params.threadId === "string" ? params.threadId : "",
    turnID: typeof params.turnId === "string" ? params.turnId : "",
    payload: {
      approvalID: String(requestID),
      kind: "fileChange",
      title: "Approve file changes",
      detail: detailParts.join("\n"),
      riskLevel: typeof params.grantRoot === "string" ? "high" : "medium",
    },
  };
}

function malformedNotificationError(method: string): ErrorEvent {
  return buildErrorEvent(
    "malformed_provider_notification",
    `Codex notification ${method} did not match the expected shape.`,
    undefined,
    {
      method,
    },
  );
}

function malformedProviderRequestError(method: string): ErrorEvent {
  return buildErrorEvent(
    "malformed_provider_request",
    `Codex server request ${method} did not match the expected shape.`,
    undefined,
    {
      method,
    },
  );
}

function buildErrorEvent(
  code: string,
  message: string,
  requestID?: string,
  detail?: Record<string, unknown>,
): ErrorEvent {
  return {
    type: "error",
    timestamp: new Date().toISOString(),
    provider: "codex",
    requestID,
    payload: {
      code,
      message,
      retryable: false,
      detail,
    },
  };
}

function extractFileSummariesFromChanges(changes: unknown): DiffFileSummary[] {
  if (!Array.isArray(changes)) {
    return [];
  }

  return changes.flatMap((change, index) => {
    if (!isPlainObject(change) || typeof change.path !== "string") {
      return [];
    }

    const counts = countDiffLines(typeof change.diff === "string" ? change.diff : "");
    return [
      {
        id: `${change.path}:${index}`,
        path: change.path,
        additions: counts.additions,
        deletions: counts.deletions,
      },
    ];
  });
}

export function extractDiffFileSummaries(diff: string): DiffFileSummary[] {
  const summaries = new Map<string, DiffFileSummary>();
  let currentPath: string | null = null;

  for (const line of diff.split("\n")) {
    if (line.startsWith("diff --git ")) {
      const match = /^diff --git a\/(.+?) b\/(.+)$/.exec(line);
      currentPath = match?.[2] ?? match?.[1] ?? null;
      if (currentPath && !summaries.has(currentPath)) {
        summaries.set(currentPath, {
          id: currentPath,
          path: currentPath,
          additions: 0,
          deletions: 0,
        });
      }
      continue;
    }

    if (currentPath === null) {
      continue;
    }

    if (line.startsWith("+++ ") || line.startsWith("--- ")) {
      continue;
    }

    const summary = summaries.get(currentPath);
    if (!summary) {
      continue;
    }

    if (line.startsWith("+")) {
      summary.additions += 1;
    } else if (line.startsWith("-")) {
      summary.deletions += 1;
    }
  }

  return Array.from(summaries.values());
}

function countDiffLines(diff: string): { additions: number; deletions: number } {
  let additions = 0;
  let deletions = 0;

  for (const line of diff.split("\n")) {
    if (line.startsWith("+++ ") || line.startsWith("--- ")) {
      continue;
    }

    if (line.startsWith("+")) {
      additions += 1;
    } else if (line.startsWith("-")) {
      deletions += 1;
    }
  }

  return { additions, deletions };
}

function summarizeFiles(files: DiffFileSummary[]): string {
  if (files.length === 0) {
    return "No file changes";
  }

  if (files.length === 1) {
    return files[0].path;
  }

  return `${files.length} files changed`;
}

function toPlanStep(step: unknown, index: number): PlanStep[] {
  if (!isPlainObject(step) || typeof step.step !== "string" || typeof step.status !== "string") {
    return [];
  }

  return [
    {
      id: `step-${index}`,
      title: step.step,
      status:
        step.status === "pending" || step.status === "completed"
          ? step.status
          : "in_progress",
    },
  ];
}

function mapTurnStatus(status: string): "completed" | "failed" | "cancelled" | "interrupted" {
  switch (status) {
    case "completed":
      return "completed";
    case "failed":
      return "failed";
    case "interrupted":
      return "interrupted";
    default:
      return "cancelled";
  }
}

function mapActivityStatus(status: unknown): "completed" | "failed" | "cancelled" {
  switch (status) {
    case "completed":
      return "completed";
    case "failed":
      return "failed";
    case "declined":
    default:
      return "cancelled";
  }
}

function describeCommandCompletion(item: Record<string, unknown>): string | undefined {
  const parts: string[] = [];

  if (typeof item.exitCode === "number") {
    parts.push(`exit code ${item.exitCode}`);
  }

  if (typeof item.durationMs === "number") {
    parts.push(`${item.durationMs} ms`);
  }

  return parts.length > 0 ? parts.join(", ") : undefined;
}

function buildAccountDescription(params: Record<string, unknown>): string | null {
  const authMode = typeof params.authMode === "string" ? params.authMode : null;
  const planType = typeof params.planType === "string" ? params.planType : null;

  if (!authMode) {
    return null;
  }

  if (planType) {
    return `${authMode} (${planType})`;
  }

  return authMode;
}

function toRateLimitBuckets(value: unknown): RateLimitBucket[] | null {
  if (!isPlainObject(value)) {
    return null;
  }

  const buckets: RateLimitBucket[] = [];

  if (isPlainObject(value.primary) && typeof value.primary.usedPercent === "number") {
    buckets.push({
      id: typeof value.limitId === "string" ? `${value.limitId}:primary` : "primary",
      kind: "requests",
      resetAt:
        typeof value.primary.resetsAt === "number"
          ? new Date(value.primary.resetsAt * 1_000).toISOString()
          : undefined,
      detail: formatRateLimitDetail(
        typeof value.limitName === "string" ? value.limitName : "primary",
        value.primary.usedPercent,
        typeof value.primary.windowDurationMins === "number"
          ? value.primary.windowDurationMins
          : null,
      ),
    });
  }

  if (isPlainObject(value.secondary) && typeof value.secondary.usedPercent === "number") {
    buckets.push({
      id: typeof value.limitId === "string" ? `${value.limitId}:secondary` : "secondary",
      kind: "tokens",
      resetAt:
        typeof value.secondary.resetsAt === "number"
          ? new Date(value.secondary.resetsAt * 1_000).toISOString()
          : undefined,
      detail: formatRateLimitDetail(
        typeof value.limitName === "string" ? value.limitName : "secondary",
        value.secondary.usedPercent,
        typeof value.secondary.windowDurationMins === "number"
          ? value.secondary.windowDurationMins
          : null,
      ),
    });
  }

  return buckets;
}

function formatRateLimitDetail(name: string, usedPercent: number, windowDurationMins: number | null): string {
  if (windowDurationMins === null) {
    return `${name}: ${usedPercent}% used`;
  }

  return `${name}: ${usedPercent}% used over ${windowDurationMins}m`;
}

function toCodexThreadForEvent(value: Record<string, unknown>): {
  id: string;
  preview: string;
  updatedAt: number;
  name: string | null;
  status?: unknown;
  turns?: unknown[];
  archived?: boolean;
} {
  return {
    id: typeof value.id === "string" ? value.id : "thread",
    preview: typeof value.preview === "string" ? value.preview : "",
    updatedAt: typeof value.updatedAt === "number" ? value.updatedAt : 0,
    name: typeof value.name === "string" ? value.name : null,
    status: value.status,
    turns: Array.isArray(value.turns) ? value.turns : [],
    archived: value.archived === true,
  };
}

function threadStatusToRunning(status: unknown): boolean {
  return isPlainObject(status) && status.type === "active";
}

function threadStatusToErrorMessage(status: unknown): string | undefined {
  if (!isPlainObject(status) || status.type !== "systemError") {
    return undefined;
  }

  return "Thread reported a system error.";
}

function extractTranscriptMessages(turns: unknown[]): ConversationMessage[] {
  const messages: ConversationMessage[] = [];

  for (const turn of turns) {
    if (!isPlainObject(turn) || !Array.isArray(turn.items)) {
      continue;
    }

    for (const item of turn.items) {
      const message = toConversationMessage(item);
      if (message) {
        messages.push(message);
      }
    }
  }

  return messages;
}

function toConversationMessage(item: unknown): ConversationMessage | null {
  if (!isPlainObject(item) || typeof item.id !== "string" || typeof item.type !== "string") {
    return null;
  }

  if (item.type === "userMessage" && Array.isArray(item.content)) {
    const text = item.content
      .flatMap((contentItem) => {
        if (!isPlainObject(contentItem) || typeof contentItem.type !== "string") {
          return [];
        }

        if (contentItem.type === "text" && typeof contentItem.text === "string") {
          return [contentItem.text];
        }

        return [];
      })
      .join("");

    return text.length > 0
      ? {
          id: item.id,
          role: "user",
          text,
        }
      : null;
  }

  if (item.type === "agentMessage" && typeof item.text === "string") {
    return {
      id: item.id,
      role: "assistant",
      text: item.text,
    };
  }

  return null;
}

function fallbackThreadTitle(preview: string, threadID: string): string {
  const trimmed = preview.trim();
  return trimmed.length > 0 ? trimmed.split("\n", 1)[0] : threadID;
}

function isPlainObject(value: unknown): value is Record<string, any> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
