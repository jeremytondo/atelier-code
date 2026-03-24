import { access } from "node:fs/promises";
import path from "node:path";

import type { ExecutableDiscoveryResult, ExecutableDiscoverySource } from "../protocol/types";

export interface ExecutableDiscoveryOptions {
  executableName: string;
  environmentVariable?: string;
  knownPaths?: string[];
}

export async function discoverExecutable(
  options: ExecutableDiscoveryOptions,
): Promise<ExecutableDiscoveryResult> {
  const checkedPaths: string[] = [];

  const environmentPath = normalizeConfiguredPath(
    options.environmentVariable ? process.env[options.environmentVariable] : undefined,
  );
  if (environmentPath) {
    checkedPaths.push(environmentPath);
    if (await isExecutable(environmentPath)) {
      return buildResult(options.executableName, "environment", checkedPaths, environmentPath);
    }
  }

  const pathMatch = Bun.which(options.executableName);
  if (pathMatch) {
    checkedPaths.push(pathMatch);
    return buildResult(options.executableName, "path", checkedPaths, pathMatch);
  }

  for (const candidate of options.knownPaths ?? []) {
    checkedPaths.push(candidate);
    if (await isExecutable(candidate)) {
      return buildResult(options.executableName, "known-path", checkedPaths, candidate);
    }
  }

  return {
    executableName: options.executableName,
    status: "missing",
    resolvedPath: null,
    source: "not-found",
    checkedPaths,
  };
}

export async function discoverCodexExecutable(): Promise<ExecutableDiscoveryResult> {
  const skipKnownPaths = process.env.ATELIERCODE_SKIP_KNOWN_CODEX_PATHS === "1";

  return discoverExecutable({
    executableName: "codex",
    environmentVariable: "ATELIERCODE_CODEX_PATH",
    knownPaths: skipKnownPaths ? [] : codexKnownPaths(),
  });
}

function codexKnownPaths(): string[] {
  const home = process.env.HOME;
  const candidates = [
    "/opt/homebrew/bin/codex",
    "/usr/local/bin/codex",
    home ? path.join(home, ".local", "bin", "codex") : null,
    home ? path.join(home, ".npm-global", "bin", "codex") : null,
  ];

  return candidates.flatMap((candidate) => (candidate ? [candidate] : []));
}

async function isExecutable(candidatePath: string): Promise<boolean> {
  try {
    await access(candidatePath);
    return true;
  } catch {
    return false;
  }
}

function normalizeConfiguredPath(candidatePath: string | undefined): string | null {
  if (!candidatePath) {
    return null;
  }

  const trimmedPath = candidatePath.trim();
  return trimmedPath.length > 0 ? trimmedPath : null;
}

function buildResult(
  executableName: string,
  source: ExecutableDiscoverySource,
  checkedPaths: string[],
  resolvedPath: string,
): ExecutableDiscoveryResult {
  return {
    executableName,
    status: "found",
    resolvedPath,
    source,
    checkedPaths,
  };
}
