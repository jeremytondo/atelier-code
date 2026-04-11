import { describe, expect, test } from "bun:test";
import { mapCodexThread } from "@/agents/codex-adapter/model-mapper";

describe("mapCodexThread", () => {
  test("rejects negative provider timestamps instead of clamping them", () => {
    expect(() =>
      mapCodexThread({
        id: "thread-1",
        preview: "Thread preview",
        createdAt: -1,
        updatedAt: 1,
        name: null,
        status: { type: "idle" },
        cwd: "/tmp/project",
      }),
    ).toThrow("Codex thread createdAt must be a non-negative unix timestamp.");
  });
});
