# AtelierCode Implementation Overview

## Summary

This roadmap translates the architecture in `Docs/architecture.md` into an execution path for the first version of AtelierCode: a Codex-first native macOS app in a single repository, with a bundled Bun/TypeScript bridge in top-level `AgentBridge/`.

The first release supports one active workspace per window, uses WebSocket for local app-to-bridge transport, and prioritizes the core conversation, approval, and thread-management loop before remote support or additional providers.

Implementation should follow the refined structure introduced during planning: split app state into `AppModel`, `WorkspaceController`, and `ThreadSession`, and treat Codex as the source of truth for thread persistence.

## Execution Plan

### 1. Establish the repo and runtime foundation

- Keep the macOS app and bridge in the same repository
- Add a top-level `AgentBridge/` Bun project with normal TypeScript conventions inside:
  - `src/index.ts`
  - `src/protocol/types.ts`
  - `src/protocol/version.ts`
  - `src/codex/codex-transport.ts`
  - `src/codex/codex-client.ts`
  - `src/codex/codex-event-mapper.ts`
  - `src/discovery/executable.ts`
- Bundle the compiled bridge executable inside the macOS app for local use
- Disable App Sandbox in the app target configuration before bridge-launch work begins
- Keep the bridge responsibility narrow: process lifecycle, protocol translation, approval relay, executable discovery, and health reporting

### 2. Build the app state architecture

- Add `AppModel` for app settings, recent workspaces, selected workspace restoration, and startup diagnostics
- Add `WorkspaceController` for one active workspace connection, bridge lifecycle, thread list, auth state, and connection status
- Add `ThreadSession` for transcript rendering, current turn state, approvals, activity items, plan state, and aggregated diff
- Keep observable mutations on `@MainActor`
- Persist only app-owned state:
  - recent workspaces
  - last-selected workspace
  - codex path override
  - UI preferences
- Do not persist transcript history locally

### 3. Define the stable bridge protocol and Codex mapping

- Use WebSocket as the initial local transport
- Implement a versioned bridge protocol with:
  - handshake messages: `hello`, `welcome`
  - command messages: `thread.start`, `thread.resume`, `thread.list`, `turn.start`, `turn.cancel`, `approval.resolve`, `account.read`, `account.login`, `account.logout`
  - event messages: `turn.started`, `message.delta`, `thinking.delta`, `tool.started`, `tool.output`, `tool.completed`, `fileChange.started`, `fileChange.completed`, `approval.requested`, `diff.updated`, `plan.updated`, `turn.completed`, `thread.list.result`, `account.login.result`, `auth.changed`, `rateLimit.updated`, `error`, `provider.status`
- Spawn `codex app-server` over stdio and map Codex JSONL notifications into the bridge protocol
- Include request/response correlation, partial-frame assembly, malformed-message handling, version mismatch handling, and bridge restart/reconnect behavior
- Treat browser-based ChatGPT login as a first-class flow: the bridge must surface login initiation data such as auth URL and login/session identifiers so the app can complete sign-in without requiring an API key

### 4. Deliver the UI in phases

- Phase 1: conversation MVP
  - workspace picker
  - connection and startup diagnostics
  - transcript with streamed assistant text
  - composer with send/cancel
- Phase 2: activity and approvals
  - reasoning/thinking sections
  - command execution cards with streamed output
  - file change cards with diff previews
  - approval prompts for command and file changes
  - plan progress and turn diff summary
- Phase 3: thread and workspace flows
  - thread sidebar for the active workspace
  - list, resume, fork, archive, unarchive, rollback, and read flows
  - workspace switching with explicit reset/reload rules
- Phase 4: account and readiness
  - codex binary discovery through PATH lookup, known install-path probing, and manual override
  - login, logout, account state, and rate-limit display
  - browser-based ChatGPT login flow, including opening the provider auth URL from bridge-provided login result data and reacting to completion/cancellation updates
- Phase 5: polish
  - richer Markdown rendering
  - syntax-highlighted code and diffs
  - keyboard shortcuts
  - long-thread performance improvements
  - skills and review mode UI after the transcript model is stable

## Interfaces and Boundaries

- Swift layer:
  - `AppModel`
  - `WorkspaceController`
  - `ThreadSession`
  - provider-agnostic view models for messages, approvals, activity items, diffs, and thread summaries
- Bridge layer:
  - versioned protocol types in `AgentBridge/src/protocol/types.ts`
  - Codex-specific implementation isolated behind transport, client, and event-mapper layers
- Architectural rule:
  - provider-specific logic stays below the bridge boundary
  - product behavior and UI logic stay in the Swift app
  - full multi-provider capability extraction is deferred until Codex flows are proven

## Test Scenarios

- Bridge protocol handling:
  - JSONL framing with partial reads and multiple messages per chunk
  - request/response correlation with interleaved notifications
  - delta assembly for assistant text, reasoning, tool output, and turn completion
  - approval request relay and resolution
  - browser-login initiation relay with auth URL handoff to the app
  - malformed payload and protocol mismatch handling
- App state handling:
  - new thread start
  - turn send/cancel
  - approval accept, decline, duplicate, stale, and cancelled flows
  - workspace switching reset/reload behavior
  - bridge crash and reconnect recovery
  - thread resume, fork, archive, unarchive, and rollback flows
- UI coverage:
  - conversation MVP
  - approval prompts
  - activity rendering
  - thread switching
  - startup diagnostics and missing-binary states

## Assumptions and Defaults

- First release is Codex-first
- The repo remains a monorepo
- The bridge lives in top-level `AgentBridge/`
- Files inside `AgentBridge/` follow normal TypeScript naming conventions
- Initial local transport is WebSocket
- V1 supports one active workspace per window
- The app may perform app-owned actions such as workspace selection, binary discovery, auth URL opening, and preference storage
- Browser-based provider login is a required first-party flow and must not depend on the user supplying an API key
- The app does not read files, write files, or run commands on behalf of the agent
- Codex remains the source of truth for thread persistence
- Remote support, Claude/Gemini adapters, and broader capability extraction are deferred until the Codex implementation is stable
