# ash_a2a v26.9.16 — Working Backwards Press Release & FAQ

- **Status**: DRAFT CHARTER. Nothing below is shipped. This is a DMEDI
  *Define*-phase artifact, written Amazon-"working backwards"-style —
  the release is described as already-launched, then interrogated by an
  FAQ, specifically to pressure-test the scope *before* code exists.
- **Scope note**: this charters two of the smallest real, bounded,
  closeable gaps named by the [500M-agent-fleet requirements
  exploration](../../../research/) done this session (7-lens workflow,
  synthesized into `PROVISION-500M-AGENT-FLEET`). It does **not** claim
  v26.9.16 gets ash_a2a anywhere near 500M-agent scale — that synthesis's
  own "hardest unresolved problem" (Sybil-resistant identity issuance)
  is explicitly *not* solved here, only given a first real seam.
- Every capability named "already real" below is inspected and cited by
  file/line as of this repo's current `main` (`7cda483`); every
  capability named "new in this release" does not exist yet.

---

## Press Release (draft)

### ash_a2a v26.9.16 wires the router into live dispatch, formalizes the broker seam

*ash_a2a v26.9.16 closes two gaps this project has carried as explicitly
disclosed, open work since the router and authority modules were first
built: the tri-tier request router — built, tested, and adversarially
verified, but never actually called on a live message — is now the real
default entry point for semantic dispatch; and `AshA2A.Authority`'s
long-implicit dependency on an unnamed "authority broker" now has an
actual contract, `AshA2A.Authority.Broker`, with one reference
implementation.*

**The problem.** Every consequential action in ash_a2a already passes
through real authority-fencing and admission gates before it can be
actuated (`AshA2A.CommandBus`, `Planning.candidate_fence/1`,
`Semantic.Admission.fence/1`). But two real gaps sat upstream of those
gates, both self-disclosed in prior release work rather than hidden:

1. `AshA2A.Planning.RequestRouter` — the tri-modal facts/phrase/text
   router built to keep known-shape requests off the LLM path entirely
   — had 39 passing tests and zero callers. `git diff` against
   `AshA2A.Agent`/`AshA2A.Dispatcher` was empty. A caller could not
   actually reach the deterministic tier through the library's own
   real dispatch surface.
2. `AshA2A.Authority.new/3` accepts `source: :authority_broker` as its
   default value, and the module's own moduledoc says authority
   structs must be "construct[ed] only after a transport or host
   authority broker has admitted the caller" — but no
   `AshA2A.Authority.Broker` module, behaviour, or contract existed
   anywhere in the codebase. The concept was named in a comment and an
   atom, never given a shape a caller could implement against.

**The fix.** `AshA2A.Agent.dispatch_semantic/2`
(`lib/ash_a2a/agent.ex:228`) now checks for a `goal_facts` /
`:goal_facts` metadata key via `AshA2A.MetadataKey.fetch/2` before
falling through to the existing `dispatch_semantic_compile/2` LLM path,
routing facts- and phrase-shaped requests to
`RequestRouter.route/3` → `HddlDeterministicSynthesis.synthesize/3`
instead. A new `AshA2A.Authority.Broker` behaviour defines
`issue/3`, `revoke/2`, and `verify/2` callbacks; a reference
`AshA2A.Authority.Broker.InMemory` implementation ships alongside it —
explicitly documented as a single-node, non-Sybil-resistant, development
/test-fixture implementation, not a production identity system.

**Result.** A deterministic-tier request now measurably avoids the LLM
call path in the library's own real dispatch flow, not just in a
dedicated test harness — `AshA2A.Telemetry.RouterCounters` starts
carrying real, non-zero traffic instead of only test traffic. Any
caller wanting a real distributed or hardware-backed authority broker
now has an actual `Broker` behaviour to implement, instead of an
undefined atom to guess at.

> "The router and the broker concept both already existed as real,
> tested code. What they didn't have was a caller. This release doesn't
> invent new architecture — it connects two things that were sitting
> next to each other, disclosed as disconnected, for two release
> cycles."
> — an ash_a2a maintainer

> "We'd been holding off wiring our own onboarding flow to the
> deterministic router because there was nothing to call. Now there
> is. We're not touching the broker piece yet — we don't need
> distributed identity, we need our internal admin tool's existing
> auth check to hand ash_a2a a `Broker.verify/2` implementation
> instead of a bespoke shim."
> — a platform engineer at a mid-size internal-tools team (illustrative
> persona, not an attributed real customer)

**Getting started.** No API changes are required for existing callers —
`goal_facts`-free messages fall through to the unchanged LLM
compilation path exactly as before. Callers who want deterministic
routing set `goal_facts` metadata on their `A2A.Message` per
`RequestRouter`'s existing (already-real, already-tested) contract.
Callers who want a custom authority source implement the three
`AshA2A.Authority.Broker` callbacks and pass their module where
`InMemory` is used today.

---

## FAQ

### External / customer-facing

**Q: Does this mean ash_a2a can now run without an LLM at all?**
No. It means a request whose intent can be expressed as `goal_facts` or
a registered phrase template *can* avoid the LLM call, through the
library's real default dispatch path rather than only in tests. Free-text
requests with no caller-registered template still compile through
`AshA2A.Semantic.Compiler`, unchanged.

**Q: Does the new `Authority.Broker` give me distributed/Sybil-resistant
identity?**
No, explicitly not. `Broker.InMemory` is a single-node reference
implementation for development and testing. The 500M-fleet requirements
synthesis this charter draws its scope from names Sybil-resistant
issuance as its single hardest unresolved problem — real, published,
backed by a formal impossibility result (Douceur, 2002) — and this
release does not attempt to solve it. It gives you a real seam to plug a
real issuer into, nothing more.

**Q: Is this a breaking change?**
No. `dispatch_semantic/2`'s new branch only activates when a message
carries a `goal_facts` key; every existing caller's message shape is
unaffected and falls through to the pre-existing behavior.

### Internal / technical

**Q: Why these two items specifically, out of everything the 500M-fleet
synthesis named as a gap?**
Both were already fully-specified, already-tested, already-disclosed
gaps with a named concrete seam — not new design. `RequestRouter`
wiring is a bounded diff against one function
(`lib/ash_a2a/agent.ex:228-239`). `Authority.Broker` formalizes an atom
(`:authority_broker`) and a sentence in an existing moduledoc into a
real behaviour. Neither requires inventing new architecture or
resolving an open research problem, unlike sharding/Partisan clustering,
multi-node receipt atomicity, or Sybil-resistant identity — all
explicitly deferred, not silently dropped.

**Q: What existing real code does this build on, and what's genuinely
new?**
Already real, unmodified by this charter: `RequestRouter.detect_tier/1`
and `route/3` (tri-tier detection + routing, 39 tests),
`HddlDeterministicSynthesis.synthesize/3`, `GoalFacts.admit/2`
(including this session's `validate_request_id/1` fix),
`Planning.candidate_fence/1`, `Semantic.Admission.fence/1`,
`Telemetry.RouterCounters`. New in this release: the actual call site in
`dispatch_semantic/2`, a `dispatch_semantic_goal_facts/2` sibling
function, `AshA2A.Authority.Broker` (behaviour), and
`AshA2A.Authority.Broker.InMemory` (reference implementation).

**Q: What does v26.9.17+ need to pick up next, per the requirements
synthesis?**
In rough dependency order: (1) a federated/sharded topology using
Partisan + Horde + libcluster once any real multi-node deployment is
attempted (currently single-node only); (2) multi-node receipt-store
claim atomicity (the repo's own risk register already tracks this gap,
R-2); (3) a real, non-`InMemory` `Authority.Broker` implementation
against whatever identity system a real deployment actually has; (4) a
class-level kill switch (today only per-command fail-closed exists).
Sybil-resistant issuance itself has no proposed next step — it's named
as an open problem, not a backlog item with a known shape.

**Q: What's the verification bar before this charter becomes a real
PR?**
Matching this session's standing ladder: `mix format --check-formatted`,
`mix compile --warnings-as-errors`, `mix test` (full suite, unaffected
baseline preserved), `mix ash_a2a.verify_architecture`, a real
Chicago-style test asserting a `goal_facts` message never reaches the
LLM seam (the same paired positive/negative falsifier idiom already
used by `request_router_llm_never_called_test.exs`), and
`grep -rn "Mox\|:meck\|Mock("` returning zero new matches.

---

## See Also

- The 500M-agent-fleet requirements synthesis this charter's scope is
  drawn from (this session's own multi-lens workflow output — not yet
  committed as a standing repo document; ask to have it written to
  `docs/` if it should become one).
- `docs/jira/v26.9.15/README.md` — the release-charter format this
  document follows.
- `lib/ash_a2a/planning/request_router.ex` — the already-real,
  already-tested router this charter wires in.
- `lib/ash_a2a/authority.ex` — the already-real `Authority` struct whose
  moduledoc names the broker concept this charter formalizes.
