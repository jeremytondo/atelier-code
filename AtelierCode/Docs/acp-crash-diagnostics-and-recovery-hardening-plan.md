# ACP Crash Diagnostics And Recovery Hardening Plan

## Goal

Make Gemini transport failures diagnosable and recoverable enough for real dogfooding sessions.

This work is not primarily about fixing one specific crash. It is about making AtelierCode tell us:
- what failed
- when it failed
- what the agent was doing when it failed
- what the user can do next without losing the full session context

## Why This Comes Before More Environment Work

The current app can fall back to a generic `Gemini subprocess failed` recovery surface even when the underlying cause is unclear.

Right now we cannot reliably distinguish between:
- Gemini exiting on its own
- a broken ACP pipe or send-after-exit condition
- an ACP protocol or decoding problem
- a timed out request
- a shell or environment issue
- an ordinary tool failure that should have remained inside the session transcript

Without better diagnostics, additional environment work is too speculative.

## Current Pain Points

- Transport failure currently collapses many distinct failure modes into one generic recovery state.
- We aggressively reset the live session after transport failure.
- Terminal state and host activity are cleared during failure handling.
- We keep at most a thin transport diagnostic signal instead of a useful crash report.
- The recovery surface hides the rich context that would help explain the failure.
- The user can recover, but cannot understand what just happened.

## Definition Of Done

This effort is complete when all of the following are true:
- A Gemini transport failure preserves a readable crash summary inside the app.
- The app distinguishes at least these failure classes:
  - subprocess exit
  - subprocess signal termination
  - request timeout
  - dead transport while sending
  - invalid ACP response or decode failure
  - recoverable session-load failure
- The recovery UI still exposes recent host activity and terminal context after failure.
- A user can reconnect or reset without losing the last useful evidence of the failure.
- Dogfood sessions produce enough local evidence that we can decide whether the next problem is transport, environment, protocol, or product logic.

## Scope

### In Scope

- transport crash diagnostics
- richer failure classification
- preserving host activity and terminal state through failure
- better recovery UI copy and evidence display
- lightweight persistence of recent failure evidence for the active workspace
- tests for new failure handling behavior

### Out Of Scope

- automatic multi-step self-healing
- full environment parity work
- embedded Gemini crash reporting outside the app
- visual polish beyond what is required for clarity

## Proposed Work

## Phase 1: Capture Better Failure Evidence

### Goal

Record enough structured context at the moment of failure to make the error actionable.

### Implementation

- Add a dedicated transport failure snapshot model, for example:
  - failure timestamp
  - workspace path
  - Gemini model
  - process exit status
  - termination reason
  - last ACP request method
  - request id if known
  - whether a prompt was in flight
  - last active terminal command and cwd
  - last N stderr diagnostic lines
  - last N host activity items
- Replace the single `latestTransportDiagnostic` string with a small rolling diagnostic buffer.
- Capture transport lifecycle events:
  - process started
  - first response received
  - send failure
  - termination observed
  - cleanup completed
- Preserve the final snapshot before `ACPStore` or `ACPSessionClient` reset clears transient state.

### Acceptance Criteria

- A transport failure includes more than just `localizedDescription`.
- The app can show the latest stderr lines and exit metadata.
- We can tell whether the process exited cleanly, was signaled, or died mid-request.

## Phase 2: Stop Destroying Useful Context

### Goal

Keep recent session evidence visible after failure instead of dropping back to a nearly blank recovery shell.

### Implementation

- Do not clear host activity history when handling a transport failure.
- Do not discard terminal state and output snapshots immediately on failure.
- Preserve the last assistant message, last in-flight prompt text, and terminal activity associated with the failure.
- Keep the main session surface mounted when possible, with a clear failure banner or overlay.
- If the blocking shell is still needed, embed recent failure evidence directly in that surface instead of hiding it.

### Acceptance Criteria

- After a crash, the user can still inspect recent terminal output and host activity.
- The last meaningful actions before failure are visible without reconnecting.
- Recovery does not feel like a total context wipe.

## Phase 3: Classify Failures More Precisely

### Goal

Turn the current generic recovery state into distinct failure categories with better guidance.

### Implementation

- Expand recovery issue classification to include separate kinds for:
  - subprocess exited with nonzero status
  - subprocess terminated by signal
  - send attempted on dead transport
  - request timed out
  - invalid ACP payload or decode failure
  - session resume failure that should fall back cleanly
- Preserve the underlying structured error alongside the user-facing recovery issue.
- Improve recovery suggestions based on failure class.
- Show exact status values and dates in user-facing diagnostics where helpful.

### Acceptance Criteria

- Two different transport failures no longer always produce the same user-facing recovery issue.
- Timeout and decode failures are distinguishable from subprocess exits.
- Resume-related failures do not look like hard crashes if they are recoverable.

## Phase 4: Improve Recovery UX

### Goal

Make reconnect and reset feel intentional, safe, and informed.

### Implementation

- Add a failure details section to the recovery surface or session banner.
- Show:
  - failure title
  - short explanation
  - timestamp
  - last Gemini diagnostic lines
  - last terminal command if relevant
  - recommended next action
- Differentiate:
  - `Reconnect`
  - `Reset Session`
  - `Copy Diagnostics`
- Consider a single automatic reconnect attempt for unexpected transport exit after startup, but only after evidence capture is in place.

### Acceptance Criteria

- The user can understand the tradeoff between reconnect and reset.
- Failure details are visible without opening Xcode or the console.
- Recovery actions no longer feel blind.

## Data Model Sketch

- `ACPTransportFailureSnapshot`
- `ACPTransportLifecycleEvent`
- `ACPRecoveryIssueKind` additions for precise transport and protocol failures
- optional workspace-scoped in-memory or persisted recent failure store

Possible fields for `ACPTransportFailureSnapshot`:
- `occurredAt`
- `workspacePath`
- `model`
- `exitStatus`
- `terminationReason`
- `lastRequestMethod`
- `lastRequestID`
- `wasPromptInFlight`
- `lastTerminalCommand`
- `lastTerminalCwd`
- `diagnostics: [String]`
- `recentActivities: [ACPMessageActivity]`

## Testing Plan

### Unit Tests

- subprocess termination with exit code
- subprocess termination by signal
- send on dead transport
- request timeout
- invalid response decoding
- failure snapshot captures recent diagnostics and last request metadata
- recovery handling preserves host activity and terminal evidence

### Integration Tests

- mid-prompt transport exit preserves context and surfaces reconnect actions
- reconnect from failure creates a fresh transport while keeping prior crash evidence visible
- reset session clears stale ACP session state but preserves prior failure summary for the current view

### Manual Dogfood Checks

- Start a real coding task and intentionally force a transport failure.
- Confirm the app shows:
  - exact failure type
  - recent diagnostics
  - last terminal command
  - recent host activity
- Confirm reconnect and reset behave differently and predictably.

## Implementation Notes

- Favor a rolling in-memory buffer over verbose permanent logs at first.
- Keep the first version app-owned and local; external telemetry can come later.
- Preserve enough structure that we can later export or copy diagnostics cleanly.
- Do not over-automate recovery until we trust the new classification layer.

## Recommended Order

1. Failure snapshot model and rolling diagnostics buffer
2. Preserve host activity and terminal evidence through failure
3. Add finer-grained recovery issue classification
4. Upgrade the recovery UI to show evidence and clearer actions
5. Re-evaluate environment work using the new diagnostics

## Expected Outcome

After this hardening pass, AtelierCode should still fail when Gemini or the transport fails, but it should fail in a way that is understandable, inspectable, and useful for the next engineering decision.
