# Architecture

This explains how ash_a2a is actually put together today, not how it is
eventually meant to work. There are two layers in this codebase, and they are
at very different levels of maturity: a projection layer that is real, tested,
and wired into every dispatch, and an admission/receipt layer that is real
and tested but sits beside the default path rather than inside it.

## Layer 1: capability projection (the default path)

`AshA2A.Info.agent_card/2` and `AshA2A.CapabilityIndex.Compiler` turn a
resource or domain's `AshA2A` DSL entities into a compiled, persisted
capability index, and `AshA2A.CapabilityIndex.AgentCardBuilder` projects that
index into an `A2A.AgentCard` (name, skills). `AshA2A.Agent.__using__/1`
reads this same compiled card at macro-expansion time via
`__card_opts__/2`, so the `A2A.Agent` GenServer generated for a resource can
never advertise a skill the compiler didn't actually see.

When a message arrives, `AshA2A.Agent.__dispatch__/3` resolves the skill name,
pulls `history` off the `A2A.Agent.context()` and `auth_identity` out of
`context.metadata["a2a.auth"]` (populated only by `A2A.Plug.Auth` after real
credential verification -- never from caller-controlled `A2A.Message.metadata`),
and calls `AshA2A.Dispatcher.dispatch/5` directly. `Dispatcher` resolves
actor/tenant through `AshA2A.ContextResolver.from_a2a_message/4` and invokes
the real Ash action with the non-bang `Ash.Changeset.for_create/3` /
`Ash.Query.for_read/3` / `Ash.ActionInput.for_action/3` APIs. This chain --
projection, resolution, dispatch -- is what every `AshA2A.Agent` call goes
through today, and it is the only thing a plain `MyApp.EchoAgent` deployment
exercises.

Alongside it, `AshA2A.LLMProfiles` gives resources a role-based way to
resolve which LLM provider/model backs a given capability. It is real and
wired in wherever a resource author calls it, tested against a live call,
and orthogonal to admission -- it answers "which provider," not "was this
authorized."

## Layer 2: admission and receipts (real, but opt-in)

`AshA2A.Command`, `AshA2A.Authority`, `AshA2A.Identity`, and
`AshA2A.CommandBus.run/4` form a second, parallel route to the same
dispatcher. `CommandBus.run/4` looks up the skill via `AshA2A.Info.skill/2`,
classifies the underlying Ash action as `:observe` (read) or `:change`
(everything else), and for `:change` actions requires an `AshA2A.Authority`
struct that names the same principal and capability the command claims
(`Authority.admits?/2`) -- a command with no authority, or authority for a
different principal or capability, is refused before dispatch ever runs.
Once admitted, it asks a pluggable `AshA2A.ReceiptStore` to `claim/2` the
command: a fresh claim proceeds to real dispatch and commits an
`AshA2A.Receipt`; a claim that has already been executed is replayed by
returning the stored receipt instead of re-executing. This is real
idempotency and real evidence, not a sketch -- it is exercised by
`AshA2A.Reactor.ExecuteCommand` (a `Reactor.Step` that calls `CommandBus.run/4`
and nothing else) and by the Oban/FLAME adapters described below.

What it is not, today, is mandatory. `AshA2A.Agent.__dispatch__/3` calls
`AshA2A.Dispatcher.dispatch/5` directly -- it does not construct an
`AshA2A.Command`, does not consult `AshA2A.Authority`, and never touches a
`ReceiptStore`. A plain `A2A.Message` sent to a generated agent is authorized
only by whatever `A2A.Plug.Auth` verified at the transport boundary and
whatever the Ash action's own policies enforce; it produces no receipt and
is not deduplicated on replay.

## Why CommandBus isn't in the default dispatch path

This is a deliberate, named gap, not an oversight. `CommandBus.run/4` needs
an `AshA2A.Command` (with a `principal_id`, a `capability_id`, and often an
`AshA2A.Authority`) and a `ReceiptStore` (the in-memory default has no
cross-node or restart durability). Building an `AshA2A.Command` from a bare
`A2A.Message` requires deciding, for every resource author, what "the same
command" means for replay (the `fingerprint`), what identity issues
`Authority` for an ordinary transport call with no explicit authority broker
present, and what a `:read` action's "receipt" is worth when it is
deliberately treated as `:observe` and never admitted at all. None of those
decisions has one correct default across every resource this library
serves, so wiring `CommandBus` into `__dispatch__/3` today would mean
picking authority-issuance and receipt-durability defaults most callers
didn't ask for, on every call. Leaving it opt-in keeps the zero-config path
(a resource author who just wants a working `A2A.Agent`) unchanged, while
giving Reactor/Oban/FLAME callers -- who already have a durable job or
workflow identity to hang a command on -- a real receipted route to use
deliberately.

## The ecosystem adapters are seams, not integrations

`AshA2A.Delivery.Oban`, `AshA2A.Topology.Group`, `AshA2A.Topology.Presence`,
`AshA2A.Durability.DurableServer`, and `AshA2A.Execution.FLAME` each guard
themselves with `Code.ensure_loaded?/1` and degrade to an `:unsupported`
error or a no-op when their provider isn't present. None of `oban`, `flame`,
a `Group` topology module, `Phoenix.Presence`, or a `DurableServer` provider
is a dependency of this project's `mix.exs` today. These modules exist so a
host that *does* depend on one of those libraries gets a receipted,
non-authoritative bridge to it (queue insertion records delivery only;
FLAME placement never gains independent authority; a `Group` registration
returns an `AshA2A.RuntimeReceipt`, never Ash domain truth) -- but inside
this repository, every one is exercised only by tests that stub the
provider or assert the `:unsupported` degradation path. They are real code
with no real collaborator to call yet.

`AshA2A.TaskLifecycle` is the same shape for a sixth dependency:
`AshStateMachine` is not installed here, so `possible_next_states/2` always
returns `{:error, {:unsupported, :ash_state_machine}}` in this repo -- the
module declares the canonical A2A state vocabulary for interoperability but
defers transition legality to the host's own `AshStateMachine` when present.

## What would need to change

For the admission/receipt layer to become the enforced default,
`AshA2A.Agent.__dispatch__/3` would need to build an `AshA2A.Command` from
the inbound message (a default fingerprinting scheme, a default authority
source for the common case), pick a `ReceiptStore` with real durability as
the shipped default instead of the in-memory one, and call
`AshA2A.CommandBus.run/4` in place of its current direct
`AshA2A.Dispatcher.dispatch/5` call. That is the single largest remaining
gap between what exists today and a system that enforces receipted
admission on every call, rather than only on calls explicitly routed
through `CommandBus`, `Reactor.ExecuteCommand`, `Delivery.Oban`, or
`Execution.FLAME`. Each ecosystem adapter becoming a real integration is a
smaller, separate change: add the real dependency, and the existing
`Code.ensure_loaded?` seam starts resolving to the real provider with no
change to the adapter's contract.
