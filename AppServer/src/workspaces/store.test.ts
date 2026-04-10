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
      let nextWorkspaceId = 1;
      let createWorkspaceIdCallCount = 0;
      const createWorkspaceId = () => {
        createWorkspaceIdCallCount += 1;
        const workspaceId = `workspace-${nextWorkspaceId}`;
        nextWorkspaceId += 1;
        return workspaceId;
      };

      const firstOpen = await store.openWorkspace({
        workspacePath: "/tmp/project",
        openedAt: "2026-04-10T10:00:00.000Z",
        createWorkspaceId,
      });
      const secondOpen = await store.openWorkspace({
        workspacePath: "/tmp/project",
        openedAt: "2026-04-10T11:00:00.000Z",
        createWorkspaceId,
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
      expect(createWorkspaceIdCallCount).toBe(1);
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
