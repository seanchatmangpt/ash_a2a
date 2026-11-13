# Module Coverage

Standing: PARTIAL

Index of public module families under `lib/ash_a2a` that lack a dedicated
reference doc. Entries list file and directory names only; no behavior is
described here. Standing `undocumented` means no per-module doc exists
outside `docs/reference/generated/reference.md` (generated) and the
excluded `docs/archive`, `docs/sjira` trees.

Method: `ls lib/ash_a2a/<family>`; `grep -rlE` for the module namespace and
path over `docs/**/*.md` excluding the three trees above. Checked 2026-11-10.

## Replan (`lib/ash_a2a/replan/`)

Existing coverage: partial: mentioned in `docs/explanation/pplan-seams.md`, `docs/reference/telemetry.md`.

| entry | standing |
|---|---|
| `attempt_budget.ex` | undocumented |
| `candidate_fence.ex` | undocumented |
| `conformance.ex` | undocumented |
| `decision.ex` | undocumented |
| `effect_identity.ex` | undocumented |
| `feedback.ex` | undocumented |
| `loop.ex` | undocumented |
| `observation.ex` | undocumented |
| `outcome.ex` | undocumented |
| `port` | undocumented |
| `port.ex` | undocumented |
| `portable_envelope.ex` | undocumented |
| `portable_schema.ex` | undocumented |
| `proposal.ex` | undocumented |
| `provider.ex` | undocumented |
| `provider_failure.ex` | undocumented |
| `provider_registry.ex` | undocumented |
| `provider_result.ex` | undocumented |
| `provider_set.ex` | undocumented |
| `receipt_cursor.ex` | undocumented |
| `receipt_feedback.ex` | undocumented |
| `reconcile_gate.ex` | undocumented |
| `recovery_policy.ex` | undocumented |
| `refusal.ex` | undocumented |
| `replay_key.ex` | undocumented |
| `router.ex` | undocumented |
| `stale_plan.ex` | undocumented |
| `subject_lineage.ex` | undocumented |
| `telemetry.ex` | undocumented |
| `trace.ex` | undocumented |

## C2 (`lib/ash_a2a/c2/`)

Existing coverage: partial: `docs/reference/c2-certificate.md`, `c2-compromise-court.md`, `c2-wire-interop.md` cover certificate, compromise court, wire.

| entry | standing |
|---|---|
| `actuation_pipeline.ex` | undocumented |
| `actuator.ex` | undocumented |
| `actuator_client.ex` | undocumented |
| `actuator_client_framed.ex` | undocumented |
| `actuator_client_remote.ex` | undocumented |
| `actuator_profile.ex` | undocumented |
| `architecture_closure.ex` | undocumented |
| `authority_client.ex` | undocumented |
| `authority_client_framed.ex` | undocumented |
| `authority_client_remote.ex` | undocumented |
| `authority_request.ex` | undocumented |
| `authority_response.ex` | undocumented |
| `authority_service.ex` | undocumented |
| `budget_ledger.ex` | undocumented |
| `certificate.ex` | undocumented |
| `certificate_verifier.ex` | undocumented |
| `claim_store.ex` | undocumented |
| `claim_store_ets.ex` | undocumented |
| `complete_mediation.ex` | undocumented |
| `confused_deputy.ex` | undocumented |
| `control_plane_fence.ex` | undocumented |
| `crypto_verifier.ex` | undocumented |
| `effector.ex` | undocumented |
| `effector_registry.ex` | undocumented |
| `fencing_token.ex` | undocumented |
| `memory_claim_store.ex` | undocumented |
| `policy_epoch.ex` | undocumented |
| `policy_evidence` | undocumented |
| `policy_evidence.ex` | undocumented |
| `prepared_effect.ex` | undocumented |
| `principal.ex` | undocumented |
| `resource_envelope.ex` | undocumented |
| `revocation_epoch.ex` | undocumented |
| `wire.ex` | undocumented |

## Eval (`lib/ash_a2a/eval/`)

Existing coverage: none outside generated reference.

| entry | standing |
|---|---|
| `report.ex` | undocumented |
| `runner.ex` | undocumented |
| `scorers.ex` | undocumented |
| `suite.ex` | undocumented |

## BoardPersona (`lib/ash_a2a/board_persona/`)

Existing coverage: none outside generated reference.

| entry | standing |
|---|---|
| `activist_pressured.ex` | undocumented |
| `deliberation.ex` | undocumented |
| `growth_focused_founder_led.ex` | undocumented |
| `risk_averse_fiduciary.ex` | undocumented |

## CS2 (`lib/ash_a2a/cs2/`)

Existing coverage: none outside generated reference.

| entry | standing |
|---|---|
| `consumer_contract.ex` | undocumented |
| `contract.ex` | undocumented |
| `fleet_adapter.ex` | undocumented |
| `fleet_contract.ex` | undocumented |
| `generated_consumer.ex` | undocumented |
| `xaas_bridge.ex` | undocumented |

## DfCM (`lib/ash_a2a/dfcm/`)

Existing coverage: partial: `docs/archive/dfcm/fleet-absorption-v26.9.30.md` (Standing: UNVERIFIED).

| entry | standing |
|---|---|
| `court.ex` | undocumented |
| `fleet_intake.ex` | undocumented |
| `generated` | undocumented |

## Semantic (`lib/ash_a2a/semantic/`)

Existing coverage: partial: referenced by explanation/how-to docs (e.g. `enable-semantic-requests.md`, `graphlaw-wasm-integration.md`); no per-module reference.

| entry | standing |
|---|---|
| `admission.ex` | undocumented |
| `admission_hash.ex` | undocumented |
| `admission_pipeline.ex` | undocumented |
| `admission_refusal.ex` | undocumented |
| `admission_standing.ex` | undocumented |
| `agent_card.ex` | undocumented |
| `allocator.ex` | undocumented |
| `attestation.ex` | undocumented |
| `bounded_production.ex` | undocumented |
| `bounds.ex` | undocumented |
| `canonical_digest.ex` | undocumented |
| `canonical_graph.ex` | undocumented |
| `canonical_term_digest.ex` | undocumented |
| `capability_composition.ex` | undocumented |
| `compiler.ex` | undocumented |
| `conformance.ex` | undocumented |
| `construct.ex` | undocumented |
| `engine` | undocumented |
| `envelope.ex` | undocumented |
| `episode` | undocumented |
| `episode.ex` | undocumented |
| `evidence_ref.ex` | undocumented |
| `execution_package.ex` | undocumented |
| `extension.ex` | undocumented |
| `falsifier.ex` | undocumented |
| `falsifier_fixtures.ex` | undocumented |
| `falsifier_suite.ex` | undocumented |
| `feedback.ex` | undocumented |
| `graph_law` | undocumented |
| `graph_law.ex` | undocumented |
| `graph_law_bridge.ex` | undocumented |
| `hook_reactor` | undocumented |
| `hook_reactor.ex` | undocumented |
| `interchange_contract.ex` | undocumented |
| `ir.ex` | undocumented |
| `ir_admission_seal.ex` | undocumented |
| `iri.ex` | undocumented |
| `law_document.ex` | undocumented |
| `llm_boundary.ex` | undocumented |
| `logic_closure` | undocumented |
| `logic_closure.ex` | undocumented |
| `machine_experience.ex` | undocumented |
| `mapping_registry.ex` | undocumented |
| `meta_admission.ex` | undocumented |
| `ontology.ex` | undocumented |
| `ontology_cache.ex` | undocumented |
| `package_store.ex` | undocumented |
| `peer.ex` | undocumented |
| `peer_capability_reconciliation.ex` | undocumented |
| `plan_package.ex` | undocumented |
| `plan_projection.ex` | undocumented |
| `planning_ir.ex` | undocumented |
| `policy_phenotype.ex` | undocumented |
| `policy_population.ex` | undocumented |
| `policy_population_rdf.ex` | undocumented |
| `profile.ex` | undocumented |
| `refusal.ex` | undocumented |
| `revision.ex` | undocumented |
| `root_manifest` | undocumented |
| `root_manifest.ex` | undocumented |
| `schema.ex` | undocumented |
| `select.ex` | undocumented |
| `serialize.ex` | undocumented |
| `shacl_severity.ex` | undocumented |
| `source.ex` | undocumented |
| `standing.ex` | undocumented |
| `term_registry.ex` | undocumented |
| `unknown` | undocumented |
| `unknown.ex` | undocumented |
| `vocabulary.ex` | undocumented |
| `work_envelope.ex` | undocumented |

## ConsequenceKernel (`lib/ash_a2a/consequence_kernel/`)

Existing coverage: partial: referenced by RFC/assurance/conformance docs; no per-module reference.

| entry | standing |
|---|---|
| `authority_revalidation.ex` | undocumented |
| `call_graph_court.ex` | undocumented |
| `claim.ex` | undocumented |
| `closure` | undocumented |
| `closure_court.ex` | undocumented |
| `complete_mediation.ex` | undocumented |
| `effect_claim_store` | undocumented |
| `effect_identity.ex` | undocumented |
| `exact_subject.ex` | undocumented |
| `identity_bundle.ex` | undocumented |
| `identity_guard.ex` | undocumented |
| `identity_version.ex` | undocumented |
| `key_custody` | undocumented |
| `key_custody.ex` | undocumented |
| `ocel.ex` | undocumented |
| `prepared_effect_store` | undocumented |
| `prepared_effect_store.ex` | undocumented |
| `prepared_record_codec.ex` | undocumented |
| `receipt.ex` | undocumented |
| `receipt_chain.ex` | undocumented |
| `refusal.ex` | undocumented |
| `refusal_codes` | undocumented |
| `refusal_codes.ex` | undocumented |
| `refusal_registry.ex` | undocumented |
| `replay_evidence.ex` | undocumented |
| `request_identity.ex` | undocumented |
| `runtime` | undocumented |
| `standing.ex` | undocumented |
| `unknown_outcome.ex` | undocumented |
| `w4` | undocumented |
| `w4b` | undocumented |
| `w4c` | undocumented |
| `w5` | undocumented |
| `wire.ex` | undocumented |

## See Also

- [Reference index](index.md)
- [Generated reference](generated/reference.md)
- [Ingress attestation](ingress-attestation.md)
