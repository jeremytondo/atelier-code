import { constants as fsConstants } from "node:fs";
import { access } from "node:fs/promises";
import path from "node:path";

import type {
  BridgeEnvironmentSource,
  ExecutableDiscoveryResult,
  ExecutableDiscoverySource,
} from "../protocol/types";

export interface ExecutableDiscoveryOptions {
  executableName: string;
  environmentVariable?: string;
  knownPaths?: string[];
}

export interface ExecutableDiscoveryContext {
  environment: Readonly<Record<string, string>>;
  baseEnvironmentSource: BridgeEnvironmentSource;
}

export async function discoverExecutable(
  options: ExecutableDiscoveryOptions,
  context: ExecutableDiscoveryContext,
): Promise<ExecutableDiscoveryResult> {
  const checkedPaths: string[] = [];

  const environmentPath = normalizeConfiguredPath(
    options.environmentVariable ? context.environment[options.environmentVariable] : undefined,
  );
  if (environmentPath) {
    checkedPaths.push(environmentPath);
    if (await isExecutable(environmentPath)) {
      return buildResult(
        options.executableName,
        "environment",
        checkedPaths,
        environmentPath,
        context.baseEnvironmentSource,
      );
    }
  }

  const pathMatch = await findExecutableOnPath(options.executableName, context.environment.PATH, checkedPaths);
  if (pathMatch) {
    return buildResult(
      options.executableName,
      "path",
      checkedPaths,
      pathMatch,
      context.baseEnvironmentSource,
    );
  }

  for (const candidate of options.knownPaths ?? []) {
    checkedPaths.push(candidate);
    if (await isExecutable(candidate)) {
      return buildResult(
        options.executableName,
        "known-path",
        checkedPaths,
        candidate,
        context.baseEnvironmentSource,
      );
    }
  }

  return {
    executableName: options.executableName,
    status: "missing",
    resolvedPath: null,
    source: "not-found",
    baseEnvironmentSource: context.baseEnvironmentSource,
    checkedPaths,
  };
}

export async function discoverCodexExecutable(
  context: ExecutableDiscoveryContext,
): Promise<ExecutableDiscoveryResult> {
  const skipKnownPaths = context.environment.ATELIERCODE_SKIP_KNOWN_CODEX_PATHS === "1";

  return discoverExecutable(
    {
      executableName: "codex",
      environmentVariable: "ATELIERCODE_CODEX_PATH",
      knownPaths: skipKnownPaths ? [] : codexKnownPaths(context.environment),
    },
    context,
  );
}

function codexKnownPaths(environment: Readonly<Record<string, string>>): string[] {
  const home = environment.HOME;
  const candidates = [
    "/opt/homebrew/bin/codex",
    "/usr/local/bin/codex",
    home ? path.join(home, ".local", "bin", "codex") : null,
    home ? path.join(home, ".npm-global", "bin", "codex") : null,
  ];

  return candidates.flatMap((candidate) => (candidate ? [candidate] : []));
}

async function findExecutableOnPath(
  executableName: string,
  candidatePath: string | undefined,
  checkedPaths: string[],
): Promise<string | null> {
  const pathDirectories = (candidatePath ?? "")
    .split(":")
    .map((directory) => directory.trim())
    .filter((directory) => directory.length > 0);

  for (const directory of pathDirectories) {
    const candidate = path.join(directory, executableName);
    checkedPaths.push(candidate);

    if (await isExecutable(candidate)) {
      return candidate;
    }
  }

  return null;
}

async function isExecutable(candidatePath: string): Promise<boolean> {
  try {
    await access(candidatePath, fsConstants.X_OK);
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
  baseEnvironmentSource: BridgeEnvironmentSource,
): ExecutableDiscoveryResult {
  return {
    executableName,
    status: "found",
    resolvedPath,
    source,
    baseEnvironmentSource,
    checkedPaths,
  };
}
