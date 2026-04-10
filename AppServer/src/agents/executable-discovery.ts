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
  overrideEnvironmentVariable?: string;
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
    options.overrideEnvironmentVariable
      ? context.environment[options.overrideEnvironmentVariable]
      : undefined,
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

  return {
    executableName: options.executableName,
    status: "missing",
    resolvedPath: null,
    source: "not-found",
    baseEnvironmentSource: context.baseEnvironmentSource,
    checkedPaths,
  };
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
