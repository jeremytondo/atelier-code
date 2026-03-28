The checked-in artifacts under this directory are generated from the locally pinned `codex-cli 0.114.0` app-server contract.

Regenerate them from `AgentBridge/` with:

`bun run generate:codex-contract`

The JSON Schema snapshot is the canonical raw Codex contract for the bridge. The generated TypeScript bindings are derived artifacts that the raw Codex layer imports for exact request and response shapes.
