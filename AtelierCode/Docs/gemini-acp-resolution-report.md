# Gemini ACP Hanging Prompt — Resolution Report

## Date
March 14, 2026

## Problem Summary
AtelierCode's ACP (Agent Client Protocol) integration with Gemini CLI was hanging indefinitely on normal text prompts. The app would successfully connect, complete the ACP handshake (`initialize` → `session/new`), and receive `available_commands_update` notifications — but `agent_message_chunk` updates and the final `session/prompt` response never arrived for model-backed prompts. Slash commands like `/memory list` continued to work. The hang was intermittent: it would work immediately after re-authenticating with Google, then stop working within hours.

## Root Cause
Two compounding issues were responsible:

### 1. Incorrect client capabilities and metadata in `initialize`

AtelierCode was advertising minimal capabilities during the ACP `initialize` handshake:

```json
{
  "clientCapabilities": {
    "fs": { "readTextFile": false, "writeTextFile": false },
    "terminal": false
  }
}
```

The Zed editor — a working reference implementation of an ACP client for Gemini CLI — advertises:

```json
{
  "clientCapabilities": {
    "fs": { "readTextFile": true, "writeTextFile": true },
    "terminal": true,
    "_meta": { "terminal_output": true, "terminal-auth": true }
  }
}
```

Gemini CLI's internal behavior, including how it sets up the Code Assist backend session and routes API calls through `cloudcode-pa.googleapis.com`, is influenced by these capability declarations. With `terminal: false` and no `_meta` hints, Gemini's ACP mode entered a code path where the streaming API call to Google's Code Assist server would establish a TCP connection but never receive response data — hanging indefinitely with no timeout.

### 2. Eager `authenticate` call interfering with session setup

AtelierCode was calling `authenticate` with `"oauth-personal"` immediately after `initialize`, before `session/new`. This is not how working ACP clients behave:

- **Zed defers authentication entirely** — it never sends `authenticate` during connection setup. It only authenticates reactively when the agent returns an `AuthRequired` error.
- **Gemini CLI's `authenticate` handler** calls `refreshAuth` on the agent's global config and writes the auth type to user settings. When `session/new` then creates a session-specific config and calls `refreshAuth` again, the two auth flows could interfere with each other.

The combination of incorrect capabilities and eager authentication created a state where Gemini would accept the `session/prompt` request, open a connection to the Code Assist API, and then never receive a response.

### 3. Missing `NO_BROWSER=1` environment variable

Zed sets `NO_BROWSER=1` when launching Gemini in headless/ACP mode. Without this, Gemini may attempt browser-based operations that cannot succeed in a subprocess without a TTY.

## How the Root Cause Was Identified

### Symptom analysis

| Scenario | Behavior | Explanation |
|---|---|---|
| ACP slash commands (`/memory list`) | Worked | Local operations — no API call to Code Assist needed |
| Direct CLI `gemini -p "test"` | Worked | Different initialization flow, interactive auth refresh |
| ACP text prompts | Hung indefinitely | Streaming API call to `cloudcode-pa.googleapis.com` accepted connection but never returned data |
| Re-auth then immediate ACP | Worked briefly | Fresh OAuth token + warm connection to Code Assist succeeded initially |
| ACP after ~1 hour | Hung again | Not a simple token expiry — credentials were still valid (`expiry_date` showed 55+ minutes remaining) |

### Key diagnostic steps

1. **Network inspection** (`lsof -i -p <gemini_pid>`) confirmed Gemini had ESTABLISHED TCP connections to Google servers (`iu-in-f95.1e100.net`, `lga15s46-in-f10.1e100.net`) during the hang — the connection was open but no data flowed.

2. **Source code analysis** of Gemini CLI (v0.33.1) revealed:
   - `oauth-personal` routes through `CodeAssistServer` at `cloudcode-pa.googleapis.com` (not the standard `generativelanguage.googleapis.com` API)
   - The streaming request (`requestStreamingPost`) uses `retry: false` and **no timeout** — if the server accepts the connection but stalls, the client hangs forever
   - Client capabilities influence Gemini's internal initialization and Code Assist session setup

3. **Reference implementation comparison** — studying the [Zed editor's ACP integration](https://github.com/zed-industries/zed) (`crates/agent_servers/src/acp.rs`) revealed the three differences described above.

4. **Validation** — an ACP probe using Zed-style initialization (correct capabilities, no eager auth, `NO_BROWSER=1`) successfully completed a text prompt where the original configuration hung.

## Solution

Three changes were made to align AtelierCode's ACP flow with the working Zed reference implementation:

### 1. Updated client capabilities (`ACPProtocol.swift`)

```swift
// Before
static let atelierCodeDefaults = ACPClientCapabilities(
    fs: .unsupported,     // readTextFile: false, writeTextFile: false
    terminal: false
)

// After
static let atelierCodeDefaults = ACPClientCapabilities(
    fs: ACPFileSystemCapabilities(readTextFile: true, writeTextFile: true),
    terminal: true,
    _meta: ["terminal_output": true, "terminal-auth": true]
)
```

The `_meta` field was added to `ACPClientCapabilities` to support the Gemini-specific hints that Zed sends. These tell Gemini CLI that the client can handle terminal output and terminal-based authentication flows.

### 2. Removed eager authentication (`ACPSessionClient.swift`)

```swift
// Before: initialize → authenticate → session/new
let initializeResponse = try await sendRequest(method: .initialize, ...)
if let authMethodID = selectAuthenticationMethodID(from: authMethods) {
    _ = try await sendRequest(method: .authenticate, ...)
}
let newSessionResponse = try await sendRequest(method: .sessionNew, ...)

// After: initialize → session/new (auth deferred to agent)
let initializeResponse = try await sendRequest(method: .initialize, ...)
let newSessionResponse = try await sendRequest(method: .sessionNew, ...)
```

The `selectAuthenticationMethodID` helper was also removed. Authentication is now fully deferred — Gemini CLI handles auth internally during `session/new` using the credentials already stored in `~/.gemini/oauth_creds.json`. If auth is required, the agent returns `ErrorCode.AuthRequired` which the client can handle reactively.

### 3. Added `NO_BROWSER=1` environment variable (`LocalACPTransport.swift`)

```swift
environment["NO_BROWSER"] = "1"
```

This prevents Gemini CLI from attempting browser-based operations when running as a headless subprocess.

### Connection flow after fix

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
  │    clientInfo: { name: "AtelierCode" } }
  │
  │  ← { protocolVersion: 1,            │
  │       authMethods: [...],            │
  │       agentCapabilities: {...} }     │
  │                                      │
  ├─ session/new ──────────────────────→
  │  { cwd: "...", mcpServers: [] }
  │                                      │
  │  ← { sessionId: "..." }             │
  │                                      │
  ├─ session/prompt ───────────────────→
  │  { sessionId, prompt: [{text}] }
  │                                      │
  │  ← session/update (notification) ────┤
  │     available_commands_update        │
  │                                      │
  │  ← session/update (notification) ────┤
  │     agent_thought_chunk              │
  │                                      │
  │  ← session/update (notification) ────┤
  │     agent_message_chunk: "Hello!"    │
  │                                      │
  │  ← session/prompt response ──────────┤
  │     { stopReason: "end_turn" }       │
  │                                      │
  ✓ Complete
```

## Test Changes

- **`ACPPhase2Tests`**: Updated `initializeRequestEncodesExpectedShape` to verify new capability values (`true/true`, `terminal: true`, `_meta`). Updated `sessionClientRunsInitializeSessionAndPromptFlow` to expect `["initialize", "session/new", "session/prompt"]` (no `authenticate`). Renamed `sessionClientSkipsAuthenticateWhenOAuthPersonalIsUnavailable` to `sessionClientDefersAuthenticationToAgent`.
- **`ACPTransportPhase1Tests`**: Added `processEnvironmentSetsNoBrowser` test.

## Files Changed

| File | Change |
|---|---|
| `ACPProtocol.swift` | Added `_meta` to `ACPClientCapabilities`, updated defaults to `fs: supported`, `terminal: true` |
| `ACPSessionClient.swift` | Removed eager `authenticate` call and `selectAuthenticationMethodID` |
| `LocalACPTransport.swift` | Added `NO_BROWSER=1` to process environment |
| `ACPPhase2Tests.swift` | Updated capability assertions, removed `authenticate` from expected flow |
| `ACPTransportPhase1Tests.swift` | Added `NO_BROWSER` test |

## Prior Fixes (from earlier troubleshooting)

These were fixed before the root cause was identified and remain necessary:

1. **App Sandbox disabled** — Gemini needs filesystem access to `~/.gemini`
2. **Process PATH fixed** — GUI app launches had no PATH; Gemini couldn't find `node` (exit 127)
3. **Mise Gemini binary discovery** — Dynamic discovery of mise-managed Gemini installs
4. **`session/request_permission` handling** — App responds to Gemini permission requests
5. **Working directory fallback** — App no longer defaults to `/` for cwd
6. **Protocol tolerance** — Support for string JSON-RPC IDs, field aliases, richer update types

## Recommendations

### Short-term
- **Add a prompt timeout**: The Gemini CLI Code Assist streaming path has no timeout. If a future issue causes a similar hang, the app should cancel the request after a configurable duration rather than waiting indefinitely.
- **Handle `AuthRequired` errors reactively**: If `session/new` or `session/prompt` returns error code `-32000` (auth required), surface a clear message suggesting the user run `gemini` in a terminal to re-authenticate.

### Medium-term
- **Adopt a community Swift ACP SDK**: Three Swift SDKs exist ([wiedymi/swift-acp](https://github.com/wiedymi/swift-acp), [aptove/swift-sdk](https://github.com/aptove/swift-sdk), [rebornix/acp-swift-sdk](https://github.com/rebornix/acp-swift-sdk)). These handle protocol edge cases, timeout management, and cancellation that the hand-rolled implementation does not.
- **Implement file system request handlers**: Now that `readTextFile` and `writeTextFile` are advertised as `true`, Gemini may send file read/write requests. The app should implement handlers for these ACP methods.
- **Surface `agent_thought_chunk` updates**: Gemini sends model reasoning as thought chunks. These could be displayed in the UI as a thinking indicator.

### Long-term
- **Monitor Gemini CLI releases**: The `--experimental-acp` flag indicates this is an evolving interface. Track Gemini CLI releases for changes to ACP behavior, auth methods, and capability requirements.
