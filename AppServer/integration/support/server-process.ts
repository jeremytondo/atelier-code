export interface StartupRecord {
  recordType: "app-server.startup";
  host: string;
  port: number;
  version: string;
  pid: number;
}

export interface ServerProcessHarness {
  process: Bun.Subprocess<"ignore", "pipe", "pipe">;
  startup: StartupRecord;
  stop(): Promise<void>;
}

export async function spawnServerProcess(
  cwd: string,
): Promise<ServerProcessHarness> {
  const processHandle = Bun.spawn({
    cmd: [process.execPath, "run", "./src/index.ts"],
    cwd,
    stdout: "pipe",
    stderr: "pipe",
  });

  const startup = await readStartupRecord(processHandle);

  return {
    process: processHandle,
    startup,
    async stop(): Promise<void> {
      processHandle.kill();
      await processHandle.exited;
    },
  };
}

async function readStartupRecord(
  processHandle: Bun.Subprocess<"ignore", "pipe", "pipe">,
): Promise<StartupRecord> {
  const stdout = processHandle.stdout;
  if (!stdout) {
    throw new Error("Server process did not expose stdout.");
  }

  const reader = stdout.getReader();
  const decoder = new TextDecoder();
  let output = "";

  while (true) {
    const { done, value } = await reader.read();
    if (done) {
      throw new Error(
        `Server exited before publishing startup JSON. Output: ${output}`,
      );
    }

    output += decoder.decode(value, { stream: true });
    const newlineIndex = output.indexOf("\n");
    if (newlineIndex === -1) {
      continue;
    }

    const firstLine = output.slice(0, newlineIndex).trim();
    if (firstLine.length === 0) {
      output = output.slice(newlineIndex + 1);
      continue;
    }

    const parsed = JSON.parse(firstLine) as StartupRecord;
    if (parsed.recordType !== "app-server.startup") {
      throw new Error(`Unexpected startup record: ${firstLine}`);
    }

    reader.releaseLock();
    return parsed;
  }
}
