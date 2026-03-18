# ACP Foundation Readiness Plan

## Goal

Stabilize the current ACP implementation so it is safe to build on before adding more protocol surface area.

The intent is not to implement full ACP immediately. The intent is to make the existing handshake, transport, tests, and troubleshooting story solid enough that future feature work does not pile onto a shaky base.

## Scope

This plan covers the six foundation steps identified during review:

1. Make the ACP test suite fully green and deterministic.
2. Add a strict protocol-version guard.
3. Define an intentional interim capability story.
4. Add timeout and error hardening around the core flows.
5. Add transcript-style integration coverage for the happy path.
6. Align the docs with the current code and decisions.

## Success Criteria

Before starting new ACP feature work, all of the following should be true:

- The ACP-focused tests pass consistently.
- The current handshake path is explicitly validated, not just assumed.
- Capability advertisement matches an intentional product decision.
- Core requests fail clearly instead of hanging indefinitely.
- The current happy path is locked in by higher-confidence tests.
- The docs describe the current implementation truthfully and consistently.

## Step 1. Make The Test Baseline Green

### Objective

Remove known flaky or misleading test failures so the suite becomes trustworthy again.

### Why

Future ACP work will be hard to evaluate if the baseline is already noisy. A red suite that is "expected" stops being useful.

### Tasks

- Fix the brittle temp-path assertions in `ACPTransportPhase1Tests.swift`.
- Normalize or canonicalize temp-directory paths in the affected tests.
- Re-run the ACP-focused tests until they pass consistently.
- Re-run the full Xcode test suite and confirm there are no known flaky ACP failures left.

### Done when

- The current ACP test suite is green.
- The failing `/var` vs `/private/var` path issue is resolved in a durable way.

## Step 2. Add A Strict ACP Protocol-Version Guard

### Objective

Fail fast if the agent negotiates an ACP protocol version the client does not support.

### Why

Right now the client records the negotiated `protocolVersion` but does not enforce it. That means the app could continue into an incompatible protocol state and fail later in much harder-to-debug ways.

### Tasks

- Decide exactly which ACP protocol versions AtelierCode supports.
- Validate the `initialize` response before proceeding to `session/new`.
- Surface a clear incompatibility error when the negotiated version is unsupported.
- Add tests for both the supported and unsupported version cases.

### Done when

- `initialize` rejects unsupported ACP versions immediately.
- The behavior is covered by focused tests.

## Step 3. Define An Intentional Capability Strategy

### Objective

Be explicit about what AtelierCode claims to support during `initialize`, and why.

### Why

Today the app advertises file-system and terminal capabilities, but it does not implement the corresponding ACP client methods yet. That might be temporarily necessary for Gemini compatibility, but it should be an explicit decision rather than an accidental mismatch.

### Tasks

- Confirm which advertised capabilities are required for Gemini's working path today.
- Decide whether the short-term strategy is:
  - keep advertising them temporarily for compatibility, or
  - narrow the advertisement to only what is actually implemented.
- If keeping them temporarily, document that this is intentional and transitional.
- If possible, add minimal explicit fallback behavior for unimplemented client methods so failures are clearer.
- Write tests that reflect the chosen strategy.

### Done when

- The capability story is deliberate, documented, and testable.
- Future work can build from a known compatibility stance instead of uncertainty.

## Step 4. Harden Core Request Lifecycles

### Objective

Prevent the basic ACP flows from failing silently or hanging forever.

### Why

The current implementation is simple, which is good, but it still depends heavily on the agent eventually answering. When something goes wrong, we want fast, understandable failure modes instead of indefinite hangs.

### Tasks

- Add timeouts around:
  - `initialize`
  - `session/new`
  - `session/prompt`
- Preserve more structured ACP error context instead of flattening everything into generic text.
- Make authentication-related and model-related failures easier to distinguish in surfaced errors.
- Add tests for timeout and structured error cases.

### Done when

- Core ACP requests fail clearly and predictably.
- Troubleshooting no longer depends on guessing whether the app is hung or waiting.

## Step 5. Add Transcript-Style Integration Coverage

### Objective

Lock in the known-good basic ACP flow with tests that exercise a realistic message transcript.

### Why

The current unit coverage is useful, but higher-confidence transcript tests will better protect the handshake and streaming behavior as the implementation grows.

### Tasks

- Add a transcript-style test covering:
  - `initialize`
  - `session/new`
  - `session/prompt`
  - streamed `session/update` notifications
  - final prompt response
- Keep the transcript small and focused on the basic happy path.
- Add at least one failure transcript for an early setup error or prompt failure.
- Use these tests as the baseline contract before adding richer ACP features.

### Done when

- A realistic happy path is locked in by tests.
- Basic ACP changes can be reviewed against a clear behavioral contract.

## Step 6. Align Docs With Current Reality

### Objective

Make sure the docs reflect the implementation as it exists now, not every experimental path we tried along the way.

### Why

The troubleshooting history is valuable, but future work gets harder if it is unclear which guidance is historical and which guidance is the current source of truth.

### Tasks

- Review the ACP docs for stale or contradictory guidance.
- Make the current handshake flow explicit.
- Clearly distinguish:
  - current implementation truth
  - historical troubleshooting notes
  - future work
- Update any docs that still imply obsolete behavior, especially around authentication and capability assumptions.

### Done when

- A new contributor can read the docs and understand the current ACP architecture without guessing.
- Historical experiments are preserved without being mistaken for current behavior.

## Recommended Order

Work through the plan in this order:

1. Green and stabilize the test baseline.
2. Add the protocol-version guard.
3. Decide and document the interim capability strategy.
4. Add timeout and error hardening.
5. Add transcript-style integration coverage.
6. Do a final docs pass so the written guidance matches the code.

## Readiness Gate Before New ACP Features

Before implementing new ACP features, confirm:

1. The ACP-focused suite is green and deterministic.
2. Unsupported ACP versions fail fast.
3. Capability advertisement is intentional and documented.
4. Core handshake and prompt flows have timeout protection.
5. The basic happy path is covered by transcript-style tests.
6. The docs match the current implementation.

## Notes

- This is a foundation plan, not a feature plan.
- It is okay for AtelierCode to remain partial ACP for a while, as long as the partial implementation is deliberate and well-defended.
- The goal is to reduce ambiguity now so later ACP expansion is simpler, safer, and easier to review.
