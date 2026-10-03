# HANDOFF

Remote-agent handoff for the v26.9.28 consequence-kernel milestone in `ash_a2a`. Subject:
`ash_a2a` main at `e2e02ebd9d674a70f1d1cdc0e08fc22a07e4b108` (section 1.1 truth table pinned to it; sections 1.2 onward were observed at `9cda21c9` and are not re-verified).
This document integrates 8 composition-adapter designs (A1-A8), 4 court designs (C2,
CHI-CLOSURE, CHI-CONSERVE, CHI-FAULT) and fleet-repo verification. Labels: OBSERVED = read
or run; DERIVED = design inference; UNVERIFIED = not run or not read.
Last Updated: 2026-09-28 (section 1.1 refreshed at e2e02eb).

## Contents

1. Current-state truth table
2. Composition diagram and authority ceilings
3. Pinned seams
4. Reproduce CI locally
5. Per-court specs
6. Ordered task list
7. Open questions for the operator
8. See Also

## 1. Current-state truth table

### 1.1 ash_a2a at e2e02ebd9d674a70f1d1cdc0e08fc22a07e4b108 versus what the RFCs assume

Pinned subject: `main` at `e2e02ebd9d674a70f1d1cdc0e08fc22a07e4b108` (OBSERVED via
`git rev-parse HEAD`, 2026-09-28). Module presence was read from `lib/` at that tree; wiring
was read by grepping `lib/` for references outside each module's own directory. Uncommitted
changes from concurrent lanes are not part of this pin.

| Assumed by RFC-004/005/006 | State at e2e02eb | Status |
|---|---|---|
| ConsequenceKernel | `lib/ash_a2a/consequence_kernel.ex` plus 22 modules under `consequence_kernel/` (claim, exact_subject, effect_identity, request_identity, authority_revalidation, unknown_outcome, receipt, receipt_chain, wire, standing, refusal registry); no caller outside `effect_instance.ex` | PRESENT, UNWIRED |
| PreparedEffect | `lib/ash_a2a/prepared_effect.ex` and `c2/prepared_effect.ex` (two modules) | PRESENT, UNWIRED |
| PreparedEffectStore | `consequence_kernel/prepared_effect_store.ex` + memory, authenticated_record, recovery, transition, refusal; HMAC key custody `key_custody/hmac_sha256.ex`; no caller from CommandBus | PRESENT, UNWIRED |
| EffectInstance, EffectClaim | `effect_instance.ex`; `consequence_kernel/claim.ex` | PRESENT, UNWIRED |
| Identity.Canonical (JCS + sha256) | `identity/canonical.ex` + encodable, normalizer, migration; used only by the kernel island and `prepared_effect.ex` | PRESENT, UNWIRED |
| Legacy digests | `command.ex` and `actuation.ex` still use `:erlang.term_to_binary([:deterministic])` | PRESENT (legacy) |
| c2/ authority pipeline | 25 modules: authority_request, authority_client, authority_service, authority_response, actuation_pipeline, actuator, certificate, certificate_verifier, crypto_verifier, signer_set, claim_store(_ets), effector(_registry), fencing_token, budget_ledger, resource_envelope, policy_epoch, revocation_epoch; no reference from outside `c2/` | PRESENT, UNWIRED |
| Certificate signature verification | `CertificateVerifier.verify/3` checks `CryptoVerifier.supported?/1` on each signature algorithm, not `CryptoVerifier.verify/4`; `crypto_verifier.ex` lists `:eddsa, :ml_dsa, :slh_dsa` and implements EdDSA only | PARTIAL |
| SecurityProfile | no defmodule in lib/ | ABSENT |
| ActuationCertificate as separate module, separate authority OS process/release | not present (X1-X4 in-repo islands only) | ABSENT |
| CallbackRegistry, Egress.EndpointPolicy | `callback_registry.ex`, `egress/endpoint_policy.ex` exist in the working tree (uncommitted at time of writing) | UNVERIFIED at pin |
| Production dispatch path | `Agent -> CommandBus.run -> BrceAnchor.put -> Dispatcher.dispatch` (command_bus.ex:1430-1446); kernel not on the path | ALIVE (legacy path) |
| Strict actuation dedup default | `CommandBus.actuation_dedup_mode/1` defaults `:strict`; court `test/ash_a2a/docs_truth_test.exs` | ALIVE |
| Pre-DO authority revalidation and kill-switch recheck | `CommandBus.pre_do_gate/3` | ALIVE |
| Receipt outbox seal (HMAC-SHA256), fsync, anchor | `receipt_outbox.ex` | ALIVE |
| Semantic.Allocator.Budget, Semantic.Bounds.delegate/2 | exist, in-VM Elixir | PRESENT |
| Semantic.Refusal, 18 classes, provider hook | exists (refusal.ex) | PRESENT |
| Chicago courts, AbstractCode, Conformance, Mutation | exist | PRESENT |
| GraphLaw in-VM host (wasmex NIF) | mix.exs, application.ex | PRESENT |
| Toolchain | `.tool-versions`: elixir 1.20.4-otp-29, erlang 29.1.1; `scripts/toolchain.sh` | ALIVE |
| Pinned OTP can do ML-DSA | pinned OTP is now 29.1.1; `:crypto.supports(:public_keys)` not run for this document | UNVERIFIED |

Still unwired (the C1/C2 gap): no production caller of `ConsequenceKernel.execute/2`, of any
`C2.*` module, of the prepared store, or of `Identity.Canonical` on the live path; identity on
the live path is BEAM term serialization; certificate signatures are not cryptographically
verified in `CertificateVerifier`; no separate authority or actuator process exists.
Lane-level status: `docs/jira/v26.9.28-kernel/_LANES_V3.md`, which predates commits
`5c60fb3`, `0704588`, `cfad84d`, `a9a4264` and should be re-tallied by the coordinator.

### 1.2 Operator and premise claims checked (observed at 9cda21c, not re-verified)

| Claim | Verdict | Evidence |
|---|---|---|
| ash_a2a main is 9cda21c | TRUE | rev-parse and origin/main equal |
| RFC-006 s20 is an OCEL vocabulary | FALSE | s20 is Replay; no OCEL vocabulary exists |
| GraphLaw PR#10 gives a self-contained WASI surface | TRUE | merged 2026-09-28 |
| GraphLaw is invoked by job file | PARTIAL | JSON pointer ABI gl_alloc/gl_free/gl_call |
| ash_a2a vendored GraphLaw equals PR#10 module | FALSE | v26.7.5 bindgen vs WASI, different ABI |
| ash_r2rml authority is NONE | PARTIAL | enforced in code; FrontierEvidence ceiling is CONSTRUCT |
| ash_r2rml already references SA2A | FALSE | zero hits |
| ash_r2rml exact-source identity | PARTIAL | bytes exact, DB state not covered |
| bcinr cascade conserves (sum leaves = 1) | FALSE | truncation residual, fallback exception |
| bcinr allocate is N=8,K=4,Q=4 | TRUE | fixed shape |
| gymact cmca.py is a flat split | FALSE | weighted 50/50 mix over Pareto frontier |
| gymact brce.py is a cryptographic seal | FALSE | in-process object() sentinel |
| gymact has reusable CMCA vectors | FALSE | 4 inline unit cases only |
| beam4pm has no DO edge | FALSE | Actuation.run/2 does Port + File.write, own receipt |
| beam4pm predecessor chain authenticated | FALSE | plain sha256, caller chain_id |
| beam4pm local checkout current | FALSE | local 26.9.24, remote has PR102/PR103 |
| xaas PR#96 depends on ash_a2a 26.9.28 | PARTIAL | release-gate only; mix.exs still ~> 26.9.12 |
| xaas has a second BRCE | TRUE | Xaas.Actuation.Kernel + CASTLE PREPARE/OUTCOME |
| ggen_igniter has priv/ggen/kernel | FALSE | new pack must be authored |
| Pinned OTP can do ML-DSA | FALSE | .tool-versions erlang 27.2.4; mldsa in OTP 28.3+ |
| Ferroplan subprocess has no timeout | FALSE | in-process max_wall_ms=10000; no OS-level kill |
| hddl_cli pin matches local ferroplan | FALSE | pin =0.28.0 e90928d7; local 0.29.0 |
| No open ash_a2a PRs | UNVERIFIED | empty gh output, exit code unchecked |
| Hex 26.9.28 of ggen_igniter / ash_r2rml exists | UNVERIFIED | release blocked upstream |

### 1.3 Fleet repo facts to bind

- ash_r2rml: e03adfe977 on epoch/v26.9.15-semantic-subject, 21 ahead of origin branch;
  origin/main d4971a40. Consume the fragment, never the working checkout.
- graphlaw: main 09fbd694 is 26.9.29 unreleased; release asset is v26.9.28. Local build
  `eda39e8c...` equals the release asset is UNVERIFIED. Pin to a release checksum.
- ggen_igniter: source 26.9.28; ash_a2a mix.lock pins hex 26.9.8.
- xaas: ceca8e1c on v26.9.27/closure-runtime; origin/main 7c3dc68b.
- bcinr: PR #42 open, unmerged; do not pin. wasm4pm-cmca pins stale bcinr b76dcb37.

## 2. Composition diagram and authority ceilings

```text
                  EVIDENCE PLANE (authority NONE)                    DO PLANE
  ash_r2rml --json--> A1 R2RMLIntake --+
  graphlaw  --proc--> A2 Evidence.GraphLaw --+--> Semantic Admission / SELECT
  bcinr/gymact -----> A4 CMCA.Port (advice)--+        |
  beam4pm  <--ocel--- A7 Projector           |        v
  beam4pm  ---port--> A3 Replan.Loop --Candidate--> SELECT/CONSTRUCT
                                                      |  (new PreparedEffect,
  xaas ---plain map--> A6 Adapters.Xaas.Intake -------+   new EffectInstance)
                                                      v
                            ConsequenceKernel.prepare (L05, in-VM, no NIF/port)
                                      |
                       A5 generated static shapes (no logic)
                                      v
                    X2 AuthorityService (OS proc, issue-only, own keys)
                                      | ActuationCertificate (X1)
                                      v
                    X4 Actuator (OS proc, verifies cert, owns effect log)
                                      |
                    A8 signer registry / k-of-n verify (X3, keyless verify)
```

### 2.1 Authority ceilings

| Component | Ceiling | Holds keys | Reaches DO |
|---|---|---|---|
| A1 R2RMLIntake / VkgObservation | NONE (clamps producer CONSTRUCT) | no | no |
| A2 Evidence.GraphLaw | NONE (Reply.authority: :none) | no | no |
| A3 Replan.* | NONE, CONSTRUCT-candidate outputs | no | no |
| A4 ResourceEnvelope/BudgetLedger | below DO, admission input only | no | no |
| A4 CMCA.Port | NONE, advice | no | no |
| A5 kernel pack | CONSTRUCT of source text | no | no |
| A6 Adapters.Xaas.* | PREPARE ceiling | no | no |
| A7 Projector, OcelForwarder | NONE | no | no |
| A8 signer registry verify | returns ValidSignerSet or refusal | public keys | no |
| C2, CHI-* courts | CONSTRUCT qualifier | test-only fresh keys in peers | test effect only |
| X2 AuthorityService | issue-only | authority keys | no |
| X4 Actuator | DO in own OS process | actuator keys | yes (sole) |

### 2.2 Forbidden edges (union, deduplicated)

1. Any evidence-plane module (A1, A2, A3, A4-CMCA, A7) to ConsequenceKernel, PreparedEffect,
   PreparedEffectStore, EffectInstance, Authority.*, Actuator, AuthorityClient, signer keys.
2. ConsequenceKernel, Authority, Actuator to any evidence-plane module. Kernel decides
   identically with every evidence adapter absent.
3. ash_a2a lib/ or mix.exs to ash_r2rml, xaas, beam4pm, bcinr, gymact (exchange is plain
   maps or JSON; oracles live in tests only).
4. ash_r2rml, xaas, beam4pm to ash_a2a types, or to a second GraphLaw path, a second OCEL
   builder, a second refusal taxonomy, or a second budget ledger.
5. Any producer standing string (UNKNOWN, ALIVE, ...) into SA2A standing. Standing is
   derived from receipts (L19), never stored or copied.
6. Any NIF, port, System.cmd, Node.*, :erpc in the kernel (RFC-006 s23). Native and OS
   processes only from non-kernel callers or from the test side.
7. UNKNOWN_OUTCOME to automatic replan or retry. Replanned effects get a NEW effect
   instance identity and never reuse the predecessor id or request id.
8. Any function that raises a limit or lowers `consumed`, except `Allocator.reissue/4` by a
   non-model issuer. Command.metadata keys `lineage`, `depth`, `max_*` are refused.
9. Generated modules to effectors, File, System, Req, :crypto, key material, GgenIgniter at
   runtime. Handwritten kernel to the pack ontology at runtime.
10. Courts to Mock, :meck, Mox, monkeypatch, patch. Courts to shared scratch or test DB
    across lanes. Any git worktree or shadow clone.
11. `xaas` authority (`Xaas.System.Authority`, `authority:` option) as a grant. It is
    evidence only.
12. beam4pm `DeviationAdmission.admit_deviation/5` and `PlanLineage` as evidence.

## 3. Pinned seams

Numbered P01-P26. Each is the single interface other lanes may code against. Signatures
marked DERIVED must be re-cut by the owning lane if L01/L03/L04/L05/L10 fix different names;
record the change in `RESOLUTIONS.md`.

### 3.1 Decisions resolving conflicts between designs

- **D1** Conflict: A3 and A7 both define an OCEL vocabulary and projector; Decision: A7 owns
  `AshA2A.Evidence.Vocabulary` and `Evidence.Projector`; A3 keeps only `Replan.Loop`, `Proposal`,
  `SubjectLineage`, `Port`, `TraceExtractor`, and calls the projector; Reason: one builder, one
  vocabulary; court A7-C1 enforces it
- **D2** Conflict: event_id formulas differ (A3 three inputs, A7 two); Decision:
  `sha256(receipt_subject_id, event_type)`; effect_instance_id is an attribute; Reason: receipt
  subject id already binds the instance; simpler replay key
- **D3** Conflict: A3 event names `sa2a.<x>` vs A7 `ash_a2a.v1.<class>.<outcome>`; Decision: A7
  form `ash_a2a.v1.<class>.<outcome>`; A3 events map into the classes `replay`, `unknown_outcome`,
  `reconcile` plus new class `replan`; Reason: vocabulary is versioned, closed
- **D4** Conflict: L05 lists `Effector.OcelExport`; A7 says export is telemetry; Decision: remove
  `effector/ocel_export.ex` from L05 Owns; OCEL export is evidence plane; Reason: an effector is a
  classed DO edge
- **D5** Conflict: A1 producer ceiling CONSTRUCT vs operator authority NONE; Decision: clamp on
  intake; record `authority: :none`; never copy declared ceiling; Reason: no producer change
  needed; refusal above CONSTRUCT
- **D6** Conflict: A4 says Bounds.delegate exists; substrate map says add Budget.split/2; Decision:
  reuse `Bounds.delegate`; add `ResourceEnvelope.split/3` (exact integer shares) built on
  `Bounds.narrowed_resources`; one algebra; Reason: avoid two algebras (L17 rule)
- **D7** Conflict: A4 shares (rational, floor) vs gymact apportion (largest remainder); Decision:
  kernel uses floor, sum <= parent, residual stays in parent; oracle asserts `floor <= apportion <=
  floor + 1`; Reason: conservation is an inequality, never equality
- **D8** Conflict: A5 generated PreparedEffect vs constructor-only; Decision: generated module is
  shape only (`fields/0`, `@type`, `digest_domain/0`, `__shape_sha__/0`); no struct literal.
  Handwritten `AshA2A.PreparedEffect` owns the struct; court GEN-5 compares both; Reason: structs
  are literal-constructible; enforcement is seal check plus L20 AST verifier
- **D9** Conflict: Refusal codes: A1, A2, A4, A5, courts each want new codes; Decision: codes enter
  only through L03 registry or a generated provider `__sa2a_refusal_codes__/0`; all map to the
  existing 18 classes; RFC-004 s14 lists 14 (RFC text to be reconciled to code); Reason: one
  taxonomy; refusal.ex is L03 hot file
- **D10** Conflict: Digest source for envelope, evidence, subject ids; Decision: interim
  `Semantic.CanonicalDigest` / `CanonicalTermDigest`; switch to `Identity.Canonical` when L01
  lands; never mix64; Reason: mix64 is non-cryptographic
- **D11** Conflict: Court ids inconsistent; Decision: ids fixed: `SA2A-C2`, `CHI-CLOSURE`, `CHI-
  CONSERVE`, `CHI-FAULT`, `R2R-C1..C6`, `GL-C01..C08`, `A3-C1..C8`, `A4-C1..C8`, `A7-C1..C9`,
  `GEN-1..9`; Reason: stable keys for mandatory corpus
- **D12** Conflict: GraphLaw canonical: wasm graph_hash vs in-BEAM RDFC; Decision: identity stays
  in-BEAM (`CanonicalGraph`); wasm `canonical` is a cross-check court only; Reason: wasm v26.7.5
  graph_hash is not RDFC-1.0
- **D13** Conflict: Signature suite; Decision: EdDSA (ed25519) is the default because pinned OTP
  27.2.4 lacks mldsa; ML-DSA is suite-gated with typed refusal `alg_unavailable`; alg mismatch is
  `alg_mismatch`; Reason: OBSERVED crypto.erl
- **D14** Conflict: xaas termination seam; Decision: reuse `:castle_kernel_module` config seam
  (castle.ex:56); adapter lives in ash_a2a as plain-map intake; Reason: no new config surface; no
  ash_a2a to xaas edge
- **D15** Conflict: A6 wants an outcome type; kernel lane owns it; Decision: `AshA2A.EffectOutcome`
  is L10-owned; A6 consumes only status enum `:applied` `:not_applied` `:unknown_outcome`; Reason:
  pin in RESOLUTIONS.md
- **D16** Conflict: ML-DSA vs :crypto in kernel under s23; Decision: verify-only OTP `:crypto` is
  allowed; RFC-006 s23 needs an explicit carve-out (operator question Q7); Reason: tension, not
  silently assumed

### 3.2 Pinned interfaces

Evidence intake (A1):

```elixir
# P01
defstruct [:evidence_id, :kind, :source, :subject, :exact_source, :producer,
           :producer_head, :producer_claim, authority: :none, standing: :candidate]
# AshA2A.Evidence.VkgObservation; kind :: :sparql_observation | :obda_observation |
#   :compilation_receipt | :mapping_bundle | :frontier_fragment

# P02
@spec admit(map(), keyword()) ::
  {:ok, VkgObservation.t()} | {:error, AshA2A.Semantic.Refusal.t()}
# AshA2A.Evidence.R2RMLIntake.admit/2; opts :expected_subject, :max_bytes, :now; pure

# P03
@spec to_semantic_subject(map(), String.t()) ::
  {:ok, AshA2A.SemanticSubject.t()} | {:error, {:refused_semantic_subject, atom()}}
# projection_digest and manufacturer_digest are caller-supplied, never defaulted

# P04
@spec no_authority_guard(VkgObservation.t()) ::
  :ok | {:error, {:refused_authority, :vkg_evidence_carries_authority}}
```

GraphLaw evidence service (A2):

```elixir
# P05
@callback evaluate(Request.t(), keyword()) :: {:ok, Reply.t()} | {:error, Refusal.t()}
@callback identity(keyword()) :: {:ok, ArtifactIdentity.t()} | {:error, Refusal.t()}
@callback available?(keyword()) :: :ok | {:error, Refusal.t()}
# AshA2A.Evidence.GraphLaw.Host; impls OsProcessHost (default), WasmtimeBindgenHost and
# WasmexInVmHost (legacy, dev/test only)

# P06
%AshA2A.Evidence.GraphLaw.Reply{ok: boolean(), op: atom(), result: map(),
  artifact: ArtifactIdentity.t(), request_digest: String.t(), candidate_digest: String.t(),
  evidence_digest: String.t(), authority: :none, duration_us: non_neg_integer(),
  fuel_used: non_neg_integer()}
# evidence_digest = sha256(canonical_json(result) <> wasm_sha256 <> request_digest)

# P07
@spec evaluate(atom(), map(), keyword()) :: {:ok, Reply.t()} | {:error, Refusal.t()}
# AshA2A.Evidence.GraphLaw.evaluate/3 facade; op allowlist {capabilities, sniff, parse,
#   canonical, sparql, shacl, shex, n3, entail, datalog, hooks, law(shacl|n3|rdfs|owl-rl|hooks)}
#   law steps plan, record-receipts, require-receipt -> :refused_capability
```

Host wire protocol (A2): stdin frame `{"v":1,"op":..,"input":..,"limits":{fuel,
max_memory_bytes,max_output_bytes}}`, stdout frame `{"v":1,"ok":..,"result":..,
"artifact":{wasm_sha256,host_sha256,wasmtime,abi_version,engine_version},
"fuel_used":N,"duration_us":N}`. WASI ctx empty: no preopens, no env, no network.
Host binary path is digest-pinned, never PATH-resolved, never caller-supplied. (P08)

Replan and OCEL (A3, A7):

```elixir
# P09
@spec event(term(), keyword()) ::
  {:ok, AshA2A.Evidence.Projector.Event.t()} | {:error, {:refused_projection, atom()}}
@spec objects(term(), keyword()) :: [AshA2A.Evidence.Projector.Object.t()]
@spec gall_event(map(), map(), term()) ::
  {:ok, Event.t()} | {:error, {:refused_gall, :ocel_projection, :invalid_subject}}
@spec dispatch_event(map(), map()) :: Event.t()
# AshA2A.Evidence.Projector; Event keeps flat wire keys event_id, event_type, event_time,
#   attributes, relationships (beam4pm decode reads top-level relationships)

# P10
@spec event_types() :: [String.t()]
@spec qualifiers() :: [String.t()]
@spec version() :: pos_integer()
@spec valid?(Event.t()) :: :ok | {:error, [term()]}
# AshA2A.Evidence.Vocabulary; classes request, effect_claim, prepare,
#   certificate_verified, actuation, receipt, replay, unknown_outcome, reconcile,
#   gall_intervention, replan; type form ash_a2a.v1.<class>.<outcome>

# P11
@spec for_consumer(term()) ::
  {:ok, %{receipt_json: binary(), seal: %{kid: String.t(), alg: String.t(),
          tag: binary()}, subject_id: String.t()}} | {:error, term()}
# AshA2A.Evidence.ReceiptView; beam4pm never receives a shared HMAC key

# P12
@callback conformance(map(), String.t(), [String.t()]) ::
  {:ok, %{conforms: boolean(), fitness: number(), deviations: [[String.t()]],
          cost: number()}} | {:error, term()}
@callback replan(map(), [{String.t(), boolean()}], String.t(), keyword()) ::
  {:ok, %{plan: map(), plan_id: String.t(), trigger: atom(),
          evidence_digest: String.t() | nil}} | {:error, term()}
# AshA2A.Replan.Port; real impl Port.Beam4pm in a separate OS process; absent beam4pm ->
#   {:error, {:unsupported, :beam4pm}}

# P13
%AshA2A.Replan.Proposal{subject_digest: binary(), predecessor_effect_instance_id: String.t(),
  disposition: :conforming | :hold_unknown | :deviation_replanned | :deviation_refused,
  candidates: [Planning.Candidate.t()], evidence_digest: binary(),
  authority: :none, standing: :candidate, do_edge: false}
@spec run(Receipt.t() | Identity.t(), Candidate.t() | nil, module(), keyword()) ::
  {:ok, Proposal.t()} | {:error, Replan.Refusal.t()}   # AshA2A.Replan.Loop

# P14
@spec bind(Planning.Candidate.t(), %{subject_digest: binary(), effect_instance_id: String.t()}) ::
  {:ok, Planning.Candidate.t()} | {:error, {:subject_drift, binary(), binary()}}
# AshA2A.Replan.SubjectLineage; subject preserved, effect-instance identity NEW
```

Budget (A4, CHI-CONSERVE):

```elixir
# P15
@spec split(ResourceEnvelope.t(), [{binary(), {non_neg_integer(), pos_integer()}}], keyword()) ::
  {:ok, [ResourceEnvelope.t()], residual :: map()} |
  {:error, %{code: :share_not_closed | :child_sum_exceeds_parent | :duplicate_child |
             :depth_exhausted | :unknown_dimension}}
# limit_c = div(num * limit_p, den); shares must sum to exactly 1; refuse, never normalize

# P16
@callback reserve(binary(), binary(), %{atom() => pos_integer()}, keyword()) ::
  {:ok, Reservation.t()} | {:error, %{code: :budget_exhausted | :envelope_unknown |
            :envelope_epoch_stale | :cost_not_positive | :duplicate_reservation_mismatch}}
@callback settle(binary(), %{atom() => non_neg_integer()}) :: {:ok, entry()} | {:error, map()}
@callback release(binary(), atom()) :: :ok | {:error, map()}
@callback record_split(binary(), [ResourceEnvelope.t()]) :: :ok | {:error, map()}
@callback entries(binary()) :: [entry()]
@callback replay([entry()]) :: {:ok, map()} | {:error, %{code: :ledger_divergence, at: integer()}}
# AshA2A.BudgetLedger; append-only hash-chained; reserve idempotent on
#   (envelope_id, effect_claim_digest)

# P17
@callback propose(%{tree: [map()], lenses: [integer()], config_identity: binary()}) ::
  {:ok, %{shares: [{binary(), {non_neg_integer(), pos_integer()}}], engine: map(),
          trace: [map()]}} | {:error, %{code: :cmca_refusal | :engine_unavailable |
                                         :timeout | :bad_output}}
# AshA2A.Evidence.CMCA.Port; Port.Static is the always-available fallback; advice is data,
#   re-checked by split/3, any error falls back with advice_used: false

# P18
@spec bound_gate(Command.t(), ExecutionContext.t(), module()) ::
  {:ok, Reservation.t()} | {:error, %{code: :budget_exhausted | :envelope_override_refused}}
# additive hunk in command_bus.ex pre_do_gate after revalidate and kill switch
```

Generated surface (A5):

```elixir
# P19  (all under AshA2A.Kernel.Generated.*, shape only)
@spec fields() :: [atom()]              # PreparedEffectShape, EffectInstanceShape
@spec digest_domain() :: binary()       # "sa2a/prepared-effect/1"
@spec identity_inputs() :: [atom()]     # [:request_identity, :effect_claim_digest,
                                        #   :generation, :attempt]
@spec keys() :: [%{key: atom(), type: atom(), default: term(), forbidden_in_opts: boolean()}]
def __sa2a_refusal_codes__() :: %{atom() => AshA2A.Semantic.Refusal.class()}
@spec derive_standing(semantic, authority, execution, evidence) :: standing
# ProductState is total over 5*4*8*4 = 640 cells and ceiling-monotone
```

Drift gate (A5): `mix ash_a2a.kernel.gen_check` (MIX_ENV=dev) exits 1 with
`REFUSED_GENERATED_DRIFT[file, expected_sha, actual_sha]`; alias `verify.kernel_gen`. (P20)

xaas termination (A6):

```elixir
# P21
@spec to_effect_claim(map(), keyword()) ::
  {:ok, AshA2A.EffectClaim.t()} | {:error, {:refused, atom(), map()}}
@spec run(EffectClaim.t(), %{authority_client: module(), actuator_client: module(),
          store: module()}) ::
  {:ok, %AshA2A.EffectOutcome{status: :applied | :not_applied | :unknown_outcome,
                              receipt_ref: String.t()}} | {:error, {:refused, atom(), map()}}
@spec to_seal_input(EffectOutcome.t()) ::
  %{status: :ok | :error | :unknown, evidence: map(), receipt_ref: String.t(), standing: atom()}
@spec check_route(map(), EffectClaim.t()) ::
  :ok | {:refused, :admission_vacuous, %{field: String.t()}}
# AshA2A.Adapters.Xaas.{Intake,Terminate,Outcome,Conformance}; plain maps, no Xaas.* alias
```

Signer registry (A8), authority courts, closure:

```elixir
# P22
@callback verify(msg :: binary(), sig :: binary(), pubkey :: binary()) :: boolean()
# AshA2A.Signer.Suite; k-of-n verifier counts distinct registered signers only; ceiling
#   returns ValidSignerSet or typed refusal (:alg_mismatch, :alg_unavailable, :quorum_short)

# P23
@spec sinks() :: [%{mfa: {module(), atom(), arity() | :any}, class: atom(),
                    kernel_only: boolean(), declared_sink_owner: module() | nil}]
# AshA2A.Effector.Classification; single data table (ggen-generated if a pack exists) used
#   by CHI-CLOSURE, mix ash_a2a.effector_graph and L20 SEC-M01-7

# P24
@spec build(keyword()) ::
  {:ok, %{edges: [edge], unresolved: [site], modules: [module], extractors: [atom()]}} |
  {:error, {:no_debug_info, [module()]}}
# AshA2A.Chicago.ClosureGraph; extractors :abstract_code and :xref (:xref API over beam
#   dirs preferred to nested mix); A xor B edge -> extractor_disagreement

# P25
@spec points() :: [%{id: atom(), s29: String.t(), event: [atom()], match: map(),
                     side_effect_expected: :none | :maybe | :one, requires: [atom()]}]
@spec classify_outcome(env :: term(), command_id :: term()) ::
  {:no_consequence | :exactly_one_reconcilable | :unknown_no_replay | :violation, map()}
# AshA2A.Chicago.Fixtures.FaultInjection

# P26
@spec start(keyword()) :: {:ok, %{cp: node(), auth: node(), act: node(),
                                  effect_log: Path.t(), stop: (-> :ok)}} | {:error, term()}
@spec attack(map(), atom() | String.t(), integer()) ::
  %{attacker_return: term(), effect_rows: [map()], marker: binary()}
# AshA2A.Chicago.Fixtures.ControlPlaneCompromise.Harness; oracle is the actuator effect
#   log, never control-plane receipts, telemetry, or OCEL
```

Pinned interface count: 26 (P01-P26). Unresolved names (EffectClaim, EffectOutcome,
EffectInstance constructor, ConsequenceKernel.prepare) are UNVERIFIED until L04/L05/L10.

## 4. Reproduce CI locally

Baseline: CI run 36497097705. All commands below are the shape to use; exact flags not
executed by this writer (UNVERIFIED). Use `MIX_BUILD_ROOT=_build-lane<N>` per lane and
never share the test DB with another workflow.

### 4.1 Toolchain

```bash
cd /Users/sac/ash_a2a && pwd && git rev-parse HEAD
# expect 9cda21c9b8728ec240ef499dfc186be2ee5e923b
cat .tool-versions                                   # erlang 27.2.4 pinned; no :crypto mldsa
```

### 4.2 Postgres with TCP forward

CI expects Postgres reachable on 5432 and a TCP forward to 55432. Start a local Postgres on
5432, then forward.

```bash
pg_isready -h 127.0.0.1 -p 5432
socat TCP-LISTEN:55432,fork,reuseaddr TCP:127.0.0.1:5432 &
pg_isready -h 127.0.0.1 -p 55432
```

### 4.3 Native builds

```bash
cargo build --release --manifest-path native/hddl_cli/Cargo.toml
cargo build --release --manifest-path native/graphlaw_host/Cargo.toml
```

`hddl_cli` pins ferroplan `=0.28.0` rev e90928d7; local ~/ferroplan is 0.29.0. Build from the
pin, not the local checkout. Record binary sha256 in any plan identity.

### 4.4 Full suite

```bash
mix deps.get && MIX_ENV=test mix ecto.create && mix test.all --cover
mix ash_a2a.chicago.pin_court_manifest --check   # sa2a-conformance.yml:95
mix hex.audit
```

Note: `--cover` compiles beams via cover; use `AshA2A.BeamFile.path/1` (untracked
`beam_file.ex`, commit first) so AbstractCode reads original beams.

### 4.5 Known red set (CI run 36497097705)

| Item | Class | Pre-existing? | Owner |
|---|---|---|---|
| 35 test failures | mixed | pre-existing | list not attached; re-run 4.4, record per test |
| `hex.audit` mint | dependency audit | pre-existing | fix by dependency bump lane |
| court manifest drift | manifest json stale | pre-existing | run pin_court_manifest; owner L20 |
| GALL exact-head compile | compile failure | pre-existing | GALL lane |
| Hex release | blocked upstream | pre-existing | needs ggen_igniter and ash_r2rml 26.9.28 on Hex |

Any new failure introduced by a lane must be stated as introduced, separately from this set.
The dirty tree at 9cda21c may itself affect the red set (UNVERIFIED which of the 35).

## 5. Per-court spec

Each court: module, id, profile, falsifiers, oracle, anti-vacuity, blockers. All courts are
Chicago style: real collaborators, state assertions, zero Mock/patch (grep-verify each run:
`grep -rn "unittest.mock\|Mock(\|:meck\|Mox\|monkeypatch\|patch(" test lib/ash_a2a/chicago`).

### 5.1 SA2A-C2 control-plane compromise (RFC-006 s26)

- Module `AshA2A.Chicago.Courts.ControlPlaneCompromise`; profile :do; 30 attacks plus `-00`
  legitimate control arm, `-00b` key partition check, `-00c` oracle independence probe.
- Three real `:peer` nodes: control plane (attacker has `:erpc` arbitrary MFA), AuthorityService
  (X2), Actuator (X4) with fsynced append-only effect log. Peers 2 and 3 use `-connect_all
  false`, distinct cookies, wire endpoints only.
- Pass per attack: effect-log rows with the attack marker equal 0, or exactly 1 for the
  certified control. Crash or timeout alone scores nothing.
- Attack data: `priv/sa2a/control_plane_attacks.json`, digest-pinned. Groups: 01-05 forged
  artifacts, 06-07 mediation bypass, 08-10 identity mutation, 11-14 certificate validity,
  15-16 quorum (BLOCKED without X3), 17-20 duplicate and crash windows, 21-23 amplification,
  24-25 policy and kill, 26-28 adapter and target substitution, 29-30 injection and
  deserialization.
- Mutations (mandatory corpus): drop certificate verify, exact-subject check, epoch check,
  single-use claim, quorum count; each must turn its attack red.
- BLOCKED until X1, X2, X4 exist; never PASS by default. Record residual: same-uid peers
  (ptrace) unless separate uid or container.

### 5.2 CHI-CLOSURE architecture closure (RFC-006 s27)

- Module `AshA2A.Chicago.Courts.ArchitectureClosure`, `ClosureGraph`, `mix
  ash_a2a.effector_graph [--json path] [--scratch-src dir]`.
- Passes iff every edge to a classified effector has a Kernel-set caller and every dynamic
  site is allowlisted with proof or fails closed. Not covered (stated in output):
  Module.concat, runtime-valued apply, NIF, hot load, Code.eval; runtime seal and X4 cover.
- Falsifiers CLOSURE-01..12: direct edge, transitive edge, dynamic apply, allowlist pinning,
  mutation twin (git archive scratch dir, plain directory), stripped beams fail closed,
  extractor disagreement, kernel-internal sinks, default-deny for new modules, runtime seal,
  crash-window tie-in, conservation twin (sink inventory floor).
- Apply-site dispositions: agent.ex:1258 via `Effector.OnCancelHook`; extended_card.ex:90
  behaviour_check PARTIAL; planning.ex:121 authority NONE; semantic_projection.ex:70 resolved
  observe sink; receipt_outbox.ex:431 kernel-internal; delivery/oban.ex and execution/flame.ex
  behind kernel; others computed, not assumed.
- Red by design on the current tree until L06; use mutation twin so it is not vacuous.

### 5.3 CHI-CONSERVE resource conservation (RFC-006 s28)

- Module `AshA2A.Chicago.Courts.ResourceConservation`, profile :plan, gate 6. StreamData
  (already at mix.exs:312) trees of spawn, delegate, retry, reschedule, attacks. Independent
  pure `Model` oracle; SUT adapters over `Bounds`, `Allocator`, ledger memory, ledger ekv,
  peer node.
- CONSERVE-1 recursive conservation, -2 amplification attempts, -3 retry recharge,
  -4 no self-grant reissue, -5 concurrent reservation, -6 crash-window leak,
  -7 anti-vacuity mutation, -8 dimension parity, -9 no second DO path.
- 500 runs default, 5000 under `SA2A_CONSERVE_DEEP=1`; seed stored in Result.
- CONSERVE-1..4 and -7 runnable before L17 against Bounds/Allocator. Ledger adapters compile
  only if `Code.ensure_loaded?(AshA2A.BudgetLedger)`, else named UNSUPPORTED.
- gymact differential is A4-C5: python3 oracle vectors (>= 50), named skip if absent. No
  gymact conservation oracle exists (OBSERVED); court ships its own model.

### 5.4 CHI-FAULT fault injection (RFC-006 s29)

- Module `AshA2A.Chicago.Courts.FaultInjection`, profile :do. Extends CHI-CRASH and reuses
  `Fixtures.ChaosReconciliation`; new files only (existing two are dirty).
- Per s29 point exactly one of NO_CONSEQUENCE, EXACTLY_ONE_RECONCILABLE, UNKNOWN_NO_REPLAY.
- FLT-01 request claim, -02 effect claim (BLOCKED L04/L05), -03 durable prepare, -04 authority
  (BLOCKED X1/X2), -05 actuator submit (BLOCKED X4), -06 during DO, -07 post-DO pre-response,
  -08 verification, -09 pre-receipt commit, -10 trichotomy completeness, -11 double fault,
  -12 positive control plus anti-vacuity, -13 injection determinism.
- Runnable now against CommandBus: FLT-01, -03 (anchor part), -06, -07, -09, -11, -13.
- Mutations appended to catalog: `fault_skip_unknown_outcome_latch`, `fault_replay_on_restart`,
  `fault_commit_before_do`.

### 5.5 Adapter courts

- **A1** Courts: R2R-C1..C6; Headline falsifier: DO-ceiling fragment -> REFUSED_AUTHORITY; ALIVE
  claim -> REFUSED_META_RIGOR; genuine CONSTRUCT fragment admitted with authority :none, standing
  :candidate; zero edges both ways to kernel
- **A2** Courts: GL-C01..C08; Headline falsifier: byte-flipped wasm refused
  `graphlaw_artifact_mismatch`; law step `plan` refused; SIGKILL host mid-call returns typed
  refusal and next call succeeds; no :wasmex in release closure
- **A3** Courts: A3-C1..C8; Headline falsifier: UNKNOWN_OUTCOME yields zero candidates and zero
  Port.replan calls; replan reusing predecessor id refused; second run on same receipt yields zero
  do_started events
- **A4** Courts: A4-C1..C8; Headline falsifier: StreamData conservation >= 1000 runs per property;
  Port output summing to 1.5 or 0.9 replaced by Static with advice_used false
- **A5** Courts: GEN-1..9; Headline falsifier: one-byte hand edit under `kernel/generated/` fails
  gen_check; adding a 19th refusal class refused by SHACL
- **A6** Courts: A6-C1..C7; Headline falsifier: kill xaas after DO before seal_external:
  UNKNOWN_OUTCOME, never a second DO; re-enabling `Kernel.actuate` DO body turns A6-C1 red
- **A7** Courts: A7-C1..C9; Headline falsifier: grep finds exactly one OCEL map builder (fails
  today: three); byte-identical re-projection; forged seal refused
- **A8** Courts: A8-C1; Headline falsifier: algorithm downgrade refused `alg_mismatch`

Anti-vacuity is mandatory for every court: the revert-mutation must make the acceptance
fail, and a seeded violation fixture must prove each scanner refuses.

## 6. Ordered task list

Pick tasks in order within a track; tracks are independent unless a Needs column says
otherwise. Acceptance is always a falsifier run on an exact SHA, with pasted output. One
writer per file; lane files declared in `_LANES.md`. Agents never run git state commands;
the coordinator commits per lane.

- **T00** Task: Commit or abandon the 15 dirty files and `beam_file.ex`; free the tree from the
  perf workflow; Needs: operator; Acceptance: `git status --porcelain` empty; `mix test.all
  --cover` red set equals 4.5
- **T01** Task: Add X1-X4, A1-A8, C2, CHI-* rows to `_LANES.md`; remove `effector/ocel_export.ex`
  from L05 Owns; pin D1-D16 in `RESOLUTIONS.md`; Needs: T00; Acceptance: grep shows each id once;
  no file owned by two lanes
- **T02** Task: Reproduce the CI red set locally (section 4); record 35 failing tests by name;
  Needs: T00; Acceptance: list committed under docs; identical failure set on re-run
- **T03** Task: Fix court manifest drift: `mix ash_a2a.chicago.pin_court_manifest` then `--check`;
  Needs: T00; Acceptance: `--check` exits 0; mutate a court and it exits nonzero
- **T04** Task: A1 R2RMLIntake: VkgObservation, admit/2, to_source/1, refusal_map/0, guard,
  vectors; Needs: T00; Acceptance: R2R-C1, C2, C5, C6 pass; C3 fails when a kernel reference is
  injected
- **T05** Task: A7 Vocabulary and Projector; delegate SemanticProjection.ocel_event/1, Gall
  OcelProjection, OcelForwarder builders; Needs: T00, L18 sequencing; Acceptance: A7-C1 red before,
  green after; existing forwarder tests green
- **T06** Task: CHI-CLOSURE: ClosureGraph, Classification data, court, mutation twin; run red on
  current tree; Needs: T00; Acceptance: CLOSURE-05 mutated exits nonzero; unmutated reports named
  violations
- **T07** Task: CHI-CONSERVE against Bounds and Allocator (CONSERVE-1..4, -7); Needs: T00;
  Acceptance: property run 500 seeds zero violations; mutants each fail a falsifier
- **T08** Task: A4 ResourceEnvelope.split/3 plus CMCA.Port.Static and Adjudicate; Needs: T07;
  Acceptance: A4-C1, C4, C7 pass; A4-C5 differential or named skip
- **T09** Task: A5 kernel pack K0: ontology, shapes, RefusalTable, ProductState, drift gate; Needs:
  T01; author standing rules (Q3); Acceptance: GEN-1, GEN-2, GEN-8 pass; GEN-6 needs rule rows
- **T10** Task: A2 vendor WASI module with MANIFEST, build native/graphlaw_wasi_host,
  OsProcessHost, facade; Needs: T00; release asset checksum (Q8); Acceptance: GL-C01, C02, C04, C07
  pass; GL-C08 result recorded
- **T11** Task: A2 demotion steps 2 and 3 (application child conditional, :wasmex to dev/test);
  Needs: T10 plus xref of bench tasks; Acceptance: GL-C03: no wasmex in release app list
- **T12** Task: A3 Replan: Loop, Proposal, SubjectLineage, Port, Port.Beam4pm; Needs: T05, L01,
  L10; Acceptance: A3-C1..C4, C6 pass; C7 named skip when beam4pm absent
- **T13** Task: CHI-FAULT runnable points (FLT-01, -03, -06, -07, -09, -11, -13); Needs: T00;
  Acceptance: control passes; each mutation flips one FLT falsifier red
- **T14** Task: L01, L03, L04, L05, L06 kernel spine (per `_LANES.md`); Needs: T01; Acceptance:
  each lane's own acceptance; CLOSURE-08 turns green after L06
- **T15** Task: L17 BudgetLedger memory and ekv, bound_gate/3; Needs: T08, L12, L10; Acceptance:
  CONSERVE-5, -6 pass; A4-C2, C3 pass
- **T16** Task: A8 Suite behaviour, registry, k-of-n verifier, EdDSA arm; ML-DSA gated; Needs: T14;
  Acceptance: A8-C1 plus quorum attacks 15, 16 no longer BLOCKED
- **T17** Task: X1 ActuationCertificate, X2 AuthorityService, X4 minimal Actuator (separate OTP
  releases); Needs: T14, T16; Acceptance: FLT-04, -05 unblocked; C2 attack 00 control yields
  exactly 1 row
- **T18** Task: SA2A-C2 harness and 30 attacks; Needs: T17; Acceptance: 30 of 30 non-PASS-by-crash,
  zero attributable rows; five mutants red
- **T19** Task: CHI-FAULT remaining points; Needs: T17; Acceptance: FLT-02, -04, -05 pass; FLT-10
  trichotomy complete
- **T20** Task: A6 xaas adapters in ash_a2a; xaas-side terminator behind `:castle_kernel_module`;
  Needs: T14, T17; xaas owner; Acceptance: A6-C1..C7; xaas transactional path unchanged (A6-C7)
- **T21** Task: hddl_cli spawn wrapper: OS deadline plus SIGKILL, stdout and input caps, limits via
  argv; Needs: T14; Acceptance: oversized input and hang refused typed; process gone
- **T22** Task: Hex release once ggen_igniter and ash_r2rml 26.9.28 exist; Needs: upstream;
  Acceptance: `mix hex.audit` clean; release dry run

## 7. Open questions for the operator

1. Clamp or producer-side NONE profile for ash_r2rml FrontierEvidence (ceiling CONSTRUCT vs
   authority NONE)? Default proposed: clamp on intake.
2. Should RFC-006 gain a normative OCEL vocabulary section, a new RFC-SA2A-007, or an RDF
   ontology projected by ggen? RFC-006 s20 is Replay and cannot be cited.
3. Who authors the remaining RFC-004 s4 derive_standing rows (only two are stated)? GEN-6 and
   L19 cannot be ALIVE without them.
4. Reconcile RFC-004 s14 (14 refusal classes) with refusal.ex (18): edit the RFC text?
5. Actuator and AuthorityService placement: in-repo test/support first, or separate sibling
   release? Same-uid peers leave ptrace residual; accept, or require separate uid or container?
6. Ledger shape: per-envelope append-only chain or one global chain? Cost model owner
   (effect-class registry vs certificate)? Rolling windows or lifetime ceilings?
7. RFC-006 s23 carve-out: is verify-only OTP `:crypto` permitted in the kernel? Pinned OTP
   27.2.4 lacks ML-DSA; raise the pin to 28.3 or ship EdDSA-only first?
8. GraphLaw: does `eda39e8c...` equal the v26.9.28 release asset? Job-per-process (about 100 ms
   compile cost) or warm pool? Pin clock and random, or refuse ops that use them (GL-C08)?
   Keep v26.7.5 pinned for replay of old evidence?
9. Is the kernel a single module or a supervised set (kernel, store, token holder)? Are
   configured callback modules allowed to be effectors, or must they be a closed set?
10. Is `Reconciliation` allowed a distinct `:unknown_outcome` state in place of
    `:prepared_unknown_outcome`?
11. xaas: adapter in ash_a2a (as designed) or separate `ash_a2a_xaas` package? Which store is
    crash-recovery truth, Postgres outer intent or the ash_a2a store? Does CASTLE keep
    PREPARE/OUTCOME as provider-side ledger under X4?
12. Does anything outside ash_a2a call `Gall.Closure.OcelProjection.project/3`, and does xaas
    already consume FrontierEvidence (a second admission)? Fleet-wide grep needed.
13. Should beam4pm ever verify receipt seals (requires asymmetric seals; L18 plans HMAC)?
    Should OcelForwarder emit only from kernel-sealed receipts?
14. Do beam4pm's generated OcelEvent types accept `ash_a2a.v1.*` types and arbitrary
    attributes, or does its admission graph restrict them? Add a conformance route there?
15. Is a pack search in `~/ggen-marketplace/packs` for effector classification, refusal
    tables and attack schemas required before hand-writing (UNSUPPORTED(generator-capability)
    receipts otherwise)? Does `mix ggen_igniter.sync --pack kernel` resolve in a consumer
    repo? mix.lock pins ggen_igniter 26.9.8 versus source 26.9.28.
16. Should the wasm4pm-cmca binding be re-pinned, and should bcinr export a JSON CLI for
    arbitrary trees (CLIs are fixed N=8,K=4,Q=4)? Merge of bcinr PR #42 is a precondition for
    any pin.
17. Confirm the 35 red tests, and whether the dirty tree affects them; confirm no open
    ash_a2a PRs (gh exit code was not checked).

Open-question count: 17.

## 8. See Also

- `docs/jira/v26.9.28-kernel/_LANES.md` - lane map L01-L20 (to be extended per T01)
- `docs/jira/v26.9.28-kernel/RESOLUTIONS.md` - pinned seams and shared-file relay order
- `docs/rfc/RFC-SA2A-004` (normative), `RFC-SA2A-005` (security profile), `RFC-SA2A-006`
  (adversarial control plane, s20-s30 referenced above)
- `~/.claude/rules/same-checkout-fanout.md` - one checkout, disjoint lanes, no agent git
- `~/.claude/rules/testing-chicago-style.md` - no mocks; grep plus real passing run
