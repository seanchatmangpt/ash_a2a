# Engineering Standards Root Binding

> Generated adoption header. Shared engineering semantics are rooted at `seanchatmangpt/engineering-standards@5a3bb6446aeaee2255a7523d4d8cebf6042960c3`.

- Repository subject: `seanchatmangpt/ash_a2a@43ac10928ab0fc8820c2db8a790c015b207605c6`
- Ecosystem role: SA2A transport and runtime profile
- Adoption manifest: `engineering-standards.json`
- Project profile: `semantic/engineering-standards-profile.ttl`

The local constitution below remains authoritative for repository-specific mechanics. It may narrow the root but may not redefine shared WorkOrder identity, authority, receipt/replay, generated-artifact sovereignty, or evidence standing. Ticket, agent, capability, plan, proof, and generated output do not acquire ambient DO authority.

---

Read repository-specific README, architecture, manifests, and verifier entrypoints before changing implementation.

---

# Contributor and Agent Guide

AshA2A is an Ash extension that serves public Ash actions as A2A protocol skills. Ash is
the source of truth for capabilities; this library adds the A2A projection, transports,
authority checks and the agent card.

## Repository layout

| Path | Contents |
|---|---|
| `lib/ash_a2a.ex`, `lib/ash_a2a/dsl.ex` | Resource/domain extension entrypoint and the `a2a` DSL |
| `lib/ash_a2a/domain.ex` | Domain extension: `agent`, `transport`, `security` sections |
| `lib/ash_a2a/info.ex`, `lib/ash_a2a/domain/info.ex` | Public introspection of DSL state |
| `lib/ash_a2a/transformers/`, `lib/ash_a2a/domain/transformers/` | Compile-time persistence of DSL state |
| `lib/ash_a2a/verifiers/`, `lib/ash_a2a/domain/verifiers/`, `lib/ash_a2a/verify.ex` | Compile-time refusals and warnings |
| `lib/ash_a2a/capability_index/` | Derives skills from `Ash.Resource.Info.public_actions/1` |
| `lib/ash_a2a/protocol/` | Wire types, agent card, client, auth plugs |
| `lib/ash_a2a/transport/`, `lib/ash_a2a/a2a_transport/` | HTTP+JSON, JSON-RPC, gRPC and live (`/message:live`) transports |
| `lib/ash_a2a/authority/` | Authority grants and brokers |
| `lib/mix/tasks/` | Mix tasks, including `ash_a2a.install` |
| `docs/` | How-to guides and reference (`docs/how-to`, `docs/reference`) |
| `test/` | Test suite; `config/test.exs` configures the test database partitions |

## Running tests

Tests are split into tiers by the aliases in `mix.exs`:

| Command | Runs |
|---|---|
| `mix test` | Default tier: everything except tests tagged `serial` |
| `mix test.serial` | Only tests tagged `serial` |
| `mix test.all` | Default plus serial; excludes `graphlaw`, `graphlaw_engine` and `sibling_repos` tags (what CI runs) |
| `mix test.serial.shard` / `mix test.serial.solo` | Partitioned and solo serial subsets (see the comments in `mix.exs`) |
| `mix test.live` | External-API tests with `ASH_A2A_LIVE_LLM=1` |
| `mix check` | Quality gate via `.check.exs`; `CHECK_STAGES=compile,test mix check` scopes it |

Tests use real collaborators (real plugs, processes and data layers). Do not introduce
mocking libraries; a hand-written module implementing the real behaviour is fine.

## Public vs internal modules

- Public: modules with a `@moduledoc` describing user-facing behaviour, for example
  `AshA2A`, `AshA2A.Info`, `AshA2A.Domain`, `AshA2A.Domain.Info`, `AshA2A.Protocol.*`
  and the transport plugs.
- Internal: modules marked `@moduledoc false`, and functions marked `@doc false`.
  Do not call them from outside the library.
- Read DSL state only through `AshA2A.Info` and `AshA2A.Domain.Info`. Persisted keys
  (`ash_a2a_*`) are an implementation detail of those modules and the extension's own
  transformers and verifiers. Add an Info function instead of reading a key elsewhere.

## Conventions

- Verifiers and transformers read DSL state with `Spark.Dsl.Transformer.get_entities/2`
  and `get_option/4`; use `get_persisted` only for values this extension persisted.
- Compile-time refusals raise `Spark.Error.DslError` with a `path` and `location`.
- Run `mix format` before committing; keep `@moduledoc` text focused on what a user
  can do with the module.
- Never hand-edit generated files; change the source and regenerate.
- Security-relevant changes (auth, authority, consequence handling) need a test that
  drives the real transport and asserts the refusal.
