# Gemini ACP Troubleshooting Log

## Scope
This document records the Gemini ACP troubleshooting work completed on March 14, 2026 for the hanging prompt issue in AtelierCode.

Primary symptom:
- The app launches Gemini successfully, accepts a prompt, and enters `Streaming reply`, but no assistant response ever arrives for a normal text prompt.

Current best-known state:
- Startup issues have been fixed.
- The app now uses the correct Gemini install path and can launch Gemini ACP successfully.
- Gemini can create chat state under `~/.gemini/.../chats`.
- The remaining issue is that normal ACP text prompts still hang after session setup, even though direct CLI prompts and ACP slash commands work.

## Current Repro
- App path: `/Users/jeremytondo/Library/Developer/Xcode/DerivedData/AtelierCode-dcuirsfgbtfsxhbyxjtjzsmhakaj/Build/Products/Debug/AtelierCode.app`
- Gemini binary under test: `/Users/jeremytondo/.local/share/mise/installs/gemini/0.33.1/bin/gemini`
- Repro behavior:
  1. App connects successfully.
  2. User submits a normal text prompt such as `Is this thing on?`
  3. Gemini emits `session/update` with `available_commands_update`.
  4. No `agent_message_chunk` arrives.
  5. No final `session/prompt` response arrives.

## Troubleshooting Steps Tried So Far

### 1. Disabled App Sandbox to unblock Gemini filesystem access
What was tried:
- Turned off App Sandbox for the app target so Gemini could write under `~/.gemini/.../chats` and execute normally as a local CLI subprocess.

Why:
- `session/new` was previously blocked because Gemini could not create its chat state under `~/.gemini`.

Result:
- This fixed the runtime permission problem.
- Gemini was able to write to `~/.gemini/tmp/.../chats`.
- This did not fix the hanging prompt behavior.

Conclusion:
- Sandbox restrictions were a real startup blocker, but they were not the cause of the remaining prompt hang.

### 2. Fixed the GUI launch PATH so Gemini could find `node`
What was tried:
- Added an explicit `PATH` for the spawned Gemini process in the app transport.

Why:
- The app previously failed with exit status `127`.
- The Gemini script uses `#!/usr/bin/env node`, and the GUI app environment did not expose the expected PATH entries.

Result:
- The app stopped failing with `status 127`.
- Gemini launched successfully under the app.
- The hanging prompt issue remained.

Conclusion:
- Missing `node` lookup was a real launch bug, but not the root cause of the stalled ACP turn.

### 3. Verified and preferred the real mise Gemini install
What was tried:
- Confirmed the intended Gemini binary is:

```text
/Users/jeremytondo/.local/share/mise/installs/gemini/0.33.1/bin/gemini
```

- Verified troubleshooting and probe runs against that binary instead of assuming `/opt/homebrew/bin/gemini`.

Why:
- There was concern that an older Homebrew Gemini install might still be getting picked up.

Result:
- The remaining ACP hang reproduces with the exact mise-managed Gemini binary.
- This rules out the stale Homebrew Gemini binary as the cause of the current issue.

Conclusion:
- Wrong Gemini executable selection was not the remaining problem.

### 4. Added `session/request_permission` handling
What was tried:
- Implemented support for Gemini ACP permission requests and selected the best available allow option when Gemini asks.

Why:
- One possible explanation was that Gemini was waiting on a permission round-trip the app was not answering.

Result:
- The app became capable of answering ACP permission requests correctly.
- In the hanging normal-text repro, Gemini does not emit a permission request before stalling.

Conclusion:
- Missing permission handling was worth fixing, but it is not what blocks the current hanging prompt.

### 5. Fixed the app working-directory fallback
What was tried:
- Changed the app’s default cwd handling to prefer `PWD` and otherwise fall back to the user’s home directory instead of `/`.

Why:
- Manual app launches were sometimes starting Gemini from `/`, which could affect Gemini project state and temp directories.

Result:
- Gemini no longer defaults to `/` for a normal app launch.
- This did not fix the hanging text prompt.

Conclusion:
- Cwd normalization was an improvement, but not the root cause of the stalled ACP prompt.

### 6. Audited the ACP client against the docs and made the protocol models more tolerant
What was tried:
- Compared the client flow against the ACP docs.
- Expanded the Swift ACP protocol layer to support:
  - `authMethods`
  - `agentCapabilities`
  - Gemini's `mcpCapabilities` field alias
  - string JSON-RPC IDs
  - tolerant decoding for richer `session/update` payloads
  - `available_commands_update`

Why:
- The app needed to be validated against the protocol spec rather than only against assumptions from ad hoc debugging.

Result:
- The protocol layer became more spec-tolerant.
- Focused ACP tests passed after these changes.
- The live Gemini text prompt still hung in the same place.

Conclusion:
- The app had a few schema/decoding gaps, but fixing them did not resolve the prompt hang.

### 7. Added ACP `authenticate` support
What was tried:
- Updated the client to send `authenticate` when Gemini advertises `oauth-personal`.

Why:
- Gemini exposes `authMethods` in `initialize`, and it was important to verify that the app was not skipping a required ACP handshake step.

Result:
- The app now follows `initialize -> authenticate -> session/new` when `oauth-personal` is available.
- Focused tests and builds passed after this change.
- The live normal-text ACP prompt still hangs even after explicit authentication.

Conclusion:
- Missing ACP authentication support was worth fixing, but it was not the root cause of the prompt hang in this environment.

### 8. Built a minimal ACP probe and tested Gemini outside the app
What was tried:
- Ran `tools/acp_probe.mjs` directly against the mise Gemini binary outside the app to separate app bugs from Gemini ACP behavior.

Why:
- The fastest way to isolate the failure was to reproduce it without SwiftUI, app lifecycle, or store code in the path.

Result:
- The probe reproduced the same issue:
  - `initialize` succeeds
  - `session/new` succeeds
  - `session/prompt` is accepted
  - `available_commands_update` arrives
  - the turn then stalls

Conclusion:
- The problem is not specific to the AtelierCode UI or store. It reproduces in a minimal ACP client.

### 9. Confirmed that direct non-ACP Gemini CLI prompts work
What was tried:
- Ran the Gemini CLI directly with:

```bash
/Users/jeremytondo/.local/share/mise/installs/gemini/0.33.1/bin/gemini -p "Is this thing on?"
```

Why:
- This checks whether Gemini itself can answer prompts at all outside ACP.

Result:
- The direct CLI prompt returned normally.

Conclusion:
- Gemini itself is functional.
- The failure appears specific to Gemini's ACP prompt path, not to Gemini's non-ACP CLI path.

### 10. Compared ACP slash commands versus normal ACP text prompts
What was tried:
- Sent `/memory list` through the ACP probe.
- Sent `Is this thing on?` through the ACP probe.

Why:
- This distinguishes local command handling from model-backed text prompt handling.

Result:
- `/memory list` completes successfully over ACP.
- A normal text prompt hangs over ACP.

Conclusion:
- ACP is not completely broken.
- The failing path is specifically the model-backed normal prompt turn, not the whole protocol.

### 11. Tested explicit ACP authentication methods
What was tried:
- Ran the ACP probe with explicit auth methods:
  - `oauth-personal`
  - `gemini-api-key`
  - `vertex-ai`

Why:
- This checks whether Gemini ACP is getting stuck because it needs a specific explicit auth mode.

Result:
- `oauth-personal`: authenticate succeeds, but the normal text prompt still hangs
- `gemini-api-key`: `session/new` fails with `Gemini API key is missing or not configured.`
- `vertex-ai`: the prompt returns a credentials error instead of hanging

Conclusion:
- Authentication mode changes Gemini's behavior, but they do not produce a clean successful ACP text prompt in this environment.

### 12. Tested outside the project directory
What was tried:
- Ran the same ACP text prompt from `/tmp` instead of the AtelierCode project directory.

Why:
- This checks whether the project context or project-specific Gemini state is involved.

Result:
- In `/tmp`, `session/new` failed immediately with `Gemini API key is missing or not configured.`
- In the AtelierCode project, `session/new` succeeds but the later normal text prompt hangs.

Conclusion:
- Gemini ACP behavior changes by cwd and/or project state.
- That is a strong sign that Gemini's own config/auth/session logic is involved.

### 13. Tried forcing a model through ACP
What was tried:
- Attempted to set an explicit session model through the probe.

Why:
- One hypothesis was that Gemini's ACP default model selection might be the failing branch.

Result:
- Gemini returned:

```text
"Method not found": unstable_setSessionModel
```

Conclusion:
- That path is not available in the current Gemini ACP surface, so it did not provide a usable workaround.

### 14. Inspected Gemini local state under `~/.gemini`
What was tried:
- Examined Gemini chat/session files and local project metadata under `~/.gemini`.

Why:
- Needed to determine whether Gemini was producing a reply internally but failing to return it over ACP.

Result:
- For hanging ACP runs, Gemini wrote the user prompt into the chat/session file but no assistant message was ever recorded.

Conclusion:
- Gemini is not merely failing to stream the response back to the client.
- It is failing to complete the assistant turn internally as well.

### 15. Checked the Xcode console warning shown during the UI hang
What was tried:
- Reviewed the warning visible in the Xcode UI console during the hang:
  - task name port warning
  - `ViewBridge to RemoteViewService Terminated`

Why:
- Needed to determine whether the UI warning was related to the Gemini prompt stall.

Result:
- This appears to be unrelated Xcode/UI debug noise, not ACP transport evidence.

Conclusion:
- No evidence so far suggests that the Xcode ViewBridge warning is causing the Gemini ACP hang.

## What Has Been Fixed But Did Not Resolve the Main Hang
- Disabled App Sandbox so Gemini can function as a local CLI subprocess
- Fixed Gemini launch PATH so `node` can be resolved
- Verified the correct mise Gemini binary is being tested
- Implemented ACP permission handling
- Improved cwd handling for GUI app launches
- Expanded ACP protocol decoding and spec alignment
- Implemented ACP `authenticate`

These were all worthwhile fixes, but none of them resolved the remaining hanging normal-text prompt.

## Strongest Evidence at This Point
- Direct Gemini CLI prompts work.
- ACP slash commands work.
- Minimal ACP client repros hang in the same way as the app.
- The hang reproduces with the intended mise Gemini binary.
- The hang persists even after adding ACP authentication support.
- Gemini does not record an assistant message locally for the stalled turn.

## Current Working Theory
The remaining issue is most likely inside Gemini CLI ACP behavior for normal text prompt turns in this environment, rather than in AtelierCode's launch, transport, or basic ACP session flow.

## Recommended Next Step
- Treat this as an upstream Gemini ACP repro unless new evidence appears.
- Use the existing `tools/acp_probe.mjs` script and the transcript above to prepare a minimal upstream bug report.
