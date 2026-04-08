import type { ThreadStartParams } from "../../protocol/types";
import {
  type ValidationResult,
  assignOptional,
  invalid,
  isOptionalApprovalPolicy,
  isOptionalArray,
  isOptionalBoolean,
  isOptionalPlainObject,
  isOptionalSandboxMode,
  isOptionalServiceTier,
  isOptionalString,
  isPlainObject,
} from "../shared";

export function validateThreadStartParams(
  value: unknown,
): ValidationResult<ThreadStartParams> {
  if (!isPlainObject(value)) {
    return invalid("thread/start params must be an object.");
  }

  if (typeof value.experimentalRawEvents !== "boolean") {
    return invalid(
      "thread/start params must include boolean experimentalRawEvents.",
    );
  }

  if (typeof value.persistExtendedHistory !== "boolean") {
    return invalid(
      "thread/start params must include boolean persistExtendedHistory.",
    );
  }

  if (!isOptionalString(value.model)) {
    return invalid("thread/start model must be a string when provided.");
  }

  if (!isOptionalString(value.modelProvider)) {
    return invalid(
      "thread/start modelProvider must be a string when provided.",
    );
  }

  if (!isOptionalServiceTier(value.serviceTier)) {
    return invalid(
      "thread/start serviceTier must be fast, flex, null, or omitted.",
    );
  }

  if (!isOptionalString(value.cwd)) {
    return invalid("thread/start cwd must be a string when provided.");
  }

  if (!isOptionalApprovalPolicy(value.approvalPolicy)) {
    return invalid(
      "thread/start approvalPolicy must be a Codex-shaped approval policy when provided.",
    );
  }

  if (!isOptionalSandboxMode(value.sandbox)) {
    return invalid(
      "thread/start sandbox must be a supported sandbox mode when provided.",
    );
  }

  if (!isOptionalPlainObject(value.config)) {
    return invalid("thread/start config must be an object when provided.");
  }

  if (!isOptionalString(value.serviceName)) {
    return invalid("thread/start serviceName must be a string when provided.");
  }

  if (!isOptionalString(value.baseInstructions)) {
    return invalid(
      "thread/start baseInstructions must be a string when provided.",
    );
  }

  if (!isOptionalString(value.developerInstructions)) {
    return invalid(
      "thread/start developerInstructions must be a string when provided.",
    );
  }

  if (!isOptionalString(value.personality)) {
    return invalid("thread/start personality must be a string when provided.");
  }

  if (!isOptionalBoolean(value.ephemeral)) {
    return invalid("thread/start ephemeral must be a boolean when provided.");
  }

  if (!isOptionalArray(value.dynamicTools)) {
    return invalid("thread/start dynamicTools must be an array when provided.");
  }

  if (!isOptionalString(value.mockExperimentalField)) {
    return invalid(
      "thread/start mockExperimentalField must be a string when provided.",
    );
  }

  return {
    ok: true,
    value: buildThreadStartParams(value),
  };
}

function buildThreadStartParams(
  value: Record<string, unknown>,
): ThreadStartParams {
  const params: ThreadStartParams = {
    experimentalRawEvents: value.experimentalRawEvents as boolean,
    persistExtendedHistory: value.persistExtendedHistory as boolean,
  };

  assignOptional(params, "model", value.model as ThreadStartParams["model"]);
  assignOptional(
    params,
    "modelProvider",
    value.modelProvider as ThreadStartParams["modelProvider"],
  );
  assignOptional(
    params,
    "serviceTier",
    value.serviceTier as ThreadStartParams["serviceTier"],
  );
  assignOptional(params, "cwd", value.cwd as ThreadStartParams["cwd"]);
  assignOptional(
    params,
    "approvalPolicy",
    value.approvalPolicy as ThreadStartParams["approvalPolicy"],
  );
  assignOptional(
    params,
    "sandbox",
    value.sandbox as ThreadStartParams["sandbox"],
  );
  assignOptional(params, "config", value.config as ThreadStartParams["config"]);
  assignOptional(
    params,
    "serviceName",
    value.serviceName as ThreadStartParams["serviceName"],
  );
  assignOptional(
    params,
    "baseInstructions",
    value.baseInstructions as ThreadStartParams["baseInstructions"],
  );
  assignOptional(
    params,
    "developerInstructions",
    value.developerInstructions as ThreadStartParams["developerInstructions"],
  );
  assignOptional(
    params,
    "personality",
    value.personality as ThreadStartParams["personality"],
  );
  assignOptional(
    params,
    "ephemeral",
    value.ephemeral as ThreadStartParams["ephemeral"],
  );
  assignOptional(
    params,
    "dynamicTools",
    value.dynamicTools as ThreadStartParams["dynamicTools"],
  );
  assignOptional(
    params,
    "mockExperimentalField",
    value.mockExperimentalField as ThreadStartParams["mockExperimentalField"],
  );

  return params;
}
