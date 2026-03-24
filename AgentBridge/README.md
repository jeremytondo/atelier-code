# AgentBridge

`AgentBridge/` contains the Bun-based helper executable that AtelierCode embeds into the macOS app bundle for local development and direct-download distribution.

## Bootstrap

1. Install Bun.
2. From `AgentBridge/`, run `bun install`.

## Local Commands

- `bun run typecheck`
- `bun run build`
- `bun run healthcheck`

## Output Location

- Local builds write the standalone executable to `AgentBridge/dist/ateliercode-agent-bridge`.
- Xcode app builds compile the helper into `$(DERIVED_FILE_DIR)/ateliercode-agent-bridge` and then copy it into `AtelierCode.app/Contents/MacOS/ateliercode-agent-bridge`.

## Packaging Assumptions

- AtelierCode is packaged as a direct-download macOS app, not a Mac App Store app.
- The app target is expected to run without App Sandbox restrictions before bridge launch work begins.
- Step 1 keeps the bridge limited to executable discovery, health reporting, and typed integration seams. Transport and provider session behavior land later.
