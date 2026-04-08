import type { TurnStartParams } from "../../core/protocol/types";
import type { UserInputRecord } from "../../core/shared/models";
import {
  type ValidationResult,
  assignOptional,
  invalid,
  isOptionalApprovalPolicy,
  isOptionalReasoningEffort,
  isOptionalServiceTier,
  isOptionalString,
  isPlainObject,
} from "../../core/shared/validation-utils";

export function validateTurnStartParams(
  value: unknown,
): ValidationResult<TurnStartParams> {
  if (
    !isPlainObject(value) ||
    typeof value.threadId !== "string" ||
    value.threadId.length === 0
  ) {
    return invalid("turn/start params must include a non-empty threadId.");
  }

  if (!Array.isArray(value.input)) {
    return invalid("turn/start params must include an input array.");
  }

  if (!isOptionalString(value.cwd)) {
    return invalid("turn/start cwd must be a string when provided.");
  }

  if (!isOptionalApprovalPolicy(value.approvalPolicy)) {
    return invalid(
      "turn/start approvalPolicy must be a supported approval policy when provided.",
    );
  }

  if (!isOptionalString(value.model)) {
    return invalid("turn/start model must be a string when provided.");
  }

  if (!isOptionalServiceTier(value.serviceTier)) {
    return invalid(
      "turn/start serviceTier must be fast, flex, null, or omitted.",
    );
  }

  if (!isOptionalReasoningEffort(value.effort)) {
    return invalid(
      "turn/start effort must be a supported reasoning effort when provided.",
    );
  }

  if (!isOptionalString(value.personality)) {
    return invalid("turn/start personality must be a string when provided.");
  }

  const input: UserInputRecord[] = [];
  for (const candidate of value.input) {
    const parsedInput = parseUserInput(candidate);
    if (!parsedInput.ok) {
      return parsedInput;
    }

    input.push(parsedInput.value);
  }

  return {
    ok: true,
    value: buildTurnStartParams(value, input),
  };
}

function buildTurnStartParams(
  value: Record<string, unknown>,
  input: UserInputRecord[],
): TurnStartParams {
  const params: TurnStartParams = {
    threadId: value.threadId as string,
    input,
  };

  assignOptional(params, "cwd", value.cwd as TurnStartParams["cwd"]);
  assignOptional(
    params,
    "approvalPolicy",
    value.approvalPolicy as TurnStartParams["approvalPolicy"],
  );
  assignOptional(
    params,
    "sandboxPolicy",
    value.sandboxPolicy as TurnStartParams["sandboxPolicy"],
  );
  assignOptional(params, "model", value.model as TurnStartParams["model"]);
  assignOptional(
    params,
    "serviceTier",
    value.serviceTier as TurnStartParams["serviceTier"],
  );
  assignOptional(params, "effort", value.effort as TurnStartParams["effort"]);
  assignOptional(
    params,
    "summary",
    value.summary as TurnStartParams["summary"],
  );
  assignOptional(
    params,
    "personality",
    value.personality as TurnStartParams["personality"],
  );
  assignOptional(
    params,
    "outputSchema",
    value.outputSchema as TurnStartParams["outputSchema"],
  );
  assignOptional(
    params,
    "collaborationMode",
    value.collaborationMode as TurnStartParams["collaborationMode"],
  );

  return params;
}

function parseUserInput(value: unknown): ValidationResult<UserInputRecord> {
  if (!isPlainObject(value) || typeof value.type !== "string") {
    return invalid("turn/start input entries must be typed objects.");
  }

  switch (value.type) {
    case "text":
      if (typeof value.text !== "string") {
        return invalid("text inputs must include text.");
      }

      return {
        ok: true,
        value: {
          type: "text",
          text: value.text,
          text_elements: [],
        },
      };
    case "image":
      if (typeof value.url !== "string") {
        return invalid("image inputs must include url.");
      }

      return {
        ok: true,
        value: {
          type: "image",
          url: value.url,
        },
      };
    case "localImage":
      if (typeof value.path !== "string") {
        return invalid("localImage inputs must include path.");
      }

      return {
        ok: true,
        value: {
          type: "localImage",
          path: value.path,
        },
      };
    case "skill":
      if (typeof value.name !== "string" || typeof value.path !== "string") {
        return invalid("skill inputs must include name and path.");
      }

      return {
        ok: true,
        value: {
          type: "skill",
          name: value.name,
          path: value.path,
        },
      };
    case "mention":
      if (typeof value.name !== "string" || typeof value.path !== "string") {
        return invalid("mention inputs must include name and path.");
      }

      return {
        ok: true,
        value: {
          type: "mention",
          name: value.name,
          path: value.path,
        },
      };
    default:
      return invalid(`Unsupported input type ${value.type}.`);
  }
}
