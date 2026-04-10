import { createLogger, type Logger, type LogLevel } from "@/app/logger";

type CapturedLogRecord = Readonly<Record<string, unknown>>;

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

export const createSilentLogger = (level: LogLevel = "info"): Logger =>
  createLogger({
    level,
    write: () => {},
  });

export const createCapturingLogger = (
  level: LogLevel = "debug",
): Readonly<{
  logger: Logger;
  records: CapturedLogRecord[];
}> => {
  const records: CapturedLogRecord[] = [];
  const logger = createLogger({
    level,
    write: (line) => {
      const parsed = JSON.parse(line) as unknown;

      if (!isRecord(parsed)) {
        throw new Error("Expected structured log output");
      }

      records.push(Object.freeze({ ...parsed }));
    },
  });

  return Object.freeze({
    logger,
    records,
  });
};
