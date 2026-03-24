export type BridgeHealthStatus = "ok" | "degraded";
export type ProviderReadiness = "available" | "degraded";
export type ExecutableDiscoveryStatus = "found" | "missing";
export type ExecutableDiscoverySource = "environment" | "path" | "known-path" | "not-found";
export type BridgeStartupErrorCode =
  | "provider_executable_missing"
  | "embedded_bridge_missing"
  | "protocol_mismatch";

export interface ExecutableDiscoveryResult {
  executableName: string;
  status: ExecutableDiscoveryStatus;
  resolvedPath: string | null;
  source: ExecutableDiscoverySource;
  checkedPaths: string[];
}

export interface ProviderHealth {
  provider: "codex";
  status: ProviderReadiness;
  detail: string;
  executable: ExecutableDiscoveryResult;
}

export interface BridgeStartupError {
  code: BridgeStartupErrorCode;
  message: string;
  recoverySuggestion?: string;
}

export interface BridgeHealthReport {
  bridgeVersion: string;
  protocolVersion: number;
  status: BridgeHealthStatus;
  generatedAt: string;
  providers: ProviderHealth[];
  errors: BridgeStartupError[];
}
