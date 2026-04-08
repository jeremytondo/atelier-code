import type {
  ClientInfo,
  InitializeCapabilities,
  InitializeParams,
} from "../protocol/types";
import type {
  ApprovalPolicyRecord,
  ReasoningEffortRecord,
  SandboxModeRecord,
  ServiceTierRecord,
} from "./models";

export interface ValidationSuccess<TValue> {
  ok: true;
  value: TValue;
}

export interface ValidationFailure {
  ok: false;
  error: string;
}

export type ValidationResult<TValue> =
  | ValidationSuccess<TValue>
  | ValidationFailure;

export function invalid(error: string): ValidationFailure {
  return {
    ok: false,
    error,
  };
}

export function isPlainObject(
  value: unknown,
): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function isStringArray(value: unknown): value is string[] {
  return (
    Array.isArray(value) && value.every((entry) => typeof entry === "string")
  );
}

export function isOptionalString(
  value: unknown,
): value is string | null | undefined {
  return value === undefined || value === null || typeof value === "string";
}

export function isOptionalBoolean(
  value: unknown,
): value is boolean | null | undefined {
  return value === undefined || value === null || typeof value === "boolean";
}

export function isOptionalArray(
  value: unknown,
): value is unknown[] | null | undefined {
  return value === undefined || value === null || Array.isArray(value);
}

export function isOptionalPlainObject(
  value: unknown,
): value is Record<string, unknown> | null | undefined {
  return value === undefined || value === null || isPlainObject(value);
}

export function isOptionalServiceTier(
  value: unknown,
): value is ServiceTierRecord | null | undefined {
  return (
    value === undefined ||
    value === null ||
    value === "fast" ||
    value === "flex"
  );
}

export function isOptionalReasoningEffort(
  value: unknown,
): value is ReasoningEffortRecord | null | undefined {
  return (
    value === undefined ||
    value === null ||
    value === "none" ||
    value === "minimal" ||
    value === "low" ||
    value === "medium" ||
    value === "high" ||
    value === "xhigh"
  );
}

export function isOptionalSandboxMode(
  value: unknown,
): value is SandboxModeRecord | null | undefined {
  return (
    value === undefined ||
    value === null ||
    value === "read-only" ||
    value === "workspace-write" ||
    value === "danger-full-access"
  );
}

export function isOptionalApprovalPolicy(
  value: unknown,
): value is ApprovalPolicyRecord | null | undefined {
  return (
    value === undefined ||
    value === null ||
    value === "untrusted" ||
    value === "on-failure" ||
    value === "on-request" ||
    value === "never" ||
    isApprovalRejectPolicy(value)
  );
}

export function isApprovalRejectPolicy(
  value: unknown,
): value is Extract<ApprovalPolicyRecord, { reject: unknown }> {
  if (!isPlainObject(value) || !isPlainObject(value.reject)) {
    return false;
  }

  return (
    typeof value.reject.sandbox_approval === "boolean" &&
    typeof value.reject.rules === "boolean" &&
    typeof value.reject.request_permissions === "boolean" &&
    typeof value.reject.mcp_elicitations === "boolean"
  );
}

export function assignOptional<
  TTarget extends object,
  TKey extends keyof TTarget,
>(target: TTarget, key: TKey, value: TTarget[TKey] | undefined): void {
  if (value !== undefined) {
    target[key] = value;
  }
}

export function validateInitializeParams(
  value: unknown,
): ValidationResult<InitializeParams> {
  if (!isPlainObject(value)) {
    return invalid("initialize params must be an object.");
  }

  const clientInfo = parseClientInfo(value.clientInfo);
  if (!clientInfo.ok) {
    return clientInfo;
  }

  const capabilities = parseInitializeCapabilities(value.capabilities);
  if (!capabilities.ok) {
    return capabilities;
  }

  return {
    ok: true,
    value: {
      clientInfo: clientInfo.value,
      capabilities: capabilities.value,
    },
  };
}

function parseClientInfo(value: unknown): ValidationResult<ClientInfo> {
  if (!isPlainObject(value)) {
    return invalid("initialize clientInfo must be an object.");
  }

  if (typeof value.name !== "string" || value.name.length === 0) {
    return invalid("initialize clientInfo.name must be a non-empty string.");
  }

  if (!(value.title === null || typeof value.title === "string")) {
    return invalid("initialize clientInfo.title must be a string or null.");
  }

  if (typeof value.version !== "string" || value.version.length === 0) {
    return invalid("initialize clientInfo.version must be a non-empty string.");
  }

  return {
    ok: true,
    value: {
      name: value.name,
      title: value.title,
      version: value.version,
    },
  };
}

function parseInitializeCapabilities(
  value: unknown,
): ValidationResult<InitializeCapabilities | null> {
  if (value === null || value === undefined) {
    return {
      ok: true,
      value: null,
    };
  }

  if (!isPlainObject(value) || typeof value.experimentalApi !== "boolean") {
    return invalid(
      "initialize capabilities.experimentalApi must be a boolean.",
    );
  }

  if (
    value.optOutNotificationMethods !== undefined &&
    value.optOutNotificationMethods !== null &&
    !isStringArray(value.optOutNotificationMethods)
  ) {
    return invalid(
      "initialize optOutNotificationMethods must be a string array when provided.",
    );
  }

  return {
    ok: true,
    value:
      value.optOutNotificationMethods === undefined
        ? {
            experimentalApi: value.experimentalApi,
          }
        : {
            experimentalApi: value.experimentalApi,
            optOutNotificationMethods: value.optOutNotificationMethods,
          },
  };
}
