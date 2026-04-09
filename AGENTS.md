# AGENTS.md

This file guides AI coding agents working on the new `AppServer/` effort.
It complements [app-server-design.md](/Docs/app-server-design.md).

## Scope

Use this guidance for implementation work related to the new Bun + TypeScript App Server foundation.

## App Server Standards

- Use Bun and TypeScript with ECMAScript modules (`import` / `export`) only.
- Use Biome as the single formatter and linter for `AppServer/`.
- Use Bun's built-in test runner (`bun:test`) for App Server tests.
- Keep TypeScript strict. Do not use `any`; prefer `unknown`, explicit narrowing, and discriminated unions.
- Treat protocol schemas and typed contracts as the source of truth at ingress and egress.
- Use TypeBox as the canonical schema and runtime validation library for App Server protocol and persistence-adjacent schemas.
- Keep validation layers distinct: JSON-RPC envelope validation, method and event payload validation, and domain execution-rule validation.
- Prefer specific naming: use `Agent`, `App Server`, and `WebSocket Server`; avoid generic `runtime` terminology in `AppServer/`.
- Keep shared App Server code provider-neutral. Use `Codex` only in adapter-specific code under `src/agents/` or for literal provider and model values.
- Keep Bun-specific APIs at the edges. Domain logic must stay transport-agnostic and runtime-agnostic.
- Preserve App / Core / Features boundaries. Feature code must stay transport-blind, and only `src/app/` composes `core/` and feature modules.
- Within a feature, only `store.ts` should touch the database handle or Drizzle APIs directly. Services should depend on store functions or store-shaped capabilities.
- Preserve stable IDs and typed event models for `Thread`, `Turn`, `Item`, and approval flows.
- Model reasoning, plan, diff, and approval events as first-class typed variants even when an early phase only passes them through or stubs part of the behavior.
- Keep side effects out of domain logic. Prefer injected interfaces and small pure mapping functions.
- Prefer typed `Result` returns in domain services. Reserve `throw` for exceptional infrastructure failures, and keep domain rule failures distinct from schema and parse failures.
- Prefer deterministic tests with fakes and fixtures. Add or update tests for lifecycle sequencing, event ordering, approvals, and error handling when behavior changes.
- Treat generated or vendored Codex contract artifacts as read-only reference inputs. Update them through their generation or import workflow, not by hand.

## App Server Required Checks

Before considering App Server work complete:

- Run `biome format` or `biome check` as appropriate.
- Run `tsc --noEmit`.
- Run targeted `bun test` coverage for the touched area.
- Add or update `bun:test` coverage when changing contract, domain, adapter, or persistence behavior.
