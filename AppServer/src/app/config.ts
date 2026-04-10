import { readFile } from "node:fs/promises";
import { isAbsolute, resolve } from "node:path";
import { type Static, Type } from "@sinclair/typebox";
import { Value } from "@sinclair/typebox/value";
import { AgentsConfigSchema, validateAgentsConfig } from "@/agents";
import {
  ConfigParseStartupError,
  ConfigReadStartupError,
  ConfigValidationStartupError,
} from "@/core/shared";

export const APP_SERVER_CONFIG_PATH_ENV = "APP_SERVER_CONFIG_PATH";
export const APP_SERVER_PORT_ENV = "APP_SERVER_PORT";
export const APP_SERVER_DATABASE_PATH_ENV = "APP_SERVER_DATABASE_PATH";
export const APP_SERVER_LOG_LEVEL_ENV = "APP_SERVER_LOG_LEVEL";

export const DEFAULT_APP_SERVER_CONFIG_PATH = "appserver.config.example.json";

const AppServerConfigFileSchema = Type.Object(
  {
    port: Type.Integer({ minimum: 1, maximum: 65535 }),
    databasePath: Type.String({ minLength: 1 }),
    logLevel: Type.Union([
      Type.Literal("debug"),
      Type.Literal("info"),
      Type.Literal("warn"),
      Type.Literal("error"),
    ]),
    agents: AgentsConfigSchema,
  },
  { additionalProperties: false },
);

type AppServerConfigFile = Static<typeof AppServerConfigFileSchema>;

export type AppServerEnvironment = Readonly<
  Partial<
    Record<
      | typeof APP_SERVER_CONFIG_PATH_ENV
      | typeof APP_SERVER_PORT_ENV
      | typeof APP_SERVER_DATABASE_PATH_ENV
      | typeof APP_SERVER_LOG_LEVEL_ENV,
      string | undefined
    >
  >
>;

export type AppServerConfig = Readonly<
  AppServerConfigFile & {
    readonly configPath: string;
  }
>;

export type LoadAppServerConfigOptions = Readonly<{
  cwd?: string;
  env?: AppServerEnvironment;
  readTextFile?: (path: string) => Promise<string>;
}>;

export const loadAppServerConfig = async (
  options: LoadAppServerConfigOptions = {},
): Promise<AppServerConfig> => {
  const cwd = options.cwd ?? process.cwd();
  const env = resolveEnvironment(options.env);
  const configPath = resolveConfigPath(cwd, env[APP_SERVER_CONFIG_PATH_ENV]);
  const readTextFile = options.readTextFile ?? readTextFileFromDisk;

  const rawConfigText = await readConfigText(configPath, readTextFile);
  const parsedConfig = parseConfigText(rawConfigText, configPath);
  const configFromFile = validateConfig(parsedConfig, configPath, "configuration file");
  const resolvedConfig = applyEnvironmentOverrides(configFromFile, env, configPath);

  return Object.freeze({
    configPath,
    ...resolvedConfig,
  });
};

const resolveConfigPath = (cwd: string, configPathOverride: string | undefined): string => {
  const rawPath = configPathOverride?.trim() || DEFAULT_APP_SERVER_CONFIG_PATH;

  return isAbsolute(rawPath) ? rawPath : resolve(cwd, rawPath);
};

const readConfigText = async (
  configPath: string,
  readTextFile: (path: string) => Promise<string>,
): Promise<string> => {
  try {
    return await readTextFile(configPath);
  } catch (error) {
    throw new ConfigReadStartupError(configPath, error);
  }
};

const parseConfigText = (rawConfigText: string, configPath: string): unknown => {
  try {
    return JSON.parse(rawConfigText) as unknown;
  } catch (error) {
    const message = error instanceof Error ? error.message : "Invalid JSON";
    throw new ConfigParseStartupError(configPath, message);
  }
};

const validateConfig = (
  candidate: unknown,
  configPath: string,
  source: string,
): AppServerConfigFile => {
  if (!Value.Check(AppServerConfigFileSchema, candidate)) {
    const issues = [
      ...[...Value.Errors(AppServerConfigFileSchema, candidate)].map((validationError) => {
        const path = validationError.path || "/";
        return `${source} ${path}: ${validationError.message}`;
      }),
    ];

    throw new ConfigValidationStartupError(configPath, issues);
  }

  const validatedConfig = candidate as AppServerConfigFile;
  const agentConfigIssues = validateAgentsConfig(validatedConfig.agents);

  if (agentConfigIssues.length > 0) {
    throw new ConfigValidationStartupError(configPath, [...agentConfigIssues]);
  }

  return Object.freeze({
    port: validatedConfig.port,
    databasePath: validatedConfig.databasePath,
    logLevel: validatedConfig.logLevel,
    agents: validatedConfig.agents,
  });
};

const applyEnvironmentOverrides = (
  config: AppServerConfigFile,
  env: AppServerEnvironment,
  configPath: string,
): AppServerConfigFile => {
  const candidate: Record<string, unknown> = {
    ...config,
  };

  if (env[APP_SERVER_PORT_ENV] !== undefined) {
    candidate.port = parsePortOverride(env[APP_SERVER_PORT_ENV]);
  }

  if (env[APP_SERVER_DATABASE_PATH_ENV] !== undefined) {
    candidate.databasePath = env[APP_SERVER_DATABASE_PATH_ENV].trim();
  }

  if (env[APP_SERVER_LOG_LEVEL_ENV] !== undefined) {
    candidate.logLevel = parseLogLevelOverride(env[APP_SERVER_LOG_LEVEL_ENV]);
  }

  return validateConfig(candidate, configPath, "resolved configuration");
};

const parsePortOverride = (rawPort: string): number => {
  const trimmedPort = rawPort.trim();

  if (!/^\d+$/.test(trimmedPort)) {
    return Number.NaN;
  }

  return Number.parseInt(trimmedPort, 10);
};

const parseLogLevelOverride = (rawLogLevel: string): string => {
  return rawLogLevel.trim();
};

const resolveEnvironment = (env: AppServerEnvironment | undefined): AppServerEnvironment =>
  Object.freeze({
    [APP_SERVER_CONFIG_PATH_ENV]:
      env?.[APP_SERVER_CONFIG_PATH_ENV] ?? process.env[APP_SERVER_CONFIG_PATH_ENV],
    [APP_SERVER_PORT_ENV]: env?.[APP_SERVER_PORT_ENV] ?? process.env[APP_SERVER_PORT_ENV],
    [APP_SERVER_DATABASE_PATH_ENV]:
      env?.[APP_SERVER_DATABASE_PATH_ENV] ?? process.env[APP_SERVER_DATABASE_PATH_ENV],
    [APP_SERVER_LOG_LEVEL_ENV]:
      env?.[APP_SERVER_LOG_LEVEL_ENV] ?? process.env[APP_SERVER_LOG_LEVEL_ENV],
  });

const readTextFileFromDisk = async (path: string): Promise<string> =>
  readFile(path, { encoding: "utf8" });
