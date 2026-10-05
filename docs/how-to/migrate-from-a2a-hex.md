# Migrate from the a2a hex package

For apps that consume the old `ash_a2a` (hex 26.9.x line) together with the
standalone `{:a2a, "~> 0.2"}` hex package (the a2a-elixir 0.3.0 lineage).
This is the xaas / ggen_igniter consumer class:

- xaas pins `ash_a2a` via git ref `3325032d9dea201e6deb82ef242c534aacb3b420`
  plus `{:a2a, "~> 0.2"}` (`/Users/sac/xaas/mix.exs:103-111`).
- ggen_igniter pins `{:ash_a2a, "~> 26.9"}` (`/Users/sac/ggen_igniter/mix.exs:271`)
  and its installer-assertion test expects the installer to add `{:a2a, "~> 0.2"}`
  (`/Users/sac/ggen_igniter/test/ggen_igniter_semantic_a2a_manufacture_test.exs:66`).

The target is ash_a2a v26.10.3 (`/Users/sac/ash_a2a/mix.exs:25`), which
vendors the whole protocol surface as `AshA2A.Protocol.*` under
`lib/ash_a2a/protocol/` and no longer needs the `:a2a` package.

## Contents

1. Remove the `:a2a` dependency and port `A2A.*` calls
2. Wire-shape deltas for code asserting raw JSON
3. Installer flow
4. DSL compatibility
5. Sibling-repo follow-ups
6. Rollback
7. Verification checklist
8. See Also

## 1. Remove the `:a2a` dependency and port `A2A.*` calls

In your `mix.exs`, delete the `{:a2a, "~> 0.2"}` line. Then port every
direct `A2A.*` reference. Each row below is verified against the old
package's module on disk (a2a hex 0.3.0, `deps/a2a/lib/a2a/`) and the
new module in this repo:

| Old (`a2a` 0.3.0) | New (ash_a2a 26.10.3) | Grounding (new side) |
|-------------------|-----------------------|----------------------|
| `A2A.Message.new_user/1` | `Protocol.Message.new_user/1` | `protocol/message.ex:37` |
| `A2A.Message.new_agent/1` | `Protocol.Message.new_agent/1` | `protocol/message.ex:53` |
| `A2A.Part.Text` | `Protocol.Part.Text` | `protocol/part.ex:15` |
| `A2A.Part.File` | `Protocol.Part.File` | `protocol/part.ex:36` |
| `A2A.Part.Data` | `Protocol.Part.Data` | `protocol/part.ex:58` |
| `A2A.Plug` | `Protocol.Plug` | `protocol/plug.ex:2` |
| `A2A.Plug.Auth` | `Protocol.Plug.Auth` | `protocol/plug/auth.ex:2` |
| `A2A.AgentSupervisor` | `Protocol.AgentSupervisor` | `protocol/agent_supervisor.ex:1` |
| `A2A.Agent` | `Protocol.Agent` | `protocol/agent.ex:1` |

Grounding paths are relative to `lib/ash_a2a/` and cite the `defmodule`/
`def` line for each new module/function.

This is a namespace rename: the structs, field names, and function names are
unchanged (`new_user/1` and `new_agent/1` keep the same `is_binary`/`is_list`
clauses in both packages -- compare `deps/a2a/lib/a2a/message.ex:35-55` with
`lib/ash_a2a/protocol/message.ex:37-57`). Most ports are a single
find-and-replace of the `A2A.` prefix with `AshA2A.Protocol.`. Before
deleting the dep, sweep your tree:

```console
grep -rn --include='*.ex' --include='*.exs' 'A2A\.' lib test config
```

Grep your tree for `alias A2A` too -- aliases keep compiling after the dep
is gone only until the next clean; port them in the same pass.

`A2A.Transport.Plug`? No — there is no such module in the old package; the
in-repo `AshA2A.A2ATransport.Plug` (`lib/ash_a2a/a2a_transport/plug.ex`) is
ash_a2a-owned transport with push notifications, SSE fallback, extended
card, and ownership scoping. It is an upgrade path, not a rename target.

## 2. Wire-shape deltas for code asserting raw JSON

Only relevant if you assert on the raw JSON-RPC frames in tests or a client
that decodes responses itself. Four deltas, all v0.3 → v1.0:

- **`kind` discriminator dropped in favor of flat frames.** v0.3
  discriminated the event union with a `"kind"` field
  (`lib/ash_a2a/protocol/json.ex:789`); v1.0 SSE frames are flat
  `StreamResponse` wrappers (`{"task": ...}`, `{"statusUpdate": ...}`,
  `{"artifactUpdate": ...}`
  (`docs/reference/a2a-spec-version-mapping.md`, "v1.0 notes"). Decode-side
  the codec still accepts the v0.3 `"kind"` discriminator as a fallback
  (`lib/ash_a2a/protocol/json.ex:460-464`), so a not-yet-migrated peer still
  decodes.
  `A2A.Event.StatusUpdate` / `A2A.Event.ArtifactUpdate` structs still exist
  on the new side as `AshA2A.Protocol.Event.StatusUpdate` /
  `AshA2A.Protocol.Event.ArtifactUpdate` (compare
  `deps/a2a/lib/a2a/event.ex:14,51` with `lib/ash_a2a/protocol/event.ex`).
- **`final` boolean dropped.** v0.3 carried finality in `"final": true`
  (`lib/ash_a2a/protocol/json.ex:18`); v1.0 never emits it — finality is
  carried by a terminal status state (`completed`, `canceled`, `failed`,
  `rejected`; `lib/ash_a2a/protocol/task.ex:31`,
  `lib/ash_a2a/protocol/event.ex:22`). The decode path reads it from legacy
  frames only (`lib/ash_a2a/protocol/json.ex:581`).
- **Error payloads are `google.rpc.ErrorInfo` objects.** Every A2A-specific
  error (`-32001..-32009` plus `-32602`) serializes its `data` as a
  `google.rpc.ErrorInfo` with domain `a2a-protocol.org` (`-32001`
  TASK_NOT_FOUND, `-32002` TASK_NOT_CANCELABLE, `-32003`
  PUSH_NOTIFICATION_NOT_SUPPORTED, `-32004` UNSUPPORTED_OPERATION,
  `-32602` INVALID_PARAMS); registry in
  `lib/ash_a2a/protocol/jsonrpc/error.ex:8` and mapping in
  `lib/ash_a2a/protocol/client.ex:772-810`.
- **Card `url` moved inside `supportedInterfaces[]`.** The old
  `A2A.AgentCard` had a top-level `url` plus top-level `protocolVersion`
  (a2a 0.3.0, `deps/a2a/lib/a2a/agent_card.ex:59-63`). The v1.0 card keeps
  `url` but carries `protocolVersion` only inside `supportedInterfaces[]`
  (`lib/ash_a2a/protocol/card_signing.ex:32-34`), with the interface URL
  seeded as `supportedInterfaces[0].url`
  (`lib/ash_a2a/protocol/card_signing.ex:84`), and the struct gains
  `supported_interfaces` (`lib/ash_a2a/protocol/agent_card.ex:80,105`).
  `protocolVersion` is `1.0` (`AshA2A.Protocol.Version`, `@protocol_version
  "1.0"`, `lib/ash_a2a/protocol/version.ex:12`), with `0.3` still listed in
  `supported` (`version.ex:16`). `0.3` peers: an empty or missing
  `A2A-Version` header is interpreted as `0.3` (`version.ex:7,49-50`).

If your client decodes via `AshA2A.Protocol.JSON` (or the old `A2A.JSON`),
none of the struct-level code changes -- only raw-frame assertions do.

## 3. Installer flow

`mix ash_a2a.install`
(`lib/mix/tasks/ash_a2a.install.ex:152-153`, schema
`[target: :string, type: :string, skill: :keep, with_pplan: :boolean]`)
generates an `a2a do` block and appends skills via the
`skill :name, Resource, :action` grammar. It no longer adds an `:a2a`
dependency to the target project. The only optional dep is the plan
provider, added when you pass `--with-pplan`
(`ash_a2a.install.ex:40-42,162,174`):

```console
mix ash_a2a.install --with-pplan   # optional plan-provider dep
```

## 4. DSL compatibility

The `extensions: [AshA2A]` grammar is unchanged: three sections,
`def sections, do: [@a2a, @authority, @hooks]`
(`lib/ash_a2a/dsl.ex:221`). Existing `a2a do skill ... end`,
`authority` and `hooks` blocks compile unchanged. New skill-entity fields,
all defaulted, so they are additive only:

- `argument_mapping` — wire name to action-argument-name map
  (`dsl.ex:69`; map of wire string name to atom action arg name; empty =
  pass through unchanged).
- `get?` — marks a read skill as a single-record get, mirroring
  ash_json_api's `get?` semantic (`dsl.ex:78`).
- `lease_required?` — governance boundary declaration; dispatch under this
  skill requires a valid authority lease (`dsl.ex:86`).

All three default to no-op (`%{}`, `false`, `false`), so a pre-26.10
resource compiles without edits; adopt them per skill as needed.

## 5. Sibling-repo follow-ups

- ggen_igniter's installer-assertion test
  `test/ggen_igniter_semantic_a2a_manufacture_test.exs:66-68` asserts the
  generated mix.exs contains `{:a2a, "~> 0.2"}` — this assertion flips to
  asserting the dep is absent once the sibling pins the new ash_a2a. Same
  file's dispatch test (`test/ggen_igniter_semantic_a2a_dispatch_test.exs:44-56`)
  still aliases `A2A.Plug.Auth` / `A2A.Plug` / `%A2A.SecurityScheme.HTTPAuth{}`.
- ggen_igniter's `a2a_manufacture` template: the same installer-assertion
  site (`..._manufacture_test.exs:66`) is the known place to update when
  the template stops adding `:a2a`.

These are sibling-repo edits, tracked there, not here.

## 6. Rollback

The old pins still resolve: `v26.9.x` tags exist in this repo
(`git tag`: `v26.9.14` ... `v26.9.30`) and the a2a hex 0.3.0 package is
unchanged, so reverting to the old `mix.exs` pins (xaas's git ref
`3325032...` or hex `~> 26.9` with `{:a2a, "~> 0.2"}`) restores the
pre-migration state. Mix resolves both pins against the tags/registry, so
rollback is a pin revert plus `mix deps.get`.

## 7. Verification checklist

After porting, run from your app root:

```console
grep -rn --include='*.ex' --include='*.exs' 'A2A\.' lib test config
grep -rn --include='*.ex' --include='*.exs' '{:a2a' mix.exs
```

Zero matches on both is the pass gate (the first must be zero after the
port; the second must be zero after the dep removal, because
`AshA2A.Protocol.*` is the only protocol surface). Then `mix deps.unlock
a2a`, `mix deps.get`, and run your suite.

## See Also

`docs/reference/a2a-spec-version-mapping.md` ·
`docs/how-to/migrate-legacy-to-strict.md` ·
`docs/reference/a2a-endpoint-contract.md` · `docs/reference/mix-tasks.md`
