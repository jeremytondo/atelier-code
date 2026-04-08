import type {
  ClientInfo,
  InitializeCapabilities,
  InitializeParams,
} from "../protocol/types";
import {
  type ValidationResult,
  invalid,
  isPlainObject,
  isStringArray,
} from "./shared";

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
