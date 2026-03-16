# Gemini ACP Integration — Implementation Guide

This document is the primary reference for AtelierCode's ACP (Agent Client Protocol) integration with Gemini CLI. It covers the correct configuration, the protocol flow, past issues and their fixes, and a diagnostic playbook for future problems.

## Architecture Overview

AtelierCode launches Gemini CLI as a local subprocess and communicates over stdin/stdout using JSON-RPC 2.0 with JSONL framing (newline-delimited). The protocol is ACP — an open standard for IDE-to-agent communication.

```
┌──────────────┐    stdin (JSONL)     ┌─────────────┐    HTTPS     ┌──────────────────────────┐
│  AtelierCode │ ──────────────────→  │ Gemini CLI  │ ──────────→  │ Code Assist API          │
│  (ACP Client)│ ←────────────────── │ (ACP Agent) │ ←────────── │ cloudcode-pa.googleapis.com│
└──────────────┘   stdout (JSONL)     └─────────────┘             └──────────────────────────┘
```

### Key files

| File | Role |
|---|---|
| `ACPProtocol.swift` | JSON-RPC message types, client/agent capabilities, content blocks |
| `ACPSessionClient.swift` | Handshake sequence, request/response routing, notification dispatch |
| `ACPStore.swift` | Observable UI state, connection lifecycle, message streaming |
| `LocalACPTransport.swift` | Process management, pipes, JSONL framing, environment setup |
| `GeminiExecutableLocator.swift` | Discovery of the Gemini binary across mise, homebrew, etc. |
| `AgentTransport.swift` | Protocol definition for transport abstraction |

## Launching Gemini CLI

### Process arguments

```swift
// LocalACPTransport.swift
arguments: [String] = ["--acp", "--model", "gemini-2.5-pro"]
```

- **`--acp`** — Starts Gemini in ACP mode (JSON-RPC over stdin/stdout). This replaced the earlier `--experimental-acp` flag, which is now deprecated.
- **`--model gemini-2.5-pro`** — Explicitly sets the model. **This is required.** See [Default Model Deprecation](#default-model-deprecation-march-2026) for why.

### Process environment

The environment is constructed by `GeminiProcessEnvironment.make()`:

| Variable | Value | Why |
|---|---|---|
| `NO_BROWSER` | `1` | Prevents Gemini from attempting browser-based auth in headless mode. Zed sets this too. |
| `PATH` | Gemini bin dir + inherited + fallbacks | GUI apps launch with a minimal PATH. The merged PATH ensures Gemini can find `node` and other dependencies. |
| `HOME` | User home directory | Set if missing from the inherited environment. Gemini needs this to find `~/.gemini/`. |

**Fallback PATH directories** (appended in order):
1. `~/.local/share/mise/shims`
2. `~/.local/bin`
3. `~/bin`
4. `/opt/homebrew/bin`
5. `/usr/local/bin`
6. `/usr/bin`, `/bin`, `/usr/sbin`, `/sbin`

### Binary discovery

`GeminiExecutableLocator` searches in priority order:

1. Mise installs (newest version first): `~/.local/share/mise/installs/gemini/<version>/bin/gemini`
2. Mise shim: `~/.local/share/mise/shims/gemini`
3. User local: `~/.local/bin/gemini`, `~/bin/gemini`
4. Homebrew: `/opt/homebrew/bin/gemini`, `/usr/local/bin/gemini`
5. System `which` lookup (fallback)

## Protocol Flow

### Connection handshake

```
Client                              Gemini CLI
  │
  ├─ initialize ───────────────────────→
  │  { protocolVersion: 1,
  │    clientCapabilities: {
  │      fs: { readTextFile: true,
  │            writeTextFile: true },
  │      terminal: true,
  │      _meta: { terminal_output: true,
  │               terminal-auth: true }
  │    },
  │    clientInfo: {
  │      name: "AtelierCode",
  │      title: "AtelierCode",
  │      version: "0.1.0"
  │    }
  │  }
  │
  │  ← initialize response ────────────┤
  │     { protocolVersion: 1,          │
  │       authMethods: [...],          │
  │       agentCapabilities: {...} }   │
  │                                    │
  ├─ session/new ──────────────────────→
  │  { cwd: "...", mcpServers: [] }
  │                                    │
  │  ← session/new response ───────────┤
  │     { sessionId: "..." }           │
```

**Critical rules:**
- The flow is `initialize` → `session/new`. **Do not call `authenticate` between them.** Gemini handles auth internally. See [Eager Auth Bug](#2-eager-authenticate-call).
- Client capabilities must match what the client actually supports. See [Capabilities](#client-capabilities).
- There is no heartbeat or keepalive in the protocol.

### Prompt flow

```
  ├─ session/prompt ───────────────────→
  │  { sessionId, prompt: [{type: "text", text: "..."}] }
  │                                    │
  │  ← session/update (notification) ──┤  available_commands_update
  │  ← session/update (notification) ──┤  agent_thought_chunk
  │  ← session/update (notification) ──┤  agent_message_chunk (repeated)
  │                                    │
  │  ← session/prompt response ────────┤
  │     { stopReason: "end_turn" }     │
```

- **Notifications** have no `id` field. They stream during a prompt.
- **Responses** have an `id` matching the request. The `session/prompt` response arrives after all streaming is complete.
- `agent_message_chunk` contains the model's text output, streamed incrementally.
- `agent_thought_chunk` contains model reasoning (not currently surfaced in UI).
- `available_commands_update` lists slash commands (e.g., `/memory`).

### Client-side request handling

Gemini may send requests *to* the client (requests with an `id` and `method`). Currently handled:

| Method | Handler | Behavior |
|---|---|---|
| `session/request_permission` | `handlePermissionRequest` | Auto-approves with `allow_once` preference |
| All others | Default | Returns JSON-RPC error `-32601` (method not found) |

**Future work:** Zed implements `fs/read_text_file`, `fs/write_text_file`, and a full terminal suite (`terminal/create`, `terminal/output`, `terminal/wait_for_exit`, `terminal/kill`, `terminal/release`). We advertise these capabilities but don't yet handle the requests. This hasn't caused issues so far because simple prompts don't trigger tool use, but it should be implemented.

## Client Capabilities

```swift
// ACPProtocol.swift
static let atelierCodeDefaults = ACPClientCapabilities(
    fs: ACPFileSystemCapabilities(readTextFile: true, writeTextFile: true),
    terminal: true,
    _meta: ["terminal_output": true, "terminal-auth": true]
)
```

These values must match the Zed reference implementation. Gemini CLI uses them to determine internal code paths, including how it routes API calls through the Code Assist backend. Incorrect capabilities cause silent hangs. See [Capabilities Bug](#1-incorrect-client-capabilities).

| Field | Value | Purpose |
|---|---|---|
| `fs.readTextFile` | `true` | Tells Gemini the client can read files on its behalf |
| `fs.writeTextFile` | `true` | Tells Gemini the client can write files on its behalf |
| `terminal` | `true` | Tells Gemini the client can run terminal commands |
| `_meta.terminal_output` | `true` | Gemini-specific: client can render terminal output |
| `_meta.terminal-auth` | `true` | Gemini-specific: client can handle terminal-based auth flows |

## Authentication

AtelierCode uses `oauth-personal` authentication, which routes through Google's Code Assist API at `cloudcode-pa.googleapis.com` (not the standard `generativelanguage.googleapis.com`).

**How it works:**
1. User authenticates once by running `gemini` interactively in a terminal.
2. Credentials are stored in `~/.gemini/oauth_creds.json`.
3. Gemini CLI reads these credentials during `session/new` — no explicit `authenticate` call needed.
4. If credentials expire, the user must re-authenticate in a terminal.

**What not to do:**
- Do not call `authenticate` during connection setup. This interferes with Gemini's internal auth flow.
- Do not set `GEMINI_API_KEY` or `GOOGLE_AI_API_KEY` when using `oauth-personal`. These switch Gemini to the standard Generative Language API, which is a different backend with different behavior.

## Resolved Issues

### 1. Incorrect client capabilities

**When:** March 14, 2026
**Symptom:** Prompts hung indefinitely. `available_commands_update` arrived but `agent_message_chunk` never did.
**Root cause:** Advertising `fs: false, terminal: false` caused Gemini to enter a Code Assist code path where the streaming API call accepted the TCP connection but never returned data (no timeout on their end).
**Fix:** Updated capabilities to match Zed: `fs: true/true, terminal: true, _meta: { terminal_output: true, terminal-auth: true }`.

### 2. Eager `authenticate` call

**When:** March 14, 2026
**Symptom:** Compounded the capabilities issue. The hanging was intermittent — it worked right after re-authentication, then stopped.
**Root cause:** Calling `authenticate` before `session/new` caused two competing `refreshAuth` flows (global and session-specific) that could interfere with each other.
**Fix:** Removed the `authenticate` call entirely. Flow is now `initialize` → `session/new`.

### 3. Missing `NO_BROWSER=1`

**When:** March 14, 2026
**Symptom:** Potential browser-based operations in a headless subprocess.
**Fix:** Added `NO_BROWSER=1` to the process environment.

### 4. Default model deprecation (March 2026)

**When:** March 16, 2026
**Symptom:** Identical to issue #1 — prompts hung after `available_commands_update` with no message chunks. All ACP fixes were in place and correct. The hang occurred on a fresh build with a trivial prompt ("what directory are you in") that had worked two days prior.
**Root cause:** Google deprecated the default model that Gemini CLI v0.33.1 requests via the Code Assist API. The API returned `404 ModelNotFoundError: Requested entity was not found`. In ACP mode, this error was swallowed by the streaming retry logic (which has no timeout), causing a silent hang. In non-interactive mode (`gemini -p "test"`), the same hang occurred — but when `--model` was specified explicitly, the actual 404 error was surfaced.
**How identified:**
1. Ran `gemini -p "test"` directly — hung (same as ACP).
2. Ran `gemini -p "test" --model gemini-2.0-flash` — got `ModelNotFoundError: 404`.
3. Ran `gemini -p "test" --model gemini-2.5-pro` — worked instantly.
4. Ran ACP probe with `--model gemini-2.5-pro` — worked. Without `--model` — hung.
**Fix:** Added `"--model", "gemini-2.5-pro"` to the launch arguments. Also switched from `--experimental-acp` (deprecated) to `--acp`.
**Key lesson:** The Code Assist API (`cloudcode-pa.googleapis.com`) can deprecate models server-side at any time, with no CLI update or warning. When the default model is removed, Gemini CLI hangs silently in streaming mode because the retry path has no timeout. Always specify an explicit model.

### 5. Earlier infrastructure fixes

These were resolved before the ACP protocol issues and remain necessary:

| Fix | Why |
|---|---|
| App Sandbox disabled | Gemini needs filesystem access to `~/.gemini` |
| Process PATH construction | GUI apps launch with minimal PATH; Gemini couldn't find `node` (exit 127) |
| Mise binary discovery | Dynamic discovery of mise-managed Gemini installs |
| `session/request_permission` handling | Gemini sends permission requests the client must respond to |
| Working directory fallback | App no longer defaults to `/` for cwd |
| Protocol tolerance | Support for string JSON-RPC IDs, field aliases, richer update types |

## Diagnostic Playbook

When prompts hang, follow this sequence to isolate the problem:

### Step 1: Test the CLI directly

```bash
gemini -p "say hello" --model gemini-2.5-pro
```

If this hangs or errors, the problem is in Gemini CLI or Google's backend, not AtelierCode.

### Step 2: Test without `--model`

```bash
gemini -p "say hello"
```

If this hangs but step 1 worked, the default model has been deprecated. Update the `--model` argument.

### Step 3: Check OAuth credentials

```bash
python3 -c "
import json, datetime
creds = json.load(open('$HOME/.gemini/oauth_creds.json'))
expiry = datetime.datetime.fromtimestamp(creds['expiry_date'] / 1000)
print(f'Expires: {expiry}')
print(f'Expired: {expiry < datetime.datetime.now()}')
print(f'Has refresh token: {\"refresh_token\" in creds}')
"
```

If expired, re-authenticate: run `gemini` interactively in a terminal.

### Step 4: Test ACP mode with a probe

```bash
node tools/acp_probe.mjs
```

Or manually:

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{"fs":{"readTextFile":true,"writeTextFile":true},"terminal":true,"_meta":{"terminal_output":true,"terminal-auth":true}},"clientInfo":{"name":"AtelierCode","version":"0.1.0"}}}' | gemini --acp --model gemini-2.5-pro
```

If `initialize` responds but `session/prompt` hangs, there may be a new capability or protocol requirement.

### Step 5: Compare with Zed

Zed is the reference ACP client for Gemini. If Zed works but AtelierCode doesn't, diff the initialization payloads and environment. Key Zed source files:
- `crates/agent_servers/src/acp.rs` — Process spawning, JSON-RPC routing
- `crates/acp_thread/src/acp_thread.rs` — Session updates, streaming, tool calls
- `crates/agent_servers/src/custom.rs` — Environment variables (NO_BROWSER, SURFACE, API keys)

Notable Zed behaviors we don't yet replicate:
- Sets `SURFACE=zed` environment variable
- Implements `fs/read_text_file` and `fs/write_text_file` request handlers
- Implements full terminal suite (`terminal/create`, `terminal/output`, etc.)
- Has a 30-second initialization timeout
- Handles all 10 `session/update` notification types

### Step 6: Inspect the Gemini process

```bash
# Find the Gemini process
ps aux | grep gemini

# Check its network connections
lsof -i -p <PID>

# Check if it wrote an error report
ls -lt /tmp/gemini-client-error-* | head -5
cat /tmp/gemini-client-error-<latest>.json | python3 -m json.tool
```

## Zed Reference Comparison

This table summarizes the known differences between AtelierCode and Zed's ACP implementation, for tracking what to implement next.

| Feature | Zed | AtelierCode | Priority |
|---|---|---|---|
| `fs/read_text_file` handler | Implemented | Returns error | High |
| `fs/write_text_file` handler | Implemented | Returns error | High |
| Terminal handlers (5 methods) | Implemented | Returns error | Medium |
| `SURFACE` env var | `SURFACE=zed` | Not set | Low |
| Init timeout | 30 seconds | None | Medium |
| Prompt timeout | None | None | Medium |
| `agent_thought_chunk` display | Shown in UI | Ignored | Low |
| `AuthRequired` reactive handling | Terminal auth flow | Not implemented | Medium |
| All 10 session update types | Handled | Only `agent_message_chunk` | Low |
| Explicit `--model` | Not needed (different flow?) | Required | N/A |

## Version History

| Date | Gemini CLI | Change |
|---|---|---|
| March 14, 2026 | v0.33.1 | Fixed capabilities, removed eager auth, added NO_BROWSER |
| March 16, 2026 | v0.33.1 | Added explicit `--model gemini-2.5-pro`, switched to `--acp` flag |
