import path from "node:path";
import type { AgentEnvironmentDiagnostics, AgentEnvironmentSource } from "@/agents/contracts";

const ENV_ENTRY_KEY_PATTERN = /^[A-Za-z_][A-Za-z0-9_]*$/;
const FALLBACK_SHELL_PATH = "/bin/zsh";
const SHELL_PROBE_STDERR_TAIL_LIMIT = 2_048;
const USER_MANAGED_PATH_MARKERS = [
  "/opt/homebrew",
  "/usr/local/bin",
  "/.local/bin",
  "/.local/share/mise",
  "/.cargo/bin",
  "/.nvm",
  "/.pyenv",
  "/.asdf",
  "/.npm-global",
] as const;
const SHELL_PROBE_BEGIN_SENTINEL = "__ATELIER_APPSERVER_ENV_BEGIN_4c58d0e1__";
const SHELL_PROBE_END_SENTINEL = "__ATELIER_APPSERVER_ENV_END_4c58d0e1__";
const SENTINEL_ENCODER = new TextEncoder();
const SENTINEL_DECODER = new TextDecoder();
const SHELL_PROBE_BEGIN_BYTES = SENTINEL_ENCODER.encode(`${SHELL_PROBE_BEGIN_SENTINEL}\0`);
const SHELL_PROBE_END_BYTES = SENTINEL_ENCODER.encode(`${SHELL_PROBE_END_SENTINEL}\0`);

export const DEFAULT_ENV_PROBE_TIMEOUT_MS = 3_000;
export const DEFAULT_ENV_PROBE_STDOUT_BYTE_LIMIT = 256 * 1_024;

export type ResolvedAgentEnvironment = Readonly<{
  environment: Readonly<Record<string, string>>;
  diagnostics: AgentEnvironmentDiagnostics;
}>;

export type ShellProbeOptions = Readonly<{
  timeoutMs: number;
  stdoutByteLimit: number;
}>;

type ShellProbeProcess = Readonly<{
  stdout: ReadableStream<Uint8Array> | null;
  stderr: ReadableStream<Uint8Array> | null;
  exited: Promise<number>;
  kill: () => void;
}>;

export type BaseEnvironmentResolverDependencies = Readonly<{
  inheritedEnvironment?: Record<string, string | undefined>;
  probeEnvironment?: (
    shellPath: string,
    inheritedEnvironment: Readonly<Record<string, string>>,
    options: ShellProbeOptions,
  ) => Promise<Record<string, string>>;
  probeTimeoutMs?: number;
  probeStdoutByteLimit?: number;
}>;

export class BaseEnvironmentResolver {
  private readonly dependencies: Required<BaseEnvironmentResolverDependencies>;
  private cachedResolution: Promise<ResolvedAgentEnvironment> | null = null;

  constructor(dependencies: BaseEnvironmentResolverDependencies = {}) {
    this.dependencies = {
      inheritedEnvironment: dependencies.inheritedEnvironment ?? process.env,
      probeEnvironment: dependencies.probeEnvironment ?? probeLoginShellEnvironment,
      probeTimeoutMs: dependencies.probeTimeoutMs ?? DEFAULT_ENV_PROBE_TIMEOUT_MS,
      probeStdoutByteLimit:
        dependencies.probeStdoutByteLimit ?? DEFAULT_ENV_PROBE_STDOUT_BYTE_LIMIT,
    };
  }

  resolve(): Promise<ResolvedAgentEnvironment> {
    if (this.cachedResolution === null) {
      this.cachedResolution = this.resolveFresh();
    }

    return this.cachedResolution;
  }

  private async resolveFresh(): Promise<ResolvedAgentEnvironment> {
    const inheritedEnvironment = normalizeEnvironment(this.dependencies.inheritedEnvironment);
    const shellPath = resolvePreferredShellPath(inheritedEnvironment);

    if (!shouldProbeBaseEnvironment(inheritedEnvironment)) {
      return buildResolvedEnvironment(inheritedEnvironment, "inherited", shellPath, null);
    }

    try {
      const probedEnvironment = normalizeEnvironment(
        await this.dependencies.probeEnvironment(shellPath, inheritedEnvironment, {
          timeoutMs: this.dependencies.probeTimeoutMs,
          stdoutByteLimit: this.dependencies.probeStdoutByteLimit,
        }),
      );

      return buildResolvedEnvironment(probedEnvironment, "login_probe", shellPath, null);
    } catch (error) {
      return buildResolvedEnvironment(
        appendFallbackPathDirectories(inheritedEnvironment),
        "fallback",
        shellPath,
        describeProbeError(error),
      );
    }
  }
}

export const normalizeEnvironment = (
  environment: Record<string, string | undefined>,
): Record<string, string> =>
  Object.fromEntries(
    Object.entries(environment).flatMap(([key, value]) =>
      value === undefined ? [] : [[key, value] as const],
    ),
  );

export const shouldProbeBaseEnvironment = (
  environment: Readonly<Record<string, string>>,
): boolean => {
  const homeDirectory = normalizeEnvironmentValue(environment.HOME);
  const shellPath = normalizeEnvironmentValue(environment.SHELL);
  const pathDirectories = splitPathDirectories(environment.PATH);

  if (homeDirectory === null || shellPath === null || pathDirectories.length === 0) {
    return true;
  }

  return !pathDirectories.some((directory) =>
    USER_MANAGED_PATH_MARKERS.some((marker) => directory.includes(marker)),
  );
};

export const resolvePreferredShellPath = (environment: Readonly<Record<string, string>>): string =>
  normalizeEnvironmentValue(environment.SHELL) ?? FALLBACK_SHELL_PATH;

export const appendFallbackPathDirectories = (
  environment: Readonly<Record<string, string>>,
): Record<string, string> => {
  const homeDirectory = normalizeEnvironmentValue(environment.HOME);
  const existingDirectories = splitPathDirectories(environment.PATH);
  const fallbackDirectories = [
    "/opt/homebrew/bin",
    "/usr/local/bin",
    homeDirectory ? path.join(homeDirectory, ".local", "bin") : null,
    homeDirectory ? path.join(homeDirectory, ".npm-global", "bin") : null,
    homeDirectory ? path.join(homeDirectory, ".cargo", "bin") : null,
    homeDirectory ? path.join(homeDirectory, ".local", "share", "mise", "shims") : null,
    homeDirectory ? path.join(homeDirectory, ".asdf", "shims") : null,
  ].flatMap((directory) => (directory ? [directory] : []));

  const mergedDirectories = uniqueDirectories([...existingDirectories, ...fallbackDirectories]);

  return {
    ...environment,
    ...(mergedDirectories.length > 0 ? { PATH: mergedDirectories.join(":") } : {}),
  };
};

export const probeLoginShellEnvironment = async (
  shellPath: string,
  inheritedEnvironment: Readonly<Record<string, string>>,
  options: ShellProbeOptions,
): Promise<Record<string, string>> => {
  const process = spawnShellProbeProcess(shellPath, inheritedEnvironment);

  if (process.stdout === null || process.stderr === null) {
    process.kill();
    throw new Error("Shell environment probe did not start with piped stdio.");
  }

  const stdoutPromise = readStreamWithLimit(process.stdout, options.stdoutByteLimit);
  const stderrPromise = readStreamTail(process.stderr, SHELL_PROBE_STDERR_TAIL_LIMIT);
  const completionPromise = Promise.all([stdoutPromise, stderrPromise, process.exited] as const);
  const timeoutPromise = Bun.sleep(options.timeoutMs).then(() => {
    throw new Error(`Shell environment probe timed out after ${options.timeoutMs}ms.`);
  });

  try {
    const [stdout, stderrTail, exitCode] = await Promise.race([completionPromise, timeoutPromise]);

    if (exitCode !== 0) {
      throw buildProbeFailure(
        `Shell environment probe exited with status ${exitCode}.`,
        stderrTail,
      );
    }

    return parseShellProbeOutput(stdout);
  } catch (error) {
    process.kill();
    await process.exited.catch(() => undefined);

    const stderrTail = await stderrPromise.catch(() => "");
    throw buildProbeFailure(describeProbeError(error), stderrTail);
  }
};

export const parseShellProbeOutput = (output: Uint8Array): Record<string, string> => {
  const payload = extractSentinelBoundPayload(output);
  if (payload === null) {
    throw new Error(
      "Shell environment probe output did not include the expected sentinel markers.",
    );
  }

  const decodedPayload = SENTINEL_DECODER.decode(payload);
  const environment: Record<string, string> = {};

  for (const entry of decodedPayload.split("\0")) {
    if (entry.length === 0) {
      continue;
    }

    const equalsIndex = entry.indexOf("=");
    if (equalsIndex <= 0) {
      throw new Error("Shell environment probe produced a malformed environment entry.");
    }

    const key = entry.slice(0, equalsIndex);
    const value = entry.slice(equalsIndex + 1);

    if (!ENV_ENTRY_KEY_PATTERN.test(key)) {
      throw new Error(`Shell environment probe produced an invalid environment key: ${key}`);
    }

    environment[key] = value;
  }

  return environment;
};

export const splitPathDirectories = (candidatePath: string | undefined): string[] =>
  uniqueDirectories(
    (candidatePath ?? "")
      .split(":")
      .map((directory) => directory.trim())
      .filter((directory) => directory.length > 0),
  );

const buildResolvedEnvironment = (
  environment: Record<string, string>,
  source: AgentEnvironmentSource,
  shellPath: string,
  probeError: string | null,
): ResolvedAgentEnvironment => ({
  environment,
  diagnostics: {
    source,
    shellPath,
    probeError,
    pathDirectoryCount: splitPathDirectories(environment.PATH).length,
    homeDirectory: normalizeEnvironmentValue(environment.HOME),
  },
});

const spawnShellProbeProcess = (
  shellPath: string,
  inheritedEnvironment: Readonly<Record<string, string>>,
): ShellProbeProcess =>
  Bun.spawn(shellProbeCommand(shellPath), {
    stdin: "ignore",
    stdout: "pipe",
    stderr: "pipe",
    env: inheritedEnvironment,
  });

const shellProbeCommand = (shellPath: string): string[] => [
  shellPath,
  "-l",
  "-c",
  [
    "printf '%s\\0' ",
    `'${SHELL_PROBE_BEGIN_SENTINEL}'`,
    " ; env -0 ; printf '%s\\0' ",
    `'${SHELL_PROBE_END_SENTINEL}'`,
  ].join(""),
];

const readStreamWithLimit = async (
  stream: ReadableStream<Uint8Array>,
  limitBytes: number,
): Promise<Uint8Array> => {
  const reader = stream.getReader();
  const chunks: Uint8Array[] = [];
  let totalBytes = 0;

  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) {
        break;
      }

      totalBytes += value.byteLength;
      if (totalBytes > limitBytes) {
        throw new Error(`Shell environment probe output exceeded ${limitBytes} bytes.`);
      }

      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }

  const result = new Uint8Array(totalBytes);
  let offset = 0;
  for (const chunk of chunks) {
    result.set(chunk, offset);
    offset += chunk.byteLength;
  }

  return result;
};

const readStreamTail = async (
  stream: ReadableStream<Uint8Array>,
  tailLimit: number,
): Promise<string> => {
  const reader = stream.getReader();
  const decoder = new TextDecoder();
  let tail = "";

  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) {
        break;
      }

      tail = `${tail}${decoder.decode(value, { stream: true })}`;
      if (tail.length > tailLimit) {
        tail = tail.slice(tail.length - tailLimit);
      }
    }

    tail = `${tail}${decoder.decode()}`;
  } finally {
    reader.releaseLock();
  }

  return tail;
};

const extractSentinelBoundPayload = (output: Uint8Array): Uint8Array | null => {
  const beginIndex = findSequence(output, SHELL_PROBE_BEGIN_BYTES);
  if (beginIndex < 0) {
    return null;
  }

  const payloadStart = beginIndex + SHELL_PROBE_BEGIN_BYTES.byteLength;
  const endIndex = findSequence(output, SHELL_PROBE_END_BYTES, payloadStart);
  if (endIndex < 0) {
    return null;
  }

  return output.slice(payloadStart, endIndex);
};

const findSequence = (haystack: Uint8Array, needle: Uint8Array, from = 0): number => {
  outer: for (let index = from; index <= haystack.length - needle.length; index += 1) {
    for (let needleIndex = 0; needleIndex < needle.length; needleIndex += 1) {
      if (haystack[index + needleIndex] !== needle[needleIndex]) {
        continue outer;
      }
    }

    return index;
  }

  return -1;
};

const uniqueDirectories = (directories: readonly string[]): string[] => [...new Set(directories)];

const normalizeEnvironmentValue = (value: string | undefined): string | null => {
  const trimmedValue = value?.trim();
  return trimmedValue && trimmedValue.length > 0 ? trimmedValue : null;
};

const buildProbeFailure = (message: string, stderrTail: string): Error => {
  const stderr = stderrTail.trim();
  return new Error(stderr.length > 0 ? `${message} Stderr: ${stderr}` : message);
};

const describeProbeError = (error: unknown): string =>
  error instanceof Error ? error.message : String(error);
