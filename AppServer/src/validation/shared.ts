import type {
  ApprovalPolicyRecord,
  ReasoningEffortRecord,
  SandboxModeRecord,
  ServiceTierRecord,
} from "../domain/models";

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
