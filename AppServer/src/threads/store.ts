import { and, asc, eq } from "drizzle-orm";
import { integer, sqliteTable, text, uniqueIndex } from "drizzle-orm/sqlite-core";
import type { AgentProvider, AgentReasoningEffort } from "@/agents/contracts";
import type { AppDatabase } from "@/core/store";

export const workspaceThreadsTable = sqliteTable(
  "workspace_threads",
  {
    workspaceId: text("workspace_id").notNull(),
    provider: text("provider").notNull(),
    threadId: text("thread_id").notNull(),
    threadWorkspacePath: text("thread_workspace_path").notNull(),
    archived: integer("archived", { mode: "boolean" }).notNull(),
    model: text("model"),
    reasoningEffort: text("reasoning_effort"),
    firstSeenAt: text("first_seen_at").notNull(),
    lastSeenAt: text("last_seen_at").notNull(),
  },
  (table) => [
    uniqueIndex("workspace_threads_workspace_provider_thread_unique").on(
      table.workspaceId,
      table.provider,
      table.threadId,
    ),
  ],
);

type WorkspaceThreadRow = typeof workspaceThreadsTable.$inferSelect;

export type WorkspaceThreadLink = Readonly<{
  workspaceId: string;
  provider: AgentProvider;
  threadId: string;
  threadWorkspacePath: string;
  archived: boolean;
  model: string | null;
  reasoningEffort: AgentReasoningEffort | null;
  firstSeenAt: string;
  lastSeenAt: string;
}>;

export type WorkspaceThreadLinkLookup = Readonly<{
  workspaceId: string;
  provider: AgentProvider;
  threadId: string;
}>;

export type WorkspaceThreadLinkRecord = Readonly<{
  threadId: string;
  threadWorkspacePath: string;
  archived: boolean;
  model?: string | null;
  reasoningEffort?: AgentReasoningEffort | null;
}>;

export type UpsertWorkspaceThreadLinksInput = Readonly<{
  workspaceId: string;
  provider: AgentProvider;
  seenAt: string;
  links: readonly WorkspaceThreadLinkRecord[];
}>;

export type ListWorkspaceThreadLinksInput = Readonly<{
  workspaceId: string;
  provider: AgentProvider;
}>;

export type ThreadsStore = Readonly<{
  getWorkspaceThreadLink: (
    lookup: WorkspaceThreadLinkLookup,
  ) => Promise<WorkspaceThreadLink | undefined>;
  listWorkspaceThreadLinks: (
    input: ListWorkspaceThreadLinksInput,
  ) => Promise<readonly WorkspaceThreadLink[]>;
  upsertWorkspaceThreadLinks: (input: UpsertWorkspaceThreadLinksInput) => Promise<void>;
}>;

type AppDatabaseProvider = () => AppDatabase;

export const createSqliteThreadsStore = (getDatabase: AppDatabaseProvider): ThreadsStore => {
  const getWorkspaceThreadLink: ThreadsStore["getWorkspaceThreadLink"] = async (lookup) => {
    const database = getDatabase();
    const row = database
      .select()
      .from(workspaceThreadsTable)
      .where(
        and(
          eq(workspaceThreadsTable.workspaceId, lookup.workspaceId),
          eq(workspaceThreadsTable.provider, lookup.provider),
          eq(workspaceThreadsTable.threadId, lookup.threadId),
        ),
      )
      .get();

    return row === undefined ? undefined : mapWorkspaceThreadRow(row);
  };

  const listWorkspaceThreadLinks: ThreadsStore["listWorkspaceThreadLinks"] = async (input) => {
    const database = getDatabase();
    const rows = database
      .select()
      .from(workspaceThreadsTable)
      .where(
        and(
          eq(workspaceThreadsTable.workspaceId, input.workspaceId),
          eq(workspaceThreadsTable.provider, input.provider),
        ),
      )
      .orderBy(asc(workspaceThreadsTable.threadId))
      .all();

    return rows.map(mapWorkspaceThreadRow);
  };

  const upsertWorkspaceThreadLinks: ThreadsStore["upsertWorkspaceThreadLinks"] = async (input) => {
    const database = getDatabase();

    for (const link of input.links) {
      const existing = await getWorkspaceThreadLink({
        workspaceId: input.workspaceId,
        provider: input.provider,
        threadId: link.threadId,
      });

      if (existing === undefined) {
        insertWorkspaceThreadLink(database, input, link);
        continue;
      }

      updateWorkspaceThreadLink(database, input, link, existing.firstSeenAt);
    }
  };

  return Object.freeze({
    getWorkspaceThreadLink,
    listWorkspaceThreadLinks,
    upsertWorkspaceThreadLinks,
  });
};

export const createInMemoryThreadsStore = (
  initialLinks: readonly WorkspaceThreadLink[] = [],
): ThreadsStore => {
  const linksByKey = new Map(
    initialLinks.map((link) => [toWorkspaceThreadKey(link), Object.freeze({ ...link })] as const),
  );

  return Object.freeze({
    getWorkspaceThreadLink: async (lookup) => linksByKey.get(toWorkspaceThreadKey(lookup)),
    listWorkspaceThreadLinks: async ({ workspaceId, provider }) =>
      [...linksByKey.values()]
        .filter((link) => link.workspaceId === workspaceId && link.provider === provider)
        .sort((left, right) => left.threadId.localeCompare(right.threadId)),
    upsertWorkspaceThreadLinks: async (input) => {
      for (const link of input.links) {
        const key = toWorkspaceThreadKey({
          workspaceId: input.workspaceId,
          provider: input.provider,
          threadId: link.threadId,
        });
        const existing = linksByKey.get(key);

        linksByKey.set(
          key,
          Object.freeze({
            workspaceId: input.workspaceId,
            provider: input.provider,
            threadId: link.threadId,
            threadWorkspacePath: link.threadWorkspacePath,
            archived: link.archived,
            model: link.model !== undefined ? link.model : (existing?.model ?? null),
            reasoningEffort:
              link.reasoningEffort !== undefined
                ? link.reasoningEffort
                : (existing?.reasoningEffort ?? null),
            firstSeenAt: existing?.firstSeenAt ?? input.seenAt,
            lastSeenAt: input.seenAt,
          }),
        );
      }
    },
  });
};

const insertWorkspaceThreadLink = (
  database: AppDatabase,
  input: UpsertWorkspaceThreadLinksInput,
  link: WorkspaceThreadLinkRecord,
): void => {
  database
    .insert(workspaceThreadsTable)
    .values({
      workspaceId: input.workspaceId,
      provider: input.provider,
      threadId: link.threadId,
      threadWorkspacePath: link.threadWorkspacePath,
      archived: link.archived,
      model: link.model ?? null,
      reasoningEffort: link.reasoningEffort ?? null,
      firstSeenAt: input.seenAt,
      lastSeenAt: input.seenAt,
    })
    .run();
};

const updateWorkspaceThreadLink = (
  database: AppDatabase,
  input: UpsertWorkspaceThreadLinksInput,
  link: WorkspaceThreadLinkRecord,
  firstSeenAt: string,
): void => {
  database
    .update(workspaceThreadsTable)
    .set({
      threadWorkspacePath: link.threadWorkspacePath,
      archived: link.archived,
      ...(link.model !== undefined ? { model: link.model } : {}),
      ...(link.reasoningEffort !== undefined ? { reasoningEffort: link.reasoningEffort } : {}),
      firstSeenAt,
      lastSeenAt: input.seenAt,
    })
    .where(
      and(
        eq(workspaceThreadsTable.workspaceId, input.workspaceId),
        eq(workspaceThreadsTable.provider, input.provider),
        eq(workspaceThreadsTable.threadId, link.threadId),
      ),
    )
    .run();
};

const mapWorkspaceThreadRow = (row: WorkspaceThreadRow): WorkspaceThreadLink =>
  Object.freeze({
    workspaceId: row.workspaceId,
    provider: row.provider as AgentProvider,
    threadId: row.threadId,
    threadWorkspacePath: row.threadWorkspacePath,
    archived: row.archived,
    model: row.model,
    reasoningEffort: (row.reasoningEffort as AgentReasoningEffort | null) ?? null,
    firstSeenAt: row.firstSeenAt,
    lastSeenAt: row.lastSeenAt,
  });

const toWorkspaceThreadKey = (lookup: WorkspaceThreadLinkLookup): string =>
  `${lookup.workspaceId}:${lookup.provider}:${lookup.threadId}`;
