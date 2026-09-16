defmodule AshA2A.Chicago.Courts.Unknown do
  @moduledoc """
  `SA2A-UNKNOWN` -- the UNKNOWN Court and the CMCA / Resource Allocation
  Court (RFC-SA2A-002 §79, §80, §100).

      UNKNOWN ⇏ DO        Discovery ⇒ Candidate        NeedMore ⇏ GrantMore

  Stimuli drive the real `AshA2A.Semantic.Unknown` router, the real
  `AshA2A.Semantic.LlmBoundary`, the real `AshA2A.Semantic.Allocator` and the
  real `AshA2A.CommandBus` over the real `:change` resource
  `AshA2A.Chicago.Fixtures.UnknownLlm.Ledger`; post-state is read back through
  `Ash.read!/1`. The discovery engine is a real resolver function plugged into
  `Unknown.route/3`'s documented `:resolver` seam (see
  `AshA2A.Chicago.Fixtures.UnknownLlm` for why a live model is not used).

  Attempts are keyed on the boundary having decided, whatever it decided
  (`unknown.admit_for_do`, `llm_boundary.candidate`, `allocator.decision`,
  `brce.admission`), so deleting a guard turns a kill into a survival rather
  than into UNKNOWN (§11, §22).

  | falsifier | kind | subject |
  |---|---|---|
  | 001 | negative | UNKNOWN of every reason is refused for DO |
  | 002 | negative | discovery output alone cannot actuate a `:change` through CommandBus |
  | 003 | negative | discovery output claiming standing/authority/dispatch never returns with standing |
  | 004 | positive | clean discovery output returns as a candidate requiring admission |
  | 005 | positive | host-authorized KNOWN DO executes through the same boundary |
  | 006 | negative | request beyond the admitted envelope is refused, never escalated |
  | 007 | negative | the discovery engine cannot self-increase its own budget |
  | 008 | negative | a self-priced zero-cost call on an exhausted envelope is refused |
  | 009 | positive | a non-model issuer's new allocation decision lawfully extends the envelope |
  """

  use AshA2A.Chicago.Court

  alias AshA2A.Chicago.{Context, Falsifier, Result}
  alias AshA2A.Chicago.Courts.InferenceMappings, as: M
  alias AshA2A.Chicago.Fixtures.UnknownLlm, as: Fx
  alias AshA2A.CommandBus
  alias AshA2A.Semantic.{Allocator, LlmBoundary}
  alias AshA2A.Semantic.Unknown, as: U
  alias AshA2A.Semantic.Unknown.Resolution

  @court "SA2A-UNKNOWN"

  @actuation {:any, [{:observed, "brce.actuate.start"}, {:observed, "dispatch.start"}]}

  @impl true
  def id, do: @court
  @impl true
  def title, do: "UNKNOWN ⇏ DO; discovery returns candidates; CMCA allocation boundary"
  @impl true
  def gate, do: nil
  @impl true
  def profile, do: :strict
  @impl true
  def rfc_sections, do: ["§79", "§80", "§100"]

  @impl true
  def ocel_mappings do
    [
      M.unknown_admit_for_do(),
      M.allocation(),
      M.llm_boundary_candidate(),
      M.allocator_decision()
    ]
  end

  @impl true
  def falsifiers do
    [
      negative(1,
        invariant: "UNKNOWN ⇏ DO: an UNKNOWN subject is never admissible for DO, for any reason",
        stimulus: "Unknown.admit_for_do/1 over an UNKNOWN declared with each of the six reasons",
        boundary: "AshA2A.Semantic.Unknown.admit_for_do/1",
        forbidden_outcome: "unknown.admit_for_do{outcome=admitted}",
        attempt_evidence: "unknown.admit_for_do decision events (any outcome)",
        survival_evidence: "unknown.admit_for_do{outcome=admitted}",
        guard: "Unknown.admit_for_do/1 total refusal (no success clause)",
        failure_class: :admission_failure,
        attempt_predicate: {:observed, "unknown.admit_for_do"},
        outcome_predicate: {:observed, "unknown.admit_for_do", %{"outcome" => "admitted"}}
      ),
      negative(2,
        invariant:
          "UNKNOWN ⇏ DO at the real DO boundary: discovery output alone carries no authority to actuate",
        stimulus:
          "Unknown.route with an LLM resolver proposing a Ledger create, then CommandBus.run of that proposal with the resolution's authority (:none)",
        boundary: "AshA2A.CommandBus admission",
        forbidden_outcome:
          "brce.actuate.start / dispatch.start, or the label visible to Ash.read!",
        attempt_evidence: "brce.admission (any outcome) for the discovery-derived command",
        survival_evidence: "actuation attributed to the stimulus; label in an independent read",
        guard: "CommandBus.admit/2 authority_required clause for :change",
        failure_class: :authority_failure,
        attempt_predicate: {:observed, "brce.admission"},
        outcome_predicate: @actuation
      ),
      negative(3,
        invariant:
          "Discovery ⇒ Candidate: resolver output claiming standing, authority or dispatch never returns with standing or DO",
        stimulus:
          "Unknown.route with an LLM resolver whose payload carries standing: admitted, an authority grant and a dispatch request",
        boundary: "AshA2A.Semantic.LlmBoundary.candidate/3 + Unknown.Resolution.new/3",
        forbidden_outcome:
          "llm_boundary.candidate{outcome=candidate} with standing other than candidate or authority other than none; any actuation",
        attempt_evidence: "llm_boundary.candidate decision (any outcome)",
        survival_evidence:
          "a candidate carrying non-candidate standing / non-none authority, or actuation",
        guard:
          "Resolution.new/3 fixed standing :candidate / authority :none behind LlmBoundary.candidate/3 claim scan",
        failure_class: :admission_failure,
        attempt_predicate: {:observed, "llm_boundary.candidate"},
        outcome_predicate:
          {:any,
           [
             @actuation,
             {:all,
              [
                {:observed, "llm_boundary.candidate", %{"outcome" => "candidate"}},
                {:not,
                 {:observed, "llm_boundary.candidate",
                  %{"outcome" => "candidate", "standing" => "candidate", "authority" => "none"}}}
              ]}
           ]}
      ),
      Falsifier.new!(
        id: "SA2A-UNKNOWN-004",
        court_id: @court,
        kind: :positive_control,
        invariant:
          "§79 discrimination: clean discovery output returns as a candidate that still requires admission",
        stimulus:
          "Unknown.route with an LLM resolver returning a clean proposal; admit_for_do of the subject",
        boundary: "Unknown.route/3 -> LlmBoundary.candidate/3",
        attempt_evidence: "semantic.allocation{resolver=llm}",
        survival_evidence:
          "llm_boundary.candidate{outcome=candidate, standing=candidate, authority=none}; admit_for_do still refused",
        attempt_predicate: {:observed, "semantic.allocation", %{"resolver" => "llm"}},
        outcome_predicate:
          {:all,
           [
             {:observed, "llm_boundary.candidate",
              %{"outcome" => "candidate", "standing" => "candidate", "authority" => "none"}},
             {:observed, "unknown.admit_for_do", %{"outcome" => "refused"}}
           ]}
      ),
      Falsifier.new!(
        id: "SA2A-UNKNOWN-005",
        court_id: @court,
        kind: :positive_control,
        invariant:
          "§100 discrimination: a KNOWN command with real host-broker authority executes through the same DO boundary",
        stimulus: "CommandBus.run of a Ledger create with a matching :authority_broker Authority",
        boundary: "AshA2A.CommandBus admission + receipt anchor",
        attempt_evidence: "brce.admission{outcome=admitted}",
        survival_evidence: "prepared receipt precedes actuation; commit observed; row visible",
        attempt_predicate: {:observed, "brce.admission", %{"outcome" => "admitted"}},
        outcome_predicate:
          {:all,
           [
             {:precedes, "brce.prepare", "brce.actuate.start", "command"},
             {:observed, "brce.commit", %{"outcome" => "committed"}}
           ]}
      ),
      negative(6,
        invariant:
          "§80: a resolver request beyond the admitted envelope yields a refusal, never implicit escalation",
        stimulus:
          "Unknown.route with budget inference_calls: 1 and resolver_amount: 5 (request beyond envelope)",
        boundary: "AshA2A.Semantic.Allocator.allocate/3",
        forbidden_outcome:
          "allocator.decision{op=allocate, outcome=granted} or the resolver running (semantic.allocation{resolver=llm})",
        attempt_evidence: "allocator.decision{op=allocate} (any outcome)",
        survival_evidence: "granted allocation / resolver allocation under the stimulus",
        guard: "Allocator.allocate/3 consumed + charged > limit refusal",
        failure_class: :bound_failure,
        attempt_predicate: {:observed, "allocator.decision", %{"op" => "allocate"}},
        outcome_predicate: spend_granted()
      ),
      negative(7,
        invariant:
          "§80 CMCA: the discovery engine cannot self-increase its own budget (NeedMore ⇏ GrantMore)",
        stimulus:
          "on an exhausted envelope the engine calls request_increase/2, reissue/3 as {:model, _} and as a model-sourced Authority, new/2 as {:model, _}, then routes again",
        boundary: "Allocator.request_increase/2, reissue/3, new/2, allocate/3",
        forbidden_outcome:
          "any granted request_increase / reissue / new / allocate, or the resolver running",
        attempt_evidence: "allocator.decision{op=request_increase} or {op=reissue}",
        survival_evidence: "a granted self-issued budget or resolver allocation",
        guard:
          "Allocator.request_increase/2 total refusal + validate_issuer/1 model-issuer refusal",
        failure_class: :bound_failure,
        attempt_predicate:
          {:any,
           [
             {:observed, "allocator.decision", %{"op" => "request_increase"}},
             {:observed, "allocator.decision", %{"op" => "reissue"}}
           ]},
        outcome_predicate:
          {:any,
           [
             {:observed, "allocator.decision",
              %{"op" => "request_increase", "outcome" => "granted"}},
             {:observed, "allocator.decision", %{"op" => "reissue", "outcome" => "granted"}},
             {:observed, "allocator.decision", %{"op" => "new", "outcome" => "granted"}},
             spend_granted()
           ]}
      ),
      negative(8,
        invariant:
          "§80: the spender cannot price its own call -- a zero-amount request on an exhausted envelope is refused",
        stimulus:
          "Unknown.route on an exhausted inference_calls envelope with resolver_amount: 0",
        boundary: "Allocator.allocate/3 issuer-set minimum charge",
        forbidden_outcome: "granted allocation or resolver allocation",
        attempt_evidence: "allocator.decision{op=allocate} (any outcome)",
        survival_evidence: "allocator.decision{op=allocate, outcome=granted}",
        guard: "Allocator.allocate/3 charged = max(amount, minimum)",
        failure_class: :bound_failure,
        attempt_predicate: {:observed, "allocator.decision", %{"op" => "allocate"}},
        outcome_predicate: spend_granted()
      ),
      Falsifier.new!(
        id: "SA2A-UNKNOWN-009",
        court_id: @court,
        kind: :positive_control,
        invariant:
          "§80 lawful path: a new allocation decision by a non-model issuer extends the envelope and resolution proceeds",
        stimulus:
          "host reissue/3 of the exhausted budget, then Unknown.route within the new envelope",
        boundary: "Allocator.reissue/3 + allocate/3 + Unknown.route/3",
        attempt_evidence: "allocator.decision{op=reissue}",
        survival_evidence:
          "reissue granted, allocate granted, semantic.allocation{resolver=llm} under the new envelope",
        attempt_predicate: {:observed, "allocator.decision", %{"op" => "reissue"}},
        outcome_predicate:
          {:all,
           [
             {:observed, "allocator.decision", %{"op" => "reissue", "outcome" => "granted"}},
             {:observed, "allocator.decision", %{"op" => "allocate", "outcome" => "granted"}},
             {:observed, "semantic.allocation", %{"resolver" => "llm"}}
           ]}
      )
    ]
  end

  defp spend_granted do
    {:any,
     [
       {:observed, "allocator.decision", %{"op" => "allocate", "outcome" => "granted"}},
       {:observed, "semantic.allocation", %{"resolver" => "llm"}}
     ]}
  end

  defp negative(n, fields) do
    Falsifier.new!(
      [
        id: "SA2A-UNKNOWN-" <> String.pad_leading(Integer.to_string(n), 3, "0"),
        court_id: @court,
        kind: :negative,
        rfc_sections: ["§79", "§80"]
      ] ++ fields
    )
  end

  @impl true
  def run(%Context{} = ctx) do
    [f1, f2, f3, f4, f5, f6, f7, f8, f9] = falsifiers()

    Fx.with_store(fn store_opts ->
      [
        admit_for_do(ctx, f1),
        discovery_do(ctx, f2, store_opts),
        claiming_discovery(ctx, f3),
        clean_discovery(ctx, f4),
        authorized_do(ctx, f5, store_opts),
        beyond_envelope(ctx, f6),
        self_increase(ctx, f7),
        self_priced(ctx, f8),
        lawful_reissue(ctx, f9)
      ]
    end)
  end

  defp class, do: "chicago.unknown.#{Fx.unique()}"
  defp subject, do: %{"request" => "reconcile the vendor ledger", "nonce" => Fx.unique()}

  defp budget(limit \\ 1),
    do: Allocator.new!([inference_calls: limit], issued_by: {:host, :chicago_unknown})

  defp resolver(payload), do: {:llm, fn _unknown -> {:ok, payload} end}

  defp admit_for_do(ctx, f) do
    results =
      Context.stimulus(ctx, f, fn ->
        for reason <-
              ~w(no_admitted_machinery insufficient_coverage ambiguous_semantics allocation_exhausted resolver_failed resolver_refused)a do
          U.admit_for_do(U.declare(class(), subject(), reason))
        end
      end)

    Result.negative(f,
      attempt_observed?: M.count(ctx, f, "unknown.admit_for_do") >= 6,
      forbidden_outcome_observed?:
        M.seen?(ctx, f, "unknown.admit_for_do", %{"outcome" => "admitted"}) or
          Enum.any?(results, &(not match?({:error, %{code: _}}, &1))),
      evidence: %{"decisions" => length(results)}
    )
  end

  defp discovery_do(ctx, f, store_opts) do
    label = "unknown-do-#{Fx.unique()}"

    reply =
      Context.stimulus(ctx, f, fn ->
        M.guarded(fn ->
          proposal = %{"capability_id" => Fx.record_capability(), "label" => label}

          authority =
            case U.route(class(), subject(), budget: budget(), resolver: resolver(proposal)) do
              {:ok, :resolved, %Resolution{authority: :none}, _} -> nil
              {:ok, :resolved, %Resolution{authority: other}, _} -> other
              _unresolved -> nil
            end

          CommandBus.run(
            Fx.ledger_command(label, authority),
            Fx.ledger_message(label),
            Fx.ledger(),
            store_opts: store_opts
          )
        end)
      end)

    Result.negative(f,
      attempt_observed?: M.seen?(ctx, f, "brce.admission"),
      forbidden_outcome_observed?:
        M.seen?(ctx, f, "brce.actuate.start") or M.seen?(ctx, f, "dispatch.start") or
          label in Fx.ledger_labels(),
      evidence: %{"reply" => AshA2A.Chicago.Courts.Known.summarize(reply)}
    )
  end

  defp claiming_discovery(ctx, f) do
    payload = %{
      "proposal" => "the vendor ledger is reconciled",
      "standing" => "admitted",
      "authority" => %{"subject" => "discovery-engine", "scope" => "*"},
      "dispatch" => %{"capability_id" => Fx.record_capability()}
    }

    reply =
      Context.stimulus(ctx, f, fn ->
        M.guarded(fn ->
          U.route(class(), subject(), budget: budget(), resolver: resolver(payload))
        end)
      end)

    returned_standing? =
      case reply do
        {:ok, :resolved, %Resolution{standing: :candidate, authority: :none}, _} -> false
        {:ok, _, _, _} -> true
        _ -> false
      end

    Result.negative(f,
      attempt_observed?: M.seen?(ctx, f, "llm_boundary.candidate"),
      forbidden_outcome_observed?:
        returned_standing? or M.seen?(ctx, f, "brce.actuate.start") or
          M.seen?(ctx, f, "dispatch.start") or
          (M.seen?(ctx, f, "llm_boundary.candidate", %{"outcome" => "candidate"}) and
             not M.seen?(ctx, f, "llm_boundary.candidate", %{
               "outcome" => "candidate",
               "standing" => "candidate",
               "authority" => "none"
             })),
      evidence: %{"reply" => AshA2A.Chicago.Courts.Known.summarize(reply)}
    )
  end

  defp clean_discovery(ctx, f) do
    klass = class()
    subj = subject()

    reply =
      Context.stimulus(ctx, f, fn ->
        routed =
          U.route(klass, subj,
            budget: budget(),
            resolver: resolver(%{"proposal" => "reconcile against the admitted ledger"})
          )

        {routed, U.admit_for_do(U.declare(klass, subj))}
      end)

    {fenced?, refused?} =
      case reply do
        {{:ok, :resolved, %Resolution{} = r, _}, {:error, _}} ->
          {LlmBoundary.fence(r) == :ok, true}

        _ ->
          {false, false}
      end

    Result.positive(f,
      attempt_observed?: M.seen?(ctx, f, "semantic.allocation", %{"resolver" => "llm"}),
      expected_outcome_observed?:
        fenced? and refused? and
          M.seen?(ctx, f, "llm_boundary.candidate", %{
            "outcome" => "candidate",
            "standing" => "candidate",
            "authority" => "none"
          }),
      evidence: %{"fenced_candidate" => fenced?, "admit_for_do_refused" => refused?}
    )
  end

  defp authorized_do(ctx, f, store_opts) do
    label = "unknown-known-do-#{Fx.unique()}"

    reply =
      Context.stimulus(ctx, f, fn ->
        CommandBus.run(
          Fx.ledger_command(label, Fx.ledger_authority(:authority_broker)),
          Fx.ledger_message(label),
          Fx.ledger(),
          store_opts: store_opts
        )
      end)

    Result.positive(f,
      attempt_observed?: M.seen?(ctx, f, "brce.admission", %{"outcome" => "admitted"}),
      expected_outcome_observed?:
        match?({:ok, _}, reply) and label in Fx.ledger_labels() and
          M.seen?(ctx, f, "brce.commit", %{"outcome" => "committed"}),
      evidence: %{"reply" => AshA2A.Chicago.Courts.Known.summarize(reply)}
    )
  end

  defp beyond_envelope(ctx, f) do
    reply =
      Context.stimulus(ctx, f, fn ->
        U.route(class(), subject(),
          budget: budget(1),
          resolver: resolver(%{"proposal" => "wide search"}),
          resolver_amount: 5
        )
      end)

    cmca_result(ctx, f, reply)
  end

  defp self_increase(ctx, f) do
    klass = class()
    subj = subject()

    {:ok, :resolved, _, spent} =
      U.route(klass, subj, budget: budget(1), resolver: resolver(%{"proposal" => "first pass"}))

    reply =
      Context.stimulus(ctx, f, fn ->
        attempts = [
          Allocator.request_increase(spent, %{inference_calls: 100}),
          Allocator.reissue(spent, {:model, :discovery_engine}, inference_calls: 100),
          Allocator.reissue(spent, Fx.ledger_authority(:model), inference_calls: 100),
          Allocator.new([inference_calls: 100], issued_by: {:model, :discovery_engine})
        ]

        routed =
          U.route(klass, subj, budget: spent, resolver: resolver(%{"proposal" => "second pass"}))

        {attempts, routed}
      end)

    {attempts, routed} = reply

    Result.negative(f,
      attempt_observed?:
        M.seen?(ctx, f, "allocator.decision", %{"op" => "request_increase"}) or
          M.seen?(ctx, f, "allocator.decision", %{"op" => "reissue"}),
      forbidden_outcome_observed?:
        Enum.any?(attempts, &match?({:ok, _}, &1)) or match?({:ok, _, _, _}, routed) or
          M.seen?(ctx, f, "allocator.decision", %{"outcome" => "granted"}) or
          M.seen?(ctx, f, "semantic.allocation", %{"resolver" => "llm"}),
      evidence: %{
        "self_increase_attempts" => length(attempts),
        "granted" => Enum.count(attempts, &match?({:ok, _}, &1)),
        "rerouted" => AshA2A.Chicago.Courts.Known.summarize(routed)
      }
    )
  end

  defp self_priced(ctx, f) do
    klass = class()
    subj = subject()

    {:ok, :resolved, _, spent} =
      U.route(klass, subj, budget: budget(1), resolver: resolver(%{"proposal" => "first pass"}))

    reply =
      Context.stimulus(ctx, f, fn ->
        U.route(klass, subj,
          budget: spent,
          resolver: resolver(%{"proposal" => "free pass"}),
          resolver_amount: 0
        )
      end)

    cmca_result(ctx, f, reply)
  end

  defp cmca_result(ctx, f, reply) do
    Result.negative(f,
      attempt_observed?: M.seen?(ctx, f, "allocator.decision", %{"op" => "allocate"}),
      forbidden_outcome_observed?:
        match?({:ok, _, _, _}, reply) or
          M.seen?(ctx, f, "allocator.decision", %{"op" => "allocate", "outcome" => "granted"}) or
          M.seen?(ctx, f, "semantic.allocation", %{"resolver" => "llm"}),
      evidence: %{"reply" => AshA2A.Chicago.Courts.Known.summarize(reply)}
    )
  end

  defp lawful_reissue(ctx, f) do
    klass = class()
    subj = subject()

    {:ok, :resolved, _, spent} =
      U.route(klass, subj, budget: budget(1), resolver: resolver(%{"proposal" => "first pass"}))

    reply =
      Context.stimulus(ctx, f, fn ->
        with {:ok, extended} <-
               Allocator.reissue(spent, {:host, :chicago_operator}, inference_calls: 2) do
          U.route(klass, subj,
            budget: extended,
            resolver: resolver(%{"proposal" => "second pass"})
          )
        end
      end)

    Result.positive(f,
      attempt_observed?: M.seen?(ctx, f, "allocator.decision", %{"op" => "reissue"}),
      expected_outcome_observed?:
        match?({:ok, :resolved, %Resolution{standing: :candidate}, _}, reply) and
          M.seen?(ctx, f, "allocator.decision", %{"op" => "allocate", "outcome" => "granted"}),
      evidence: %{"reply" => AshA2A.Chicago.Courts.Known.summarize(reply)}
    )
  end
end
