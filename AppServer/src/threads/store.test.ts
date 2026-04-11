import { Database } from "bun:sqlite";
import { describe, expect, test } from "bun:test";
import { drizzle } from "drizzle-orm/bun-sqlite";
import { migrate } from "drizzle-orm/bun-sqlite/migrator";
import { type AppDatabase, DEFAULT_MIGRATIONS_FOLDER } from "@/core/store";
import { createInMemoryThreadsStore, createSqliteThreadsStore } from "@/threads/store";

describe("threads store", () => {
  const storeFactories = [
    {
      name: "sqlite",
      createStore: async () => {
        const database = createMigratedInMemoryDatabase();
        return createSqliteThreadsStore(() => database);
      },
    },
    {
      name: "in-memory",
      createStore: async () => createInMemoryThreadsStore(),
    },
  ] as const;

  for (const storeFactory of storeFactories) {
    test(`${storeFactory.name} inserts workspace-thread links`, async () => {
      const store = await storeFactory.createStore();

      await store.upsertWorkspaceThreadLinks({
        workspaceId: "workspace-1",
        provider: "codex",
        seenAt: "2026-04-10T10:00:00.000Z",
        links: [
          {
            threadId: "thread-1",
            threadWorkspacePath: "/tmp/project",
            archived: false,
          },
        ],
      });

      await expect(
        store.getWorkspaceThreadLink({
          workspaceId: "workspace-1",
          provider: "codex",
          threadId: "thread-1",
        }),
      ).resolves.toEqual({
        workspaceId: "workspace-1",
        provider: "codex",
        threadId: "thread-1",
        threadWorkspacePath: "/tmp/project",
        archived: false,
        firstSeenAt: "2026-04-10T10:00:00.000Z",
        lastSeenAt: "2026-04-10T10:00:00.000Z",
      });
    });

    test(`${storeFactory.name} performs idempotent upserts for repeated sightings`, async () => {
      const store = await storeFactory.createStore();

      await store.upsertWorkspaceThreadLinks({
        workspaceId: "workspace-1",
        provider: "codex",
        seenAt: "2026-04-10T10:00:00.000Z",
        links: [
          {
            threadId: "thread-1",
            threadWorkspacePath: "/tmp/project",
            archived: false,
          },
        ],
      });
      await store.upsertWorkspaceThreadLinks({
        workspaceId: "workspace-1",
        provider: "codex",
        seenAt: "2026-04-10T11:00:00.000Z",
        links: [
          {
            threadId: "thread-1",
            threadWorkspacePath: "/tmp/project",
            archived: true,
          },
        ],
      });

      await expect(
        store.listWorkspaceThreadLinks({
          workspaceId: "workspace-1",
          provider: "codex",
        }),
      ).resolves.toEqual([
        {
          workspaceId: "workspace-1",
          provider: "codex",
          threadId: "thread-1",
          threadWorkspacePath: "/tmp/project",
          archived: true,
          firstSeenAt: "2026-04-10T10:00:00.000Z",
          lastSeenAt: "2026-04-10T11:00:00.000Z",
        },
      ]);
    });

    test(`${storeFactory.name} keeps associations separate per workspace`, async () => {
      const store = await storeFactory.createStore();

      await store.upsertWorkspaceThreadLinks({
        workspaceId: "workspace-1",
        provider: "codex",
        seenAt: "2026-04-10T10:00:00.000Z",
        links: [
          {
            threadId: "thread-1",
            threadWorkspacePath: "/tmp/project-a",
            archived: false,
          },
        ],
      });
      await store.upsertWorkspaceThreadLinks({
        workspaceId: "workspace-2",
        provider: "codex",
        seenAt: "2026-04-10T10:30:00.000Z",
        links: [
          {
            threadId: "thread-1",
            threadWorkspacePath: "/tmp/project-b",
            archived: false,
          },
        ],
      });

      await expect(
        store.listWorkspaceThreadLinks({
          workspaceId: "workspace-1",
          provider: "codex",
        }),
      ).resolves.toEqual([
        {
          workspaceId: "workspace-1",
          provider: "codex",
          threadId: "thread-1",
          threadWorkspacePath: "/tmp/project-a",
          archived: false,
          firstSeenAt: "2026-04-10T10:00:00.000Z",
          lastSeenAt: "2026-04-10T10:00:00.000Z",
        },
      ]);
      await expect(
        store.listWorkspaceThreadLinks({
          workspaceId: "workspace-2",
          provider: "codex",
        }),
      ).resolves.toEqual([
        {
          workspaceId: "workspace-2",
          provider: "codex",
          threadId: "thread-1",
          threadWorkspacePath: "/tmp/project-b",
          archived: false,
          firstSeenAt: "2026-04-10T10:30:00.000Z",
          lastSeenAt: "2026-04-10T10:30:00.000Z",
        },
      ]);
    });
  }
});

const createMigratedInMemoryDatabase = (): AppDatabase => {
  const sqliteHandle = new Database(":memory:", { strict: true });
  const database = drizzle(sqliteHandle);

  migrate(database, {
    migrationsFolder: DEFAULT_MIGRATIONS_FOLDER,
  });

  return database;
};
