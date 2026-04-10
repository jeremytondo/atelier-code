import { readFileSync } from "node:fs";
import { dirname, isAbsolute, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { defineConfig } from "drizzle-kit";

const ROOT_DIRECTORY = dirname(fileURLToPath(import.meta.url));
const DEFAULT_CONFIG_PATH = resolve(ROOT_DIRECTORY, "appserver.config.example.json");

type AppServerConfigFile = Readonly<{
  databasePath?: unknown;
}>;

const resolveConfigPath = (): string => {
  const rawPath = process.env.APP_SERVER_CONFIG_PATH?.trim() || DEFAULT_CONFIG_PATH;

  return isAbsolute(rawPath) ? rawPath : resolve(process.cwd(), rawPath);
};

const resolveDatabasePath = (): string => {
  const configPath = resolveConfigPath();
  const rawConfig = JSON.parse(readFileSync(configPath, "utf8")) as AppServerConfigFile;

  if (typeof rawConfig.databasePath !== "string" || rawConfig.databasePath.trim() === "") {
    throw new Error(`App Server drizzle config is missing a databasePath in ${configPath}`);
  }

  const trimmedDatabasePath = rawConfig.databasePath.trim();

  return isAbsolute(trimmedDatabasePath)
    ? trimmedDatabasePath
    : resolve(dirname(configPath), trimmedDatabasePath);
};

export default defineConfig({
  dialect: "sqlite",
  schema: "./src/**/store.ts",
  out: "./drizzle",
  dbCredentials: {
    url: resolveDatabasePath(),
  },
});
