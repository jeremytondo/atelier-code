import { Database } from "bun:sqlite";
import { mkdir } from "node:fs/promises";
import { dirname, isAbsolute, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { type BunSQLiteDatabase, drizzle } from "drizzle-orm/bun-sqlite";
import { migrate } from "drizzle-orm/bun-sqlite/migrator";
import type { AppServerConfig } from "@/app/config";
import type { Logger } from "@/app/logger";
import type { LifecycleComponent } from "@/core/shared";

const STORE_DIRECTORY = dirname(fileURLToPath(import.meta.url));

export const DEFAULT_MIGRATIONS_FOLDER = resolve(STORE_DIRECTORY, "../../../drizzle");

export type AppDatabase = BunSQLiteDatabase<Record<string, never>> & {
  readonly $client: Database;
};

export type StoreBootstrap = Readonly<{
  lifecycle: LifecycleComponent;
  getDatabase: () => AppDatabase;
  getDatabasePath: () => string;
  getSqliteHandle: () => Database;
}>;

export type CreateStoreBootstrapOptions = Readonly<{
  config: AppServerConfig;
  logger: Logger;
  migrationsFolder?: string;
}>;

export const createStoreBootstrap = (options: CreateStoreBootstrapOptions): StoreBootstrap => {
  const databasePath = resolveDatabasePath(options.config);
  const migrationsFolder = options.migrationsFolder ?? DEFAULT_MIGRATIONS_FOLDER;
  const logger = options.logger;
  let database: AppDatabase | null = null;
  let sqliteHandle: Database | null = null;

  const lifecycle: LifecycleComponent = Object.freeze({
    name: "core.store",
    start: async () => {
      if (database !== null && sqliteHandle !== null) {
        return;
      }

      await mkdir(dirname(databasePath), { recursive: true });

      const openedSqliteHandle = new Database(databasePath, {
        create: true,
        strict: true,
      });

      try {
        openedSqliteHandle.exec("PRAGMA journal_mode = WAL;");
        const openedDatabase = drizzle(openedSqliteHandle);

        migrate(openedDatabase, {
          migrationsFolder,
        });

        sqliteHandle = openedSqliteHandle;
        database = openedDatabase;

        logger.info("Store bootstrap completed", {
          databasePath,
          migrationsFolder,
        });
      } catch (error) {
        openedSqliteHandle.close(false);
        throw error;
      }
    },
    stop: async (reason) => {
      if (sqliteHandle === null) {
        return;
      }

      sqliteHandle.close(false);
      sqliteHandle = null;
      database = null;

      logger.info("Store bootstrap stopped", {
        databasePath,
        reason,
      });
    },
  });

  return Object.freeze({
    lifecycle,
    getDatabase: () => {
      if (database === null) {
        throw new Error("App Server database is not started");
      }

      return database;
    },
    getDatabasePath: () => databasePath,
    getSqliteHandle: () => {
      if (sqliteHandle === null) {
        throw new Error("App Server SQLite handle is not started");
      }

      return sqliteHandle;
    },
  });
};

export const resolveDatabasePath = (config: AppServerConfig): string =>
  isAbsolute(config.databasePath)
    ? config.databasePath
    : resolve(dirname(config.configPath), config.databasePath);
