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

## Architectural Approach: Native SDK Observer Model

### The Core Decision

Agent UI adopts a **native SDK observer model** rather than an Agent Client Protocol (ACP) host model. This is the same architectural pattern used by T3 Code and similar agent wrapper applications.

In this model:

- The AI agent runs as an autonomous process that directly reads files, writes files, and executes terminal commands on its own.
- Agent UI spawns the agent, subscribes to its structured event stream, and presents the agent's activity in the UI.
- When the agent needs user approval (e.g., before running a command or editing a file), it emits a structured approval request. Agent UI presents this as a native UI prompt. The user's decision is forwarded back to the agent, and the agent executes (or skips) the action itself.
- Agent UI never reads files, writes files, or runs terminal commands on behalf of the agent.

### Why This Approach

The alternative — implementing an ACP host — requires the application to build and maintain a full workspace runtime: process management for agent-requested terminals, a file system access layer with workspace sandboxing and path resolution, and a permission-gated execution pipeline. This is substantial infrastructure, and it duplicates functionality that every target CLI tool already implements natively.

The observer model eliminates that entire layer. The CLI tools already know how to interact with the file system and run commands. Agent UI's responsibility is to present what the agent is doing, give the user control over approval decisions, and provide workspace and session management. This aligns directly with the product vision of being a polished UI layer rather than a code execution engine.

### Comparison with ACP Host Model

| Concern | ACP Host Model | Native SDK Observer Model |
|---|---|---|
| File reads | App reads files and returns content to agent | Agent reads files directly; app is notified |
| File writes | App writes files on agent's behalf | Agent writes files directly; app is notified |
| Terminal execution | App spawns processes and streams output to agent | Agent spawns processes directly; app observes |
| Permission control | App can deny and prevent execution | App can deny; agent respects the decision and skips execution |
| Adding a new provider | Automatic if provider speaks ACP | Requires a new adapter |
| Infrastructure required | Protocol client + workspace runtime | Protocol client only |
| Remote support | Requires proxying all execution over network | Run agent on remote machine; stream events to app |

---

## MVP Integration: Codex App Server

The first provider integration is the **Codex App Server** protocol. This is the same protocol that powers the Codex VS Code extension, the Codex desktop app, and the Codex web app. It is open source, well-documented, and designed specifically for rich client integrations.

### Why Codex First

- The protocol is mature and explicitly designed for the use case Agent UI targets — embedding Codex into a product with authentication, conversation history, approvals, and streamed agent events.
- The protocol documentation includes schema generation (`codex app-server generate-ts` / `generate-json-schema`) so our Swift types can be validated against the exact version of Codex being used.
- Thread management (list, resume, fork, archive, rollback) is built into the protocol, which directly maps to the session management UI goals.
- The approval flow for command execution and file changes is a first-class protocol feature with structured request/response semantics — exactly what's needed for the native permission prompt UI.

### Protocol Overview

The Codex App Server communicates via **JSONL over stdio** using a JSON-RPC 2.0 variant that omits the `"jsonrpc":"2.0"` header. The server is started with `codex app-server` and waits for messages on stdin, emitting responses and notifications on stdout.

Communication is bidirectional:

- **Requests** (client → server): Include `method`, `params`, and `id`. The server responds with a matching `id` plus `result` or `error`.
- **Notifications** (server → client): Include `method` and `params` but no `id`. These are the streamed events that drive the UI.
- **Server-initiated requests** (server → client): Include `method`, `params`, and `id`. The client must respond. Used for approval flows.

### Core Primitives

The protocol is organized around three primitives:

- **Thread**: A conversation between the user and the Codex agent. Threads contain turns and are persisted by the server as JSONL log files. Threads can be started, resumed, forked, archived, unarchived, and rolled back.
- **Turn**: A single user request and the agent work that follows. A turn contains items and streams incremental updates. Turns have a lifecycle: `inProgress` → `completed` | `interrupted` | `failed`.
- **Item**: A unit of input or output within a turn. Item types include user messages, agent messages, reasoning, command executions, file changes, MCP tool calls, web searches, review mode entries, and more.

### Connection Lifecycle

```
Client                                  Codex App Server
  │                                            │
  ├─ initialize ─────────────────────────────→ │
  │  { clientInfo: { name, title, version } }  │
  │                                            │
  │ ←─────────────────────────── result ──────┤
  │                                            │
  ├─ initialized (notification) ─────────────→ │
  │                                            │
  │  (server is now ready for thread/turn ops) │
  │                                            │
  ├─ thread/start ───────────────────────────→ │
  │  { model, cwd, approvalPolicy, sandbox }   │
  │                                            │
  │ ←──────────── result { thread: { id } } ──┤
  │ ←──────────── thread/started notification ─┤
  │                                            │
  ├─ turn/start ─────────────────────────────→ │
  │  { threadId, input: [{ type, text }] }     │
  │                                            │
  │ ←──────────── result { turn: { id } } ────┤
  │ ←──────────── turn/started ────────────────┤
  │ ←──────────── item/started (reasoning) ────┤
  │ ←──────────── item/reasoning/summary... ───┤
  │ ←──────────── item/started (commandExec) ──┤
  │ ←──── item/commandExecution/requestApproval ┤
  │                                            │
  ├─ approval response { decision: "accept" } → │
  │                                            │
  │ ←──────────── item/commandExecution/output ─┤
  │ ←──────────── item/completed ──────────────┤
  │ ←──────────── item/agentMessage/delta ─────┤
  │ ←──────────── item/agentMessage/delta ─────┤
  │ ←──────────── turn/diff/updated ───────────┤
  │ ←──────────── turn/plan/updated ───────────┤
  │ ←──────────── turn/completed ──────────────┤
  │                                            │
  ✓ Turn finished                              │
```

### Item Types and UI Mapping

Each item type in the Codex protocol maps to a specific UI presentation:

| Item Type | Protocol Shape | UI Presentation |
|---|---|---|
| `userMessage` | `{ id, content: [{ type, text }] }` | User message bubble |
| `agentMessage` | `{ id, text }` | Assistant message bubble with streamed text via `item/agentMessage/delta` |
| `reasoning` | `{ id, summary, content }` | Collapsible thinking section (Xcode-style); `summary` for collapsed, `content` for expanded |
| `commandExecution` | `{ id, command, cwd, status, exitCode, durationMs }` | Terminal activity card with command, output stream, exit status |
| `fileChange` | `{ id, changes: [{ path, kind, diff }], status }` | File diff card with syntax-highlighted unified diff |
| `mcpToolCall` | `{ id, server, tool, status, arguments, result }` | Tool call activity card |
| `webSearch` | `{ id, query }` | Search activity indicator |
| `enteredReviewMode` / `exitedReviewMode` | `{ id, review }` | Review mode banner/section |
| `compacted` | `{ threadId, turnId }` | Subtle indicator that history was compacted |

### Approval Flow

Approvals are the primary user interaction beyond prompting. The Codex server sends a **server-initiated JSON-RPC request** to the client when it needs permission. The client must respond with `{ "decision": "accept" }` or `{ "decision": "decline" }`.

There are two approval types:

**Command Execution Approval:**
1. Server emits `item/started` with a `commandExecution` item showing the pending command.
2. Server sends `item/commandExecution/requestApproval` with `itemId`, `threadId`, `turnId`, optional `reason`/`risk`, and `parsedCmd`.
3. Client renders a native approval prompt showing the command, working directory, and risk assessment.
4. Client responds with accept or decline (optionally with `acceptSettings`).
5. Server emits `item/completed` with final status: `completed`, `failed`, or `declined`.

**File Change Approval:**
1. Server emits `item/started` with a `fileChange` item showing proposed changes and diffs.
2. Server sends `item/fileChange/requestApproval` with `itemId`, `threadId`, `turnId`, and optional `reason`.
3. Client renders a native approval prompt showing the proposed file changes with diff preview.
4. Client responds with accept or decline.
5. Server emits `item/completed` with final status.

The `approvalPolicy` set during `thread/start` or `turn/start` controls when approvals are triggered:

- `"never"` — the agent runs autonomously without asking.
- `"unlessTrusted"` — the agent asks unless the action is in the trusted set.

### Thread Management

The Codex protocol provides rich thread lifecycle operations that map directly to the session management UI:

| Operation | Method | UI Action |
|---|---|---|
| Create new conversation | `thread/start` | "New Thread" button |
| Continue existing conversation | `thread/resume` | Selecting a thread from the sidebar |
| Branch a conversation | `thread/fork` | "Fork Thread" action |
| View thread without resuming | `thread/read` | Thread preview / hover |
| List all threads | `thread/list` | Thread sidebar with pagination |
| List loaded threads | `thread/loaded/list` | Active thread indicators |
| Archive a thread | `thread/archive` | Swipe-to-archive or menu action |
| Restore archived thread | `thread/unarchive` | Archive view restore action |
| Undo recent turns | `thread/rollback` | "Undo Last Turn" action |

Thread listing supports cursor-based pagination, sorting by `created_at` or `updated_at`, and filtering by `modelProviders`, `sourceKinds`, and `archived` status.

### Turn Features

Each turn supports configuration overrides that persist for the thread:

- **Model selection**: Override per turn with `model` parameter.
- **Effort level**: Control reasoning depth with `effort` parameter.
- **Working directory**: Override `cwd` per turn.
- **Sandbox policy**: Control file system access (`readOnly`, `workspaceWrite`, `dangerFullAccess`, `externalSandbox`).
- **Summary mode**: Control conversation summarization.
- **Output schema**: Request structured JSON output for a specific turn.

### Streaming Events During a Turn

During an active turn, the server streams several categories of events:

**Item lifecycle events** (authoritative state):
- `item/started` — full item when work begins.
- `item/completed` — final item state when work finishes.

**Incremental deltas** (for real-time UI updates):
- `item/agentMessage/delta` — streamed text chunks for the assistant reply.
- `item/reasoning/summaryTextDelta` — streamed reasoning summary text.
- `item/reasoning/textDelta` — streamed raw reasoning text.
- `item/commandExecution/outputDelta` — streamed terminal stdout/stderr.
- `item/fileChange/outputDelta` — tool call response for file changes.

**Turn-level aggregates**:
- `turn/diff/updated` — aggregated unified diff across all file changes in the turn.
- `turn/plan/updated` — agent's current plan with step statuses (`pending`, `inProgress`, `completed`).
- `thread/tokenUsage/updated` — token usage for the thread.

### Authentication

The Codex App Server handles authentication internally with two methods:

**API Key**: Simple key-based auth via `account/login/start` with `type: "apiKey"`.

**ChatGPT Login**: Browser-based OAuth flow:
1. Client sends `account/login/start` with `type: "chatgpt"`.
2. Server returns a `loginId` and `authUrl`.
3. Client opens `authUrl` in the system browser.
4. Server hosts the OAuth callback locally.
5. Server emits `account/login/completed` and `account/updated` notifications.

### Skills

Codex supports reusable prompt templates called skills. Agent UI should:
- List available skills via `skills/list` (scoped by workspace `cwd`).
- Allow users to invoke skills with `$<skill-name>` syntax in prompts.
- Include the `skill` input item in `turn/start` for reliable resolution.
- Support enabling/disabling skills via `skills/config/write`.

### Review Mode

Codex has a built-in code reviewer triggered via `review/start` with targets:
- `uncommittedChanges` — review current working tree.
- `baseBranch` — diff against a branch.
- `commit` — review a specific commit.
- `custom` — free-form review instructions.

Reviews can be `inline` (on the current thread) or `detached` (forked to a new thread).

### Command Execution (Standalone)

`command/exec` runs a single command under the server sandbox without creating a thread. Useful for utility operations like running linters, formatters, or build commands from the UI.

---

## System Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                        Agent UI App                           │
│                                                               │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │                  SwiftUI View Layer                       │ │
│  │  Conversation · Activity · Approvals · Diffs · Threads   │ │
│  └──────────────────────┬──────────────────────────────────┘ │
│                         │                                     │
│  ┌──────────────────────▼──────────────────────────────────┐ │
│  │              Unified Session Model                       │ │
│  │  AgentSession · Messages · Activities · Approvals ·      │ │
│  │  Terminal Output · Diffs · Plans · Thread Management      │ │
│  └──────────────────────┬──────────────────────────────────┘ │
│                         │                                     │
│  ┌──────────────────────▼──────────────────────────────────┐ │
│  │              Agent Adapter Layer                          │ │
│  │                                                           │ │
│  │  ┌──────────────┐  ┌───────────────┐  ┌──────────────┐  │ │
│  │  │ Codex App    │  │ Claude Code   │  │ Gemini       │  │ │
│  │  │ Server       │  │ Adapter       │  │ Adapter      │  │ │
│  │  │ Adapter      │  │ (future)      │  │ (future)     │  │ │
│  │  └──────┬───────┘  └───────────────┘  └──────────────┘  │ │
│  └─────────┼───────────────────────────────────────────────┘ │
│            │                                                  │
└────────────┼──────────────────────────────────────────────────┘
             │ stdin/stdout (JSONL)
     ┌───────▼────────────┐
     │ codex app-server   │
     │ (child process)    │
     └───────┬────────────┘
             │
      ┌──────▼──────┐
      │  Workspace   │
      │  (files,     │
      │   terminals, │
      │   git)       │
      └─────────────┘
```

### Layer Responsibilities

**SwiftUI View Layer** — Presentation only. Renders conversation messages, agent reasoning (collapsible), command execution with approval prompts, file change diffs, plan progress, thread sidebar, and workspace management. Driven entirely by the unified session model.

**Unified Session Model** — The single source of truth for all UI state. Provider-agnostic. Holds the conversation transcript, streaming state, activity feed, pending approvals, terminal output, file diffs, plan steps, thread metadata, and connection lifecycle. All mutations happen on `@MainActor` via `@Observable`.

**Agent Adapter Layer** — One adapter per supported agent backend. Each adapter conforms to a shared protocol and is responsible for: spawning the agent process, managing the JSONL communication, parsing provider-specific events, normalizing them into the unified model's event types, and forwarding user input (prompts, approval decisions, cancellations) to the agent.

**Codex App Server** — The actual agent process. Handles all file system access, terminal execution, model communication, and session persistence internally. Agent UI communicates with it exclusively through the JSONL protocol.

---

## Codex Adapter Design

### Process Management

The Codex adapter spawns `codex app-server` as a child process using Foundation's `Process` and `Pipe`. Communication is JSONL over stdin/stdout. Stderr is captured for diagnostics.

```swift
final class CodexProcess {
    private let process: Process
    private let stdin: Pipe
    private let stdout: Pipe
    private let stderr: Pipe
    private var framer: JSONLFramer

    func start(codexPath: String) throws { ... }
    func send(_ message: CodexRequest) throws { ... }
    func stop() { ... }

    var messages: AsyncStream<CodexMessage> { ... }
}
```

### Message Types

The adapter defines Swift types mirroring the Codex protocol. Key distinction from standard JSON-RPC: the `"jsonrpc":"2.0"` header is omitted.

```swift
// Outbound: client → server
struct CodexRequest: Encodable {
    let method: String
    let id: Int
    let params: CodexParams
}

struct CodexNotification: Encodable {
    let method: String
    let params: CodexParams
}

// Inbound: server → client
enum CodexInbound {
    case response(id: Int, result: CodexResult?, error: CodexError?)
    case notification(method: String, params: CodexJSON)
    case serverRequest(id: CodexRequestID, method: String, params: CodexJSON)
}
```

### Approval Response Handling

When the server sends an approval request, the adapter must respond on the same JSON-RPC channel. This is the one place where the client sends a response to a server-initiated request:

```swift
struct CodexApprovalResponse: Encodable {
    let id: CodexRequestID
    let result: ApprovalDecision
}

struct ApprovalDecision: Encodable {
    let decision: String  // "accept" or "decline"
    let acceptSettings: AcceptSettings?  // optional, for command approvals
}
```

### Event Normalization

The adapter maps Codex-specific events to the normalized `AgentEvent` model:

| Codex Event | Normalized AgentEvent |
|---|---|
| `item/agentMessage/delta` | `.messageChunk(text:)` |
| `item/reasoning/summaryTextDelta` | `.thinking(text:)` |
| `item/started` (commandExecution) | `.toolActivity(.commandStarted(...))` |
| `item/commandExecution/outputDelta` | `.terminalOutput(...)` |
| `item/commandExecution/requestApproval` | `.approvalRequest(.command(...))` |
| `item/started` (fileChange) | `.toolActivity(.fileChangeStarted(...))` |
| `item/fileChange/requestApproval` | `.approvalRequest(.fileChange(...))` |
| `item/completed` | `.toolActivity(.completed(...))` |
| `turn/diff/updated` | `.diffUpdate(...)` |
| `turn/plan/updated` | `.planUpdate(...)` |
| `turn/completed` | `.turnComplete(status:)` |
| `account/updated` | `.authStateChanged(...)` |
| `account/rateLimits/updated` | `.rateLimitUpdate(...)` |

---

## Agent Adapter Protocol

Each adapter conforms to a shared Swift protocol. The Codex adapter is the MVP implementation; future adapters for Claude Code and Gemini will conform to the same interface.

```swift
protocol AgentAdapter: AnyObject {
    /// Start the agent for a given workspace.
    func start(workspace: String, configuration: AgentConfiguration) async throws

    /// Send a user prompt to the agent within an active thread.
    func sendPrompt(threadID: String, input: [PromptInput]) async throws

    /// Cancel the current in-flight turn.
    func cancelTurn(threadID: String, turnID: String) async throws

    /// Respond to an approval request from the agent.
    func resolveApproval(requestID: RequestID, decision: ApprovalDecision) throws

    /// Stop the agent and clean up resources.
    func stop() async

    /// Stream of normalized events from the agent.
    var events: AsyncStream<AgentEvent> { get }
}

/// Extended protocol for adapters that support thread management.
protocol ThreadManagingAdapter: AgentAdapter {
    func startThread(model: String?, cwd: String?) async throws -> ThreadInfo
    func resumeThread(threadID: String) async throws -> ThreadInfo
    func forkThread(threadID: String) async throws -> ThreadInfo
    func listThreads(cursor: String?, limit: Int?) async throws -> ThreadListPage
    func archiveThread(threadID: String) async throws
    func unarchiveThread(threadID: String) async throws
    func rollbackThread(threadID: String, turns: Int) async throws
    func readThread(threadID: String, includeTurns: Bool) async throws -> ThreadInfo
}

/// Extended protocol for adapters that support authentication.
protocol AuthenticatingAdapter: AgentAdapter {
    func readAccount() async throws -> AccountInfo?
    func loginWithAPIKey(_ key: String) async throws
    func loginWithChatGPT() async throws -> ChatGPTLoginFlow
    func cancelLogin(loginID: String) async throws
    func logout() async throws
    func readRateLimits() async throws -> RateLimits?
}

/// Extended protocol for adapters that support skills.
protocol SkillsAdapter: AgentAdapter {
    func listSkills(cwds: [String]) async throws -> [SkillInfo]
    func setSkillEnabled(path: String, enabled: Bool) async throws
}
```

The Codex adapter conforms to all four protocols. Future adapters implement whichever subset their backend supports.

### Normalized Event Model

```swift
enum AgentEvent {
    // Message streaming
    case messageChunk(text: String)
    case thinking(ThinkingEvent)

    // Tool activity lifecycle
    case toolActivity(ToolActivity)

    // Approval requests (server → client, requires response)
    case approvalRequest(ApprovalRequest)

    // Terminal output streaming
    case terminalOutput(TerminalEvent)

    // File changes and diffs
    case diffUpdate(DiffUpdate)

    // Agent plan progress
    case planUpdate(PlanUpdate)

    // Turn lifecycle
    case turnStarted(TurnInfo)
    case turnComplete(TurnResult)

    // Thread lifecycle
    case threadStarted(ThreadInfo)

    // Auth and account
    case authStateChanged(AuthState)
    case rateLimitUpdate(RateLimits)

    // Errors
    case error(AgentError)
}
```

---

## Unified Session Model

The session model is provider-agnostic and represents everything the UI needs:

```
AgentSession
├── connectionState: .disconnected | .connecting | .ready | .streaming | .cancelling
├── provider: .codex | .claudeCode | .gemini
├── workspace: WorkspaceConfiguration
├── activeThreadID: String?
├── threads: [ThreadSummary]                   // For sidebar listing
├── messages: [ConversationMessage]             // Current thread messages
├── currentTurn: TurnState?                     // In-flight turn with items
│   ├── items: [TurnItem]                       // Reasoning, commands, file changes, etc.
│   ├── plan: [PlanStep]                        // Agent's current plan
│   ├── aggregatedDiff: String?                 // Unified diff for all file changes
│   └── status: .inProgress | .completed | ...
├── pendingApprovals: [ApprovalRequest]         // Awaiting user decision
├── authState: AuthState                        // Account info, login state
├── rateLimits: RateLimits?                     // Usage tracking
└── lastError: AgentError?
```

The model is `@Observable` and drives SwiftUI views through standard observation. All mutations happen on `@MainActor`.

---

## Workspace and Session Management

Agent UI supports multiple workspaces and sessions:

- A **workspace** is a local directory (typically a git repository) that serves as the root for agent operations.
- A **thread** is a single conversation with an agent within a workspace. Thread terminology and lifecycle follow the Codex model (start, resume, fork, archive, rollback).
- Multiple threads can exist per workspace, and multiple workspaces can be open in the app.
- Thread listing and history are managed through the Codex protocol's `thread/list`, `thread/read`, and related methods. The Codex server persists thread logs as JSONL files — Agent UI does not need to implement its own persistence for conversation history.
- The workspace picker, thread list, and thread switching are app-level concerns that live above the adapter layer.

---

## Remote Support (Future)

The adapter protocol is designed so that the transport between Agent UI and the agent process can change without affecting the session model or views.

For remote support:

- A **local adapter** spawns `codex app-server` as a child process on the user's Mac (the current model).
- A **remote adapter** connects to a `codex app-server` process already running on a remote machine over SSH, WebSocket, or a similar transport.

The agent runs on the remote machine where the codebase lives. Agent UI receives the same JSONL event stream over the network connection. The unified session model and all SwiftUI views remain completely unchanged.

---

## Technology Stack

| Component | Technology |
|---|---|
| Application framework | SwiftUI (macOS native) |
| State management | Swift Observation (`@Observable`, `@MainActor`) |
| Adapter layer | Swift (Foundation `Process`, `Pipe`, async streams) |
| Agent communication | JSONL over stdio (JSON-RPC 2.0 without `jsonrpc` header) |
| Thread persistence | Delegated to Codex server (JSONL log files) |
| App settings persistence | UserDefaults |
| Code rendering | Syntax-highlighted views (Splash or custom AttributedString) |
| Markdown rendering | Native SwiftUI Markdown or rich rendering library |
| Diff rendering | Unified diff parser with syntax-highlighted split/unified views |
| Build system | Xcode / Swift Package Manager |
| Minimum deployment target | macOS 14.0+ |

---

## Development Phases

### Phase 1: Codex Foundation

- Implement the `CodexProcess` layer: spawn `codex app-server`, manage JSONL framing over stdin/stdout, handle process lifecycle.
- Implement the Codex adapter with support for: `initialize` / `initialized` handshake, `thread/start`, `turn/start`, and streaming event parsing for `item/agentMessage/delta`, `item/started`, `item/completed`, and `turn/completed`.
- Define the `AgentAdapter` protocol and `AgentEvent` model.
- Build the unified session model.
- Build the core SwiftUI views: conversation view with user/assistant messages, composer with send/cancel, basic connection status.
- Goal: send a prompt, see a streamed response, in a usable app.

### Phase 2: Approval Flow and Tool Activity

- Implement approval handling: parse `item/commandExecution/requestApproval` and `item/fileChange/requestApproval`, present native approval prompts, send accept/decline responses.
- Render command execution activity cards with streamed output via `item/commandExecution/outputDelta`.
- Render file change cards with diff preview.
- Render reasoning/thinking sections (collapsible, Xcode-style) from `item/reasoning/summaryTextDelta`.
- Render plan progress from `turn/plan/updated`.
- Goal: a full turn with tool use is visible and controllable.

### Phase 3: Thread Management

- Implement thread listing via `thread/list` with pagination.
- Build thread sidebar UI.
- Implement `thread/resume`, `thread/fork`, `thread/archive`, `thread/unarchive`, `thread/rollback`.
- Add workspace selection and persistence.
- Goal: multi-thread, multi-workspace session management.

### Phase 4: Authentication and Account

- Implement `account/read`, API key login, ChatGPT browser-based login flow.
- Render auth state and rate limit information in the UI.
- Handle auth-related errors gracefully with recovery prompts.
- Goal: first-launch experience works without pre-configuring Codex externally.

### Phase 5: UI Polish

- Collapsible, Xcode-style activity presentation for all item types.
- Rich syntax-highlighted code and diff rendering.
- Beautifully rendered Markdown for assistant messages.
- Keyboard shortcuts and navigation.
- Skills browser and invocation UI.
- Review mode UI.
- Goal: the UI matches the quality bar of the Xcode Agent integration.

### Phase 6: Additional Providers

- Implement Claude Code adapter (via Claude Agent SDK or claude-agent-acp).
- Implement Gemini adapter (investigate native SDK vs. ACP approach).
- Provider selection in the UI.
- Validate unified session model works across all providers.

### Phase 7: Remote Support

- Define remote adapter transport.
- Implement remote adapter variant.
- Remote workspace configuration UI.

### Phase 8: Extended Integrations

- Markdown editor integration.
- Project/issue tracker integration.
- Additional agent backends.

---

## Open Questions

- **Codex executable discovery.** Determine the best approach for locating the `codex` binary on the user's system. Consider common install paths (npm global, Homebrew, Cargo/crates.io since codex-rs is Rust), PATH resolution, and a settings override for custom paths.
- **Schema validation.** The Codex App Server can generate TypeScript and JSON Schema bundles specific to the installed version. Investigate whether to use these for compile-time Swift type generation or runtime validation.
- **Sandbox policy defaults.** Determine sensible defaults for `approvalPolicy` and `sandboxPolicy` in the UI. The Xcode-style UX suggests `unlessTrusted` as the default approval policy, but this needs user testing.
- **Claude Code adapter: SDK vs. ACP.** The Claude Agent SDK and the Zed ACP adapter are both options. Evaluate both during Phase 6. The native SDK likely provides richer events; the ACP adapter may be simpler.
- **Gemini adapter model.** Gemini CLI in ACP mode expects the host to handle execution. Investigate whether Gemini has or will have a native SDK mode. If not, the Gemini adapter may require a thin execution shim or the existing ACP host implementation could be repurposed specifically for Gemini.
- **Diff rendering.** Determine the best approach for rendering unified diffs in SwiftUI with syntax highlighting. The `turn/diff/updated` event provides aggregated diffs per turn, and `fileChange` items provide per-file diffs.
- **Thread persistence ownership.** Codex persists threads as JSONL log files. Determine whether Agent UI should maintain any additional metadata (tags, notes, workspace associations) or rely entirely on Codex's storage.
