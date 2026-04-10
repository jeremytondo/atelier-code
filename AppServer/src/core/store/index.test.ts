import { afterEach, describe, expect, test } from "bun:test";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createStoreBootstrap, resolveDatabasePath } from "@/core/store";
import { createSilentLogger } from "@/test-support/logger";

const temporaryDirectories: string[] = [];

afterEach(async () => {
  while (temporaryDirectories.length > 0) {
    const directory = temporaryDirectories.pop();

    if (directory === undefined) {
      continue;
    }

    await rm(directory, { force: true, recursive: true });
  }
});

describe("resolveDatabasePath", () => {
  test("resolves relative database paths from the config file directory", () => {
    expect(
      resolveDatabasePath({
        configPath: "/tmp/config/appserver.config.json",
        port: 7331,
        databasePath: "./var/appserver.sqlite",
        logLevel: "info",
      }),
    ).toBe("/tmp/config/var/appserver.sqlite");
  });
});

describe("createStoreBootstrap", () => {
  test("applies migrations for a fresh database", async () => {
    const config = await createTestConfig();
    const bootstrap = createStoreBootstrap({
      config,
      logger: createSilentLogger(),
    });

    await bootstrap.lifecycle.start();

    const databaseFile = await readFile(bootstrap.getDatabasePath(), "utf8");
    const workspacesTable = bootstrap
      .getSqliteHandle()
      .query("select name from sqlite_master where type = 'table' and name = 'workspaces' limit 1")
      .get() as { readonly name: string } | undefined;

    expect(databaseFile.length).toBeGreaterThan(0);
    expect(workspacesTable).toEqual({ name: "workspaces" });
  });

  test("starts cleanly when the database is already migrated", async () => {
    const config = await createTestConfig();
    const bootstrap = createStoreBootstrap({
      config,
      logger: createSilentLogger(),
    });

    await bootstrap.lifecycle.start();
    await bootstrap.lifecycle.stop("first-stop");
    await expect(bootstrap.lifecycle.start()).resolves.toBeUndefined();
  });

  test("closes the database handle during shutdown", async () => {
    const config = await createTestConfig();
    const bootstrap = createStoreBootstrap({
      config,
      logger: createSilentLogger(),
    });

    await bootstrap.lifecycle.start();
    const sqliteHandle = bootstrap.getSqliteHandle();

    await bootstrap.lifecycle.stop("test-stop");

    expect(() => sqliteHandle.query("select 1").get()).toThrow();
    expect(() => bootstrap.getSqliteHandle()).toThrow("App Server SQLite handle is not started");
  });

  test("fails startup cleanly when migrations are invalid", async () => {
    const config = await createTestConfig();
    const migrationsFolder = await createBrokenMigrationsFolder();
    const bootstrap = createStoreBootstrap({
      config,
      logger: createSilentLogger(),
      migrationsFolder,
    });

    await expect(bootstrap.lifecycle.start()).rejects.toThrow();
    expect(() => bootstrap.getSqliteHandle()).toThrow("App Server SQLite handle is not started");
  });
});

const createBrokenMigrationsFolder = async (): Promise<string> => {
  const directory = await createTemporaryDirectory("atelier-appserver-store-bad-migrations-");
  const metaDirectory = join(directory, "meta");

  await mkdir(metaDirectory, { recursive: true });
  await writeFile(
    join(metaDirectory, "_journal.json"),
    JSON.stringify({
      version: "7",
      dialect: "sqlite",
      entries: [
        {
          idx: 0,
          version: "7",
          when: 1_744_322_400_000,
          tag: "0000_broken",
          breakpoints: true,
        },
      ],
    }),
  );
  await writeFile(join(directory, "0000_broken.sql"), "this is not valid sql;");

  return directory;
};

const createTestConfig = async () => {
  const configDirectory = await createTemporaryDirectory("atelier-appserver-store-config-");

  return Object.freeze({
    configPath: join(configDirectory, "appserver.config.json"),
    port: 0,
    databasePath: "./var/test.sqlite",
    logLevel: "info" as const,
  });
};

const createTemporaryDirectory = async (prefix: string): Promise<string> => {
  const directory = await mkdtemp(join(tmpdir(), prefix));
  temporaryDirectories.push(directory);
  return directory;
};
