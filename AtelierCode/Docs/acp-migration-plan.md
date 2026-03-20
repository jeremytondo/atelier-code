# Convert AtelierCode to ACP in Phases

Historical note:
- This document is the original ACP migration plan.
- It is preserved for project history and commit sequencing context.
- The current implementation contract lives in `gemini-acp-implementation-guide.md`.

## Summary
Convert the existing app in place rather than starting from scratch, but execute it as a phased refactor with small, reviewable commits. Keep the current SwiftUI shell and observable-store pattern, and replace the Codex-specific core in stages so transport, protocol, and UI cutover can each be validated independently.

Default delivery strategy:
- Replace the current Codex path in place.
- Target debug-local Gemini subprocess execution for the PoC.
- Keep strict sandbox packaging out of v1 and document that limitation.
- Lower the app deployment target to macOS 14.0 to match the stated objective.

## Phased Implementation

### Phase 0: Lock the plan and baseline
- Commit the ACP migration plan doc.
- Confirm the current app still builds before refactoring begins.
- Treat this as the rollback point for all later phases.

### Phase 1: Add ACP transport scaffolding without changing app behavior
- Introduce `AgentTransport` with `start() throws`, `send(message: Data)`, and `onReceive`.
- Add `LocalACPTransport` using `Process`, `Pipe`, and JSONL framing over stdio.
- Add an executable locator that checks known install paths first, then falls back to `/usr/bin/which gemini`.
- Launch Gemini with ACP mode. The live implementation now uses `--acp` with an explicit model argument.
- Handle stdout streaming, stderr diagnostics, and process termination, but do not wire the app UI to ACP yet.

Commit boundary:
- `refactor: add ACP transport scaffolding`

### Phase 2: Add ACP protocol models and session client flow
- Replace Codex-specific RPC assumptions with ACP request/response models for `initialize`, `session/new`, `session/prompt`, and `session/update`.
- Build the minimal ACP client flow:
  - start transport
  - send `initialize`
  - wait for successful initialize response
  - send `session/new`
  - cache `sessionId`
  - send `session/prompt` for each user message
- Keep inbound parsing flexible by decoding the top-level envelope first and extracting only `agent_message_chunk` text needed for streaming.
- Do not switch the app’s main store yet; prove the ACP flow through unit tests and store-adjacent logic.

Commit boundary:
- `feat: add ACP protocol models and session flow`

### Phase 3: Cut over the store from Codex to ACP
- Replace `CodexStore` with `ACPStore` on `@MainActor` using `@Observable`.
- Inject `AgentTransport` into the store so it remains testable without launching Gemini.
- Preserve the current UI-facing state shape:
  - connection status
  - draft text
  - message list
  - current assistant streaming index
  - error/status text
- Implement `connect()` and `sendMessage(_:)` around the ACP session flow.
- Stream `session/update` chunks into the active assistant message.
- Keep the PoC single-session and single in-flight prompt.

Commit boundary:
- `feat: switch store to ACP`

### Phase 4: Update the UI copy and root wiring
- Keep the current chat layout and interaction model.
- Update labels and status text from Codex/WebSocket wording to ACP/Gemini wording.
- Wire `AtelierCodeApp` to the new `ACPStore`.
- Keep auto-connect on appearance, scroll-to-latest behavior, and the bottom composer.
- Do not add new visual scope beyond what is needed for the ACP cutover.

Commit boundary:
- `feat: wire UI to ACP store`

### Phase 5: Final test hardening and cleanup
- Remove leftover Codex-only protocol code once the ACP path is verified.
- Add or finalize coverage for transport framing, ACP decoding, session lifecycle, streaming updates, and failure handling.
- Verify the app against a local Gemini CLI process end to end.
- Leave future sandbox-hardening work explicitly documented rather than partially implemented.

Commit boundary:
- `test: harden ACP flow and remove Codex leftovers`

## Public Interface / Type Changes
- Replace `CodexStore` with `ACPStore`.
- Add `AgentTransport` and `LocalACPTransport`.
- Keep `ConversationMessage` unless a rename becomes necessary for clarity.
- Replace Codex-specific JSON-RPC types with ACP-specific envelopes and params.
- Keep request ID tracking inside the store or a small ACP client helper; no new networking framework is needed.

## Test Plan
- Phase 1:
  - executable locator resolves common paths
  - `/usr/bin/which` fallback works
  - missing executable returns a clear error
  - JSONL framing handles full, partial, and multi-line reads
- Phase 2:
  - `initialize` request encoding is correct
  - `session/new` response decodes `sessionId`
  - `session/prompt` request shape is correct
  - `session/update` chunk extraction works for `agent_message_chunk`
- Phase 3:
  - fake transport can drive successful connect and session creation
  - prompt submission appends user and assistant rows
  - chunk updates stream into the current assistant row
  - unsupported notifications are ignored
  - transport/process failure resets sendability and surfaces a user-visible error
- Phase 4/5 manual checks:
  - app launches and connects automatically
  - Gemini starts with ACP mode
  - one session is created and reused
  - prompt submission streams live text in one assistant bubble
  - missing executable shows an actionable error

## Assumptions
- The PoC is Gemini-only even though the transport boundary is generic.
- Debug-local subprocess execution is acceptable for v1; strict sandbox-safe packaging is a follow-up.
- Unknown ACP update item types, tool calls, and richer content blocks are ignored unless needed for stable streaming.
- Each phase should land as its own commit before moving to the next so regressions are isolated quickly.

## Deferred Sandbox Follow-up
- v1 intentionally launches a local Gemini ACP subprocess with `Process`.
- No helper tool, XPC service, or sandbox-safe packaging path is partially implemented in this migration.
- Future hardening should package process launch separately instead of mixing it into the ACP store or protocol layers.
