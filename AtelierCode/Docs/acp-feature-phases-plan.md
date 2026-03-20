# ACP Feature Phases Plan

## Summary

Implement the remaining ACP work in four phases rather than one large push. Each phase should end in a shippable, testable checkpoint and should reduce one primary class of risk at a time.

Recommended order:
1. Read-only workspace tools and approval flow
2. Terminal lifecycle support
3. Richer session/update rendering
4. Prompt/session lifecycle and resume

This sequence matches the current codebase:
- the handshake, timeout, and transcript foundation is already in place
- advertised file-system and terminal capabilities are still mostly stubs
- the UI/store currently only understands streamed assistant text
- `session/cancel` and `session/load` exist in protocol surface but are not wired

## Phase 1: Read-Only Workspace Tools

### Goal

Make ACP immediately useful for real agent tasks while keeping the first expansion low-risk.

### Implementation Changes

- Implement inbound `fs/read_text_file` handling in `ACPSessionClient` instead of returning the current compatibility fallback.
- Introduce request/response wire types for file read operations in `ACPProtocol.swift`.
- Add a workspace access policy that:
  - resolves paths against the active `cwd`
  - rejects paths outside the allowed workspace root
  - returns structured ACP errors for denied or missing paths
- Keep `fs/write_text_file` unimplemented in this phase, but stop advertising write support if write handling is still absent.
- Replace the current auto-approve-only permission behavior with explicit policy plumbing for file access, even if the first UI is still minimal.
- Preserve the existing Gemini auth strategy and single-session model.

### Public / Interface Changes

- `ACPClientCapabilities` should advertise only capabilities that Phase 1 truly implements.
- Add file-read request and response types.
- Add a small permission/access-policy abstraction so later write and terminal features can reuse it.

### Acceptance Criteria

- Gemini can request file contents from within the current workspace and receive them successfully.
- Out-of-scope paths fail with clear ACP errors.
- The app no longer claims file writes if they are not implemented.
- Existing chat prompting still works unchanged.

## Phase 2: Terminal Lifecycle Support

### Goal

Enable real agent execution workflows that depend on shell interaction.

### Implementation Changes

- Implement inbound terminal client methods:
  - `terminal/create`
  - `terminal/output`
  - `terminal/wait_for_exit`
  - `terminal/release`
  - `terminal/kill`
- Add a terminal session manager separate from `LocalACPTransport` so Gemini's ACP subprocess and tool-launched terminals are not conflated.
- Track terminal instances by ACP terminal ID, including process, buffered output, exit status, and release state.
- Scope terminal launch to the workspace and inherit a controlled environment.
- Route terminal creation and destructive actions through the same permission policy introduced in Phase 1.
- Keep `fs/write_text_file` deferred unless the team explicitly wants it in this same phase.

### Public / Interface Changes

- Add ACP models for terminal method params/results.
- Add terminal state ownership in the session/store layer.
- Define terminal permission categories distinctly from file-read permissions.

### Acceptance Criteria

- Gemini can create a terminal, receive output, wait for completion, and release it.
- Killed or terminated terminal sessions clean up correctly.
- Terminal failures surface as structured user-visible errors instead of transport resets.
- Existing prompt streaming remains stable while tool terminals are active.

## Phase 3: Richer ACP Update Rendering

### Goal

Make tool-driven ACP work understandable in the UI, not just functional in the protocol layer.

### Implementation Changes

- Expand `ACPSessionUpdate` decoding beyond `agent_message_chunk` to retain:
  - tool call progress
  - available command updates
  - permission-related updates if present
  - terminal output events associated with active work
- Add a UI-facing event/state model in `ACPStore` so the app can render:
  - assistant text
  - tool activity
  - permission decisions
  - terminal output/progress
- Keep the current assistant message bubble behavior for text, but add adjacent progress/activity presentation rather than overloading assistant text with tool logs.
- Ignore unsupported future update types safely, but preserve enough shape to log or inspect them later.

### Public / Interface Changes

- Broaden the update model in `ACPProtocol.swift`.
- Add store state for non-chat ACP events.
- Add stable mapping between tool/terminal events and the currently active prompt turn.

### Acceptance Criteria

- A prompt that triggers tools shows visible progress rather than appearing idle.
- Terminal output and tool state are available to the UI in order.
- Unknown update types do not break decoding or regress chat behavior.
- The store still supports the simple chat-only path for prompts that do not use tools.

## Phase 4: Prompt Control And Session Resume

### Goal

Make long-running ACP work manageable and resilient across interruptions.

### Implementation Changes

- Implement outbound `session/cancel` and add store/UI support for cancelling an in-flight prompt.
- Add `session/load` support when Gemini advertises `loadSession`.
- Persist lightweight local session metadata keyed by workspace so the app can attempt resume after relaunch.
- Define clear fallback behavior:
  - if load succeeds, reuse the session
  - if load fails, create a new session and continue cleanly
- Ensure reconnect/reset logic distinguishes between:
  - transport failure
  - cancelled prompt
  - expired/unloadable session

### Public / Interface Changes

- Add cancel and resume methods to the session/store layer.
- Add persisted session metadata format and lookup rules.
- Extend connection state to represent cancelling/resuming when needed.

### Acceptance Criteria

- Users can cancel a running prompt without corrupting the session client.
- Relaunching into the same workspace attempts resume before creating a new session.
- Failed resume does not leave the app stuck; it cleanly falls back to `session/new`.
- Existing single in-flight prompt invariant is preserved.

## Test Plan

### Phase 1

- file read succeeds for workspace-relative path
- file read succeeds for absolute in-workspace path
- file read rejects out-of-workspace path
- missing file returns structured ACP error
- capability advertisement no longer claims unimplemented file writes

### Phase 2

- terminal create/output/wait/release happy path
- terminal kill path
- terminal process exits before wait completes
- permission denial blocks terminal creation cleanly
- terminal manager cleanup on disconnect/reset

### Phase 3

- transcript with assistant text plus tool updates
- available commands update decodes and is retained
- terminal output appears in store state in order
- unknown update types are ignored without breaking the prompt flow

### Phase 4

- cancel during prompt sends `session/cancel` and stops streaming state
- load existing session when supported
- resume failure falls back to new session
- transport failure during resume resets cleanly
- reconnect after cancel still works

## Assumptions And Defaults

- Gemini remains the only ACP target for these phases.
- The first milestone should optimize for safe, real usefulness, so read access comes before write access.
- `fs/write_text_file` is intentionally deferred until permission UX and workspace-safety rules are proven; if added later, it should slot between Phases 2 and 3 or be folded into Phase 2.5.
- Capability advertisement should become truthful at each phase boundary rather than staying permanently over-broad.
- The current auth stance remains unchanged: do not proactively call `authenticate`; react only to auth-related ACP errors.
