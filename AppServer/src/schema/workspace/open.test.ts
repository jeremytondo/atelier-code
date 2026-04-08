import { describe, expect, test } from "bun:test";

import { validateWorkspaceOpenParams } from "./open";

describe("workspace/open schema", () => {
  test("rejects empty paths", () => {
    expect(
      validateWorkspaceOpenParams({
        path: "",
      }),
    ).toEqual({
      ok: false,
      error: "workspace/open params must include a non-empty path.",
    });
  });

  test("returns typed workspace/open params", () => {
    expect(
      validateWorkspaceOpenParams({
        path: "/tmp/project",
      }),
    ).toEqual({
      ok: true,
      value: {
        path: "/tmp/project",
      },
    });
  });
});
