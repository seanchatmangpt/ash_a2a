# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Chicago.Courts.HiltWorkOrder do
  @moduledoc """
  Gate 1 -- HILT two-port graph-digest integrity (v26.10.1-loop lane A1).

  Evidence question: does a HILT work order that carries `graph_digest`
  checkpoint evidence actually pin that digest against the executing
  command's `semantic_subject.graph_digest` at admission -- so a re-pointed
  or substituted semantic graph cannot ride a still-valid work-order
  identity into claim, receipt preparation or DO?

  Every attack runs against real collaborators: the real
  `AshA2A.Hilt.WorkOrder` admission chain, the real `AshA2A.CommandBus`
  with a real `AshA2A.ReceiptStore.Memory`, a real uniquely-named
  `AshA2A.Authority.Broker.InMemory`, and the real MutationHarness Ledger
  (an Ash ETS resource with one `:change` skill).

    * CHI-HILT-001 -- unit attack on `admit_command/2`: a bound command whose
      `semantic_subject.graph_digest` disagrees with the order's carried
      `graph_digest` must be refused `:stale_graph_identity`. Killed only
      when the refusal names the checkpoint.
    * CHI-HILT-002 -- e2e attack: the same disagreeing pair driven through
      the real `AshA2A.CommandBus.run/4` (opts `work_order:`) must be
      refused before claim: no receipt minted, no `brce.claim`, no
      actuation of the Ledger.
    * CHI-HILT-003 -- positive control (§100): the agreeing pair is admitted.
    * CHI-HILT-004 -- positive control (§100): a missing digest on either
      port (order nil / subject nil) skips the checkpoint -- the boundary
      discriminates rather than refusing every order.
    * CHI-HILT-005 -- positive control (§100): `for_command!/3` carries the
      command subject's `graph_digest` by default and an explicit
      `opts[:graph_digest]` overrides the carry.

  Attempt evidence comes from telemetry the deciding boundary emits
  (`[:ash_a2a, :command_bus, :work_order]` for the e2e stimulus; the
  stimulus bracket `chicago.stimulus.start` for the in-process admission
  stimuli), never from this court.
  """

  use AshA2A.Chicago.Court

  alias AshA2A.Chicago.{Context, Falsifier, Result}
  alias AshA2A.Chicago.Fixtures.MutationHarness, as: H
  alias AshA2A.Chicago.Ocel.Mapping
  alias AshA2A.Command
  alias AshA2A.Hilt.WorkOrder

  @court "CHI-HILT"
  @boundary "AshA2A.Hilt.WorkOrder.admit_command/2 checkpoint_graph_digest/2, " <>
              "before CommandBus claim / prepare / DO"
  @sections ["§5", "§6", "§32", "§100", "§119", "§120", "§126"]

  @impl true
  def id, do: @court

  @impl true
  def title, do: "Gate 1 -- HILT two-port graph-digest integrity"

  @impl true
  def gate, do: 1

  @impl true
  def profile, do: :core

  @impl true
  def rfc_sections, do: @sections

  # --- declarations (§11) ------------------------------------------------------

  @impl true
  def falsifiers do
    [
      neg("001",
        invariant:
          "A carried work-order graph_digest that disagrees with the executing " <>
            "command's semantic_subject.graph_digest is a stale graph identity, refused " <>
            "at admission",
        stimulus:
          "WorkOrder.for_command!/3 with an explicit divergent graph_digest, bind_command/2, " <>
            "admit_command/2 over the bound command",
        boundary: @boundary,
        forbidden_outcome:
          "the disagreeing pair is admitted (:ok from admit_command/2); the stimulus then " <>
            "raises inside the bracket, so the independent consumer observes it as " <>
            "chicago.stimulus.stop outcome=raised",
        attempt_evidence:
          "the real admission chain ran for the disagreeing pair (the stimulus returned)",
        survival_evidence:
          ":ok, or a refusal naming any clause other than the graph checkpoint " <>
            "(:stale_graph_identity absent)",
        guard:
          "Hilt.WorkOrder.checkpoint_graph_digest/2 (precedent " <>
            "Planning.Preflight.work_order_bound/2: both present and disagreeing -> refuse; " <>
            "either absent -> skip)",
        failure_class: :identity_failure,
        attempt_predicate: {:observed, "chicago.stimulus.start"},
        outcome_predicate: {:observed, "chicago.stimulus.stop", %{"outcome" => "raised"}}
      ),
      neg("002",
        invariant:
          "The same stale-graph pair driven through the real CommandBus is refused before " <>
            "claim: no receipt is minted and no actuation happens",
        stimulus:
          "CommandBus.run/4 (opts work_order:) of the MutationHarness Ledger.create with a " <>
            "real authority, over a real ReceiptStore.Memory and a real InMemory broker",
        boundary: "AshA2A.CommandBus.run/4 hilt_work_order/2 before claim_receipt/3",
        forbidden_outcome:
          "a receipt claim / actuation of Ledger.create for the stale-graph command",
        attempt_evidence: "hilt.work_order (the CommandBus work-order boundary decided)",
        survival_evidence:
          "brce.claim observed, dispatch/actuation of Ledger.create, or the stimulus label " <>
            "visible to an independent Ash.read!",
        guard: "CommandBus.run/4 hilt_work_order/2 gates on WorkOrder.admit_command/2 :ok",
        failure_class: :identity_failure,
        attempt_predicate: {:observed, "hilt.work_order"},
        outcome_predicate:
          {:any,
           [
             {:observed, "hilt.work_order", %{"outcome" => "verified"}},
             {:observed, "brce.claim"},
             {:observed, "brce.actuate.start"}
           ]}
      ),
      pos("003",
        invariant:
          "The agreeing pair is admitted: the checkpoint discriminates rather than " <>
            "refusing every carried digest (§100)",
        stimulus:
          "WorkOrder.for_command!/3 carrying the subject's own graph_digest, bind_command/2, " <>
            "admit_command/2",
        boundary: @boundary,
        attempt_evidence: "the real admission chain ran for the agreeing pair",
        survival_evidence: "admit_command/2 returned :ok",
        attempt_predicate: {:observed, "chicago.stimulus.start"},
        outcome_predicate: {:observed, "chicago.stimulus.stop", %{"outcome" => "returned"}}
      ),
      pos("004",
        invariant:
          "A missing digest on either port skips the checkpoint: an order without " <>
            "graph_digest and a subject without a graph digest are both admitted (§100)",
        stimulus:
          "admit_command/2 over an order with graph_digest: nil and over a subject built " <>
            "without a graph digest; both :ok",
        boundary: @boundary,
        attempt_evidence: "the real admission chain ran for the skip cases",
        survival_evidence: "either skip case refused",
        attempt_predicate: {:observed, "chicago.stimulus.start"},
        outcome_predicate: {:observed, "chicago.stimulus.stop", %{"outcome" => "returned"}}
      ),
      pos("005",
        invariant:
          "for_command!/3 carries the command subject's graph_digest by default and an " <>
            "explicit opts[:graph_digest] overrides the carry (carry-by-default, not " <>
            "identity-by-default)",
        stimulus:
          "for_command!/3 without graph_digest over a bound subject (carried), and with an " <>
            "explicit divergent graph_digest (override)",
        boundary: "AshA2A.Hilt.WorkOrder.for_command!/3",
        attempt_evidence: "both for_command!/3 stimuli ran and returned",
        survival_evidence:
          "the carried value is not the subject's graph_digest, or the override is ignored",
        attempt_predicate: {:observed, "chicago.stimulus.start"},
        outcome_predicate: {:observed, "chicago.stimulus.stop", %{"outcome" => "returned"}}
      )
    ]
  end

  defp neg(n, fields) do
    Falsifier.new!(
      [
        id: "#{@court}-#{n}",
        court_id: @court,
        kind: :negative,
        rfc_sections: @sections
      ]
      |> Keyword.merge(fields)
    )
  end

  defp pos(n, fields),
    do:
      Falsifier.new!(
        [id: "#{@court}-#{n}", court_id: @court, kind: :positive_control]
        |> Keyword.merge(fields)
      )

  # --- OCEL mappings (§17) -----------------------------------------------------

  @impl true
  def ocel_mappings do
    [
      Mapping.new!(
        event: [:ash_a2a, :command_bus, :work_order],
        activity: "hilt.work_order",
        source: __MODULE__,
        objects: fn _m, meta ->
          [
            {"command", meta[:command_id], "command"},
            {"capability", meta[:capability_id], "capability"},
            {"principal", meta[:principal_id], "principal"}
          ]
        end,
        attributes: fn _m, meta -> Map.take(meta, [:outcome, :code]) end
      )
    ]
  end

  # --- execution ---------------------------------------------------------------

  @impl true
  def run(%Context{} = ctx) do
    f = Map.new(falsifiers(), &{&1.id, &1})
    at = fn n -> Map.fetch!(f, "#{@court}-#{n}") end

    [
      guarded(f["#{@court}-001"], fn -> unit_attack(ctx, at.("001")) end),
      guarded(f["#{@court}-002"], fn -> e2e_attack(ctx, at.("002")) end),
      guarded(f["#{@court}-003"], fn -> agree_control(ctx, at.("003")) end),
      guarded(f["#{@court}-004"], fn -> skip_controls(ctx, at.("004")) end),
      guarded(f["#{@court}-005"], fn -> carry_control(ctx, at.("005")) end)
    ]
  end

  # One broken edge must not take the other falsifiers with it (§129-§130):
  # a raise becomes UNKNOWN for that falsifier only, never a pass.
  defp guarded(%Falsifier{} = f, fun) do
    fun.()
  rescue
    exception ->
      Result.unknown(f, "raised: " <> Exception.format(:error, exception, __STACKTRACE__))
  end

  # --- shared real-collaborator builders ---------------------------------------

  @ga "sha256:" <> String.duplicate("a", 64)
  @gb "sha256:" <> String.duplicate("b", 64)
  @gc "sha256:" <> String.duplicate("c", 64)
  @gd "sha256:" <> String.duplicate("d", 64)

  defp subject(graph_digest) do
    {:ok, subject} =
      AshA2A.SemanticSubject.new(
        graph_digest: graph_digest,
        projection_digest: @gb,
        manufacturer_digest: @gc,
        ephemeral?: false
      )

    subject
  end

  # A real Ledger command carrying task + semantic-subject identity, so
  # WorkOrder.for_command!/3 can bind it. `authority` opts in to the full
  # e2e path (Ledger.create is a :change skill).
  defp ledger_command(label, graph_digest, authority) do
    Command.new(H.capability(),
      command_id: H.unique("chi-hilt"),
      agent_id: "chi-hilt-agent",
      principal_id: H.principal(),
      task_id: H.unique("chi-hilt-task"),
      authority: authority,
      semantic_subject: subject(graph_digest),
      input: %{label: label},
      metadata: %{candidate_digest: "sha256:chi-hilt-candidate"}
    )
  end

  # graph_digest: :carry (default) omits the key entirely to exercise
  # carry-by-default; any other value is passed through explicitly.
  # Unit-level falsifiers use :observe (no authority needed at admission);
  # the e2e falsifier uses :change/:do so the mutant path can really actuate.
  defp order_for(command, opts \\ []) do
    graph_opt =
      case Keyword.fetch(opts, :graph_digest) do
        {:ok, :carry} -> []
        {:ok, value} -> [graph_digest: value]
        :error -> []
      end

    consequence = Keyword.get(opts, :consequence, :observe)
    ceiling = if consequence == :change, do: :do, else: :observe

    WorkOrder.for_command!(
      command,
      consequence,
      [
        work_order_id: H.unique("chi-hilt-wo"),
        observation_bounds: %{resources: ["ledger"]},
        action_bounds: %{actions: [command.capability_id]},
        authority_ceiling: ceiling,
        process_evidence: %{ocel_required: true},
        falsifier: %{refuse_on: [:stale_graph_identity]},
        metadata: %{}
      ] ++ graph_opt
    )
  end

  # --- falsifier bodies --------------------------------------------------------

  # CHI-HILT-001
  defp unit_attack(ctx, f) do
    command = ledger_command(H.unique("chi-hilt-unit"), @ga, nil)
    order = order_for(command, graph_digest: @gd)
    bound = WorkOrder.bind_command(order, command)

    # The checkpoint has no SUT telemetry of its own; the forbidden outcome
    # (:ok on a disagreeing pair) is made OCEL-visible by raising inside the
    # stimulus bracket, so the independent consumer reads it from
    # chicago.stimulus.stop outcome=raised.
    reply =
      try do
        Context.stimulus(ctx, f, fn ->
          case WorkOrder.admit_command(order, bound) do
            :ok ->
              raise "forbidden: checkpoint admitted a disagreeing graph-digest pair"

            refusal ->
              refusal
          end
        end)
      rescue
        exception -> {:forbidden_admitted, Exception.message(exception)}
      end

    Result.negative(f,
      attempt_observed?: Context.observed?(ctx, f, "chicago.stimulus.start"),
      forbidden_outcome_observed?: match?({:forbidden_admitted, _}, reply),
      evidence: %{"reply" => inspect(reply)}
    )
  end

  # CHI-HILT-002
  defp e2e_attack(ctx, f) do
    label = H.unique("chi-hilt-e2e")

    H.with_store(fn store ->
      H.with_broker(fn broker ->
        authority = H.authority(H.principal())
        command = ledger_command(label, @ga, authority)
        order = order_for(command, graph_digest: @gd, consequence: :change)
        bound = WorkOrder.bind_command(order, command)

        reply =
          Context.stimulus(ctx, f, fn ->
            H.run(bound, label, store, work_order: order)
          end)

        forbidden? =
          Context.observed?(ctx, f, "brce.claim") or actuated?(ctx, f) or
            label in H.labels() or match?({:ok, %{receipt_id: _}}, reply)

        Result.negative(f,
          attempt_observed?: Context.observed?(ctx, f, "hilt.work_order"),
          forbidden_outcome_observed?: forbidden?,
          evidence: %{
            "label" => label,
            "broker" => inspect(elem(broker, 0)),
            "reply" => reply_summary(reply),
            "labels" => H.labels()
          }
        )
      end)
    end)
  end

  # CHI-HILT-003
  defp agree_control(ctx, f) do
    command = ledger_command(H.unique("chi-hilt-agree"), @ga, nil)
    order = order_for(command)
    bound = WorkOrder.bind_command(order, command)

    reply = Context.stimulus(ctx, f, fn -> WorkOrder.admit_command(order, bound) end)

    Result.positive(f,
      attempt_observed?: Context.observed?(ctx, f, "chicago.stimulus.start"),
      expected_outcome_observed?: reply == :ok,
      evidence: %{"reply" => inspect(reply)}
    )
  end

  # CHI-HILT-004
  defp skip_controls(ctx, f) do
    nil_order_command = ledger_command(H.unique("chi-hilt-skip-a"), @ga, nil)
    nil_order = order_for(nil_order_command, graph_digest: nil)

    raw_subject = %AshA2A.SemanticSubject{
      graph_digest: nil,
      projection_digest: @gb,
      manufacturer_digest: @gc,
      ephemeral?: false
    }

    nil_subject_command =
      Command.new(H.capability(),
        command_id: H.unique("chi-hilt-skip-b"),
        agent_id: "chi-hilt-agent",
        principal_id: H.principal(),
        task_id: H.unique("chi-hilt-task-b"),
        semantic_subject: raw_subject,
        input: %{label: H.unique("chi-hilt-skip-b")},
        metadata: %{candidate_digest: "sha256:chi-hilt-candidate"}
      )

    nil_subject_order = order_for(nil_subject_command)

    reply =
      Context.stimulus(ctx, f, fn ->
        {
          WorkOrder.admit_command(
            nil_order,
            WorkOrder.bind_command(nil_order, nil_order_command)
          ),
          WorkOrder.admit_command(
            nil_subject_order,
            WorkOrder.bind_command(nil_subject_order, nil_subject_command)
          )
        }
      end)

    {nil_order_reply, nil_subject_reply} = reply

    Result.positive(f,
      attempt_observed?: Context.observed?(ctx, f, "chicago.stimulus.start"),
      expected_outcome_observed?: nil_order_reply == :ok and nil_subject_reply == :ok,
      evidence: %{
        "nil_order" => inspect(nil_order_reply),
        "nil_subject" => inspect(nil_subject_reply)
      }
    )
  end

  # CHI-HILT-005
  defp carry_control(ctx, f) do
    reply =
      Context.stimulus(ctx, f, fn ->
        carried = ledger_command(H.unique("chi-hilt-carry-a"), @ga, nil)
        override = ledger_command(H.unique("chi-hilt-carry-b"), @ga, nil)

        {order_for(carried).graph_digest, order_for(override, graph_digest: @gd).graph_digest}
      end)

    {carried, override} = reply

    Result.positive(f,
      attempt_observed?: Context.observed?(ctx, f, "chicago.stimulus.start"),
      expected_outcome_observed?: carried == @ga and override == @gd,
      evidence: %{"carried" => inspect(carried), "override" => inspect(override)}
    )
  end

  # --- shared helpers ----------------------------------------------------------

  defp actuated?(ctx, f),
    do:
      Context.observed?(ctx, f, "brce.actuate.start") or
        Context.observed?(ctx, f, "dispatch.start")

  defp reply_summary({:ok, receipt}), do: {:ok, receipt.receipt_id}
  defp reply_summary({:error, reason}), do: {:error, inspect(reason)}
  defp reply_summary(other), do: inspect(other)
end
