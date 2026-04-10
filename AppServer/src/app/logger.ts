export const LOG_LEVELS = ["debug", "info", "warn", "error"] as const;

export type LogLevel = (typeof LOG_LEVELS)[number];
export type LogValue = string | number | boolean | null;
export type LogContext = Readonly<Record<string, LogValue>>;
export type LogWriter = (line: string) => void;

export type Logger = Readonly<{
  level: LogLevel;
  debug: (message: string, context?: LogContext) => void;
  info: (message: string, context?: LogContext) => void;
  warn: (message: string, context?: LogContext) => void;
  error: (message: string, context?: LogContext) => void;
  withContext: (context: LogContext) => Logger;
}>;

export type CreateLoggerOptions = Readonly<{
  level: LogLevel;
  context?: LogContext;
  now?: () => string;
  write?: LogWriter;
}>;

type LogRecord = Readonly<
  {
    timestamp: string;
    level: LogLevel;
    message: string;
  } & Record<string, LogValue>
>;

const LOG_LEVEL_PRIORITY: Readonly<Record<LogLevel, number>> = {
  debug: 10,
  info: 20,
  warn: 30,
  error: 40,
};

export const createLogger = (options: CreateLoggerOptions): Logger => {
  const baseContext = Object.freeze({ ...(options.context ?? {}) });
  const now = options.now ?? defaultNow;
  const write = options.write ?? defaultWrite;

  const shouldLog = (level: LogLevel): boolean =>
    LOG_LEVEL_PRIORITY[level] >= LOG_LEVEL_PRIORITY[options.level];

  const emit = (level: LogLevel, message: string, context?: LogContext): void => {
    if (!shouldLog(level)) {
      return;
    }

    const record: LogRecord = {
      timestamp: now(),
      level,
      message,
      ...baseContext,
      ...(context ?? {}),
    };

    write(JSON.stringify(record));
  };

  return Object.freeze({
    level: options.level,
    debug: (message, context) => emit("debug", message, context),
    info: (message, context) => emit("info", message, context),
    warn: (message, context) => emit("warn", message, context),
    error: (message, context) => emit("error", message, context),
    withContext: (context) =>
      createLogger({
        level: options.level,
        now,
        write,
        context: {
          ...baseContext,
          ...context,
        },
      }),
  });
};

const defaultNow = (): string => new Date().toISOString();

const defaultWrite = (line: string): void => {
  console.log(line);
};
