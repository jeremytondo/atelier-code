import type { WorkspaceOpenParams } from "../../protocol/types";
import { type ValidationResult, invalid, isPlainObject } from "../shared";

export function validateWorkspaceOpenParams(
  value: unknown,
): ValidationResult<WorkspaceOpenParams> {
  if (
    !isPlainObject(value) ||
    typeof value.path !== "string" ||
    value.path.length === 0
  ) {
    return invalid("workspace/open params must include a non-empty path.");
  }

  return {
    ok: true,
    value: {
      path: value.path,
    },
  };
}
