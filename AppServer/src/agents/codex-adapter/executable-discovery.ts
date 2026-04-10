import { constants as fsConstants } from "node:fs";
import { access } from "node:fs/promises";
import path from "node:path";
import type {
  AgentEnvironmentSource,
  AgentExecutableDiscovery,
  AgentExecutableDiscoverySource,
} from "@/agents/contracts";

export type ExecutableDiscoveryOptions = Readonly<{
  executableName: string;
  environmentVariable?: string;
  knownPaths?: readonly string[];
}>;

export type ExecutableDiscoveryContext = Readonly<{
  environment: Readonly<Record<string, string>>;
  baseEnvironmentSource: AgentEnvironmentSource;
}>;

export const discoverExecutable = async (
  options: ExecutableDiscoveryOptions,
  context: ExecutableDiscoveryContext,
): Promise<AgentExecutableDiscovery> => {
  const checkedPaths: string[] = [];
  const environmentPath = normalizeConfiguredPath(
    options.environmentVariable ? context.environment[options.environmentVariable] : undefined,
  );

  if (environmentPath !== null) {
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

  const pathMatch = await findExecutableOnPath(
    options.executableName,
    context.environment.PATH,
    checkedPaths,
  );
  if (pathMatch !== null) {
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
};

export const discoverCodexExecutable = async (
  context: ExecutableDiscoveryContext,
): Promise<AgentExecutableDiscovery> => {
  const skipKnownPaths = context.environment.ATELIERCODE_SKIP_KNOWN_CODEX_PATHS === "1";

  return discoverExecutable(
    {
      executableName: "codex",
      environmentVariable: "ATELIERCODE_CODEX_PATH",
      knownPaths: skipKnownPaths ? [] : codexKnownPaths(context.environment),
    },
    context,
  );
};

const codexKnownPaths = (environment: Readonly<Record<string, string>>): readonly string[] => {
  const homeDirectory = environment.HOME;
  const candidates = [
    "/opt/homebrew/bin/codex",
    "/usr/local/bin/codex",
    homeDirectory ? path.join(homeDirectory, ".local", "bin", "codex") : null,
    homeDirectory ? path.join(homeDirectory, ".npm-global", "bin", "codex") : null,
  ];

  return candidates.flatMap((candidate) => (candidate ? [candidate] : []));
};

const findExecutableOnPath = async (
  executableName: string,
  candidatePath: string | undefined,
  checkedPaths: string[],
): Promise<string | null> => {
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
};

const isExecutable = async (candidatePath: string): Promise<boolean> => {
  try {
    await access(candidatePath, fsConstants.X_OK);
    return true;
  } catch {
    return false;
  }
};

const normalizeConfiguredPath = (candidatePath: string | undefined): string | null => {
  const trimmedPath = candidatePath?.trim();
  return trimmedPath && trimmedPath.length > 0 ? trimmedPath : null;
};

const buildResult = (
  executableName: string,
  source: AgentExecutableDiscoverySource,
  checkedPaths: readonly string[],
  resolvedPath: string,
  baseEnvironmentSource: AgentEnvironmentSource,
): AgentExecutableDiscovery => ({
  executableName,
  status: "found",
  resolvedPath,
  source,
  baseEnvironmentSource,
  checkedPaths,
});
