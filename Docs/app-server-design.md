# Atelier Code: Technical Design
## Mission

Atelier Code delivers an uncompromising, AI-first modern coding experience. It combines the power of AI coding agents with the speed, polish, and ergonomics of a native SwiftUI interface.

## Product Domains
Atelier Code is organized around three product domains:

- **Agentic Coding**: Write code with AI agents.
- **Context Management (Future State)**: Create, organize, and manage context using a beautiful native markdown editor. 
- **Planning (Future State)**: Plan and manage product work, tasks, and execution.

This document is centered on the **Agentic Coding** domain. The other domains are important to the long-term vision, but their internal models remain intentionally high level for now.

___
# Agentic Coding
The Agentic Coding domain defines the system for working with AI agent runtimes. It governs how users do things like create workspaces, conduct conversations, run turns, receive streaming updates, respond to approval requests, and continue work over time.

Its role is to provide a stable product model across one or more agent runtimes while keeping provider-specific behavior contained within runtime adapters.

## Scope
This document is focused on the Atelier App Server and Agent Adapters for the Agentic Coding domain.

It defines the server contract, adapter responsibilities, and runtime model. Native client architecture and client-specific behaviors are intentionally out of scope and should be defined separately.

## Core System Components
The Agentic Coding domain is composed of four primary system components:

- **Client Application**: A native macOS application, with future support for iOS, that delivers the primary end-user experience. 
- **App Server**: The backend control plane responsible for managing sessions, persistence, approvals, real-time thread updates, and the stable client-facing protocol. It coordinates communication between the client application and supported agent runtimes and owns the Atelier product contract.
- **Agent Adapters**: A provider-specific integration layer that maps the App Server’s Codex-shaped contract to the native interface exposed by an agent runtime. The Codex adapter should be near pass-through. Other adapters, such as Claude Agent SDK, translate runtime-specific behavior into the Codex-shaped model used by the App Server. Adapters normalize runtime differences upward but do not redefine the platform model.
- **Agent Runtimes**: The external agent systems that perform execution on behalf of the user, including maintaining the agent loop, invoking tools, and producing outputs. Examples include [Codex App Server](https://developers.openai.com/codex/app-server) and [Claude Agent SDK](https://platform.claude.com/docs/en/agent-sdk/overview).

### Note on the Client Application
The client application is out of scope for this document, however this is some context in case it affects decisions made for the App Server and Agent Adapters.

The client is responsible for connecting to the App Server and ensuring that the App Server is installed and running on the local machine or remote development host. On macOS, this likely means local installation when needed, background process launch, and local WebSocket connection. In future remote scenarios, such as iOS clients connecting to a remote development machine, the client may connect to a remote App Server over a secure network such as Tailscale. The exact installation, startup, and reconnection mechanism is still to be determined.

## Design Stance
The **[Codex App Server](https://developers.openai.com/codex/app-server)** is the reference runtime model for the Atelier Code App Server.

The **Atelier Code App Server** should mirror Codex as closely as practical. Atelier Code is not defining a separate orchestration model; it is adopting a Codex-shaped contract and adding only Atelier-owned platform concerns such as workspace metadata, persistence, capability gating, and runtime selection.

The **Codex adapter** should be mostly pass-through. Other adapters, such as **Claude Agent SDK**, should conform to the same Codex-shaped contract. When a runtime cannot fully support that contract, the limitation should be exposed through explicit capabilities rather than weakening the model.

### Codex App Server References 
* [Documentation](https://developers.openai.com/codex/app-server/)
* [Source Code](https://github.com/openai/codex/tree/main/codex-rs/app-server)

## Protocol
The Atelier **App Server** exposes a long-lived bidirectional **WebSocket** interface to the **Client Application** built around three protocol message types:
* **Requests**
* **Responses**
* **Notifications**

The protocol should remain JSON-RPC-shaped. Requests use `{ id, method, params }`. Responses echo `id` and return either `{ result }` or `{ error }`. Notifications use `{ method, params }` and do not include an `id`.

Method and notification names should remain slash-shaped where practical, using forms such as `thread/start`, `turn/start`, and `turn/started`.

In compact form:
* Request: `{ id, method, params }`
* Response: `{ id, result }` or `{ id, error }`
* Notification: `{ method, params }`

Atelier-specific methods should be limited to Atelier-owned concerns such as `Workspace` and related platform metadata.

## Core Primitives
The **Agentic Coding** domain is built around one Atelier-owned primitive, **Workspace**, layered on top of a Codex-shaped runtime model built around **Thread**, **Turn**, and **Item**.
* **Workspace**: The top-level container for agent work within a specific code environment. It defines where work takes place, including the local or remote environment and working directory, and stores workspace metadata and associated threads.
* **Thread**: A conversation between the user and an agent. Threads contain turns.
* **Turn**: A single user request and the agent work that follows. Turns contain items and stream incremental updates.
* **Item**: A unit of input or output within a turn, such as a user message, agent message, command execution, file change, or tool call.

## Lifecycle Overview
* **Initialize once per connection**: After opening a WebSocket connection to the **Atelier App Server**, the client establishes the session and begins receiving notifications.
* **Open a workspace**: The client opens or creates a **Workspace** to establish Atelier-owned product context for execution.
* **Start or resume a thread**: The client starts, resumes, or forks a **Thread** within that workspace.
* **Begin a turn**: The client starts a **Turn** with user input.
* **Steer an active turn**: The client may append input to the active turn without creating a new one.
* **Stream updates**: While a turn is active, the server streams status changes, item updates, and requests for user action.
* **Read point-in-time state**: `thread/read` and `thread/list` return point-in-time state. Live execution state is surfaced through the notification stream.
* **Finish the turn**: The server emits the final turn state when execution completes, fails, is interrupted, or pauses for user action.

## Initialization
After opening a WebSocket connection to the **Atelier App Server**, the **Client Application** initializes the session before issuing other requests.

The Atelier App Server keeps the same general initialize-then-proceed shape as Codex, but uses initialization only for lightweight client/server compatibility, session setup, and readiness rather than broad protocol negotiation.

## API Overview
The Atelier **App Server** mirrors the core thread and turn operations of the **Codex App Server**. The API surface is centered on:
* thread/start
* thread/resume
* thread/fork
* thread/read
* thread/list
* thread/name/set
* thread/archive
* thread/unarchive
* turn/start
* turn/steer
* turn/interrupt
* model/list

The App Server does not attempt to mirror the full Codex API surface. Codex-specific admin, configuration, plugin, and auxiliary execution APIs remain outside the core Atelier protocol.

## Models
The **Atelier App Server** exposes the runtime model catalog through a Codex-aligned model/list method.

The client only needs visible models, enough metadata to render the model picker, and the reasoning options supported by each model. The response should include the model identifier, display name, supported reasoning efforts, default reasoning effort, and whether the model is the runtime’s recommended default.

New threads use the runtime default model. The client may change the model and reasoning effort for a thread, and that selection persists for subsequent turns until changed again.

The current model and reasoning effort for a thread should be exposed through thread data, not through model/list.

## Threads
A **Thread** is the conversation container for agent work. Threads are started with `thread/start`, resumed for active interaction with `thread/resume`, forked with `thread/fork`, read with `thread/read`, and listed with `thread/list`.

`thread/read` should remain distinct from `thread/resume`. `thread/read` returns stored thread data only. It does not load the thread for active runtime interaction and does not establish a live notification stream.

`thread/resume` loads the thread for active runtime interaction. After resume, live execution updates should arrive through notifications rather than through repeated point-in-time reads.

`thread/list` and `thread/read` support history, navigation, and point-in-time inspection. They should not be treated as the canonical surface for active execution. 

Loaded-thread behavior should be represented through thread runtime status and notifications, not as a separate platform primitive. Thread runtime status should remain Codex-shaped, with states such as `notLoaded`, `idle`, `active`, and `systemError`, while live loaded-thread changes are surfaced through notifications.

## Turns
A **Turn** is a single unit of work within a thread. It begins with user input and includes the agent activity that follows.

Turns are started with turn/start, may be guided further with turn/steer, and may be interrupted with turn/interrupt.

A turn belongs to exactly one thread and is ordered within that thread. Only one turn may be active at a time per thread. A `Turn` is the core execution primitive. An active turn is not a separate concept; it is a turn whose status remains in progress or is awaiting user or runtime input.

### Turn Lifecycle
* A turn begins when the client issues turn/start.
* The server forwards the request to the selected runtime and begins streaming updates.
* While the turn is active, the server streams lifecycle changes, item events, and any requests for user action such as approvals.
* The client may send turn/steer to provide additional guidance to the active turn when supported by the runtime.
* A turn remains active while execution is in progress or awaiting required user or runtime input.
* A turn ends when it completes, fails, or is interrupted.
* The final turn state is emitted through the notification stream.

### Turn State
Turn status represents overall execution progress and is distinct from item-level updates. The App Server should stay aligned with the runtime's turn model where practical. An active turn is a turn whose status is still in progress or awaiting input. Any normalization needed for cross-runtime consistency should be handled by the adapter layer.

## Events
Events are the live notification stream for thread lifecycle, turn lifecycle, item activity, and user-action requests. Read and list methods return point-in-time state; notifications are the canonical surface for active execution. After a thread is started or resumed, the client receives notifications as runtime state changes.

At a minimum, the event stream should cover:
* **Thread events** such as status changes, archive state changes, and closure.
* **Turn events** such as turn start, completion, plan updates, and diff updates.
* **Item events** such as item start, item completion, and item-specific delta streams.
* **Request resolution events** used to close the loop on approvals and other user-action requests.

Notifications are the canonical surface for loaded-thread and in-progress turn execution.

`thread/status/changed` should carry runtime thread state for loaded threads. `turn/started` and `turn/completed` should mark turn lifecycle boundaries. `item/started` and `item/completed` should mark item lifecycle boundaries.

When runtime activity pauses for approval or other user input, the App Server should surface the request through the notification stream and emit a resolution event when the request is answered or cleared.

Example happy-path flow:
* `initialize`
* `workspace/open`
* `thread/start`
* `thread/started`
* `turn/start`
* `turn/started`
* item message and item delta notifications
* `turn/completed`

### Items
Items are the units of input and output within a turn. They should remain Codex-shaped in the App Server and be surfaced through item lifecycle notifications rather than through a separate platform-specific model.

An item should have a stable identity within the turn, a concrete item type, and a final completed shape that the client can treat as authoritative. Some item types may also produce incremental delta events while work is in progress.

Item deltas may be streamed while work is in progress when the runtime supports them. These deltas improve responsiveness, but the final item/completed payload should remain the authoritative final state for that item.

The client should render live progress from deltas when available, but should reconcile to the final completed item state. The App Server should not require the client to reconstruct the durable item record solely from deltas.

## Approvals
Approvals let the **Atelier App Server** pause execution when the selected runtime requires explicit user consent before continuing.

Approval requests are surfaced by the server during an active turn and resolved by the client. They are scoped to the relevant **Thread**, **Turn**, and item or request identity, and should be presented as part of the active conversation rather than as a separate workflow.

At minimum, the system should support:
* **Command execution approvals** when the runtime requires permission before running a command.
* **File change approvals** when the runtime requires permission before applying edits.
* **Tool or connector approvals** when a tool call has side effects or otherwise requires explicit user confirmation.

The App Server should treat approvals as server-initiated requests. The client responds with a user decision, and the server then resumes, declines, or clears the pending work.

The approval lifecycle should remain Codex-shaped:
* The runtime emits an item that represents the pending action.
* The server sends an approval request to the client for that item.
* The client returns a decision.
* The server emits a resolution event.
* The item completes with its final outcome.

Example approval flow:
* item begins
* approval request is emitted
* client returns decision
* resolution event is emitted
* item completes

The App Server should preserve enough approval state to support active UI rendering, recovery, and auditability, but it should not invent a separate approval system when the runtime already provides the authoritative flow.

## Implementation Foundations
This section captures the baseline implementation decisions for the App Server. The goal is to keep the server contract explicit and Codex-shaped while introducing only the minimum structure required for reliability and growth.

### App Server Foundation
The App Server should provide:
* A runnable process with healthcheck and initialize flow.
* A long-lived WebSocket entrypoint for request, response, and notification traffic.
* A method dispatcher that maps each incoming `method` to a handler, correlates responses using request `id`, and returns consistent protocol errors for unsupported methods or invalid params.
* Session-scoped execution state needed to coordinate active work (for example, which thread is loaded, whether a turn is currently active, and whether an approval is pending), without redefining the canonical thread/turn/item records produced by the connected agent runtime.
* A `Store` interface for Atelier-owned data (such as workspace metadata and thread index data), where domain services call interface methods and concrete implementations (for example, in-memory or SQLite) are swapped underneath without changing WebSocket handlers or protocol message shapes.

### Server Framework
Use **raw `Bun.serve`** for the App Server shell.

Rationale:
* Keeps protocol ownership explicit at the transport boundary.
* Minimizes framework-level indirection for long-lived WebSocket lifecycle handling.
* Aligns with existing Bun + TypeScript tooling already used by the bridge runtime.
* Reduces risk of framework-imposed patterns drifting from the Codex-shaped contract.

### Validation Model
Use a three-layer validation model:
1. **Envelope validation**: Parse and validate JSON-RPC-shaped message envelopes at ingress.
2. **Method payload validation**: Validate `params` and event payloads with method-specific schemas.
3. **Execution rule validation**: Enforce lifecycle and state rules in domain services.

Guidelines:
* Inbound requests and outbound notifications should both be validated against canonical schemas.
* Validation failures should map to stable, machine-readable error codes and message shapes.
* Execution rule violations (for example, steering a non-active turn) should be distinct from schema parse failures.

### Persistence Strategy
Use a storage interface boundary from the start, with:
* **In-memory implementation** as the default for iteration and testing.
* **SQLite-backed implementation** as the initial durable target.

Rationale:
* Keeps protocol and lifecycle work decoupled from migration and database concerns.
* Preserves a clean upgrade path to durable thread, turn, and approval state.

### Module Boundaries
Recommended module boundaries:
* `transport/` for WebSocket server, connection/session lifecycle, and framing.
* `protocol/` for envelope parsing, dispatcher, method registry, and response/error mapping.
* `schema/` for request/response/notification payload schemas.
* `domain/` for workspace/thread/turn/approval orchestration and invariants.
* `store/` for persistence interfaces and in-memory implementations.
* `runtime-adapters/` for Codex adapter and future runtime adapters.

### Baseline Readiness Criteria
The implementation is ready for broader integration when:
* The App Server can accept a WebSocket connection, initialize, and route a minimal method set.
* Thread and turn lifecycle state transitions can be exercised end-to-end in tests.
* Approval request and resolution flow can be simulated through notifications and decisions.
* Domain orchestration depends on `Store` interfaces rather than concrete database code.
* Protocol harness tests can assert contract shape and lifecycle sequencing.

#projects/atelier-code
