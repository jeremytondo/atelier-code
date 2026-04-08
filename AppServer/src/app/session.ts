import type { ClientInfo } from "../core/protocol/types";
import { DomainError } from "../core/shared/errors";
import type { WorkspaceRecord } from "../core/shared/models";
import type { AppServerStore } from "../core/store/store";

export interface SessionRecord {
  id: string;
  initialized: boolean;
  clientInfo: ClientInfo | null;
  optOutNotificationMethods: Set<string>;
  openedWorkspaceId: string | null;
  loadedThreadId: string | null;
  activeTurnId: string | null;
  pendingRequestId: string | null;
}

export function createSessionRecord(id: string): SessionRecord {
  return {
    id,
    initialized: false,
    clientInfo: null,
    optOutNotificationMethods: new Set<string>(),
    openedWorkspaceId: null,
    loadedThreadId: null,
    activeTurnId: null,
    pendingRequestId: null,
  };
}

export function initializeSession(
  session: SessionRecord,
  clientInfo: ClientInfo,
  optOutNotificationMethods: Iterable<string>,
): void {
  session.initialized = true;
  session.clientInfo = clientInfo;
  session.optOutNotificationMethods = new Set(optOutNotificationMethods);
}

export function assertSessionInitialized(session: SessionRecord): void {
  if (!session.initialized) {
    throw new DomainError(
      "not_initialized",
      "The connection must initialize before using other methods.",
    );
  }
}

export function requireOpenedWorkspace(
  session: SessionRecord,
  store: AppServerStore,
): WorkspaceRecord {
  if (session.openedWorkspaceId === null) {
    throw new DomainError(
      "workspace_not_opened",
      "Open a workspace before starting or using threads.",
    );
  }

  const workspace = store.getWorkspaceById(session.openedWorkspaceId);
  if (!workspace) {
    throw new DomainError(
      "workspace_not_found",
      `Workspace ${session.openedWorkspaceId} was not found.`,
      {
        workspaceId: session.openedWorkspaceId,
      },
    );
  }

  return workspace;
}

export function setOpenedWorkspace(
  session: SessionRecord,
  workspaceId: string,
): void {
  session.openedWorkspaceId = workspaceId;
  session.loadedThreadId = null;
  session.activeTurnId = null;
  session.pendingRequestId = null;
}

export function markLoadedThread(
  session: SessionRecord,
  threadId: string,
): void {
  session.loadedThreadId = threadId;
}

export function markActiveTurn(session: SessionRecord, turnId: string): void {
  session.activeTurnId = turnId;
}

export function clearActiveTurn(session: SessionRecord, turnId: string): void {
  if (session.activeTurnId === turnId) {
    session.activeTurnId = null;
  }
}

export function setPendingRequest(
  session: SessionRecord,
  requestId: string | null,
): void {
  session.pendingRequestId = requestId;
}
