import path from "node:path";

import type { BridgeEnvironmentDiagnostics, BridgeEnvironmentSource } from "../protocol/types";

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
const SHELL_PROBE_BEGIN_SENTINEL = "__ATELIERCODE_ENV_BEGIN_4c58d0e1__";
const SHELL_PROBE_END_SENTINEL = "__ATELIERCODE_ENV_END_4c58d0e1__";
const SENTINEL_ENCODER = new TextEncoder();
const SENTINEL_DECODER = new TextDecoder();
const SHELL_PROBE_BEGIN_BYTES = SENTINEL_ENCODER.encode(`${SHELL_PROBE_BEGIN_SENTINEL}\0`);
const SHELL_PROBE_END_BYTES = SENTINEL_ENCODER.encode(`${SHELL_PROBE_END_SENTINEL}\0`);

export const DEFAULT_ENV_PROBE_TIMEOUT_MS = 3_000;
export const DEFAULT_ENV_PROBE_STDOUT_BYTE_LIMIT = 256 * 1_024;

export interface ResolvedBaseEnvironment {
  environment: Record<string, string>;
  diagnostics: BridgeEnvironmentDiagnostics;
}

export interface BaseEnvironmentResolverDependencies {
  inheritedEnvironment?: Record<string, string | undefined>;
  probeEnvironment?: (
    shellPath: string,
    inheritedEnvironment: Readonly<Record<string, string>>,
    options: ShellProbeOptions,
  ) => Promise<Record<string, string>>;
  probeTimeoutMs?: number;
  probeStdoutByteLimit?: number;
}

export interface ShellProbeOptions {
  timeoutMs: number;
  stdoutByteLimit: number;
}

interface ShellProbeProcess {
  stdout: ReadableStream<Uint8Array> | null;
  stderr: ReadableStream<Uint8Array> | null;
  exited: Promise<number>;
  kill(): void;
}

export class BaseEnvironmentResolver {
  private cachedResolution: Promise<ResolvedBaseEnvironment> | null = null;
  private readonly dependencies: Required<BaseEnvironmentResolverDependencies>;

  constructor(dependencies: BaseEnvironmentResolverDependencies = {}) {
    this.dependencies = {
      inheritedEnvironment: dependencies.inheritedEnvironment ?? process.env,
      probeEnvironment: dependencies.probeEnvironment ?? probeLoginShellEnvironment,
      probeTimeoutMs: dependencies.probeTimeoutMs ?? DEFAULT_ENV_PROBE_TIMEOUT_MS,
      probeStdoutByteLimit:
        dependencies.probeStdoutByteLimit ?? DEFAULT_ENV_PROBE_STDOUT_BYTE_LIMIT,
    };
  }

  resolve(): Promise<ResolvedBaseEnvironment> {
    if (this.cachedResolution === null) {
      this.cachedResolution = this.resolveFresh();
    }

    return this.cachedResolution;
  }

  private async resolveFresh(): Promise<ResolvedBaseEnvironment> {
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

export function normalizeEnvironment(
  environment: Record<string, string | undefined>,
): Record<string, string> {
  const normalizedEntries = Object.entries(environment).flatMap(([key, value]) =>
    value === undefined ? [] : [[key, value] as const],
  );

  return Object.fromEntries(normalizedEntries);
}

export function shouldProbeBaseEnvironment(environment: Readonly<Record<string, string>>): boolean {
  const homeDirectory = normalizeEnvironmentValue(environment.HOME);
  const shellPath = normalizeEnvironmentValue(environment.SHELL);
  const pathDirectories = splitPathDirectories(environment.PATH);

  if (homeDirectory === null || shellPath === null || pathDirectories.length === 0) {
    return true;
  }

  return pathDirectories.some((directory) =>
    USER_MANAGED_PATH_MARKERS.some((marker) => directory.includes(marker)),
  )
    ? false
    : true;
}

export function resolvePreferredShellPath(environment: Readonly<Record<string, string>>): string {
  return normalizeEnvironmentValue(environment.SHELL) ?? FALLBACK_SHELL_PATH;
}

export function appendFallbackPathDirectories(
  environment: Readonly<Record<string, string>>,
): Record<string, string> {
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
}

export async function probeLoginShellEnvironment(
  shellPath: string,
  inheritedEnvironment: Readonly<Record<string, string>>,
  options: ShellProbeOptions,
): Promise<Record<string, string>> {
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
      throw buildProbeFailure(`Shell environment probe exited with status ${exitCode}.`, stderrTail);
    }

    return parseShellProbeOutput(stdout);
  } catch (error) {
    process.kill();
    await process.exited.catch(() => undefined);

    const stderrTail = await stderrPromise.catch(() => "");
    throw buildProbeFailure(describeProbeError(error), stderrTail);
  }
}

export function parseShellProbeOutput(output: Uint8Array): Record<string, string> {
  const payload = extractSentinelBoundPayload(output);
  if (payload === null) {
    throw new Error("Shell environment probe output did not include the expected sentinel markers.");
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
}

export function splitPathDirectories(candidatePath: string | undefined): string[] {
  return uniqueDirectories(
    (candidatePath ?? "")
      .split(":")
      .map((directory) => directory.trim())
      .filter((directory) => directory.length > 0),
  );
}

function buildResolvedEnvironment(
  environment: Record<string, string>,
  source: BridgeEnvironmentSource,
  shellPath: string,
  probeError: string | null,
): ResolvedBaseEnvironment {
  return {
    environment,
    diagnostics: {
      source,
      shellPath,
      probeError,
      pathDirectoryCount: splitPathDirectories(environment.PATH).length,
      homeDirectory: normalizeEnvironmentValue(environment.HOME),
    },
  };
}

function spawnShellProbeProcess(
  shellPath: string,
  inheritedEnvironment: Readonly<Record<string, string>>,
): ShellProbeProcess {
  return Bun.spawn(shellProbeCommand(shellPath), {
    stdin: "ignore",
    stdout: "pipe",
    stderr: "pipe",
    env: inheritedEnvironment,
  });
}

function shellProbeCommand(shellPath: string): string[] {
  return [shellPath, shellInvocationFlag(shellPath), shellProbeScript()];
}

function shellInvocationFlag(shellPath: string): string {
  const shellName = path.basename(shellPath);

  if (shellName === "zsh" || shellName === "bash") {
    return "-ilc";
  }

  return "-lc";
}

function shellProbeScript(): string {
  return [
    `printf '%s\\0' '${SHELL_PROBE_BEGIN_SENTINEL}'`,
    "env -0",
    `printf '%s\\0' '${SHELL_PROBE_END_SENTINEL}'`,
  ].join("; ");
}

function extractSentinelBoundPayload(output: Uint8Array): Uint8Array | null {
  const beginIndex = indexOfSequence(output, SHELL_PROBE_BEGIN_BYTES);
  if (beginIndex < 0) {
    return null;
  }

  const payloadStartIndex = beginIndex + SHELL_PROBE_BEGIN_BYTES.length;
  const endIndex = indexOfSequence(output, SHELL_PROBE_END_BYTES, payloadStartIndex);
  if (endIndex < 0) {
    return null;
  }

  return output.slice(payloadStartIndex, endIndex);
}

function indexOfSequence(
  haystack: Uint8Array,
  needle: Uint8Array,
  startIndex = 0,
): number {
  if (needle.length === 0 || haystack.length < needle.length) {
    return -1;
  }

  for (let index = startIndex; index <= haystack.length - needle.length; index += 1) {
    let matched = true;
    for (let offset = 0; offset < needle.length; offset += 1) {
      if (haystack[index + offset] !== needle[offset]) {
        matched = false;
        break;
      }
    }

    if (matched) {
      return index;
    }
  }

  return -1;
}

async function readStreamWithLimit(
  stream: ReadableStream<Uint8Array>,
  limitBytes: number,
): Promise<Uint8Array> {
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

  const output = new Uint8Array(totalBytes);
  let offset = 0;
  for (const chunk of chunks) {
    output.set(chunk, offset);
    offset += chunk.byteLength;
  }

  return output;
}

async function readStreamTail(stream: ReadableStream<Uint8Array>, limitChars: number): Promise<string> {
  const reader = stream.getReader();
  const decoder = new TextDecoder();
  let tail = "";

  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) {
        break;
      }

      tail = appendTail(tail, decoder.decode(value, { stream: true }), limitChars);
    }

    tail = appendTail(tail, decoder.decode(), limitChars);
  } finally {
    reader.releaseLock();
  }

  return tail.trim();
}

function appendTail(currentTail: string, chunk: string, limitChars: number): string {
  const nextTail = `${currentTail}${chunk}`;
  return nextTail.length > limitChars ? nextTail.slice(nextTail.length - limitChars) : nextTail;
}

function buildProbeFailure(message: string, stderrTail: string): Error {
  const trimmedStderr = stderrTail.trim();
  return new Error(
    trimmedStderr.length > 0 ? `${message} stderr: ${trimmedStderr}` : message,
  );
}

function describeProbeError(error: unknown): string {
  if (error instanceof Error) {
    return error.message;
  }

  return String(error);
}

function normalizeEnvironmentValue(value: string | undefined): string | null {
  if (value === undefined) {
    return null;
  }

  const trimmedValue = value.trim();
  return trimmedValue.length > 0 ? trimmedValue : null;
}

function uniqueDirectories(directories: readonly string[]): string[] {
  return Array.from(new Set(directories));
}
