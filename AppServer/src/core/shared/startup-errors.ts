export type StartupErrorCode =
  | "CONFIG_READ_ERROR"
  | "CONFIG_PARSE_ERROR"
  | "CONFIG_VALIDATION_ERROR";

export abstract class StartupError extends Error {
  public readonly code: StartupErrorCode;

  protected constructor(code: StartupErrorCode, message: string, cause?: unknown) {
    super(message, cause === undefined ? undefined : { cause });
    this.name = new.target.name;
    this.code = code;
  }
}

export class ConfigReadStartupError extends StartupError {
  public readonly configPath: string;

  public constructor(configPath: string, cause?: unknown) {
    super("CONFIG_READ_ERROR", `Failed to read App Server config at ${configPath}`, cause);
    this.configPath = configPath;
  }
}

export class ConfigParseStartupError extends StartupError {
  public readonly configPath: string;

  public constructor(configPath: string, details: string) {
    super("CONFIG_PARSE_ERROR", `Failed to parse App Server config at ${configPath}: ${details}`);
    this.configPath = configPath;
  }
}

export class ConfigValidationStartupError extends StartupError {
  public readonly configPath: string;
  public readonly issues: readonly string[];

  public constructor(configPath: string, issues: readonly string[]) {
    super(
      "CONFIG_VALIDATION_ERROR",
      `Invalid App Server config at ${configPath}: ${issues.join("; ")}`,
    );
    this.configPath = configPath;
    this.issues = issues;
  }
}
