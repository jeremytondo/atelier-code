import { describe, expect, test } from "bun:test";
import { runConnectionClosedHandlers } from "@/app/protocol";

describe("runConnectionClosedHandlers", () => {
  test("runs every handler and aggregates failures after all handlers complete", async () => {
    const events: string[] = [];

    await expect(
      runConnectionClosedHandlers(
        [
          ({ connectionId }) => {
            events.push(`first:${connectionId}`);
            throw new Error("first failed");
          },
          ({ connectionId }) => {
            events.push(`second:${connectionId}`);
          },
          async ({ connectionId }) => {
            events.push(`third:${connectionId}`);
            throw new Error("third failed");
          },
        ],
        "connection-1",
      ),
    ).rejects.toThrow("Connection close handlers failed");

    expect(events).toEqual(["first:connection-1", "second:connection-1", "third:connection-1"]);
  });

  test("rethrows a single failure without wrapping it", async () => {
    await expect(
      runConnectionClosedHandlers(
        [
          () => {
            throw new Error("single failed");
          },
        ],
        "connection-1",
      ),
    ).rejects.toThrow("single failed");
  });
});
