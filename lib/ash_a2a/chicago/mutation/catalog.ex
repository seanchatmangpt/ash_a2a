defmodule AshA2A.Chicago.Mutation.Catalog do
  @moduledoc """
  RFC-SA2A-002 §97 security mutations mapped onto the real functions of this
  subject that enforce each guard.

  Every entry names an exact `Module.function/arity` (public or private),
  the clauses it replaces and the mutant body, plus the court-id families
  expected to kill it. Killer ids follow RFC-SA2A-002 Appendix B; a court
  that is not compiled in this subject leaves the entry `:blocked` (another
  qualification slice supplies it), and a target that does not resolve --
  e.g. `AshA2A.Semantic.RootManifest` before RFC-SA2A-001 S20 lands -- is
  `:blocked` with the resolver's reason. Nothing is silently skipped.

  `CHI-MUTGUARD` (`AshA2A.Chicago.Fixtures.MutationHarness.GuardCourt`) is a
  non-discoverable reference court over the real `AshA2A.CommandBus`,
  `AshA2A.Authority` and `AshA2A.Authority.Broker.InMemory` so the harness has
  a real killer for the BRCE/authority guards in every subject.

  | § 97 mutation                          | target                                              |
  |----------------------------------------|-----------------------------------------------------|
  | return true from authority check       | `AshA2A.CommandBus.admit/2`, `AshA2A.Authority.admits?/2` |
  | ignore expiry                          | `AshA2A.Authority.expired?/1`                        |
  | ignore revocation                      | `AshA2A.Authority.Broker.InMemory.standing?/2`       |
  | remove receipt preparation             | `AshA2A.CommandBus.prepare_receipt_anchor/3`         |
  | accept unsupported profile             | `AshA2A.Semantic.Envelope.validate_profile/1`        |
  | trust sender standing                  | `AshA2A.Semantic.Envelope.reject_declared_standing/1`|
  | skip SHACL                             | `AshA2A.Semantic.AdmissionPipeline.run_stage/4` (`:shacl`) |
  | skip graph-global falsifiers           | `AdmissionPipeline.run_stage/4` (`:sparql_falsifiers`), `AshA2A.Semantic.FalsifierSuite.admit/1` |
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
      %Mutation{
        id: "ignore_revocation",
        rfc_mutation: "ignore revocation",
        module: AshA2A.Authority.Broker.InMemory,
        function: :standing?,
        arity: 2,
        clauses: :all,
        operator:
          {:replace_body,
           """
           case maps:find(ChicagoArg2, maps:get(issued, ChicagoArg1)) of
             {ok, ChicagoEntry} -> not 'past?'(maps:get(expires_at, ChicagoEntry));
             error -> false
           end.
           """},
        guard: "Broker.InMemory.standing?/2 revoked-set membership",
        killers: ["SA2A-AUTH", @guard_court]
      },
      %Mutation{
        id: "remove_receipt_preparation",
        rfc_mutation: "remove receipt preparation",
        module: AshA2A.CommandBus,
        function: :prepare_receipt_anchor,
        arity: 3,
        clauses: :all,
        operator: {:replace_body, "{ok, nil}."},
        guard: "CommandBus.prepare_receipt_anchor/3 pending receipt anchor before DO",
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
      %Mutation{
        id: "skip_graph_global_falsifier_gate",
        rfc_mutation: "skip graph-global falsifiers (S18.2 admission gate)",
        module: AshA2A.Semantic.FalsifierSuite,
        function: :admit,
        arity: 1,
        clauses: :all,
        operator: {:replace_body, "ok."},
        guard: "FalsifierSuite.admit/1 mandatory falsifier gate (:refused_falsifier)",
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
             {replay, _} -> {execute, 'Elixir.AshA2A.Identity':execution('Elixir.Ash.UUIDv7':generate())};
             ChicagoOther -> ChicagoOther
           end.
           """},
        guard: "CommandBus replay branch: a committed receipt is returned, never re-actuated",
        killers: ["CHI-REPLAY", "CHI-BRCE", @guard_court]
      }
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
