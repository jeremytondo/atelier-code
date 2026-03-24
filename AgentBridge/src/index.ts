import type { BridgeHealthReport, BridgeStartupError, ProviderHealth } from "./protocol/types";
import { BRIDGE_PROTOCOL_VERSION } from "./protocol/version";
import { discoverCodexExecutable } from "./discovery/executable";

const BRIDGE_VERSION = "0.1.0";
const HEALTHCHECK_FLAG = "--healthcheck";

await main();

async function main(): Promise<void> {
  const argumentsList = process.argv.slice(2);

  if (argumentsList.length === 1 && argumentsList[0] === HEALTHCHECK_FLAG) {
    const report = await buildHealthReport();
    process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
    return;
  }

  process.stderr.write(
    "AgentBridge transport is not implemented yet. Run with --healthcheck for runtime diagnostics.\n",
  );
  process.exitCode = 64;
}

async function buildHealthReport(): Promise<BridgeHealthReport> {
  const codexExecutable = await discoverCodexExecutable();
  const codexProvider: ProviderHealth = {
    provider: "codex",
    status: codexExecutable.status === "found" ? "available" : "degraded",
    detail:
      codexExecutable.status === "found"
        ? `Codex executable discovered at ${codexExecutable.resolvedPath}.`
        : "Codex executable was not found. Bridge transport stays unavailable until Codex is installed or configured.",
    executable: codexExecutable,
  };

  const errors: BridgeStartupError[] =
    codexExecutable.status === "found"
      ? []
      : [
          {
            code: "provider_executable_missing",
            message: "Codex executable was not found during bridge startup discovery.",
            recoverySuggestion:
              "Install Codex or set ATELIERCODE_CODEX_PATH to a valid executable before launching the bridge.",
          },
        ];

  return {
    bridgeVersion: BRIDGE_VERSION,
    protocolVersion: BRIDGE_PROTOCOL_VERSION,
    status: errors.length == 0 ? "ok" : "degraded",
    generatedAt: new Date().toISOString(),
    providers: [codexProvider],
    errors,
  };
}
