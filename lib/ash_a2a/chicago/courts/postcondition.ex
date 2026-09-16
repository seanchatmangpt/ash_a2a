defmodule AshA2A.Chicago.Courts.Postcondition do
  @moduledoc """
  Gate 8 -- Independent Postcondition Observation, and the Independent
  Post-State Court (RFC-SA2A-002 §8, §39, §73, §100).

  Invariant: the actuator is never the sole attestor of its own success.

      ActuatorReport ≠ PostconditionObservation

  Every stimulus drives the real `AshA2A.CommandBus.run/4` over the real
  `AshA2A.Chicago.Fixtures.Postcondition.Ledger` ETS resource with a real
  `AshA2A.ReceiptStore.Memory`, and declares its postcondition through the
  real `AshA2A.Postcondition` contract. Nothing is replaced by a double:
  lying and divergent actuators are real Ash actions whose *behaviour* is
  dishonest.

  Evidence per stimulus, all read after the stimulus returns:

    * attempt -- the actuator's success claim at the real DO boundary
      (`brce.actuate.stop outcome=ok`) plus the court's own post-state
      reader (`Fixtures.Postcondition.stored_values/1`, a full scan distinct
      from the verifier's filtered query) proving the lie/divergence is real
    * outcome -- the receipt read back from the store by command id (not the
      `run/4` return value) and the `[:ash_a2a, :command_bus, :postcondition]`
      boundary event (`brce.postcondition`), re-derived from the durable OCEL
      artifact by the independent consumer

  Falsifiers:

    * `CHI-POST-001` false-positive actuator report accepted
    * `CHI-POST-002` divergent actuator report accepted
    * `CHI-POST-003` verifier that only reads the actuator's return object
      accepted / not detected as non-independent
    * `CHI-POST-004` missing postcondition treated as verified
    * `CHI-POST-005` positive control: honest actuator's real change verified
    * `CHI-POST-006` negative vacuity control: an always-refusing verifier
      must fail the `CHI-POST-005` positive-control predicate
  """

  use AshA2A.Chicago.Court

  alias AshA2A.{Authority, Command, CommandBus, Identity, Postcondition, Receipt}
  alias AshA2A.Chicago.{Context, Falsifier, Result}
  alias AshA2A.Chicago.Fixtures.Postcondition, as: Fixtures
  alias AshA2A.Chicago.Fixtures.Postcondition.{AlwaysRefusingVerifier, LedgerVerifier}
  alias AshA2A.Chicago.Fixtures.Postcondition.{Ledger, ReportReadingVerifier}
  alias AshA2A.Chicago.Ocel.Mapping

  @court "CHI-POST"
  @reported "X"
  @sections ["§8", "§39", "§73"]

  @impl true
  def id, do: @court
  @impl true
  def title, do: "Independent postcondition observation / independent post-state"
  @impl true
  def gate, do: 8
  @impl true
  def profile, do: :do
  @impl true
  def rfc_sections, do: ["§8", "§39", "§73", "§100"]

  @impl true
  def ocel_mappings do
    [
      Mapping.new!(
        event: [:ash_a2a, :command_bus, :postcondition],
        activity: "brce.postcondition",
        source: __MODULE__,
        objects: fn _m, meta ->
          [
            {"command", meta[:command_id], "command"},
            {"capability", meta[:capability_id], "capability"},
            {"principal", meta[:principal_id], "principal"},
            {"execution", meta[:execution_id], "execution"},
            {"receipt", meta[:receipt_id], "receipt"},
            {"postcondition", meta[:postcondition_id], "postcondition"}
          ]
        end,
        attributes: fn _m, meta ->
          Map.take(meta, [:outcome, :reason, :independent, :verifier, :consequence])
        end
      )
    ]
  end

  # --- predicates (questions over the observed process, never a trace) -----

  defp success_claimed, do: {:observed, "brce.actuate.stop", %{"outcome" => "ok"}}

  defp report_accepted do
    {:any,
     [
       {:observed, "brce.postcondition", %{"outcome" => "verified"}},
       {:observed, "receipt.committed", %{"status" => "completed"}}
     ]}
  end

  defp independently_verified_completed do
    {:all,
     [
       {:observed, "brce.postcondition", %{"outcome" => "verified", "independent" => "true"}},
       {:observed, "receipt.committed", %{"status" => "completed"}},
       {:precedes, "brce.actuate.stop", "brce.postcondition", "command"}
     ]}
  end

  @impl true
  def falsifiers do
    [
      Falsifier.new!(
        id: "CHI-POST-001",
        court_id: @court,
        kind: :negative,
        invariant:
          "An actuator that reports success without changing state never acquires verified or completed standing (§39)",
        stimulus:
          "CommandBus.run/4 of Ledger.lying_write (reports %{key, value} success, writes nothing) with an independent LedgerVerifier postcondition",
        boundary: "AshA2A.CommandBus postcondition observation (AshA2A.Postcondition.evaluate/3)",
        forbidden_outcome:
          "postcondition recorded verified, or the receipt committed with status completed",
        attempt_evidence:
          "brce.actuate.stop outcome=ok for the stimulus AND the court's own full-scan reader finds no ledger row for the key",
        survival_evidence:
          "brce.postcondition outcome=verified or receipt.committed status=completed in OCEL; receipt read back from the store by command id",
        guard:
          "AshA2A.Postcondition.evaluate/3 verifier verdict + apply_to_receipt/2 (:contradicted -> :postcondition_contradicted) + consequence_result/2",
        failure_class: :postcondition_failure,
        rfc_sections: @sections,
        attempt_predicate: success_claimed(),
        outcome_predicate: report_accepted()
      ),
      Falsifier.new!(
        id: "CHI-POST-002",
        court_id: @court,
        kind: :negative,
        invariant:
          "An actuator that reports one state while writing another never acquires verified or completed standing (§39)",
        stimulus:
          "CommandBus.run/4 of Ledger.divergent_write (writes value<>\":diverged\", reports value) with an independent LedgerVerifier postcondition",
        boundary: "AshA2A.CommandBus postcondition observation (AshA2A.Postcondition.evaluate/3)",
        forbidden_outcome:
          "postcondition recorded verified, or the receipt committed with status completed",
        attempt_evidence:
          "brce.actuate.stop outcome=ok AND the receipt's recorded report says X while the court's own reader finds only X:diverged",
        survival_evidence:
          "brce.postcondition outcome=verified or receipt.committed status=completed in OCEL; receipt read back from the store",
        guard:
          "AshA2A.Postcondition.evaluate/3 verifier verdict + apply_to_receipt/2 (:contradicted -> :postcondition_contradicted)",
        failure_class: :postcondition_failure,
        rfc_sections: @sections,
        attempt_predicate: success_claimed(),
        outcome_predicate: report_accepted()
      ),
      Falsifier.new!(
        id: "CHI-POST-003",
        court_id: @court,
        kind: :negative,
        invariant:
          "A verifier that reads only the actuator's return object is detected as non-independent and never yields verified (§73)",
        stimulus:
          "CommandBus.run/4 of Ledger.lying_write with a ReportReadingVerifier postcondition (verifies against the actuator's report)",
        boundary: "AshA2A.Postcondition counterfactual-report independence check",
        forbidden_outcome:
          "postcondition recorded verified, or recorded without independent=false (non-independence undetected)",
        attempt_evidence:
          "brce.actuate.stop outcome=ok AND brce.postcondition evaluated with verifier=ReportReadingVerifier AND the court's reader finds no row",
        survival_evidence:
          "brce.postcondition outcome=verified, or no brce.postcondition carrying independent=false; receipt metadata read back from the store",
        guard:
          "AshA2A.Postcondition judge/3: a verdict that changes when the actuator's report is replaced by a counterfactual failure report (post-state fixed) is :unverified / :verifier_not_independent",
        failure_class: :postcondition_failure,
        rfc_sections: @sections,
        attempt_predicate:
          {:all,
           [
             success_claimed(),
             {:observed, "brce.postcondition", %{"verifier" => inspect(ReportReadingVerifier)}}
           ]},
        outcome_predicate:
          {:any,
           [
             {:observed, "brce.postcondition", %{"outcome" => "verified"}},
             {:not_observed, "brce.postcondition", %{"independent" => "false"}}
           ]}
      ),
      Falsifier.new!(
        id: "CHI-POST-004",
        court_id: @court,
        kind: :negative,
        invariant:
          "A consequence-bearing command with no declared postcondition is recorded unverified, never verified (§39)",
        stimulus: "CommandBus.run/4 of Ledger.lying_write with no :postcondition option",
        boundary: "AshA2A.CommandBus postcondition observation (AshA2A.Postcondition.evaluate/3)",
        forbidden_outcome:
          "postcondition recorded verified, or the missing postcondition not positively recorded as unverified/no_postcondition_declared",
        attempt_evidence:
          "brce.actuate.stop outcome=ok for a :change command with no postcondition AND the court's reader finds no row",
        survival_evidence:
          "brce.postcondition outcome=verified, or no brce.postcondition outcome=unverified reason=no_postcondition_declared; receipt metadata read back",
        guard:
          "AshA2A.Postcondition.evaluate(nil, probe, _) -> :unverified / :no_postcondition_declared for consequence-bearing commands",
        failure_class: :postcondition_failure,
        rfc_sections: @sections,
        attempt_predicate: success_claimed(),
        outcome_predicate:
          {:any,
           [
             {:observed, "brce.postcondition", %{"outcome" => "verified"}},
             {:not_observed, "brce.postcondition",
              %{"outcome" => "unverified", "reason" => "no_postcondition_declared"}}
           ]}
      ),
      Falsifier.new!(
        id: "CHI-POST-005",
        court_id: @court,
        kind: :positive_control,
        invariant:
          "An honest actuator's real state change is independently verified and keeps completed standing (§73, §100)",
        stimulus:
          "CommandBus.run/4 of Ledger.honest_write (Ash create) with an independent LedgerVerifier postcondition",
        boundary: "AshA2A.CommandBus postcondition observation",
        attempt_evidence: "brce.actuate.stop outcome=ok for the stimulus",
        survival_evidence:
          "brce.postcondition verified independent=true after actuation, receipt.committed completed, and the court's reader finds the written value",
        failure_class: :postcondition_failure,
        rfc_sections: ["§39", "§73", "§100"],
        attempt_predicate: success_claimed(),
        outcome_predicate: independently_verified_completed()
      ),
      Falsifier.new!(
        id: "CHI-POST-006",
        court_id: @court,
        kind: :negative,
        invariant:
          "Positive-control standing cannot be earned by a verifier that refuses everything: the CHI-POST-005 predicate discriminates (§100)",
        stimulus:
          "CommandBus.run/4 of Ledger.honest_write (a real state change) with an AlwaysRefusingVerifier postcondition",
        boundary: "AshA2A.CommandBus postcondition observation + the CHI-POST-005 predicate",
        forbidden_outcome:
          "the CHI-POST-005 expected outcome (independent verified + completed) observed under an always-refusing verifier",
        attempt_evidence:
          "brce.actuate.stop outcome=ok AND brce.postcondition evaluated AND the court's reader finds the genuinely written value",
        survival_evidence:
          "CHI-POST-005's outcome predicate holds over this stimulus's OCEL scope; receipt read back from the store",
        guard:
          "CommandBus honours the verifier's refusal (contradicted is never recorded verified) and CHI-POST-005's predicate requires an independent verified verdict",
        failure_class: :postcondition_failure,
        rfc_sections: ["§22", "§100", "§129"],
        attempt_predicate: {:all, [success_claimed(), {:observed, "brce.postcondition"}]},
        outcome_predicate: independently_verified_completed()
      )
    ]
  end

  @impl true
  def run(%Context{} = ctx) do
    [f1, f2, f3, f4, f5, f6] = falsifiers()

    with_store(fn store_opts ->
      [
        false_positive(ctx, f1, store_opts),
        divergent(ctx, f2, store_opts),
        report_reading(ctx, f3, store_opts),
        missing(ctx, f4, store_opts),
        honest(ctx, f5, store_opts),
        always_refusing(ctx, f6, store_opts)
      ]
    end)
  end

  # --- falsifier bodies --------------------------------------------------------

  defp false_positive(ctx, f, store_opts) do
    s = drive(ctx, f, :lying_write, LedgerVerifier, store_opts)

    Result.negative(f,
      attempt_observed?: claimed?(ctx, f) and s.stored == [],
      forbidden_outcome_observed?: accepted?(ctx, f, s.receipt),
      evidence: evidence(s)
    )
  end

  defp divergent(ctx, f, store_opts) do
    s = drive(ctx, f, :divergent_write, LedgerVerifier, store_opts)
    diverged? = s.stored == [@reported <> ":diverged"] and reported_value(s.receipt) == @reported

    Result.negative(f,
      attempt_observed?: claimed?(ctx, f) and diverged?,
      forbidden_outcome_observed?: accepted?(ctx, f, s.receipt),
      evidence: evidence(s)
    )
  end

  defp report_reading(ctx, f, store_opts) do
    s = drive(ctx, f, :lying_write, ReportReadingVerifier, store_opts)

    consulted? =
      observed?(ctx, f, "brce.postcondition", %{"verifier" => inspect(ReportReadingVerifier)})

    undetected =
      case postcondition(s.receipt) do
        :unknown -> :unknown
        nil -> true
        pc -> pc.status == :verified or pc.independent != false
      end

    Result.negative(f,
      attempt_observed?: claimed?(ctx, f) and consulted? and s.stored == [],
      forbidden_outcome_observed?:
        either(observed?(ctx, f, "brce.postcondition", %{"outcome" => "verified"}), undetected),
      evidence: evidence(s)
    )
  end

  defp missing(ctx, f, store_opts) do
    s = drive(ctx, f, :lying_write, nil, store_opts)

    treated_verified =
      case postcondition(s.receipt) do
        :unknown -> :unknown
        nil -> true
        pc -> pc.status != :unverified or pc.reason != :no_postcondition_declared
      end

    Result.negative(f,
      attempt_observed?: claimed?(ctx, f) and s.stored == [],
      forbidden_outcome_observed?:
        either(
          observed?(ctx, f, "brce.postcondition", %{"outcome" => "verified"}),
          treated_verified
        ),
      evidence: evidence(s)
    )
  end

  defp honest(ctx, f, store_opts) do
    s = drive(ctx, f, :honest_write, LedgerVerifier, store_opts)

    Result.positive(f,
      attempt_observed?: claimed?(ctx, f),
      expected_outcome_observed?: verified_completed?(ctx, f, s),
      evidence: evidence(s)
    )
  end

  defp always_refusing(ctx, f, store_opts) do
    s = drive(ctx, f, :honest_write, AlwaysRefusingVerifier, store_opts)

    Result.negative(f,
      attempt_observed?:
        claimed?(ctx, f) and s.stored == [@reported] and
          Context.observed?(ctx, f, "brce.postcondition"),
      forbidden_outcome_observed?: verified_completed?(ctx, f, s),
      evidence: evidence(s)
    )
  end

  # --- stimulus + independent readers ------------------------------------------

  defp drive(ctx, f, action, verifier, store_opts) do
    key = "#{f.id}-#{System.unique_integer([:positive])}"
    capability = Fixtures.capability(action)
    principal = Identity.principal("chicago-post-subject")

    command =
      Command.new(capability,
        command_id: "chicago-post-" <> key,
        agent_id: "chicago-post-agent",
        principal_id: principal,
        authority: Authority.new(principal, capability, token_id: "tok-" <> key),
        input: %{key: key, value: @reported}
      )

    message = A2A.Message.new_user([A2A.Part.Data.new(%{"key" => key, "value" => @reported})])

    postcondition =
      verifier &&
        %Postcondition{
          id: "ledger.value_persisted",
          verifier: verifier,
          expect: %{key: key, value: @reported}
        }

    opts =
      [store_opts: store_opts] ++ if(postcondition, do: [postcondition: postcondition], else: [])

    reply = Context.stimulus(ctx, f, fn -> CommandBus.run(command, message, Ledger, opts) end)

    receipt =
      case AshA2A.ReceiptStore.Memory.fetch(command.command_id, store_opts) do
        {:ok, %Receipt{} = receipt} -> receipt
        :error -> nil
      end

    %{key: key, reply: reply, receipt: receipt, stored: Fixtures.stored_values(key)}
  end

  defp with_store(fun) do
    name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    {:ok, pid} = AshA2A.ReceiptStore.Memory.start_link(name: name)

    try do
      fun.(name: name)
    after
      if Process.alive?(pid), do: GenServer.stop(pid)
    end
  end

  defp claimed?(ctx, f), do: observed?(ctx, f, "brce.actuate.stop", %{"outcome" => "ok"})

  # Tri-state OR: any positive observation is decisive; otherwise UNKNOWN
  # stays UNKNOWN (§130) rather than collapsing to "not observed".
  defp either(true, _), do: true
  defp either(_, true), do: true
  defp either(:unknown, _), do: :unknown
  defp either(_, :unknown), do: :unknown
  defp either(false, false), do: false

  defp observed?(ctx, f, activity, attrs) do
    ctx
    |> Context.observed(f)
    |> Enum.any?(fn record ->
      record.activity == activity and
        Enum.all?(attrs, fn {k, v} -> to_string(Map.get(record.attributes, k)) == v end)
    end)
  end

  # Report accepted = verified postcondition or completed standing, judged on
  # the receipt read back from the store (not run/4's return) and the event.
  defp accepted?(_ctx, _f, nil), do: :unknown

  defp accepted?(ctx, f, %Receipt{} = receipt) do
    receipt.status == :completed or
      match?(%{status: :verified}, postcondition(receipt)) or
      observed?(ctx, f, "brce.postcondition", %{"outcome" => "verified"})
  end

  defp verified_completed?(_ctx, _f, %{receipt: nil}), do: :unknown

  defp verified_completed?(ctx, f, %{receipt: %Receipt{}} = s) do
    s.stored == [@reported] and s.receipt.status == :completed and
      match?(%{status: :verified, independent: true}, postcondition(s.receipt)) and
      observed?(ctx, f, "brce.postcondition", %{"outcome" => "verified", "independent" => "true"})
  end

  defp postcondition(nil), do: :unknown
  defp postcondition(%Receipt{metadata: metadata}), do: Map.get(metadata || %{}, :postcondition)

  defp reported_value(%Receipt{reply: {:reply, parts}}) when is_list(parts) do
    Enum.find_value(parts, fn
      %A2A.Part.Data{data: data} when is_map(data) -> data[:value] || data["value"]
      _ -> nil
    end)
  end

  defp reported_value(_receipt), do: nil

  defp evidence(s) do
    %{
      "key" => s.key,
      "reported" => @reported,
      "court_reader_stored_values" => s.stored,
      "reply" => reply_summary(s.reply),
      "receipt_status" => s.receipt && Atom.to_string(s.receipt.status),
      "receipt_postcondition" => s.receipt && postcondition(s.receipt)
    }
  end

  defp reply_summary({:ok, %Receipt{status: status}}), do: "ok:#{status}"
  defp reply_summary({:error, %{code: code}}), do: "error:#{code}"
  defp reply_summary(other), do: inspect(other, limit: 5)
end
