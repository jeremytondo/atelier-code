# Step 1 Plan: Repo and Runtime Foundation

## Summary

Step 1 should establish the monorepo foundation for the macOS app and bundled bridge. The outcome should be: the Swift app still builds, a top-level `AgentBridge/` Bun project exists in the roadmap shape, Xcode builds and embeds a standalone bridge executable into the app bundle, and the app has a small runtime boundary for locating and later launching that bridge. This step stops before transport, thread/session behavior, and UI integration beyond binary discovery.

## Implementation Changes

- Update project assumptions first:
  - Treat AtelierCode as a direct-download macOS app rather than a Mac App Store app.
  - Keep the macOS App Sandbox decision as a project-level implementation note, not a pervasive architectural theme.
  - Plan to disable `ENABLE_APP_SANDBOX` in the app target before bridge launch work begins.
- Add a top-level `AgentBridge/` Bun package with:
  - `package.json` scripts for `build`, `typecheck`, and `healthcheck`
  - `tsconfig.json`
  - `src/index.ts`
  - `src/protocol/types.ts`
  - `src/protocol/version.ts`
  - `src/codex/codex-transport.ts`
  - `src/codex/codex-client.ts`
  - `src/codex/codex-event-mapper.ts`
  - `src/discovery/executable.ts`
  - `README.md` documenting bootstrap, local build commands, output location, and packaging assumptions
- Keep the bridge dependency-light in step 1. Prefer Bun built-ins unless a package is required for the compiled executable.
- Implement `src/index.ts` as a minimal CLI entrypoint with `--healthcheck` that emits machine-readable JSON and exits cleanly. Do not start WebSocket transport yet.
- Implement executable discovery now, but keep transport/client/event-mapper as typed scaffolding only. Their purpose in step 1 is to lock structure and ownership seams, not behavior.
- Add ignore rules for generated bridge artifacts only. Do not commit compiled bridge binaries.
- Update the app target build pipeline so Xcode embeds the bridge executable during app builds:
  - Build phase 1 compiles `AgentBridge/src/index.ts` with `bun build --compile` to `$(DERIVED_FILE_DIR)/ateliercode-agent-bridge`
  - Build phase 2 copies that executable into `$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/MacOS/ateliercode-agent-bridge`
  - The build fails fast with a clear message if `bun` is unavailable
- Add a small Swift utility that resolves the embedded bridge path from the app bundle. Do not spawn the bridge from UI code in this step.

## Docs To Update

- `Docs/architecture.md`
  - Add one short packaging/runtime note that the app is intended for direct download outside the App Store and is not App Sandbox constrained.
  - Keep existing "sandbox policy" references where they refer to agent execution behavior, since that is separate from macOS app sandboxing.
  - Do not introduce helper-tool sandbox inheritance guidance.
- `Docs/roadmap.md`
  - In step 1, keep the bridge-bundling requirement but add a short note that the app target should disable App Sandbox before bridge-launch work begins.
  - Keep the bridge responsibility narrow: process lifecycle, protocol translation, approval relay, executable discovery, and health reporting.

## Interfaces and Types

- In `AgentBridge/src/protocol/version.ts`, define one exported protocol version constant for future app/bridge negotiation.
- In `AgentBridge/src/protocol/types.ts`, define only the foundation types needed now:
  - `BridgeHealthReport`
  - `ProviderHealth`
  - `ExecutableDiscoveryResult`
  - `BridgeStartupError`
- Do not define the full command/event protocol unions yet; that belongs to roadmap step 3.
- Add one Swift-side boundary type such as `BridgeExecutableLocator` that returns the embedded bridge URL or a structured missing-binary error.

## Test Plan

- `bun run typecheck` succeeds in `AgentBridge/`.
- `bun run build` produces a standalone executable on the current host architecture.
- Running the built executable with `--healthcheck` returns valid JSON including protocol version and Codex discovery status.
- An Xcode app build places the helper at `AtelierCode.app/Contents/MacOS/ateliercode-agent-bridge`.
- A Swift unit test verifies the app-side locator resolves the embedded bridge path from the bundle.
- Negative checks:
  - missing `codex` produces degraded health output, not a crash
  - missing `bun` causes an actionable build failure
  - a missing embedded helper is surfaced as a structured locator error
  - App Sandbox is disabled in the target configuration used for local development

## Assumptions and Defaults

- The app is distributed directly and not through the Mac App Store.
- The app target is expected to run without App Sandbox restrictions.
- Optimize step 1 for local development on the current host architecture. Universal and polished release packaging are deferred.
- The bridge's responsibility in step 1 is limited to executable discovery, health reporting, typed module boundaries, and build/package integration.
- WebSocket transport, JSONL protocol mapping, app state architecture, and UI flows remain out of scope for this foundation pass.
- Codex remains the only provider considered in this foundation pass.
