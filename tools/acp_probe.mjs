#!/usr/bin/env node

import { spawn } from "node:child_process";
import process from "node:process";

const promptText = process.argv[2] ?? "Is this thing on?";
const cwd = process.argv[3] ?? process.cwd();
const executable = process.env.GEMINI_EXECUTABLE ?? "/opt/homebrew/bin/gemini";
const modelId = process.env.ACP_FORCE_MODEL;
const authMethodId = process.env.ACP_AUTH_METHOD;

const child = spawn(executable, ["--experimental-acp"], {
  cwd,
  env: process.env,
  stdio: ["pipe", "pipe", "pipe"],
});

let nextId = 1;
let buffer = "";
let sessionId = null;
let promptRequestId = null;
let finished = false;
let pendingModelRequest = false;
let pendingAuthentication = false;

function send(method, params) {
  const id = nextId++;
  const payload = { jsonrpc: "2.0", id, method, params };
  console.log(">>>", JSON.stringify(payload));
  child.stdin.write(JSON.stringify(payload) + "\n");
  return id;
}

function sendResult(id, result) {
  const payload = { jsonrpc: "2.0", id, result };
  console.log(">>>", JSON.stringify(payload));
  child.stdin.write(JSON.stringify(payload) + "\n");
}

function maybeFinish(code = 0) {
  if (finished) return;
  finished = true;
  setTimeout(() => {
    child.kill("SIGTERM");
    process.exit(code);
  }, 100);
}

child.stdout.setEncoding("utf8");
child.stdout.on("data", (chunk) => {
  buffer += chunk;

  while (true) {
    const newline = buffer.indexOf("\n");
    if (newline === -1) break;

    const line = buffer.slice(0, newline).trim();
    buffer = buffer.slice(newline + 1);

    if (!line) continue;
    console.log("<<<", line);

    let message;
    try {
      message = JSON.parse(line);
    } catch (error) {
      console.error("parse-error", error);
      continue;
    }

    if (message.method === "session/request_permission") {
      const option =
        message.params?.options?.find((item) => item.kind === "allow_once") ??
        message.params?.options?.find((item) => item.kind === "allow_always") ??
        message.params?.options?.[0];

      sendResult(message.id, {
        outcome: option
          ? { outcome: "selected", optionId: option.optionId }
          : { outcome: "cancelled" },
      });
      continue;
    }

    if (message.id === 1 && message.result?.protocolVersion) {
      if (authMethodId) {
        pendingAuthentication = true;
        send("authenticate", { methodId: authMethodId });
      } else {
        send("session/new", { cwd, mcpServers: [] });
      }
      continue;
    }

    if (pendingAuthentication && message.id === 2 && (message.result || message.error)) {
      pendingAuthentication = false;
      send("session/new", { cwd, mcpServers: [] });
      continue;
    }

    if (message.result?.sessionId) {
      sessionId = message.result.sessionId;
      if (modelId) {
        pendingModelRequest = true;
        send("unstable_setSessionModel", { sessionId, modelId });
      } else {
        promptRequestId = send("session/prompt", {
          sessionId,
          prompt: [{ type: "text", text: promptText }],
        });
      }
      continue;
    }

    if (pendingModelRequest && message.result && message.id === 3) {
      pendingModelRequest = false;
      promptRequestId = send("session/prompt", {
        sessionId,
        prompt: [{ type: "text", text: promptText }],
      });
      continue;
    }

    if (promptRequestId !== null && message.id === promptRequestId) {
      console.log("prompt-finished", JSON.stringify(message.result ?? message.error ?? null));
      maybeFinish(message.error ? 1 : 0);
    }
  }
});

child.stderr.setEncoding("utf8");
child.stderr.on("data", (chunk) => {
  process.stderr.write(`stderr: ${chunk}`);
});

child.on("exit", (code, signal) => {
  console.log(`child-exit code=${code} signal=${signal}`);
  maybeFinish(code ?? 1);
});

send("initialize", {
  protocolVersion: 1,
  clientCapabilities: {
    fs: { readTextFile: false, writeTextFile: false },
    terminal: false,
  },
  clientInfo: {
    name: "AtelierCodeProbe",
    title: "AtelierCodeProbe",
    version: "0.1.0",
  },
});
