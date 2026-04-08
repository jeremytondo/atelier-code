import { SERVER_VERSION } from "../config/server-metadata";
import type {
  SandboxModeRecord,
  ThreadRecord,
  TurnRecord,
} from "../shared/models";
import type {
  JsonRpcErrorResponse,
  JsonRpcNotification,
  JsonRpcSuccessResponse,
  ProtocolItem,
  ProtocolSandboxPolicy,
  ProtocolThread,
  ProtocolTurn,
  ProtocolTurnError,
} from "./types";

export interface SerializeThreadOptions {
  includeTurns?: boolean;
}

export interface SerializeTurnOptions {
  includeItems?: boolean;
}

export function toProtocolThread(
  thread: ThreadRecord,
  options: SerializeThreadOptions = {},
): ProtocolThread {
  return {
    id: thread.id,
    preview: thread.preview,
    ephemeral: thread.ephemeral,
    modelProvider: thread.modelProvider,
    createdAt: thread.createdAt,
    updatedAt: thread.updatedAt,
    status: thread.status,
    path: null,
    cwd: thread.cwd,
    cliVersion: SERVER_VERSION,
    source: "appServer",
    agentNickname: null,
    agentRole: null,
    gitInfo: null,
    name: thread.name,
    workspaceId: thread.workspaceId,
    turns: options.includeTurns
      ? thread.turns.map((turn) => toProtocolTurn(turn, { includeItems: true }))
      : [],
  };
}

export function toProtocolTurn(
  turn: TurnRecord,
  options: SerializeTurnOptions = {},
): ProtocolTurn {
  return {
    id: turn.id,
    items: options.includeItems ? ([...turn.items] as ProtocolItem[]) : [],
    status: turn.status,
    error: toProtocolTurnError(turn.error),
  };
}

export function toProtocolSandboxPolicy(
  sandboxMode: SandboxModeRecord,
  cwd: string,
): ProtocolSandboxPolicy {
  switch (sandboxMode) {
    case "danger-full-access":
      return {
        type: "dangerFullAccess",
      };
    case "read-only":
      return {
        type: "readOnly",
        access: {
          type: "restricted",
          includePlatformDefaults: true,
          readableRoots: [cwd],
        },
        networkAccess: false,
      };
    case "workspace-write":
      return {
        type: "workspaceWrite",
        writableRoots: [cwd],
        readOnlyAccess: {
          type: "fullAccess",
        },
        networkAccess: false,
        excludeTmpdirEnvVar: false,
        excludeSlashTmp: false,
      };
  }
}

function toProtocolTurnError(
  error: TurnRecord["error"],
): ProtocolTurnError | null {
  if (error === null) {
    return null;
  }

  return {
    message: error.message,
    agentErrorInfo: null,
    additionalDetails: error.additionalDetails,
  };
}

export function serializeProtocolMessage<TParams>(
  message:
    | JsonRpcSuccessResponse
    | JsonRpcErrorResponse
    | JsonRpcNotification<TParams>,
): string {
  return JSON.stringify(message);
}
