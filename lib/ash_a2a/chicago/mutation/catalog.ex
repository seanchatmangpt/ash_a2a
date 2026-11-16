# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Chicago.Mutation.Catalog do
  @moduledoc """
  RFC-SA2A-002 §97 security mutations mapped onto the real functions of this
  subject that enforce each guard.

  Every entry names an exact `Module.function/arity` (public or private),
  the clauses it replaces and the mutant body, plus the court-id families
  expected to kill it. Killer ids follow RFC-SA2A-002 Appendix B; a court
  that is not compiled in this subject leaves the entry `:blocked` (another
  qualification slice supplies it), and a target that does not resolve --
  e.g. a module not compiled in the subject, or a guard whose arity moved --
  is `:blocked` with the resolver's reason. Nothing is silently skipped.

  `CHI-MUTGUARD` (`AshA2A.Chicago.Fixtures.MutationHarness.GuardCourt`) is a
  non-discoverable reference court over the real `AshA2A.CommandBus`,
  `AshA2A.Authority` and `AshA2A.Authority.Broker.InMemory` so the harness has
  a real killer for the BRCE/authority guards in every subject.

  | § 97 mutation                          | target                                              |
  |----------------------------------------|-----------------------------------------------------|
  | return true from authority check       | `AshA2A.CommandBus.admit/2`, `AshA2A.Authority.admits?/2` |
  | ignore expiry                          | `AshA2A.Authority.expired?/1`                        |
  | ignore revocation                      | `AshA2A.Authority.Broker.InMemory.grant_status/2`    |
  | remove receipt preparation             | `AshA2A.CommandBus.prepare_receipt_anchor/4`         |
  | accept unsupported profile             | `AshA2A.Semantic.Envelope.validate_profile/1`        |
  | trust sender standing                  | `AshA2A.Semantic.Envelope.reject_declared_standing/1`|
  | skip SHACL                             | `AshA2A.Semantic.AdmissionPipeline.run_stage/4` (`:shacl`) |
  | skip graph-global falsifiers           | `AdmissionPipeline.run_stage/4` (`:sparql_falsifiers`), `AshA2A.Semantic.FalsifierSuite.do_admit/1` |
  | allow caller-controlled consequence    | `AshA2A.CommandBus.inspect_target/2`, `AshA2A.Authority.Decision.classify/1` |
  | allow root-manifest component drift    | `AshA2A.Semantic.RootManifest.verify_pins/1`         |
  | allow replay to call actuator          | `AshA2A.CommandBus.claim_receipt/3`                  |

  Court falsifier ids (`SA2A-MUTATION-NNN`) are bound to entry ids in
  `numbered/0`; entries are append-only so ids stay stable (§136).
  """

  alias AshA2A.Chicago.Mutation

  @guard_court "CHI-MUTGUARD"

  @doc "Non-discoverable reference courts the catalog may use as killers."
  @spec reference_courts() :: [module()]
  def reference_courts, do: [AshA2A.Chicago.Fixtures.MutationHarness.GuardCourt]

  @doc "Every §97 mutation, in court falsifier order."
  @spec entries() :: [Mutation.t()]
  def entries do
    [
      %Mutation{
        id: "authority_check_true",
        rfc_mutation: "return true from authority check",
        module: AshA2A.CommandBus,
        function: :admit,
        arity: 2,
        clauses: :all,
        operator: {:replace_body, "ok."},
        guard:
          "CommandBus.admit/2 (authority_required / authority_mismatch / consequence_unclassified)",
        killers: ["SA2A-AUTH", "CHI-BRCE", @guard_court]
      },
      %Mutation{
        id: "authority_admits_true",
        rfc_mutation: "return true from authority check (authority binding)",
        module: AshA2A.Authority,
        function: :admits?,
        arity: 2,
        clauses: :all,
        operator: {:replace_body, "true."},
        guard: "Authority.admits?/2 subject/capability/expiry binding",
        killers: ["SA2A-AUTH", @guard_court]
      },
      %Mutation{
        id: "ignore_expiry",
        rfc_mutation: "ignore expiry",
        module: AshA2A.Authority,
        function: :expired?,
        arity: 1,
        clauses: :all,
        operator: {:replace_body, "false."},
        guard: "Authority.expired?/1 real-clock time bound",
        killers: ["SA2A-AUTH", @guard_court]
      },
      # `grant_status/2` is where the revoked set is read: both the broker
      # lookup (`{:grant_status, key}`) and `standing?/2` go through it.
      %Mutation{
        id: "ignore_revocation",
        rfc_mutation: "ignore revocation",
        module: AshA2A.Authority.Broker.InMemory,
        function: :grant_status,
        arity: 2,
        clauses: :all,
        operator:
          {:replace_body,
           """
           case maps:find(ChicagoArg2, maps:get(issued, ChicagoArg1)) of
             {ok, ChicagoEntry} -> 'entry_status'(false, maps:get(expires_at, ChicagoEntry));
             error -> absent
           end.
           """},
        guard: "Broker.InMemory.grant_status/2 revoked-set membership",
        killers: ["SA2A-AUTH", @guard_court]
      },
      %Mutation{
        id: "remove_receipt_preparation",
        rfc_mutation: "remove receipt preparation",
        module: AshA2A.CommandBus,
        function: :prepare_receipt_anchor,
        arity: 4,
        clauses: :all,
        operator: {:replace_body, "{ok, nil}."},
        guard: "CommandBus.prepare_receipt_anchor/4 pending receipt anchor before DO",
        killers: ["CHI-BRCE", @guard_court]
      },
      %Mutation{
        id: "accept_unsupported_profile",
        rfc_mutation: "accept unsupported profile",
        module: AshA2A.Semantic.Envelope,
        function: :validate_profile,
        arity: 1,
        clauses: {:clause, 1},
        operator: {:replace_body, "ok."},
        guard: "Envelope.validate_profile/1 known-profile check (:unsupported_profile)",
        killers: ["SA2A-ENV"]
      },
      %Mutation{
        id: "trust_sender_standing",
        rfc_mutation: "trust sender standing",
        module: AshA2A.Semantic.Envelope,
        function: :reject_declared_standing,
        arity: 1,
        clauses: :all,
        operator: {:replace_body, "ok."},
        guard: "Envelope.reject_declared_standing/1 (:standing_self_declared)",
        killers: ["SA2A-ENV", "CHI-ADM"]
      },
      %Mutation{
        id: "skip_shacl",
        rfc_mutation: "skip SHACL",
        module: AshA2A.Semantic.AdmissionPipeline,
        function: :run_stage,
        arity: 4,
        clauses: {:arg_literal, 1, :shacl},
        operator: {:replace_body, "{ok, nil}."},
        guard: "AdmissionPipeline SHACL stage (:shacl_nonconformant / undetermined)",
        killers: ["SA2A-SHACL", "CHI-ADM"]
      },
      %Mutation{
        id: "skip_graph_global_falsifiers",
        rfc_mutation: "skip graph-global falsifiers",
        module: AshA2A.Semantic.AdmissionPipeline,
        function: :run_stage,
        arity: 4,
        clauses: {:arg_literal, 1, :sparql_falsifiers},
        operator: {:replace_body, "{ok, nil}."},
        guard: "AdmissionPipeline SPARQLFalsifiers stage (:falsifier_violated)",
        killers: ["SA2A-SPARQL", "CHI-ADM"]
      },
      # The gate's DECISION (`do_admit/1`), not `admit/1` itself: `admit/1` also
      # emits the boundary's §12 attempt evidence, and a mutant that deletes the
      # evidence emitter is judged UNKNOWN (attempt unobserved) by every court,
      # never killed -- that would test observability, not the gate.
      %Mutation{
        id: "skip_graph_global_falsifier_gate",
        rfc_mutation: "skip graph-global falsifiers (S18.2 admission gate)",
        module: AshA2A.Semantic.FalsifierSuite,
        function: :do_admit,
        arity: 1,
        clauses: :all,
        operator: {:replace_body, "ok."},
        guard:
          "FalsifierSuite.admit/1 mandatory falsifier gate decision do_admit/1 (:refused_falsifier)",
        killers: ["SA2A-SPARQL", "SA2A-LOGIC"]
      },
      %Mutation{
        id: "caller_controlled_consequence",
        rfc_mutation: "allow caller-controlled consequence class",
        module: AshA2A.CommandBus,
        function: :inspect_target,
        arity: 2,
        clauses: :all,
        operator:
          {:replace_body,
           """
           case 'Elixir.AshA2A.Info':skill(ChicagoArg2, maps:get(capability_id, ChicagoArg1)) of
             {ok, ChicagoSkill} ->
               {ok, ChicagoSkill,
                'Elixir.Ash.Resource.Info':action(maps:get(resource, ChicagoSkill), maps:get(action, ChicagoSkill)),
                maps:get(consequence, maps:get(metadata, ChicagoArg1), maps:get(consequence, ChicagoSkill))};
             {error, _} ->
               {error, \#{code => capability_not_found, detail => <<"capability_not_found">>}}
           end.
           """},
        guard: "CommandBus.inspect_target/2 consequence taken from the resource DSL",
        killers: ["SA2A-AUTH", "CHI-BRCE", @guard_court]
      },
      %Mutation{
        id: "caller_controlled_consequence_decision",
        rfc_mutation: "allow caller-controlled consequence class (portable decision)",
        module: AshA2A.Authority.Decision,
        function: :classify,
        arity: 1,
        clauses: :all,
        operator: {:replace_body, "{ok, maps:get(<<\"consequence\">>, ChicagoArg1, nil)}."},
        guard: "Authority.Decision.classify/1 (:consequence_unattested)",
        killers: ["SA2A-AUTH"]
      },
      %Mutation{
        id: "root_manifest_component_drift",
        rfc_mutation: "allow root-manifest component drift",
        module: AshA2A.Semantic.RootManifest,
        function: :verify_pins,
        arity: 1,
        clauses: :all,
        operator: {:replace_body, "ok."},
        guard: "RootManifest.verify_pins/1 (REFUSED_MANIFEST_DRIFT)",
        killers: ["SA2A-ROOT", "SA2A-MANIFEST", "CHI-ID"]
      },
      %Mutation{
        id: "replay_calls_actuator",
        rfc_mutation: "allow replay to call actuator",
        module: AshA2A.CommandBus,
        function: :claim_receipt,
        arity: 3,
        clauses: :all,
        operator:
          {:replace_body,
           """
           case ChicagoArg1:claim(ChicagoArg2, ChicagoArg3) of
             {replay, ChicagoReceipt} -> {execute, maps:get(execution_id, ChicagoReceipt)};
             ChicagoOther -> ChicagoOther
           end.
           """},
        # The mutant re-issues the committed receipt's OWN execution id, so it
        # also satisfies the RFC-SA2A-004 execution fence (`confirm_claim/3`
        # compares the stored claim's execution id); a freshly minted id would
        # be stopped by that fence and the mutation would prove the fence, not
        # the replay branch.
        guard: "CommandBus replay branch: a committed receipt is returned, never re-actuated",
        killers: ["CHI-REPLAY", "CHI-BRCE", @guard_court]
      },
      # v26.10.1-loop lane A1: the two-port graph-digest checkpoint. The
      # carried order graph_digest is pinned against the executing command's
      # semantic_subject.graph_digest; deleting the pin lets a re-pointed
      # semantic graph ride a still-valid work-order identity into claim
      # and DO (CHI-HILT-001/002 observe the forbidden admission).
      %Mutation{
        id: "hilt_graph_digest_ok",
        rfc_mutation: "carry without pinning (drop the two-port graph-digest checkpoint)",
        module: AshA2A.Hilt.WorkOrder,
        function: :checkpoint_graph_digest,
        arity: 2,
        clauses: :all,
        operator: {:replace_body, "ok."},
        guard:
          "Hilt.WorkOrder.checkpoint_graph_digest/2 two-port pin: the carried order " <>
            "graph_digest must equal the executing command's semantic_subject.graph_digest " <>
            "(both present and disagreeing -> refuse :stale_graph_identity; either absent -> skip)",
        killers: ["CHI-HILT"]
      },
      # v26.10.2 loops-of-loops lane L1: the algebraic two-port lease gate.
      # One entry per conjunct-bypass -- replacing any conjunct's verdict with
      # `false` (never failed) lets a tampered lease ride into claim and DO.
      # CHI-TWO-PORT's single-bit tamper falsifiers observe the forbidden
      # admission on each.
      %Mutation{
        id: "lease_scope_check_ok",
        rfc_mutation: "scope conjunct never fails (two-port lease gate)",
        module: AshA2A.Authority.TwoPortGate,
        function: :scope_failed?,
        arity: 2,
        clauses: :all,
        operator: {:replace_body, "false."},
        guard:
          "TwoPortGate scope_failed?/2 conjunct (a): the lease's scope_digest " <>
            "must equal H(scope_of(command)) or the mask carries 0x1 " <>
            "(:lease_scope_mismatch)",
        killers: ["CHI-TWO-PORT"]
      },
      %Mutation{
        id: "lease_root_check_ok",
        rfc_mutation: "root conjunct never fails (two-port lease gate)",
        module: AshA2A.Authority.TwoPortGate,
        function: :root_failed?,
        arity: 3,
        clauses: :all,
        operator: {:replace_body, "false."},
        guard:
          "TwoPortGate root_failed?/3 conjunct (b): the lease's root_digest must " <>
            "equal the command's RDFC-1.0 root (recomputed via CanonicalGraph when " <>
            "rdf_state is carried; opaque compare of the carried graph_digest " <>
            "otherwise) or the mask carries 0x2 (:lease_root_mismatch)",
        killers: ["CHI-TWO-PORT"]
      },
      %Mutation{
        id: "lease_clock_check_ok",
        rfc_mutation: "clock conjunct never fails (two-port lease gate)",
        module: AshA2A.Authority.TwoPortGate,
        function: :clock_failed?,
        arity: 3,
        clauses: :all,
        operator: {:replace_body, "false."},
        guard:
          "TwoPortGate clock_failed?/3 conjunct (c): the hybrid clock window " <>
            "(same-VM monotonic [T_start, T_exp]; cross-VM wall " <>
            "[not_before, expires_at]) must contain the captured clock or the " <>
            "mask carries 0x4 (:lease_expired)",
        killers: ["CHI-TWO-PORT"]
      },
      %Mutation{
        id: "lease_signature_check_ok",
        rfc_mutation: "signature conjunct never fails (two-port lease gate)",
        module: AshA2A.Authority.TwoPortGate,
        function: :signature_failed?,
        arity: 2,
        clauses: :all,
        operator: {:replace_body, "false."},
        guard:
          "TwoPortGate signature_failed?/2 conjunct (d): the lease's Ed25519 " <>
            "signature must verify under the authorizing authority's public key " <>
            "(fail closed on missing key or signature) or the mask carries 0x8 " <>
            "(:lease_signature_invalid)",
        killers: ["CHI-TWO-PORT"]
      }
    ] ++ security_gate_entries()
  end

  # Security-gate mutants (appended: numbering is append-only, §136). Each
  # entry names the Chicago killer family AND, in `description`, the ExUnit
  # court file(s) that must go red when the mutant is live. A Chicago killer
  # not compiled in this subject leaves the entry `:blocked` loudly.
  defp security_gate_entries do
    [
      # Owner scope: a task is visible/actionable only to its recorded owner.
      %Mutation{
        id: "owner_scope_owned_by_true",
        rfc_mutation: "return true from owner-scope check",
        module: AshA2A.Transport.Runtime,
        function: :owned_by?,
        arity: 2,
        clauses: :all,
        operator: {:replace_body, "true."},
        guard:
          "Transport.Runtime.owned_by?/2 owner + tenant scope (foreign task reads as -32001)",
        killers: ["SA2A-TRANSPORT"],
        description:
          "court: test/ash_a2a_v1_owner_scope_test.exs, " <>
            "test/ash_a2a/protocol/list_tasks_owner_scope_test.exs"
      },
      # Forged identity: every caller collapses to one principal key, so the
      # owner comparison passes for any caller; the forged-identity tests
      # must observe the cross-principal access.
      %Mutation{
        id: "forged_identity_principal_collapse",
        rfc_mutation: "trust forged identity (principal key ignores verified identity)",
        module: AshA2A.Transport.Principal,
        function: :from_metadata,
        arity: 1,
        clauses: {:clause, 1},
        operator: {:replace_body, "<<\"sub:forged\">>."},
        guard:
          "Transport.Principal.from_metadata/1 derives the owner key only from the " <>
            "transport-bound a2a.auth identity",
        killers: ["SA2A-TRANSPORT"],
        description:
          "court: test/ash_a2a_v1_owner_scope_test.exs, " <>
            "test/ash_a2a/transport/transport_court_test.exs, " <>
            "test/auth_oidc_apikey_surface_test.exs"
      },
      # :strict boot refusals.
      %Mutation{
        id: "strict_violations_empty",
        rfc_mutation: "skip :strict boot refusals (violation list always empty)",
        module: AshA2A.SecurityProfile.Boot,
        function: :violations,
        arity: 2,
        clauses: {:arg_literal, 1, :strict},
        operator: {:replace_body, "[]."},
        guard: "SecurityProfile.Boot.violations/2 :strict refusal set",
        killers: ["CHI-FRESH"],
        description: "court: test/ash_a2a/security_profile/security_profile_test.exs"
      },
      %Mutation{
        id: "strict_enforce_ok",
        rfc_mutation: "skip :strict boot enforcement",
        module: AshA2A.SecurityProfile.Boot,
        function: :enforce!,
        arity: 2,
        clauses: {:arg_literal, 1, :strict},
        operator: {:replace_body, "ok."},
        guard: "SecurityProfile.Boot.enforce!(:strict, snapshot) raises SecurityPreflight.Error",
        killers: ["CHI-FRESH"],
        description: "court: test/ash_a2a/security_profile/security_profile_test.exs"
      },
      %Mutation{
        id: "strict_boot_check_swallowed",
        rfc_mutation: "swallow receipt-store boot_check failure at boot",
        module: AshA2A.SecurityProfile.Boot,
        function: :boot_check!,
        arity: 1,
        clauses: :all,
        operator: {:replace_body, "ok."},
        guard:
          "SecurityProfile.Boot.boot_check!/1 raises :receipt_store_boot_check_failed " <>
            "under :strict / production",
        killers: ["CHI-FRESH", "CHI-RECEIPT"],
        description: "court: test/ash_a2a/security_profile/security_profile_test.exs"
      },
      # authority_policy.
      %Mutation{
        id: "authority_policy_legacy_unflagged",
        rfc_mutation: "accept legacy :transport_verified_grants_capability authority policy",
        module: AshA2A.Authority.SecurityPreflight,
        function: :legacy_policy_violation,
        arity: 0,
        clauses: :all,
        operator: {:replace_body, "nil."},
        guard:
          "SecurityPreflight legacy_policy_violation/0 (:legacy_authority_policy_unacknowledged)",
        killers: ["SA2A-AUTH"],
        description: "court: test/ash_a2a/authority/security_preflight_test.exs"
      },
      %Mutation{
        id: "authority_policy_legacy_allowed",
        rfc_mutation: "allow legacy authority policy under :strict without acknowledgement",
        module: AshA2A.Authority.SecurityPreflight,
        function: :legacy_policy_allowed?,
        arity: 0,
        clauses: :all,
        operator: {:replace_body, "true."},
        guard:
          "SecurityPreflight.legacy_policy_allowed?/0 requires :allow_legacy_authority_policy " <>
            "ack in strict mode (:legacy_authority_policy_refused)",
        killers: ["SA2A-AUTH"],
        description:
          "court: test/ash_a2a/authority/security_preflight_test.exs, " <>
            "test/ash_a2a/authzen/authority_policy_test.exs"
      },
      %Mutation{
        id: "authority_policy_strict_forbidden_dropped",
        rfc_mutation: "drop :strict refusal of :transport_verified_grants_capability",
        module: AshA2A.SecurityProfile.Boot,
        function: :violations,
        arity: 2,
        clauses: {:arg_literal, 1, :strict},
        operator: {:replace_body, "[]."},
        guard: "Boot.violations/2 :transport_verified_policy_forbidden",
        killers: ["SA2A-AUTH", "CHI-FRESH"],
        description: "court: test/ash_a2a/security_profile/security_profile_test.exs"
      },
      # ReceiptStore.boot_check.
      %Mutation{
        id: "receipt_store_boot_check_ok",
        rfc_mutation: "ReceiptStore.boot_check always passes",
        module: AshA2A.ReceiptStore,
        function: :boot_check,
        arity: 1,
        clauses: :all,
        operator: {:replace_body, "ok."},
        guard:
          "ReceiptStore.boot_check/1 fail-closed durability rules " <>
            "(:non_durable_outbox_dir, :receipt_store_not_configured, ...)",
        killers: ["CHI-RECEIPT"],
        description: "court: test/ash_a2a/receipt_store/boot_check_test.exs"
      },
      %Mutation{
        id: "receipt_store_boot_decision_ok",
        rfc_mutation: "ReceiptStore boot decision table always admits",
        module: AshA2A.ReceiptStore,
        function: :boot_decision,
        arity: 7,
        clauses: :all,
        operator: {:replace_body, "ok."},
        guard: "ReceiptStore.boot_decision/7 production/durable-path decision table",
        killers: ["CHI-RECEIPT"],
        description: "court: test/ash_a2a/receipt_store/boot_check_test.exs"
      }
    ]
  end

  @doc """
  Security gates the catalog must cover: `{gate, module, function, arity}`.
  `test/ash_a2a_security_mutation_witness_test.exs` asserts each has an entry.
  """
  @spec security_gates() :: [{atom(), module(), atom(), non_neg_integer()}]
  def security_gates do
    [
      {:owner_scope, AshA2A.Transport.Runtime, :owned_by?, 2},
      {:forged_identity, AshA2A.Transport.Principal, :from_metadata, 1},
      {:strict_boot_violations, AshA2A.SecurityProfile.Boot, :violations, 2},
      {:strict_boot_enforce, AshA2A.SecurityProfile.Boot, :enforce!, 2},
      {:strict_boot_check, AshA2A.SecurityProfile.Boot, :boot_check!, 1},
      {:authority_policy_legacy, AshA2A.Authority.SecurityPreflight, :legacy_policy_violation, 0},
      {:authority_policy_allowed, AshA2A.Authority.SecurityPreflight, :legacy_policy_allowed?, 0},
      {:receipt_store_boot_check, AshA2A.ReceiptStore, :boot_check, 1},
      {:receipt_store_boot_decision, AshA2A.ReceiptStore, :boot_decision, 7}
    ]
  end

  @doc "`[{court_falsifier_id, mutation}]` -- append-only numbering."
  @spec numbered() :: [{String.t(), Mutation.t()}]
  def numbered do
    entries()
    |> Enum.with_index(1)
    |> Enum.map(fn {m, i} ->
      {"SA2A-MUTATION-" <> String.pad_leading(Integer.to_string(i), 3, "0"), m}
    end)
  end

  @spec ids() :: [String.t()]
  def ids, do: Enum.map(entries(), & &1.id)

  @spec fetch(String.t()) :: {:ok, Mutation.t()} | :error
  def fetch(id) do
    case Enum.find(entries(), &(&1.id == id)) do
      nil -> :error
      m -> {:ok, m}
    end
  end

  @spec fetch!(String.t()) :: Mutation.t()
  def fetch!(id) do
    case fetch(id) do
      {:ok, m} -> m
      :error -> raise ArgumentError, "unknown mutation #{inspect(id)}; known: #{inspect(ids())}"
    end
  end

  @doc """
  Static resolution of every entry without loading anything: whether the
  target builds a mutant and which killer courts exist in this subject.
  """
  @spec resolution(keyword()) :: [map()]
  def resolution(opts \\ []) do
    for m <- entries() do
      target =
        case Mutation.prepare(m) do
          {:ok, plan} -> %{status: :resolvable, clauses_mutated: plan.clauses_mutated}
          {:error, refusal} -> %{status: :blocked, code: refusal.code, detail: refusal.detail}
        end

      killers =
        case Mutation.killer_courts(m, opts) do
          {:ok, courts, missing} -> %{resolved: Enum.map(courts, & &1.id()), missing: missing}
          {:error, refusal} -> %{resolved: [], missing: m.killers, code: refusal.code}
        end

      %{
        id: m.id,
        target: Mutation.target(m),
        rfc_mutation: m.rfc_mutation,
        target_status: target,
        killers: killers
      }
    end
  end
end
