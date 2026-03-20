# Gemini ACP Integration Guide

This document is the current source of truth for AtelierCode's Gemini ACP integration.

Use this guide for the live implementation:
- transport and launch behavior
- handshake and prompt flow
- current capability and authentication decisions
- timeout and error behavior
- current limitations and next-step work

Do not use the troubleshooting log or migration plan as the primary reference for current behavior. Those documents are preserved as historical records.

## Docs Map

| Document | Purpose | Status |
|---|---|---|
| `gemini-acp-implementation-guide.md` | Current architecture and behavioral contract | Current |
| `gemini-acp-resolution-report.md` | Historical record of the March 2026 hanging-prompt fix | Historical |
| `gemini-acp-troubleshooting-log.md` | Chronological debugging notes from the unresolved hang investigation | Historical |
| `acp-migration-plan.md` | Original migration plan for the ACP cutover | Historical |
| `acp-foundation-readiness-plan.md` | Foundation hardening checklist | Active planning doc |

## Current Architecture

AtelierCode launches Gemini CLI as a local subprocess and speaks ACP over stdin/stdout using JSON-RPC 2.0 messages framed as JSONL.

```
┌──────────────┐    stdin/stdout     ┌─────────────┐
│ AtelierCode  │ ←───────────────→   │ Gemini CLI  │
│ ACP client   │     JSONL ACP       │ ACP agent   │
└──────────────┘                     └─────────────┘
```

### Key Files

| File | Role |
|---|---|
| `ACPProtocol.swift` | ACP wire types, capability policy, update decoding |
| `ACPSessionClient.swift` | Transport lifecycle, request routing, protocol guard, timeouts, inbound request handling |
| `ACPStore.swift` | App-facing connection and chat state |
| `LocalACPTransport.swift` | Gemini process launch, environment construction, JSONL framing |
| `GeminiExecutableLocator.swift` | Gemini binary discovery |
| `AgentTransport.swift` | Transport abstraction for tests and local subprocess transport |

## Current Launch Behavior

`LocalACPTransport` launches Gemini with:

```swift
["--acp", "--model", "gemini-2.5-pro"]
```

Current launch assumptions:
- AtelierCode uses `--acp`, not `--experimental-acp`.
- AtelierCode pins an explicit Gemini model because relying on Gemini's default model previously caused silent hangs when the backend default changed.
- Gemini runs as a local subprocess via `Process`.

### Process Environment

The transport builds a merged environment with:
- `PATH` starting with the Gemini executable directory, then the inherited path, then fallback directories
- `NO_BROWSER=1`
- `HOME` populated if the app environment does not already provide it

Fallback PATH directories:
1. `~/.local/share/mise/shims`
2. `~/.local/bin`
3. `~/bin`
4. `/opt/homebrew/bin`
5. `/usr/local/bin`
6. `/usr/bin`
7. `/bin`
8. `/usr/sbin`
9. `/sbin`

## Current ACP Handshake

The live connection flow is:

1. Start the transport once.
2. Send `initialize`.
3. Validate that the returned `protocolVersion` is supported.
4. Record `agentCapabilities` and `authMethods` from the initialize response.
5. Send `session/new`.
6. Cache the returned `sessionId`.
7. Reuse that session for later `session/prompt` requests.

The live prompt flow is:

1. Send `session/prompt` with a single text content block.
2. Append streamed `agent_message_chunk` text from `session/update` notifications.
3. Finish the turn when the final `session/prompt` response arrives.

Important handshake rules:
- The handshake is `initialize` -> `session/new`.
- AtelierCode does not proactively call `authenticate` during connection setup.
- Unsupported protocol versions fail before `session/new`.
- `connect()` is idempotent once a session already exists.

### Initialize Request

AtelierCode currently sends:

```json
{
  "method": "initialize",
  "params": {
    "protocolVersion": 1,
    "clientCapabilities": {
      "fs": {
        "readTextFile": true,
        "writeTextFile": true
      },
      "terminal": true,
      "_meta": {
        "terminal_output": true,
        "terminal-auth": true
      }
    },
    "clientInfo": {
      "name": "AtelierCode",
      "title": "AtelierCode",
      "version": "0.1.0"
    }
  }
}
```

### Protocol Version Policy

AtelierCode currently supports only ACP protocol version `1`.

If Gemini negotiates any other protocol version, `ACPSessionClient` throws `unsupportedProtocolVersion` and does not create a session.

## Current Capability Strategy

AtelierCode intentionally uses the `geminiCompatibility` interim capability strategy.

That means the client advertises:
- file-system read support
- file-system write support
- terminal support
- Gemini-specific `_meta` hints for terminal output and terminal auth

This is an explicit compatibility choice, not evidence that every advertised client-side ACP method is implemented.

### What Is Actually Implemented

Implemented today:
- `session/request_permission` inbound requests
- `session/update` notifications for `agent_message_chunk`
- tolerant decoding for Gemini's initialize and update payload variants

Not implemented today:
- `fs/read_text_file`
- `fs/write_text_file`
- `terminal/create`
- `terminal/output`
- `terminal/wait_for_exit`
- `terminal/kill`
- `terminal/release`
- richer `session/update` rendering beyond assistant message chunks

### Behavior For Unimplemented Client Methods

If Gemini sends one of the compatibility-only file-system or terminal client methods, AtelierCode returns JSON-RPC error `-32601` with an explicit message explaining that the capability is advertised temporarily for Gemini compatibility but the client method is not implemented yet.

This keeps the current compatibility stance visible instead of failing silently.

## Authentication Model

AtelierCode records Gemini's advertised `authMethods`, but it does not drive authentication as part of the handshake.

Current auth model:
1. The user authenticates Gemini outside the app, typically by running `gemini` in a terminal.
2. Gemini stores credentials in the local Gemini configuration directory.
3. AtelierCode launches Gemini and lets Gemini use those credentials during `session/new` and prompt execution.
4. If Gemini surfaces an auth-related ACP error, AtelierCode classifies it and shows guidance to re-authenticate in a terminal.

Important auth rule:
- Do not insert `authenticate` between `initialize` and `session/new`.

## Request Timeouts And Error Handling

`ACPSessionClient` applies request-specific timeouts to the core flow:

| Method | Timeout |
|---|---|
| `initialize` | 10 seconds |
| `session/new` | 15 seconds |
| `session/prompt` | 60 seconds |

Current error behavior:
- unsupported protocol versions fail fast during `connect()`
- request timeouts surface as `requestTimedOut`
- structured ACP server errors retain code, message, and JSON context
- authentication-related errors are classified separately and include re-auth guidance
- model-related errors are classified separately and include model-check guidance
- transport failure resets the session client and clears the active session

## Inbound ACP Handling

AtelierCode currently handles these inbound message classes:

| Inbound message | Current behavior |
|---|---|
| `session/update` with `agent_message_chunk` | Appends assistant text to the active streamed message |
| `session/update` with other update types | Ignored by the UI-facing stream path |
| `session/request_permission` | Responds automatically, preferring `allow_once`, then `allow_always`, then the first option |
| Other inbound client requests | Returns JSON-RPC `-32601` with a clear unsupported-method message |

## Store-Level Behavior

`ACPStore` wraps the session client with the app's current UX rules:
- auto-connect when needed
- keep one active ACP session in memory
- reuse the session across prompts
- append the user's prompt immediately
- create a single streaming assistant bubble per prompt
- reset connection state on failure

The store remains intentionally simple:
- single session
- single in-flight prompt
- text-only prompt input
- text-only assistant streaming in the UI

## Current Test Contract

The current ACP-focused tests cover:
- explicit protocol-version support policy
- initialize request shape
- capability-strategy expectations
- initialize response decoding, including Gemini field aliases
- timeout behavior for `initialize`, `session/new`, and `session/prompt`
- structured auth and model error classification
- transcript-style happy path coverage for `initialize` -> `session/new` -> `session/prompt`
- transcript-style prompt failure coverage
- deferred authentication behavior
- permission-request handling during a prompt

These tests are the practical contract for the current ACP foundation.

## Known Limits

The current implementation is intentionally partial ACP.

Known limits:
- compatibility-only file-system and terminal methods still return unsupported-method errors
- only `agent_message_chunk` is surfaced into the conversation UI
- assistant thought chunks and other richer update types are ignored
- there is no session persistence across app launches
- model selection is fixed by transport launch arguments rather than negotiated dynamically

## Future Work

Likely next ACP follow-up work:
- implement real file-system client handlers
- implement the advertised terminal client methods
- decide whether to keep or narrow the interim capability advertisement once those handlers exist
- surface additional `session/update` types in the UI
- add richer prompt content support beyond plain text
- revisit model configuration so it is intentional and configurable instead of transport-hardcoded

## Historical References

For historical context only:
- `gemini-acp-resolution-report.md` records how the March 2026 hanging-prompt issue was diagnosed and fixed.
- `gemini-acp-troubleshooting-log.md` preserves the unresolved investigation timeline before the final fix was locked in.
- `acp-migration-plan.md` captures the original phased migration plan and should not be read as the live implementation contract.
