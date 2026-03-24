# Agent UI — High-Level Architecture

## Product Vision

Agent UI is a native macOS SwiftUI application that provides a polished graphical interface around CLI-based AI coding agents such as Claude Code, Codex, and Gemini CLI. The app is not an IDE or code editor. It is an agent-first coding environment where the user directs AI agents to read, reason about, and modify codebases — without editing code in the app itself.

The long-term vision includes integrating with complementary tools such as a Markdown editor and a project/issue tracker to create a comprehensive AI-first development workflow.

### Core User Experience Goals

The user should be able to:

- Prompt an AI agent to ask questions about a codebase.
- Ask an AI agent to make changes to a codebase.
- Respond to permission requests from the agent for actions like running terminal commands, reading files, or editing files.
- Use slash commands, skills, and other CLI-native features the underlying agent supports.
- Manage multiple workspaces and sessions, similar to the Codex Desktop app.

### Packaging Note

AtelierCode is intended to ship as a direct-download macOS app outside the Mac App Store. The app is therefore planned around bundling and launching a local helper executable without depending on the macOS App Sandbox, while the separate "sandbox policy" references in this document continue to describe agent execution behavior instead of App Sandbox entitlements.

### UI Inspiration

The primary UI inspirations are the Xcode Agent integration and the Codex Desktop app.

From the Xcode Agent UI:

- Consolidated, collapsible presentation of agent thinking, tool calls, and activity that keeps the interface clean while remaining expandable for inspection.
- Native UI elements for user choices such as permission approvals for terminal commands, file reads, and file edits.
- IDE-quality code rendering with syntax highlighting and formatting.
- Beautifully rendered Markdown for text content.

From the Codex Desktop app:

- Workspace and session management with threads, projects, and parallel agent work.
- A workflow-oriented approach where the app is a command center for agents, not a text editor.

The goal is a UI that matches the polish of the Xcode Agent integration but is designed entirely around an agentic coding workflow rather than an IDE workflow.

---

## Architectural Approach

### Two-Process Architecture: Native App + Provider Bridge

Agent UI is split into two processes with a clear responsibility boundary:

1. **Agent UI (SwiftUI)** — The native macOS application. Owns all product logic, state management, UI presentation, approval decisions, workspace/thread management, and settings.
2. **Provider Bridge (Bun/TypeScript)** — A thin, versioned translation layer. Owns spawning CLI agent processes, parsing their native event streams, normalizing events into a stable app-facing protocol, and relaying approval requests and responses.

### Why Two Processes

**Protocol volatility.** The Codex App Server, Claude Agent SDK, and Gemini CLI are all actively evolving. When a provider ships a breaking change, updating the bridge is a lightweight operation that does not require rebuilding and redistributing the Mac app. The Swift app speaks a stable contract that we define; the bridge absorbs provider churn.

**Remote support.** When Agent UI eventually supports remote codebases, the bridge runs on the remote machine alongside the agent and the code. The Swift app connects to the bridge over the network instead of a local socket. The bridge already knows how to spawn agents and stream normalized events — the only thing that changes is the transport. Without this separation, remote support would require either proxying raw agent stdio over the network or reimplementing the adapter layer twice.

**Ecosystem alignment.** Every agent SDK and adapter in this space is TypeScript. The Codex App Server generates TypeScript schemas. The Claude Agent SDK is TypeScript. Writing the bridge in TypeScript (via Bun) means protocol updates often involve pulling in updated types directly rather than hand-translating definitions across languages.

### Responsibility Boundary

This is the most important architectural decision in the system. The bridge must stay thin. If product logic migrates into the bridge, the app becomes harder to develop, debug, and reason about.

**The Swift app owns:**

- All UI presentation and interaction.
- Session model and observable state.
- Transcript history and conversation rendering.
- Approval decision UI and policy (accept, decline, workspace-scoped saved rules).
- Thread and workspace selection, listing, and navigation.
- Settings and preferences.
- Connection lifecycle to the bridge (spawn, restart, reconnect).
- All product-level logic and feature behavior.

**The bridge owns:**

- Spawning and managing CLI agent processes.
- Parsing each provider's native event stream (Codex App Server JSONL, Claude Agent SDK events, etc.).
- Normalizing provider events into the stable bridge protocol.
- Relaying approval requests from agents to the app and approval responses from the app to agents.
- Executable discovery and compatibility checks for each provider.
- Health and version reporting.
- Eventually, accepting remote connections instead of only local ones.

**The bridge does NOT own:**

- Approval policy or auto-approval logic. It forwards requests and relays decisions.
- Thread management state. It relays thread operations to the provider and returns results.
- Transcript persistence or history beyond what the provider handles natively.
- Any UI-state assumptions or product behavior.
- Settings or configuration beyond provider connection details.

### Observer Model

Both processes together implement an observer model for agent interaction:

- The AI agent runs autonomously — it reads files, writes files, and executes terminal commands on its own.
- The bridge observes the agent's structured event stream and normalizes it for the app.
- When the agent needs user approval, the bridge relays the request to the app, the app presents it to the user, and the user's decision flows back through the bridge to the agent.
- Neither the app nor the bridge ever reads files, writes files, or runs terminal commands on behalf of the agent.

---

## Bridge Protocol

The bridge protocol is the stable contract between the Swift app and the provider bridge. It is versioned independently from both the app and the providers.

### Transport

Local: WebSocket or Unix domain socket between the SwiftUI app and the locally-spawned bridge process.

Remote (future): The same WebSocket protocol over a network connection to a bridge running on a remote machine.

### Handshake

On connection, the app and bridge exchange version information:

```json
// App -> Bridge
{ "type": "hello", "appVersion": "1.0.0", "protocolVersion": 1 }

// Bridge -> App
{ "type": "welcome", "bridgeVersion": "1.0.0", "protocolVersion": 1, "providers": ["codex"] }
```

If protocol versions are incompatible, the app surfaces a clear error with update instructions.

### Message Categories

All messages are JSON, newline-delimited.

**App -> Bridge (commands):**

- `provider.start` — Start a provider session for a workspace.
- `provider.stop` — Stop a provider session.
- `thread.start` — Create a new thread.
- `thread.resume` — Resume an existing thread.
- `thread.list` — List threads (paginated).
- `thread.fork` — Fork a thread.
- `thread.archive` / `thread.unarchive` — Archive management.
- `thread.rollback` — Undo recent turns.
- `thread.read` — Read thread data without resuming.
- `turn.start` — Send a user prompt.
- `turn.cancel` — Cancel an in-flight turn.
- `approval.resolve` — Accept or decline an approval request.
- `account.read` — Check auth state.
- `account.login` — Initiate login.
- `account.logout` — Sign out.
- `skills.list` — List available skills.
- `review.start` — Start a code review.
- `command.exec` — Run a standalone command.

**Bridge -> App (events):**

- `message.delta` — Streamed assistant text chunk.
- `thinking.delta` — Streamed reasoning/thinking text.
- `tool.started` — A tool call or command execution has begun.
- `tool.output` — Streamed terminal/command output.
- `tool.completed` — A tool call or command execution finished.
- `fileChange.started` — File changes proposed.
- `fileChange.completed` — File changes applied or declined.
- `approval.requested` — Agent is requesting user permission (bridge relays, app decides).
- `diff.updated` — Aggregated diff for the current turn.
- `plan.updated` — Agent's plan with step statuses.
- `turn.started` — A new turn has begun.
- `turn.completed` — A turn has finished (with status).
- `thread.started` — A thread was created or resumed.
- `thread.list.result` — Response to a thread list request.
- `account.login.result` — Response to a login request, including browser-login handoff data such as auth URL and login identifier when needed.
- `auth.changed` — Authentication state changed.
- `rateLimit.updated` — Rate limit information updated.
- `error` — An error occurred.
- `provider.status` — Provider health/connection status change.

### Approval Flow Through the Bridge

The bridge is a passthrough for approvals. It never makes approval decisions. It never applies policy. It forwards the request with enough structured context (command text, working directory, risk level, file paths, diffs) for the app to render a rich native approval prompt, and it relays the user's decision back to the agent.

---

## MVP Integration: Codex App Server

The first provider adapter in the bridge targets the Codex App Server protocol.

### Why Codex First

- The protocol is mature and explicitly designed for rich client integrations.
- Thread management is built into the protocol (list, resume, fork, archive, rollback).
- The approval flow is a first-class protocol feature with structured request/response semantics.
- Schema generation enables type validation against the exact installed version.

### Codex Protocol Overview

The Codex App Server communicates via JSONL over stdio using a JSON-RPC 2.0 variant that omits the `"jsonrpc":"2.0"` header. The bridge spawns `codex app-server`, sends requests on stdin, and reads responses and notifications from stdout.

### Codex Core Primitives

- **Thread**: A conversation. Contains turns. Persisted by the server as JSONL log files.
- **Turn**: A single user request and the agent work that follows. Contains items. Lifecycle: inProgress -> completed | interrupted | failed.
- **Item**: A unit of work within a turn. Types include userMessage, agentMessage, reasoning, commandExecution, fileChange, mcpToolCall, webSearch, enteredReviewMode, exitedReviewMode, and compacted.

### Codex Item Types -> Bridge Events

| Codex Event | Bridge Protocol Event |
|---|---|
| item/agentMessage/delta | message.delta |
| item/reasoning/summaryTextDelta | thinking.delta |
| item/started (commandExecution) | tool.started |
| item/commandExecution/outputDelta | tool.output |
| item/commandExecution/requestApproval | approval.requested (type: command) |
| item/started (fileChange) | fileChange.started |
| item/fileChange/requestApproval | approval.requested (type: fileChange) |
| item/completed | tool.completed or fileChange.completed |
| turn/diff/updated | diff.updated |
| turn/plan/updated | plan.updated |
| turn/started | turn.started |
| turn/completed | turn.completed |
| account/updated | auth.changed |
| account/rateLimits/updated | rateLimit.updated |

### Codex Thread Management

Thread operations are relayed through the bridge. The app sends commands, the bridge forwards them to Codex, and returns the results:

| App Command | Codex Method | Purpose |
|---|---|---|
| thread.start | thread/start | New conversation |
| thread.resume | thread/resume | Continue existing |
| thread.fork | thread/fork | Branch conversation |
| thread.list | thread/list | Paginated listing |
| thread.read | thread/read | Read without resuming |
| thread.archive | thread/archive | Archive |
| thread.unarchive | thread/unarchive | Restore |
| thread.rollback | thread/rollback | Undo turns |

### Codex Turn Features

Each turn supports configuration overrides: model selection, effort level, working directory, sandbox policy, approval policy, summary mode, output schema, and skill invocation.

### Codex Authentication

The Codex App Server handles auth internally. The bridge relays auth operations: API key login, ChatGPT browser-based OAuth flow, account state queries, and rate limit notifications.

Browser-based ChatGPT login should be treated as the default user-facing path rather than an edge case. The bridge protocol must therefore include a dedicated login result event so the app can receive and act on structured login-initiation data such as:

- the browser auth URL to open
- a login identifier or session identifier for correlating completion/cancellation updates
- provider-specific mode details needed to render the right UX without exposing raw Codex protocol details above the bridge boundary

This keeps API-key login optional instead of making it the only fully supported path.

### Codex Review Mode

review/start triggers the Codex reviewer. Targets: uncommittedChanges, baseBranch, commit, custom. Reviews can be inline or detached.

### Codex Standalone Command Execution

command/exec runs a single command under the server sandbox without creating a thread. Useful for utility operations from the UI.

---

## Swift App Architecture

### Session Model

The session model is @Observable, provider-agnostic, and drives all SwiftUI views:

- connectionState: disconnected, connecting, ready, streaming, cancelling
- provider: codex, claudeCode, gemini
- workspace: WorkspaceConfiguration
- activeThreadID
- threads: [ThreadSummary] for sidebar listing
- messages: [ConversationMessage] for current thread
- currentTurn: TurnState with items, plan, aggregatedDiff, and status
- pendingApprovals: [ApprovalRequest] awaiting user decision
- authState: AuthState
- rateLimits: RateLimits
- lastError: AgentError

All mutations happen on @MainActor.

### Bridge Connection Manager

The Swift app manages the bridge process lifecycle:

- Local mode: Spawns the bridge as a child process, connects via WebSocket or Unix socket.
- Remote mode (future): Connects to a bridge already running on a remote machine.
- Reconnection: If the bridge process crashes, the app restarts it and re-establishes the connection.
- Version check: On connection, the app verifies protocol version compatibility.

### View Layer

The SwiftUI views consume only the session model. They never reference provider-specific types or bridge protocol details. Key views: ConversationView, ActivityCard (collapsible, Xcode-style), ApprovalPrompt, DiffView, ThreadSidebar, ComposerView, and SettingsView.

---

## Bridge Implementation

### Technology

Bun (TypeScript). Chosen for ecosystem alignment with provider SDKs and generated schemas.

If remote deployment later demands a single-binary deployment story, the bridge can be rewritten in Go once the contract and requirements are well-understood. The stable bridge protocol means the Swift app would not need to change.

### Structure

```
agent-ui-bridge/
  src/
    index.ts                    Entry point, WebSocket server
    protocol/
      types.ts                  Bridge protocol type definitions
      version.ts                Protocol version constants
    adapters/
      adapter.ts                Shared adapter interface
      codex/
        codexAdapter.ts         Codex App Server adapter
        codexProcess.ts         Process lifecycle management
        codexTypes.ts           Codex protocol types
        codexNormalizer.ts      Codex events -> bridge events
      claude/                   Future
      gemini/                   Future
    discovery/
      executable.ts             CLI executable discovery
  package.json
  tsconfig.json
```

### Adapter Interface

Each provider adapter implements a shared interface covering: start/stop, prompt sending, turn cancellation, approval relay, optional thread management, optional authentication, optional skills, and an event stream.

The Codex adapter conforms to the full interface. Future adapters implement whichever subset their backend supports.

---

## Workspace and Session Management

- A workspace is a local directory (typically a git repository) serving as the root for agent operations.
- A thread is a single conversation within a workspace. Terminology follows the Codex model.
- Thread persistence is delegated to the provider (Codex persists as JSONL log files). The app does not maintain a separate transcript store.
- The app owns workspace selection, thread navigation, and any app-level metadata.

---

## Remote Support (Future)

The two-process architecture makes remote support a transport change rather than an architectural change:

- Local mode: Swift app spawns the bridge locally, connects via Unix socket or local WebSocket.
- Remote mode: Bridge runs on the remote machine alongside the codebase. Swift app connects via WebSocket over the network. The bridge protocol and event stream are identical.

Additional considerations for remote mode: authentication and trust between app and remote bridge, file path display, network latency for approval flows, and bridge installation on remote machines.

---

## Technology Stack

| Component | Technology |
|---|---|
| Mac application | SwiftUI (native macOS) |
| App state management | Swift Observation (@Observable, @MainActor) |
| Bridge | Bun (TypeScript) |
| App <-> Bridge communication | WebSocket or Unix domain socket (JSON) |
| Bridge <-> Agent communication | JSONL over stdio |
| Thread persistence | Delegated to provider |
| App settings persistence | UserDefaults |
| Code rendering | Syntax-highlighted views |
| Markdown rendering | Native SwiftUI or rich rendering library |
| Diff rendering | Unified diff parser with syntax highlighting |
| Build system | Xcode (app), Bun (bridge) |
| Minimum deployment target | macOS 14.0+ |

---

## Development Phases

### Phase 1: Bridge Foundation + Basic Chat

Bridge: Set up Bun project, WebSocket server with handshake, Codex adapter with initialize/initialized, thread/start, turn/start, and event normalization for message deltas, item started/completed, and turn lifecycle.

Swift app: BridgeConnection manager (spawn bridge, WebSocket connect, event parsing), session model, core views (conversation, composer, connection status).

Goal: send a prompt, see a streamed response.

### Phase 2: Approval Flow and Tool Activity

Bridge: Parse and relay command execution and file change approval requests. Normalize output deltas, reasoning events, plan updates, and diff updates.

Swift app: Native approval prompts, command execution cards with streamed output, file change cards with diffs, collapsible thinking sections, plan progress.

Goal: a full turn with tool use is visible and controllable.

### Phase 3: Thread Management

Bridge: Thread operation relay (list, resume, fork, archive, unarchive, rollback, read).

Swift app: Thread sidebar with pagination, thread selection and navigation, workspace selection and persistence.

Goal: multi-thread, multi-workspace session management.

### Phase 4: Authentication

Bridge: Auth operation relay (account read, login, logout, rate limits).

Swift app: Auth state rendering, login flows, rate limit display, error recovery.

Authentication phase work explicitly includes browser-based ChatGPT login end to end:

- app sends `account.login`
- bridge returns `account.login.result` with login-initiation data when browser handoff is required
- app opens the auth URL and tracks the pending login session
- bridge relays completion, cancellation, refreshed account state, and rate-limit updates back into the session model

Goal: first-launch experience works without requiring the user to provide an API key.

### Phase 5: UI Polish

Swift app: Xcode-style collapsible activity, syntax-highlighted code/diffs, Markdown rendering, keyboard shortcuts, skills UI, review mode UI.

Goal: matches the quality bar of the Xcode Agent integration.

### Phase 6: Additional Providers

Bridge: Claude Code adapter (via Claude Agent SDK), Gemini adapter (investigate approach).

Swift app: Provider selection UI, validate session model across providers.

### Phase 7: Remote Support

Bridge: Accept remote connections with authentication, package for remote deployment. Consider Go rewrite if needed.

Swift app: Remote connection configuration, remote workspace UI.

### Phase 8: Extended Integrations

Markdown editor, project/issue tracker, additional agent backends.

---

## Versioning and Compatibility

The bridge protocol is versioned independently from both the app and the providers. The handshake includes version negotiation. When a provider ships a protocol change, only the bridge needs updating — the app continues to speak the stable bridge protocol.

For the MVP, keep app and bridge versions in lockstep. As the protocol stabilizes, they can drift more freely.

---

## Packaging and Distribution

Swift app: Standard macOS app bundle (DMG or direct download).

Bridge: Bundled with the app for the initial release using `bun build --compile` to produce a standalone executable inside the app bundle. No Bun runtime required on the user's machine for local mode. For remote mode, the bridge will also be independently installable.

### Remote Bridge Installation Model

Remote deployment should use a different packaging path than the local macOS app bundle.

- Local mode: the bridge is embedded inside the signed macOS app bundle and updates when the app updates.
- Remote mode: the app installs a prebuilt standalone bridge binary onto the remote machine instead of relying on the app bundle or requiring Bun to be installed remotely.
- Preferred bootstrap flow: the app connects over SSH, detects remote OS and architecture, checks for a compatible bridge version in a user-scoped install directory, uploads or downloads the correct binary if needed, runs a healthcheck, and then launches the bridge.
- Preferred remote install location: a versioned path inside the remote user's home directory such as `~/.ateliercode/bridge/<version>/ateliercode-agent-bridge`, with a `current` symlink or equivalent pointer for the active version.
- The app and bridge should negotiate protocol compatibility on connect. If the remote bridge is missing or incompatible, the app should install or switch to a compatible version before starting a session.
- Remote installation should avoid root privileges and should treat the bridge as a disposable runtime dependency that can be replaced or rolled back per host.
- Remote binaries should be distributed as prebuilt artifacts for supported targets such as Linux and macOS. Independent remote installation does not require the remote machine to have Bun installed.
- Before launching a remote bridge, the app should verify artifact integrity and trust, such as checksum validation and whatever signing/notarization story is appropriate for the distribution channel.

---

## Open Questions

- Local socket vs. WebSocket for local communication. Unix domain sockets have lower overhead; WebSocket is more natural for eventual remote use. Evaluate starting with WebSocket everywhere for simplicity.
- Bridge crash recovery behavior. Define exact restart and reconnection semantics.
- Codex executable discovery strategy in the bridge.
- Schema validation approach using Codex-generated JSON Schema bundles.
- Claude Code adapter: Claude Agent SDK vs. Zed ACP adapter. Evaluate during Phase 6.
- Gemini adapter: investigate whether Gemini has a native SDK mode or requires ACP host behavior.
- Thread metadata: determine if the app needs metadata beyond what Codex persists.
- Go rewrite criteria: define when remote deployment requirements justify rewriting the bridge.
