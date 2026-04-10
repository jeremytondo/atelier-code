import { eq } from "drizzle-orm";
import { sqliteTable, text, uniqueIndex } from "drizzle-orm/sqlite-core";
import type { AppDatabase } from "@/core/store";
import type { Workspace } from "@/workspaces/schemas";

export const workspacesTable = sqliteTable(
  "workspaces",
  {
    id: text("id").primaryKey(),
    workspacePath: text("workspace_path").notNull(),
    createdAt: text("created_at").notNull(),
    lastOpenedAt: text("last_opened_at").notNull(),
  },
  (table) => [uniqueIndex("workspaces_workspace_path_unique").on(table.workspacePath)],
);

type WorkspaceRow = typeof workspacesTable.$inferSelect;
type CreateWorkspaceStoreInput = Readonly<{
  workspaceId: string;
  workspacePath: string;
  openedAt: string;
}>;

export type OpenWorkspaceStoreInput = Readonly<{
  workspacePath: string;
  openedAt: string;
  createWorkspaceId: () => string;
}>;

export type WorkspacesStore = Readonly<{
  openWorkspace: (input: OpenWorkspaceStoreInput) => Promise<Workspace>;
}>;

type AppDatabaseProvider = () => AppDatabase;

export const createSqliteWorkspacesStore = (getDatabase: AppDatabaseProvider): WorkspacesStore => {
  const openWorkspace: WorkspacesStore["openWorkspace"] = async (input) => {
    const database = getDatabase();
    const existingWorkspace = findWorkspaceByPath(database, input.workspacePath);

    if (existingWorkspace !== undefined) {
      return reopenWorkspace(database, existingWorkspace, input.openedAt);
    }

    try {
      const workspaceId = input.createWorkspaceId();

      insertWorkspace(database, {
        ...input,
        workspaceId,
      });
      return Object.freeze({
        id: workspaceId,
        workspacePath: input.workspacePath,
        createdAt: input.openedAt,
        lastOpenedAt: input.openedAt,
      });
    } catch (error) {
      const concurrentWorkspace = findWorkspaceByPath(database, input.workspacePath);

      if (concurrentWorkspace === undefined) {
        throw error;
      }

      return reopenWorkspace(database, concurrentWorkspace, input.openedAt);
    }
  };

  return Object.freeze({
    openWorkspace,
  });
};

export const createInMemoryWorkspacesStore = (
  initialWorkspaces: readonly Workspace[] = [],
): WorkspacesStore => {
  const workspacesByPath = new Map<string, Workspace>(
    initialWorkspaces.map((workspace) => [
      workspace.workspacePath,
      Object.freeze({ ...workspace }),
    ]),
  );

  return Object.freeze({
    openWorkspace: async (input) => {
      const existingWorkspace = workspacesByPath.get(input.workspacePath);

      if (existingWorkspace !== undefined) {
        const reopenedWorkspace = Object.freeze({
          ...existingWorkspace,
          lastOpenedAt: input.openedAt,
        });

        workspacesByPath.set(input.workspacePath, reopenedWorkspace);
        return reopenedWorkspace;
      }

      const workspaceId = input.createWorkspaceId();
      const createdWorkspace = Object.freeze({
        id: workspaceId,
        workspacePath: input.workspacePath,
        createdAt: input.openedAt,
        lastOpenedAt: input.openedAt,
      });

      workspacesByPath.set(input.workspacePath, createdWorkspace);
      return createdWorkspace;
    },
  });
};

const findWorkspaceByPath = (
  database: AppDatabase,
  workspacePath: string,
): Workspace | undefined => {
  const workspaceRow = database
    .select()
    .from(workspacesTable)
    .where(eq(workspacesTable.workspacePath, workspacePath))
    .get();

  if (workspaceRow === undefined) {
    return undefined;
  }

  return mapWorkspaceRow(workspaceRow);
};

const insertWorkspace = (database: AppDatabase, input: CreateWorkspaceStoreInput): void => {
  database
    .insert(workspacesTable)
    .values({
      id: input.workspaceId,
      workspacePath: input.workspacePath,
      createdAt: input.openedAt,
      lastOpenedAt: input.openedAt,
    })
    .run();
};

const reopenWorkspace = (
  database: AppDatabase,
  workspace: Workspace,
  openedAt: string,
): Workspace => {
  database
    .update(workspacesTable)
    .set({
      lastOpenedAt: openedAt,
    })
    .where(eq(workspacesTable.id, workspace.id))
    .run();

  return Object.freeze({
    ...workspace,
    lastOpenedAt: openedAt,
  });
};

const mapWorkspaceRow = (workspaceRow: WorkspaceRow): Workspace =>
  Object.freeze({
    id: workspaceRow.id,
    workspacePath: workspaceRow.workspacePath,
    createdAt: workspaceRow.createdAt,
    lastOpenedAt: workspaceRow.lastOpenedAt,
  });
