# ACP Dogfood Readiness Plan

## Goal

Turn the current ACP-capable prototype into a stable dogfood build you can use for real coding sessions before spending time on visual polish.

This plan assumes:
- AtelierCode already has the core ACP host functionality needed for Gemini.
- The next highest-value work is productizing startup, workspace handling, setup recovery, permission control, and host observability.
- UI polish should happen after the app has stable product states worth polishing.

Recommended order:
1. App shell and test seams
2. Workspace lifecycle
3. Setup and recovery UX
4. Permission and host activity UX

Each phase should end in a usable, testable checkpoint.

## Definition Of Done

This readiness effort is complete when all of the following are true:
- The app can launch in previews and UI tests without starting a live Gemini subprocess.
- A workspace can be opened and switched from inside the app.
- Missing Gemini, auth-required, model errors, and transport failures are presented as clear product states.
- Permission decisions are explicit and app-owned instead of silently auto-approved.
- Tool activity and terminal output are understandable during real coding sessions.
- The app is practical to use on a real repo before any visual polish pass begins.

## Phase 1: App Shell And Test Seams

### Goal

Make the app launchable, previewable, and UI-testable without depending on a live ACP session.

### Implementation

- Add a lightweight app-level model that owns:
  - launch mode
  - selected workspace placeholder
  - blocking setup state
  - the currently mounted `ACPStore?`
- Introduce launch modes:
  - `live`
  - `preview`
  - `ui_test`
- Stop relying on the root view appearing as the only way to start a live session.
- Make `ContentView` the ready-state chat/session surface instead of the entire app state machine.
- Add scenario-driven mock transport support so previews and UI tests can render ACP states without Gemini.
- Make UI tests launch the app in mock mode by default.

### Checkpoint

At the end of this phase, the app has a stable shell and deterministic non-live launch path.

### Acceptance Criteria

- UI tests do not start Gemini.
- SwiftUI previews can render realistic ready, loading, and activity states.
- The app still supports the existing live ACP flow in `live` mode.
- The current launch/termination instability in UI tests is resolved.

## Phase 2: Workspace Lifecycle

### Goal

Make the app practical for real coding sessions across repos.

### Implementation

- Add an in-app workspace picker.
- Persist the last selected workspace path.
- Treat "no workspace selected" as a valid app state.
- When a workspace is opened:
  - create a fresh `ACPStore`
  - mount it into the app shell
  - attempt session resume for that workspace
- When a workspace is switched:
  - tear down the current session cleanly
  - clear transient transcript, activity, and terminal state
  - mount a new store for the new workspace
- Reuse the existing per-workspace ACP session persistence rules.

### Checkpoint

At the end of this phase, you can use AtelierCode on an actual repo selected from inside the app.

### Acceptance Criteria

- A workspace can be opened from the app and used immediately.
- Relaunch restores the last selected workspace.
- Session resume is attempted for the selected workspace and falls back cleanly when needed.
- Switching workspaces does not leak transcript, activity, terminal, or permission state.

## Phase 3: Setup And Recovery UX

### Goal

Turn local Gemini and ACP failures into usable product states instead of technical dead ends.

### Implementation

- Add dedicated setup or recovery surfaces for:
  - Gemini executable missing
  - authentication required
  - configured model unavailable
  - transport or subprocess failure
- Add a minimal settings surface for:
  - Gemini executable override path
  - default Gemini model
  - auto-connect on launch
- Show active workspace, connection state, and reconnect/reset actions in the app shell.
- Apply preferences before building the live session stack.
- Keep Gemini authentication terminal-based for now; do not build embedded OAuth in this phase.

### Checkpoint

At the end of this phase, the app can fail in normal ways without becoming confusing or unusable.

### Acceptance Criteria

- Missing Gemini does not leave the app stuck connecting.
- Auth-required and model-unavailable failures have actionable recovery paths.
- A failed session can be reset and retried without relaunching the app.
- Preferences are respected on the next live connection attempt.

## Phase 4: Permission And Host Activity UX

### Goal

Make the host behavior understandable and trustworthy enough for real coding work.

### Implementation

- Replace the default auto-approve permission behavior with app-owned permission prompts.
- Support these decisions for file reads and terminal creation:
  - `Allow once`
  - `Always for this workspace`
  - `Deny`
- Keep terminal kill and release as per-action confirmations only.
- Persist workspace-scoped saved permission rules.
- Add a dedicated host activity surface for:
  - tool progress
  - permission events
  - terminal sessions
  - terminal output
- Keep inline message activity, but also provide a global host event stream or panel.

### Checkpoint

At the end of this phase, you can run a real coding session and understand what the agent is doing without relying on raw ACP internals.

### Acceptance Criteria

- Permission requests visibly pause and resolve through the app.
- Workspace-scoped saved rules are applied correctly.
- Terminal output, completion, truncation, and release states are inspectable outside the chat bubble flow.
- A real coding session is understandable enough to dogfood productively.

## Test Plan

### Phase 1

- mock-mode app launch
- preview rendering with scenario data
- UI tests terminate cleanly

### Phase 2

- workspace open
- workspace switch
- last-workspace restore
- resume fallback on selected workspace

### Phase 3

- missing executable
- auth-required
- model-unavailable
- reconnect or reset after transport failure

### Phase 4

- permission request resolution
- workspace-scoped saved rules
- terminal output and progress rendering
- end-to-end dogfood coding session

## Defaults And Assumptions

- Optimize for a dogfood-ready build, not a public-beta onboarding experience.
- Keep `ACPStore` as the one-active-session model.
- Use an app-level shell model to decide when and where an `ACPStore` exists.
- Keep ACP client-side file writes out of scope.
- Keep Gemini auth external and terminal-based.
- Start UI polish after Phase 2 if you want earlier design iteration.
- Start UI polish after Phase 4 if you want the full host-product state map in place first.
