import { Database } from "bun:sqlite";
import { describe, expect, test } from "bun:test";
import { drizzle } from "drizzle-orm/bun-sqlite";
import { migrate } from "drizzle-orm/bun-sqlite/migrator";
import { type AppDatabase, DEFAULT_MIGRATIONS_FOLDER } from "@/core/store";
import { createInMemoryWorkspacesStore, createSqliteWorkspacesStore } from "@/workspaces/store";

describe("workspaces store", () => {
  const storeFactories = [
    {
      name: "sqlite",
      createStore: async () => {
        const database = createMigratedInMemoryDatabase();
        return createSqliteWorkspacesStore(() => database);
      },
    },
    {
      name: "in-memory",
      createStore: async () => createInMemoryWorkspacesStore(),
    },
  ] as const;

  for (const storeFactory of storeFactories) {
    test(`${storeFactory.name} creates and reopens a workspace by canonical path`, async () => {
      const store = await storeFactory.createStore();

      const firstOpen = await store.openWorkspace({
        workspaceId: "workspace-1",
        workspacePath: "/tmp/project",
        openedAt: "2026-04-10T10:00:00.000Z",
      });
      const secondOpen = await store.openWorkspace({
        workspaceId: "workspace-2",
        workspacePath: "/tmp/project",
        openedAt: "2026-04-10T11:00:00.000Z",
      });

      expect(firstOpen).toEqual({
        id: "workspace-1",
        workspacePath: "/tmp/project",
        createdAt: "2026-04-10T10:00:00.000Z",
        lastOpenedAt: "2026-04-10T10:00:00.000Z",
      });
      expect(secondOpen).toEqual({
        id: "workspace-1",
        workspacePath: "/tmp/project",
        createdAt: "2026-04-10T10:00:00.000Z",
        lastOpenedAt: "2026-04-10T11:00:00.000Z",
      });
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
