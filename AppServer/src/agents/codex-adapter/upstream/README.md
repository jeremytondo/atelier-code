The checked-in artifacts under this directory are generated from the locally pinned `codex-cli 0.114.0` app-server contract.

Regenerate them from `AppServer/` with:

`bun run generate:codex-contract`

The JSON Schema snapshot is the canonical raw Codex contract reference for the Codex adapter seam.
The generated TypeScript bindings are derived reference artifacts only. Hand-written adapter code should import the local protocol surface in `src/agents/codex-adapter/protocol.ts` rather than importing files from this vendored tree directly.
