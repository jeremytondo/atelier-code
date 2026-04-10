import { describe, expect, test } from "bun:test";
import { createLogger } from "@/app/logger";

describe("createLogger", () => {
  test("emits structured JSON log lines", () => {
    const lines: string[] = [];
    const logger = createLogger({
      level: "info",
      now: () => "2026-04-09T00:00:00.000Z",
      write: (line) => {
        lines.push(line);
      },
    });

    logger.info("hello");

    expect(lines).toHaveLength(1);
    expect(JSON.parse(lines[0])).toEqual({
      timestamp: "2026-04-09T00:00:00.000Z",
      level: "info",
      message: "hello",
    });
  });

  test("merges base context with per-call context", () => {
    const lines: string[] = [];
    const logger = createLogger({
      level: "debug",
      context: { connectionId: "conn-1" },
      now: () => "2026-04-09T00:00:00.000Z",
      write: (line) => {
        lines.push(line);
      },
    });

    logger.info("context", { threadId: "thread-1" });

    expect(JSON.parse(lines[0])).toEqual({
      timestamp: "2026-04-09T00:00:00.000Z",
      level: "info",
      message: "context",
      connectionId: "conn-1",
      threadId: "thread-1",
    });
  });

  test("withContext creates a derived logger without mutating the parent logger", () => {
    const lines: string[] = [];
    const logger = createLogger({
      level: "info",
      context: { connectionId: "conn-1" },
      now: () => "2026-04-09T00:00:00.000Z",
      write: (line) => {
        lines.push(line);
      },
    });
    const childLogger = logger.withContext({ threadId: "thread-1" });

    logger.info("parent");
    childLogger.info("child");

    expect(JSON.parse(lines[0])).toEqual({
      timestamp: "2026-04-09T00:00:00.000Z",
      level: "info",
      message: "parent",
      connectionId: "conn-1",
    });
    expect(JSON.parse(lines[1])).toEqual({
      timestamp: "2026-04-09T00:00:00.000Z",
      level: "info",
      message: "child",
      connectionId: "conn-1",
      threadId: "thread-1",
    });
  });
});
