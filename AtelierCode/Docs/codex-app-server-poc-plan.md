# Minimal macOS Codex App Server PoC

## Summary
Build the PoC inside the existing `AtelierCode` macOS app target, keeping the architecture intentionally small: one `@Observable` store for connection + protocol state, one SwiftUI screen for chat, and a tiny set of Codable/dictionary-backed JSON-RPC envelopes just for `initialize`, `initialized`, `thread/start`, `turn/start`, and streamed `item/agentMessage/delta` events.

## Key Changes
- Switch the app target and test target to Swift 6 language mode so the PoC matches the stated concurrency target instead of relying on the current template's Swift 5 setting.
- Keep the existing App Sandbox configuration as-is; the project already has sandboxing enabled and `Outgoing Connections (Client)` turned on, so no additional capability work is required unless Xcode UI state and build settings diverge.
- Add a `CodexStore` type, ideally in a new `CodexStore.swift`, as `@MainActor @Observable final class CodexStore`.
  - Stored state: `connectionState`, `threadID`, `messages`, `draftPrompt`, `isConnecting`, `isSending`, `lastErrorDescription` or a lightweight status string, `currentAssistantMessageIndex`, `nextRequestID`, and private `URLSessionWebSocketTask` / listener task references.
  - Public methods: `connectIfNeeded() async`, `sendPrompt() async`, `disconnect()`.
  - Private flow: open socket to `ws://127.0.0.1:4500`, immediately send `initialize`, immediately send `initialized`, then send `thread/start`, then enter a continuous receive loop.
- Use a minimal message model for the UI even though the rendered content is just strings.
  - Recommended shape: `ConversationMessage(id: UUID, role: .user/.assistant/.system, text: String)`.
  - This keeps streaming simple: append a blank assistant message before a turn starts, then mutate only that entry as deltas arrive.
- Implement the protocol layer with the smallest useful envelope types.
  - Outbound request/notification structs or dictionary builders for:
    - `initialize` with dummy `clientInfo`
    - `initialized`
    - `thread/start`
    - `turn/start` with `threadId` and `input: [{ "type": "text", "text": prompt }]`
  - Inbound decoding can stay permissive:
    - one generic response envelope for matching `id`
    - one generic notification envelope with `method` and `params`
    - targeted decoders for `result.thread.id` and `params.delta.text`
- Define the connection/streaming behavior explicitly.
  - `connectIfNeeded()` is triggered from the root view's `.task` so the app auto-connects on appearance.
  - The store sends the handshake back-to-back without waiting for a separate server ack between `initialize` and `initialized`.
  - After `thread/start` succeeds, the returned thread id is cached for all later turns.
  - `sendPrompt()` is a no-op if the draft is blank or the thread id is missing.
  - The PoC supports one in-flight assistant turn at a time; disable the input control while a turn is actively streaming.
  - The receive loop handles text frames only and ignores unsupported frame types, extra methods, and non-text delta payloads.
- Replace the default template UI in `/Users/jeremytondo/Projects/AtelierCode/AtelierCode/ContentView.swift` with a simple chat surface.
  - `ScrollView` + `LazyVStack` for conversation history
  - lightweight row styling that differentiates user vs assistant
  - small status line for `Connecting`, `Ready`, `Streaming`, or a simple error string
  - bottom-pinned input row with `TextField` and `Send` button
  - auto-scroll to the newest message when a new user message or assistant delta arrives
- Wire the store into the app at the root, likely from `/Users/jeremytondo/Projects/AtelierCode/AtelierCode/AtelierCodeApp.swift`, using `@State` to own the observable store and inject it into `ContentView`.

## App-Facing Interfaces
- `CodexStore`
  - Source of truth for socket lifecycle, active thread, draft input, and streamed conversation state.
- `ConversationMessage`
  - Minimal typed UI model with `role` and `text`.
- JSON-RPC envelope types
  - only enough structure to encode outbound requests and decode `thread/start` results plus `item/agentMessage/delta` notifications.

## Test Plan
- Add lightweight unit tests in `/Users/jeremytondo/Projects/AtelierCode/AtelierCodeTests/AtelierCodeTests.swift` for:
  - decoding a `thread/start` response and extracting `result.thread.id`
  - decoding an `item/agentMessage/delta` notification and extracting `params.delta.text`
  - encoding a `turn/start` request with the expected `input` item shape
- Manual acceptance checks with a local server running on `127.0.0.1:4500`:
  - app launches and connects automatically
  - handshake completes before any thread/turn calls
  - a thread is created once per launch and its id is retained in memory
  - submitting a prompt shows the user message immediately and streams assistant text into a single live assistant row
  - restarting the app clears all state; no persistence is retained

## Assumptions
- The PoC remains single-window, single-thread, and text-only.
- No reconnect strategy, transcript persistence, tool execution, markdown rendering, or rich message item handling is included yet.
- Unknown server notifications are ignored unless they are needed to keep the minimal streaming UX coherent.
- The existing deployment target stays unchanged for now; only Swift language mode moves to Swift 6.
