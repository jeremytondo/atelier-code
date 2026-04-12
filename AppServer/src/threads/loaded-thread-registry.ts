export type LoadedThreadRegistry = Readonly<{
  markLoaded: (
    input: Readonly<{
      connectionId: string;
      workspaceId: string;
      threadId: string;
    }>,
  ) => void;
  isLoaded: (input: Readonly<{ connectionId: string; threadId: string }>) => boolean;
  listSubscribers: (threadId: string) => readonly string[];
  clearThread: (threadId: string) => readonly string[];
  clearConnection: (connectionId: string) => readonly string[];
  clearAll: () => void;
}>;

export const createLoadedThreadRegistry = (): LoadedThreadRegistry => {
  const threadIdsByConnectionId = new Map<string, Map<string, string>>();
  const connectionIdsByThreadId = new Map<string, Set<string>>();

  const clearThreadSubscription = (connectionId: string, threadId: string): void => {
    const threadIds = threadIdsByConnectionId.get(connectionId);
    threadIds?.delete(threadId);

    if (threadIds?.size === 0) {
      threadIdsByConnectionId.delete(connectionId);
    }

    const connectionIds = connectionIdsByThreadId.get(threadId);
    connectionIds?.delete(connectionId);

    if (connectionIds?.size === 0) {
      connectionIdsByThreadId.delete(threadId);
    }
  };

  return Object.freeze({
    markLoaded: ({ connectionId, workspaceId, threadId }) => {
      const existingThreadIds = threadIdsByConnectionId.get(connectionId);

      if (existingThreadIds !== undefined) {
        for (const [loadedThreadId, loadedWorkspaceId] of existingThreadIds.entries()) {
          if (loadedWorkspaceId !== workspaceId) {
            clearThreadSubscription(connectionId, loadedThreadId);
          }
        }
      }

      const threadIds = threadIdsByConnectionId.get(connectionId) ?? new Map<string, string>();
      threadIds.set(threadId, workspaceId);
      threadIdsByConnectionId.set(connectionId, threadIds);

      const connectionIds = connectionIdsByThreadId.get(threadId) ?? new Set<string>();
      connectionIds.add(connectionId);
      connectionIdsByThreadId.set(threadId, connectionIds);
    },
    isLoaded: ({ connectionId, threadId }) =>
      threadIdsByConnectionId.get(connectionId)?.has(threadId) ?? false,
    listSubscribers: (threadId) => [
      ...(connectionIdsByThreadId.get(threadId) ?? new Set<string>()),
    ],
    clearThread: (threadId) => {
      const connectionIds = [...(connectionIdsByThreadId.get(threadId) ?? new Set<string>())];

      for (const connectionId of connectionIds) {
        clearThreadSubscription(connectionId, threadId);
      }

      return connectionIds;
    },
    clearConnection: (connectionId) => {
      const threadIds = threadIdsByConnectionId.get(connectionId);

      if (threadIds === undefined) {
        return [];
      }

      const clearedThreadIds = [...threadIds.keys()];
      for (const threadId of clearedThreadIds) {
        clearThreadSubscription(connectionId, threadId);
      }

      return clearedThreadIds;
    },
    clearAll: () => {
      threadIdsByConnectionId.clear();
      connectionIdsByThreadId.clear();
    },
  });
};
