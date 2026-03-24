import type { BridgeStartupError } from "./types";

export const BRIDGE_PROTOCOL_VERSION = 1 as const;
export const SUPPORTED_BRIDGE_PROTOCOL_VERSIONS = [BRIDGE_PROTOCOL_VERSION] as const;

export type SupportedBridgeProtocolVersion = (typeof SUPPORTED_BRIDGE_PROTOCOL_VERSIONS)[number];

export interface BridgeProtocolCompatibilitySuccess {
  isCompatible: true;
  negotiatedVersion: SupportedBridgeProtocolVersion;
}

export interface BridgeProtocolCompatibilityFailure {
  isCompatible: false;
  requestedVersion: number;
  supportedVersions: readonly SupportedBridgeProtocolVersion[];
  error: BridgeStartupError;
}

export type BridgeProtocolCompatibility =
  | BridgeProtocolCompatibilitySuccess
  | BridgeProtocolCompatibilityFailure;

export function isSupportedBridgeProtocolVersion(
  version: number,
): version is SupportedBridgeProtocolVersion {
  return SUPPORTED_BRIDGE_PROTOCOL_VERSIONS.includes(version as SupportedBridgeProtocolVersion);
}

export function normalizeRequestedProtocolVersions(
  protocolVersion: number,
  supportedProtocolVersions?: readonly number[],
): number[] {
  const versions = supportedProtocolVersions ?? [protocolVersion];

  return [...new Set(versions)]
    .filter((candidate) => Number.isInteger(candidate) && candidate > 0)
    .sort((left, right) => right - left);
}

export function buildProtocolMismatchError(
  requestedVersion: number,
  supportedVersions: readonly number[] = SUPPORTED_BRIDGE_PROTOCOL_VERSIONS,
): BridgeStartupError {
  const supportedDescription = supportedVersions.join(", ");

  return {
    code: "protocol_mismatch",
    message: `Bridge protocol version ${requestedVersion} is unsupported. Supported versions: ${supportedDescription}.`,
    recoverySuggestion:
      "Update AtelierCode or the embedded bridge so both sides share at least one supported protocol version.",
  };
}

export function negotiateBridgeProtocolVersion(
  protocolVersion: number,
  supportedProtocolVersions?: readonly number[],
): BridgeProtocolCompatibility {
  const requestedVersions = normalizeRequestedProtocolVersions(protocolVersion, supportedProtocolVersions);
  const negotiatedVersion = requestedVersions.find(isSupportedBridgeProtocolVersion);

  if (negotiatedVersion !== undefined) {
    return {
      isCompatible: true,
      negotiatedVersion,
    };
  }

  return {
    isCompatible: false,
    requestedVersion: protocolVersion,
    supportedVersions: SUPPORTED_BRIDGE_PROTOCOL_VERSIONS,
    error: buildProtocolMismatchError(protocolVersion),
  };
}
