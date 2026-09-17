defmodule AshA2A.Chicago.Courts.Brce do
  @moduledoc """
  `CHI-BRCE` -- Gate 7 Sole DO Boundary / Zero Unreceipted Actuation, the BRCE
  Court and the Prepared Receipt Court (RFC-SA2A-002 §38, §68, §69).

      Attempted(a) ⇒ PreparedReceipt(a)

  The court attempts real consequence (`:change` and `:external_do`) against
  the real `AshA2A.CommandBus`, `AshA2A.Dispatcher`, `AshA2A.Agent`,
  `AshA2A.Planning`, `AshA2A.Planning.RequestRouter` and
  `AshA2A.Semantic.GraphLawBridge`, over the real
  `AshA2A.Chicago.Fixtures.Brce` ETS resources, and reads post-state back
  through `Ash.read!/1`. Faults change the environment around real
  components only (§10): the receipt journal directory is pointed under a
  regular file, and a real receipt-store process is stopped.

  ## Bypass surfaces attempted (§68)

  | falsifier | surface |
  |---|---|
  | 001, 002 | direct internal mutation path: `Dispatcher.dispatch/5` of `:change` / `:external_do` |
  | 003 | authorized request, receipt anchor journal unavailable (§69 storage failure) |
  | 004 | authorized request, primary receipt store process stopped |
  | 005 | planner: HDDL goal-facts synthesis + planning admission of a plan naming DO capabilities |
  | 006 | knowledge hook: real GraphLaw `run_hooks/3` over an actuation-requesting event |
  | 007 | semantic A2A request through the generated agent handler |
  | 008 | A2A task handler (supervised `A2A.Agent` process) of a granted `:change` |
  | 009 | generated artifact: compiled `use AshA2A.Agent` `handle_message/2` of a granted `:external_do` |
  | 010 | replay: identical command resubmitted |
  | 011 | duplicate idempotency identity with different input |

  Positive controls (§100): 012 prepared authorized DO executes (control for
  003/004), 013 dispatcher lets `:observe` through (control for 001/002), 014
  a fresh identity executes exactly once (control for 010/011), 015 the A2A
  handler's granted DO executes receipted (control for 008/009).

  ## Core OCEL question

  "No DO before durable preparation" is asked of every actuation observed
  under a stimulus, at both the BRCE boundary (`brce.actuate.start`) and the
  dispatcher's actuation point (`dispatch.actuate`):

      {:all, [{:observed, act}, {:not, {:precedes, "brce.prepare", act, "command"}}]}

  strengthened to also require the preparation to share the *receipt*
  object: a `brce.prepare` that failed carries no receipt id, so it can never
  satisfy precedence for a later actuation.
  """

  use AshA2A.Chicago.Court

  alias AshA2A.{Authority, CommandBus, Dispatcher, Identity, Planning}
  alias AshA2A.Authority.Broker.InMemory
  alias AshA2A.Chicago.{Context, Falsifier, Result}
  alias AshA2A.Chicago.Fixtures.Brce, as: Fx
  alias AshA2A.Chicago.Fixtures.Brce.{Ledger, LedgerAgent, Planned, PlannedAgent}
  alias AshA2A.Chicago.Ocel.Mapping
  alias AshA2A.Planning.RequestRouter
  alias AshA2A.Semantic.GraphLawBridge

  @court "CHI-BRCE"

  @actuations ["brce.actuate.start", "dispatch.actuate"]

  @unreceipted_actuation {:any,
                          for act <- @actuations do
                            {:all,
                             [
                               {:observed, act},
                               {:not,
                                {:all,
                                 [
                                   {:precedes, "brce.prepare", act, "command"},
                                   {:precedes, "brce.prepare", act, "receipt"}
                                 ]}}
                             ]}
                          end}

  @any_actuation {:any,
                  [
                    {:observed, "dispatch.start"},
                    {:observed, "dispatch.actuate"},
                    {:observed, "brce.actuate.start"}
                  ]}

  @receipted_do {:all,
                 [
                   {:observed, "brce.prepare", %{"outcome" => "prepared"}},
                   {:precedes, "brce.prepare", "brce.actuate.start", "command"},
                   {:precedes, "brce.prepare", "dispatch.actuate", "receipt"},
                   {:precedes, "brce.actuate.start", "brce.commit", "command"},
                   {:observed, "brce.commit", %{"outcome" => "committed"}}
                 ]}

  @impl true
  def id, do: @court
  @impl true
  def title, do: "Sole DO boundary / zero unreceipted actuation (BRCE + prepared receipt)"
  @impl true
  def gate, do: 7
  @impl true
  def profile, do: :do
  @impl true
  def rfc_sections, do: ["§38", "§68", "§69", "§100"]

  @impl true
  def ocel_mappings do
    [
      Mapping.new!(
        event: [:ash_a2a, :dispatch, :brce_gate],
        activity: "dispatch.brce_gate",
        source: __MODULE__,
        objects: &dispatch_objects/2,
        attributes: fn _m, meta -> Map.take(meta, [:outcome, :reason, :consequence]) end
      ),
      Mapping.new!(
        event: [:ash_a2a, :dispatch, :actuate],
        activity: "dispatch.actuate",
        source: __MODULE__,
        objects: &dispatch_objects/2,
        attributes: fn _m, meta -> Map.take(meta, [:consequence, :anchored]) end
      ),
      Mapping.new!(
        event: [:ash_a2a, :agent, :dispatch],
        activity: "agent.dispatch",
        source: __MODULE__,
        objects: fn _m, meta ->
          [
            {"skill", meta[:skill_name], "skill"},
            {"resource", meta[:resource_or_domain] && inspect(meta[:resource_or_domain]),
             "resource"}
          ]
        end,
        attributes: fn _m, meta -> Map.take(meta, [:route, :consequence]) end
      ),
      Mapping.new!(
        event: [:ash_a2a, :planning, :admit],
        activity: "planning.admit",
        source: __MODULE__,
        objects: fn _m, meta -> [{"plan_candidate", meta[:fingerprint], "candidate"}] end,
        attributes: fn _m, meta ->
          Map.take(meta, [:outcome, :code, :planner, :standing, :authority])
        end
      ),
      Mapping.new!(
        event: [:ash_a2a, :semantic, :hooks, :run],
        activity: "semantic.hooks.run",
        source: __MODULE__,
        attributes: fn _m, meta -> Map.take(meta, [:outcome, :status, :code, :host]) end
      )
    ]
  end

  defp dispatch_objects(_measurements, meta) do
    [
      {"skill", meta[:skill_name], "skill"},
      {"capability", meta[:capability_id], "capability"},
      {"command", meta[:command_id], "command"},
      {"receipt", meta[:receipt_id], "receipt"}
    ]
  end

  # --- falsifier declarations (§11) -----------------------------------------

  @impl true
  def falsifiers do
    [
      negative(1,
        invariant:
          "Attempted(a) ⇒ PreparedReceipt(a): a :change skill cannot actuate through the dispatcher without a durable prepared receipt",
        stimulus:
          "AshA2A.Dispatcher.dispatch(:record, msg, Ledger) called directly, outside AshA2A.CommandBus",
        boundary: "AshA2A.Dispatcher sole-DO fence (AshA2A.BrceAnchor.admit/2)",
        forbidden_outcome: "Ledger row written / dispatch.actuate with no prior brce.prepare",
        attempt_evidence: "dispatch.start emitted by the real dispatcher for this stimulus",
        survival_evidence:
          "dispatch.actuate or brce.actuate.start not preceded by brce.prepare sharing command and receipt; label visible to Ash.read!",
        guard: "AshA2A.BrceAnchor.admit/2 refusal of an unanchored consequence-bearing skill",
        failure_class: :actuation_failure,
        attempt_predicate: {:observed, "dispatch.start"},
        outcome_predicate: @unreceipted_actuation
      ),
      negative(2,
        invariant: "an :external_do skill cannot actuate through the dispatcher unreceipted",
        stimulus:
          "AshA2A.Dispatcher.dispatch(:transmit, msg, Ledger) called directly, outside AshA2A.CommandBus",
        boundary: "AshA2A.Dispatcher sole-DO fence (AshA2A.BrceAnchor.admit/2)",
        forbidden_outcome: "ExternalEffect row written with no prepared receipt",
        attempt_evidence: "dispatch.start emitted by the real dispatcher for this stimulus",
        survival_evidence:
          "unreceipted dispatch.actuate / brce.actuate.start; effect label visible to Ash.read!",
        guard: "AshA2A.BrceAnchor.admit/2 refusal of an unanchored consequence-bearing skill",
        failure_class: :actuation_failure,
        attempt_predicate: {:observed, "dispatch.start"},
        outcome_predicate: @unreceipted_actuation
      ),
      negative(3,
        invariant:
          "§69: if durable preparation cannot be established, consequence MUST NOT begin",
        stimulus:
          "authorized CommandBus.run of Ledger.record with :receipt_outbox_dir pointed under a regular file (real ENOTDIR)",
        boundary: "AshA2A.CommandBus prepare_receipt_anchor/4 (AshA2A.ReceiptOutbox.append/1)",
        forbidden_outcome: "any actuation or Ledger row after a failed preparation",
        attempt_evidence: "brce.admission admitted and brce.prepare failed for this stimulus",
        survival_evidence:
          "brce.actuate.start, dispatch.start or dispatch.actuate attributed to the stimulus; label visible to Ash.read!",
        guard: "CommandBus.execute_claimed/9 refuse_unanchored_execution branch",
        failure_class: :receipt_failure,
        attempt_predicate:
          {:all,
           [
             {:observed, "brce.admission", %{"outcome" => "admitted"}},
             {:observed, "brce.prepare", %{"outcome" => "failed"}}
           ]},
        outcome_predicate: @any_actuation
      ),
      negative(4,
        invariant: "§38: an authorized request with the receipt store unavailable fails closed",
        stimulus:
          "authorized CommandBus.run of Ledger.record against a real AshA2A.ReceiptStore.Memory process stopped before the request",
        boundary: "AshA2A.CommandBus claim_receipt/3",
        forbidden_outcome: "any actuation or Ledger row without a claimed, prepared receipt",
        attempt_evidence: "brce.admission admitted and brce.claim refused for this stimulus",
        survival_evidence:
          "brce.actuate.start, dispatch.start or dispatch.actuate attributed to the stimulus; label visible to Ash.read!",
        guard: "CommandBus.claim_receipt/3 exit/rescue -> :receipt_store_unavailable refusal",
        failure_class: :receipt_failure,
        attempt_predicate:
          {:all,
           [
             {:observed, "brce.admission", %{"outcome" => "admitted"}},
             {:observed, "brce.claim", %{"outcome" => "refused"}}
           ]},
        outcome_predicate: @any_actuation
      ),
      negative(5,
        invariant:
          "Planner non-authority (§59, §68): a plan naming :change/:external_do capabilities never actuates them",
        stimulus:
          "RequestRouter.route/3 goal-facts synthesis (real hddl_cli) + Planning.from_envelope/3 + Planning.admit/2 of a forged :admitted/:do candidate, all naming Planned.advance/unlock",
        boundary: "AshA2A.Planning admission / AshA2A.Planning.RequestRouter",
        forbidden_outcome: "any dispatch or actuation; advance/unlock rows written",
        attempt_evidence:
          "router.tier_selected facts, planning.admit admitted and planning.admit refused (authority ceiling) for this stimulus",
        survival_evidence:
          "dispatch.start / dispatch.actuate / brce.actuate.start attributed to the stimulus; planned labels visible to Ash.read!",
        guard:
          "AshA2A.Planning has no execution function; candidate_fence/1 refuses non-candidate standing",
        failure_class: :planning_failure,
        attempt_predicate:
          {:all,
           [
             {:observed, "router.tier_selected", %{"tier" => "facts"}},
             {:observed, "planning.admit", %{"outcome" => "admitted"}},
             {:observed, "planning.admit",
              %{"outcome" => "refused", "code" => "planner_authority_ceiling_violated"}}
           ]},
        outcome_predicate: @any_actuation
      ),
      negative(6,
        invariant: "Hooks are intent only, never authority: hook evaluation never actuates",
        stimulus:
          "AshA2A.Semantic.GraphLawBridge.run_hooks/3 (real praxis-graphlaw engine) over a ground-action hook graph and an event requesting Ledger.record",
        boundary: "AshA2A.Semantic.GraphLawBridge knowledge-hook evaluation",
        forbidden_outcome: "any dispatch or actuation; a Ledger row carrying the event label",
        attempt_evidence: "semantic.hooks.run evaluated for this stimulus",
        survival_evidence:
          "dispatch.start / dispatch.actuate / brce.actuate.start attributed to the stimulus; label visible to Ash.read!",
        guard: "no hook -> dispatcher wiring; AshA2A.BrceAnchor.admit/2 for any that appears",
        failure_class: :actuation_failure,
        attempt_predicate: {:observed, "semantic.hooks.run", %{"outcome" => "evaluated"}},
        outcome_predicate: @any_actuation
      ),
      negative(7,
        invariant:
          "A semantic A2A request yields a candidate package, never a DO of the capabilities it plans",
        stimulus:
          "PlannedAgent.call/3 with semantic_request: true and goal_facts whose task_sequence names Planned.advance/unlock",
        boundary: "AshA2A.Agent.__dispatch__/3 semantic route",
        forbidden_outcome: "any dispatch or actuation; advance/unlock rows written",
        attempt_evidence:
          "agent.dispatch route=semantic and router.tier_selected facts for this stimulus",
        survival_evidence:
          "dispatch.start / dispatch.actuate / brce.actuate.start attributed to the stimulus; planned labels visible to Ash.read!",
        guard: "ExecutionPackage standing :candidate / authority :none; no semantic -> DO call",
        failure_class: :planning_failure,
        attempt_predicate:
          {:all,
           [
             {:observed, "agent.dispatch", %{"route" => "semantic"}},
             {:observed, "router.tier_selected", %{"tier" => "facts"}}
           ]},
        outcome_predicate: @any_actuation
      ),
      negative(8,
        invariant:
          "§68 A2A task handler: a consequence-bearing A2A task actuates only after durable preparation",
        stimulus:
          "LedgerAgent.call/3 (real supervised A2A.Agent) of skill record by an authenticated principal holding a real broker grant",
        boundary: "AshA2A.Agent.dispatch_skill/4 -> AshA2A.CommandBus",
        forbidden_outcome: "actuation not preceded by brce.prepare sharing command and receipt",
        attempt_evidence: "agent.dispatch consequence=change for this stimulus",
        survival_evidence:
          "dispatch.actuate / brce.actuate.start without an earlier brce.prepare sharing command and receipt",
        guard: "Agent routes :change/:external_do through CommandBus; BrceAnchor.admit/2",
        failure_class: :actuation_failure,
        attempt_predicate: {:observed, "agent.dispatch", %{"consequence" => "change"}},
        outcome_predicate: @unreceipted_actuation
      ),
      negative(9,
        invariant:
          "§68 generated artifact: the compiled use AshA2A.Agent projection cannot actuate unreceipted",
        stimulus:
          "LedgerAgent.handle_message/2 invoked directly (no A2A runtime) for skill transmit by a granted principal",
        boundary:
          "generated handle_message/2 -> AshA2A.Agent.__dispatch__/3 -> AshA2A.CommandBus",
        forbidden_outcome:
          "external actuation not preceded by brce.prepare sharing command and receipt",
        attempt_evidence: "agent.dispatch consequence=external_do for this stimulus",
        survival_evidence:
          "dispatch.actuate / brce.actuate.start without an earlier brce.prepare sharing command and receipt",
        guard: "Agent routes :external_do through CommandBus; BrceAnchor.admit/2",
        failure_class: :actuation_failure,
        attempt_predicate: {:observed, "agent.dispatch", %{"consequence" => "external_do"}},
        outcome_predicate: @unreceipted_actuation
      ),
      negative(10,
        invariant: "§38/§71: a replayed command never re-actuates",
        stimulus:
          "CommandBus.run of the identical, already-committed Ledger.transmit command (same command_id and fingerprint)",
        boundary: "AshA2A.CommandBus claim_receipt/3 (AshA2A.ReceiptStore.claim/2)",
        forbidden_outcome: "a second actuation / second ExternalEffect row",
        attempt_evidence: "brce.claim outcome=replay for this stimulus",
        survival_evidence:
          "brce.actuate.start or dispatch.actuate attributed to the replay stimulus; effect label count > 1",
        guard: "ReceiptStore.Memory claim/2 {:replay, receipt} branch",
        failure_class: :replay_failure,
        attempt_predicate: {:observed, "brce.claim", %{"outcome" => "replay"}},
        outcome_predicate:
          {:any, [{:observed, "brce.actuate.start"}, {:observed, "dispatch.actuate"}]}
      ),
      negative(11,
        invariant:
          "§38 duplicate idempotency identity: the same command_id with different input never actuates",
        stimulus:
          "CommandBus.run reusing the committed command_id with a different label (different fingerprint)",
        boundary: "AshA2A.CommandBus claim_receipt/3 (AshA2A.ReceiptStore.claim/2)",
        forbidden_outcome: "actuation of the divergent input; its ExternalEffect row",
        attempt_evidence: "brce.claim refused with code command_conflict for this stimulus",
        survival_evidence:
          "brce.actuate.start or dispatch.actuate attributed to the stimulus; divergent label visible to Ash.read!",
        guard: "ReceiptStore.Memory claim/2 :command_conflict branch",
        failure_class: :replay_failure,
        attempt_predicate:
          {:observed, "brce.claim", %{"outcome" => "refused", "code" => "command_conflict"}},
        outcome_predicate:
          {:any, [{:observed, "brce.actuate.start"}, {:observed, "dispatch.actuate"}]}
      ),
      positive(12,
        invariant:
          "§100 unprepared DO blocked / prepared authorized DO executes (control for 003, 004)",
        stimulus:
          "authorized CommandBus.run of Ledger.record with a live receipt store and a writable journal",
        boundary: "AshA2A.CommandBus + AshA2A.BrceAnchor",
        attempt_evidence: "brce.admission admitted for this stimulus",
        survival_evidence:
          "prepare ≺ actuate ≺ commit on the same command; dispatch.actuate after prepare on the same receipt; label visible to Ash.read!",
        attempt_predicate: {:observed, "brce.admission", %{"outcome" => "admitted"}},
        outcome_predicate: @receipted_do
      ),
      positive(13,
        invariant:
          "§100 the dispatcher fence discriminates: an :observe skill dispatched directly still executes (control for 001, 002)",
        stimulus: "AshA2A.Dispatcher.dispatch(:entries, msg, Ledger) called directly",
        boundary: "AshA2A.Dispatcher sole-DO fence (AshA2A.BrceAnchor.admit/2)",
        attempt_evidence: "dispatch.start for this stimulus",
        survival_evidence:
          "dispatch.brce_gate not_required, dispatch.actuate consequence=observe, dispatch.stop reply",
        attempt_predicate: {:observed, "dispatch.start"},
        outcome_predicate:
          {:all,
           [
             {:observed, "dispatch.brce_gate", %{"outcome" => "not_required"}},
             {:observed, "dispatch.actuate", %{"consequence" => "observe"}},
             {:observed, "dispatch.stop", %{"reply_type" => "reply"}}
           ]}
      ),
      positive(14,
        invariant:
          "§100 a fresh command identity executes exactly once, receipted (control for 010, 011)",
        stimulus: "authorized CommandBus.run of a fresh Ledger.transmit command",
        boundary: "AshA2A.CommandBus claim + prepare + commit",
        attempt_evidence: "brce.claim outcome=execute for this stimulus",
        survival_evidence:
          "prepare ≺ actuate ≺ commit on the same command; exactly one ExternalEffect row",
        attempt_predicate: {:observed, "brce.claim", %{"outcome" => "execute"}},
        outcome_predicate: @receipted_do
      ),
      positive(15,
        invariant:
          "§100 the A2A task handler's granted DO executes through BRCE (control for 008, 009)",
        stimulus:
          "LedgerAgent.call/3 (real supervised A2A.Agent) of skill transmit by a granted principal",
        boundary: "AshA2A.Agent -> AshA2A.CommandBus -> AshA2A.Dispatcher",
        attempt_evidence: "agent.dispatch route=command_bus for this stimulus",
        survival_evidence:
          "prepare ≺ actuate ≺ commit on the same command; effect label visible to Ash.read!",
        attempt_predicate: {:observed, "agent.dispatch", %{"route" => "command_bus"}},
        outcome_predicate: @receipted_do
      )
    ]
  end

  defp negative(n, fields), do: declare(n, :negative, fields)
  defp positive(n, fields), do: declare(n, :positive_control, fields)

  defp declare(n, kind, fields) do
    Falsifier.new!(
      [
        id: falsifier_id(n),
        court_id: @court,
        kind: kind,
        rfc_sections: ["§38", "§68", "§69"]
      ] ++ fields
    )
  end

  defp falsifier_id(n), do: @court <> "-" <> String.pad_leading(Integer.to_string(n), 3, "0")

  # --- execution ---------------------------------------------------------------

  @impl true
  def run(%Context{} = ctx) do
    f = Map.new(falsifiers(), &{&1.id, &1})
    get = fn n -> Map.fetch!(f, falsifier_id(n)) end

    direct = [
      direct_dispatch(ctx, get.(1), :record),
      direct_dispatch(ctx, get.(2), :transmit),
      direct_observe(ctx, get.(13))
    ]

    storage = [
      outbox_unavailable(ctx, get.(3)),
      store_stopped(ctx, get.(4)),
      prepared_do(ctx, get.(12))
    ]

    planning = [
      planner(ctx, get.(5)),
      hooks(ctx, get.(6)),
      semantic_request(ctx, get.(7))
    ]

    agent =
      with_granted_broker(fn ->
        [
          agent_call(ctx, get.(8), :negative, "record"),
          generated_handler(ctx, get.(9)),
          agent_call(ctx, get.(15), :positive, "transmit")
        ]
      end)

    identity = replay_family(ctx, get.(14), get.(10), get.(11))

    direct ++ storage ++ planning ++ agent ++ identity
  end

  # 001 / 002
  defp direct_dispatch(ctx, falsifier, skill) do
    label = unique_label("direct-#{skill}")

    reply =
      Context.stimulus(ctx, falsifier, fn ->
        Dispatcher.dispatch(skill, message(%{"label" => label}), Ledger)
      end)

    rows = Fx.consequence_count(label)

    Result.negative(falsifier,
      attempt_observed?: Context.observed?(ctx, falsifier, "dispatch.start"),
      forbidden_outcome_observed?: rows > 0 or unreceipted_actuation?(ctx, falsifier),
      evidence: %{
        "reply" => short(reply),
        "rows_with_label" => rows,
        "gate" => attr_values(ctx, falsifier, "dispatch.brce_gate", "outcome")
      }
    )
  end

  # 013
  defp direct_observe(ctx, falsifier) do
    reply =
      Context.stimulus(ctx, falsifier, fn ->
        Dispatcher.dispatch(:entries, message(%{}), Ledger)
      end)

    Result.positive(falsifier,
      attempt_observed?: Context.observed?(ctx, falsifier, "dispatch.start"),
      expected_outcome_observed?:
        match?({:reply, _}, reply) and
          observed_attrs?(ctx, falsifier, "dispatch.actuate", %{"consequence" => "observe"}),
      evidence: %{"reply_type" => reply |> elem(0) |> to_string()}
    )
  end

  # 003
  defp outbox_unavailable(ctx, falsifier) do
    label = unique_label("outbox-unavailable")

    {reply, blocker} =
      with_outbox_unavailable(ctx, fn blocker ->
        with_store(fn store_opts ->
          reply =
            Context.stimulus(ctx, falsifier, fn ->
              CommandBus.run(
                bus_command(skill_id(:record), label),
                message(%{"label" => label}),
                Ledger,
                store_opts
              )
            end)

          {reply, blocker}
        end)
      end)

    rows = Fx.consequence_count(label)

    Result.negative(falsifier,
      attempt_observed?:
        observed_attrs?(ctx, falsifier, "brce.admission", %{"outcome" => "admitted"}) and
          observed_attrs?(ctx, falsifier, "brce.prepare", %{"outcome" => "failed"}),
      forbidden_outcome_observed?: rows > 0 or any_actuation?(ctx, falsifier),
      evidence: %{
        "reply_code" => reply_code(reply),
        "rows_with_label" => rows,
        "journal_dir" => blocker
      }
    )
  end

  # 004
  defp store_stopped(ctx, falsifier) do
    label = unique_label("store-stopped")
    name = Module.concat(__MODULE__, "StoppedStore#{System.unique_integer([:positive])}")
    {:ok, pid} = AshA2A.ReceiptStore.Memory.start_link(name: name)
    Process.unlink(pid)
    :ok = GenServer.stop(pid)

    reply =
      Context.stimulus(ctx, falsifier, fn ->
        CommandBus.run(
          bus_command(skill_id(:record), label),
          message(%{"label" => label}),
          Ledger,
          store: AshA2A.ReceiptStore.Memory,
          store_opts: [name: name]
        )
      end)

    rows = Fx.consequence_count(label)

    Result.negative(falsifier,
      attempt_observed?:
        observed_attrs?(ctx, falsifier, "brce.admission", %{"outcome" => "admitted"}) and
          observed_attrs?(ctx, falsifier, "brce.claim", %{"outcome" => "refused"}),
      forbidden_outcome_observed?: rows > 0 or any_actuation?(ctx, falsifier),
      evidence: %{"reply_code" => reply_code(reply), "rows_with_label" => rows}
    )
  end

  # 012
  defp prepared_do(ctx, falsifier) do
    label = unique_label("prepared-do")

    reply =
      with_store(fn store_opts ->
        Context.stimulus(ctx, falsifier, fn ->
          CommandBus.run(
            bus_command(skill_id(:record), label),
            message(%{"label" => label}),
            Ledger,
            store_opts
          )
        end)
      end)

    rows = Fx.consequence_count(label)

    Result.positive(falsifier,
      attempt_observed?:
        observed_attrs?(ctx, falsifier, "brce.admission", %{"outcome" => "admitted"}),
      expected_outcome_observed?:
        rows == 1 and receipted_do?(ctx, falsifier) and match?({:ok, _}, reply),
      evidence: %{"rows_with_label" => rows, "reply" => short(reply)}
    )
  end

  # 005
  defp planner(ctx, falsifier) do
    token = token()
    envelope = goal_facts(token)

    outcome =
      Context.stimulus(ctx, falsifier, fn ->
        routed = RequestRouter.route(Planned, goal_facts_message(envelope))

        from_envelope =
          Planning.from_envelope(
            Planned,
            %{"request_id" => "brce-planner-#{token}", "capability_ids" => planned_ids()},
            planner: :chicago_brce_planner,
            formalism: :hddl
          )

        forged =
          Planning.admit(Planned, %{
            Planning.Candidate.new(
              :chicago_brce_forger,
              %{"steps" => planned_ids()},
              planned_ids()
            )
            | standing: :admitted,
              authority: :do
          })

        %{routed: routed, from_envelope: from_envelope, forged: forged}
      end)

    planned_rows = planned_rows(token)

    Result.negative(falsifier,
      attempt_observed?:
        observed_attrs?(ctx, falsifier, "router.tier_selected", %{"tier" => "facts"}) and
          observed_attrs?(ctx, falsifier, "planning.admit", %{"outcome" => "admitted"}) and
          observed_attrs?(ctx, falsifier, "planning.admit", %{
            "outcome" => "refused",
            "code" => "planner_authority_ceiling_violated"
          }),
      forbidden_outcome_observed?: planned_rows > 0 or any_actuation?(ctx, falsifier),
      evidence: %{
        "routed" => package_summary(outcome.routed),
        "from_envelope" => candidate_summary(outcome.from_envelope),
        "forged" => candidate_summary(outcome.forged),
        "planned_rows" => planned_rows
      }
    )
  end

  # 006
  defp hooks(ctx, falsifier) do
    label = unique_label("hook")

    base = """
    @prefix kh: <http://seanchatmangpt.github.io/praxis/kh#> .
    @prefix ex: <http://example.org/chicago/brce#> .
    ex:actuate_hook a kh:Hook ;
      kh:name "brce_actuate_ledger_record" ;
      kh:on "assert" ;
      kh:kind "delta" ;
      kh:var "http://example.org/chicago/brce#requestsCapability" ;
      kh:effect "ground-action" ;
      kh:action ex:ledger_record .
    """

    event = """
    @prefix ex: <http://example.org/chicago/brce#> .
    ex:request ex:requestsCapability "#{skill_id(:record)}" ;
      ex:label "#{label}" .
    """

    result = Context.stimulus(ctx, falsifier, fn -> GraphLawBridge.run_hooks(base, event) end)

    case result do
      {:ok, decoded} ->
        rows = Fx.consequence_count(label)

        Result.negative(falsifier,
          attempt_observed?:
            observed_attrs?(ctx, falsifier, "semantic.hooks.run", %{"outcome" => "evaluated"}),
          forbidden_outcome_observed?: rows > 0 or any_actuation?(ctx, falsifier),
          evidence: %{
            "engine_status" => decoded["status"],
            "scheduled_hooks" => length(List.wrap(decoded["schedule"])),
            "verdicts" => length(List.wrap(decoded["verdicts"])),
            "rows_with_label" => rows,
            "host" => inspect(GraphLawBridge.host())
          }
        )

      {:error, reason} ->
        Result.blocked(
          falsifier,
          "real GraphLaw hook engine unavailable: #{inspect(reason, limit: 5)}",
          :resource_blocked
        )
    end
  end

  # 007
  defp semantic_request(ctx, falsifier) do
    token = token()
    message = goal_facts_message(goal_facts(token))

    reply =
      with_agent(PlannedAgent, fn agent ->
        Context.stimulus(ctx, falsifier, fn -> PlannedAgent.call(agent, message) end)
      end)

    planned_rows = planned_rows(token)

    Result.negative(falsifier,
      attempt_observed?:
        observed_attrs?(ctx, falsifier, "agent.dispatch", %{"route" => "semantic"}) and
          observed_attrs?(ctx, falsifier, "router.tier_selected", %{"tier" => "facts"}),
      forbidden_outcome_observed?: planned_rows > 0 or any_actuation?(ctx, falsifier),
      evidence: Map.put(task_summary(reply), "planned_rows", planned_rows)
    )
  end

  # 008 (negative, record) / 015 (positive, transmit)
  defp agent_call(ctx, falsifier, kind, skill) do
    label = unique_label("a2a-#{skill}")
    message = skill_message(skill, label)

    reply =
      with_agent(LedgerAgent, fn agent ->
        Context.stimulus(ctx, falsifier, fn ->
          LedgerAgent.call(agent, message,
            metadata: %{"a2a.auth" => %{identity: agent_principal()}}
          )
        end)
      end)

    rows = Fx.consequence_count(label)
    evidence = task_summary(reply) |> Map.put("rows_with_label", rows)

    case kind do
      :negative ->
        Result.negative(falsifier,
          attempt_observed?:
            observed_attrs?(ctx, falsifier, "agent.dispatch", %{"consequence" => "change"}),
          forbidden_outcome_observed?: unreceipted_actuation?(ctx, falsifier),
          evidence: Map.put(evidence, "receipted_do", receipted_do?(ctx, falsifier))
        )

      :positive ->
        Result.positive(falsifier,
          attempt_observed?:
            observed_attrs?(ctx, falsifier, "agent.dispatch", %{"route" => "command_bus"}),
          expected_outcome_observed?: rows == 1 and receipted_do?(ctx, falsifier),
          evidence: evidence
        )
    end
  end

  # 009
  defp generated_handler(ctx, falsifier) do
    label = unique_label("generated-transmit")
    message = skill_message("transmit", label)

    reply =
      Context.stimulus(ctx, falsifier, fn ->
        LedgerAgent.handle_message(message, %{
          metadata: %{"a2a.auth" => %{identity: agent_principal()}},
          history: []
        })
      end)

    rows = Fx.consequence_count(label)

    Result.negative(falsifier,
      attempt_observed?:
        observed_attrs?(ctx, falsifier, "agent.dispatch", %{"consequence" => "external_do"}),
      forbidden_outcome_observed?: unreceipted_actuation?(ctx, falsifier),
      evidence: %{
        "reply" => short(reply),
        "rows_with_label" => rows,
        "receipted_do" => receipted_do?(ctx, falsifier)
      }
    )
  end

  # 014 -> 010 -> 011
  defp replay_family(ctx, fresh_f, replay_f, conflict_f) do
    with_store(fn store_opts ->
      label = unique_label("identity")
      command = bus_command(skill_id(:transmit), label)
      msg = message(%{"label" => label})

      first =
        Context.stimulus(ctx, fresh_f, fn -> CommandBus.run(command, msg, Ledger, store_opts) end)

      after_first = Fx.consequence_count(label)

      fresh =
        Result.positive(fresh_f,
          attempt_observed?:
            observed_attrs?(ctx, fresh_f, "brce.claim", %{"outcome" => "execute"}),
          expected_outcome_observed?: after_first == 1 and receipted_do?(ctx, fresh_f),
          evidence: %{"rows_with_label" => after_first, "reply" => short(first)}
        )

      replayed =
        Context.stimulus(ctx, replay_f, fn -> CommandBus.run(command, msg, Ledger, store_opts) end)

      after_replay = Fx.consequence_count(label)

      replay =
        Result.negative(replay_f,
          attempt_observed?:
            observed_attrs?(ctx, replay_f, "brce.claim", %{"outcome" => "replay"}),
          forbidden_outcome_observed?: after_replay > after_first or any_do?(ctx, replay_f),
          evidence: %{
            "rows_before" => after_first,
            "rows_after" => after_replay,
            "replayed?" => match?({:ok, %{replayed?: true}}, replayed)
          }
        )

      divergent = label <> "-divergent"

      conflicting =
        bus_command(skill_id(:transmit), divergent, command_id: command.command_id)

      conflicted =
        Context.stimulus(ctx, conflict_f, fn ->
          CommandBus.run(conflicting, message(%{"label" => divergent}), Ledger, store_opts)
        end)

      divergent_rows = Fx.consequence_count(divergent)

      conflict =
        Result.negative(conflict_f,
          attempt_observed?:
            observed_attrs?(ctx, conflict_f, "brce.claim", %{
              "outcome" => "refused",
              "code" => "command_conflict"
            }),
          forbidden_outcome_observed?: divergent_rows > 0 or any_do?(ctx, conflict_f),
          evidence: %{"reply_code" => reply_code(conflicted), "divergent_rows" => divergent_rows}
        )

      [fresh, replay, conflict]
    end)
  end

  # --- environment (real faults around real components, §10) ---------------

  defp with_store(fun) do
    name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    {:ok, pid} = AshA2A.ReceiptStore.Memory.start_link(name: name)

    try do
      fun.(store: AshA2A.ReceiptStore.Memory, store_opts: [name: name])
    after
      if Process.alive?(pid), do: GenServer.stop(pid)
    end
  end

  defp with_outbox_unavailable(%Context{evidence_dir: dir}, fun) do
    :ok = File.mkdir_p(dir)
    blocker = Path.join(dir, "brce-journal-blocker-#{System.unique_integer([:positive])}")
    :ok = File.write(blocker, "a regular file where the receipt journal directory must be")
    journal = Path.join(blocker, "journal")
    previous = Application.fetch_env(:ash_a2a, :receipt_outbox_dir)
    Application.put_env(:ash_a2a, :receipt_outbox_dir, journal)

    try do
      fun.(journal)
    after
      restore_env(:receipt_outbox_dir, previous)
    end
  end

  defp with_granted_broker(fun) do
    name = Module.concat(__MODULE__, "Broker#{System.unique_integer([:positive])}")
    {:ok, pid} = InMemory.start_link(name: name)
    broker = {InMemory, [name: name]}
    previous_policy = Application.fetch_env(:ash_a2a, :authority_policy)
    previous_broker = Application.fetch_env(:ash_a2a, :authority_broker)
    Application.put_env(:ash_a2a, :authority_policy, :broker)
    Application.put_env(:ash_a2a, :authority_broker, broker)

    try do
      subject = Identity.principal(agent_principal())

      # SA2A-AUTH-017 (RFC-SA2A-002 S66): `AshA2A.Agent.build_command/4` now
      # resolves the dispatched skill's canonical capability id
      # (`AshA2A.Info.skill/2`) before calling `Grant.authorize/3`, so the
      # standing grant issued here for the real `LedgerAgent` dispatch path
      # must be keyed on that same canonical `Ledger` id, not the bare wire
      # selector.
      for capability <- ["record", "transmit"] do
        {:ok, %{id: capability_id}} = AshA2A.Info.skill(Ledger, capability)
        {:ok, %Authority{}} = Authority.Grant.grant(subject, capability_id)
      end

      fun.()
    after
      restore_env(:authority_policy, previous_policy)
      restore_env(:authority_broker, previous_broker)
      if Process.alive?(pid), do: GenServer.stop(pid)
    end
  end

  defp with_agent(agent_module, fun) do
    {:ok, pid} = GenServer.start(agent_module, [])

    try do
      fun.(pid)
    after
      if Process.alive?(pid), do: GenServer.stop(pid)
    end
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:ash_a2a, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:ash_a2a, key)

  # --- stimuli material -------------------------------------------------------

  defp principal, do: Identity.principal("chicago-brce-subject")
  defp agent_principal, do: "chicago-brce-a2a-principal"

  defp bus_command(capability_id, label, opts \\ []) do
    AshA2A.Command.new(capability_id,
      command_id: Keyword.get(opts, :command_id, "chicago-brce-" <> Ash.UUIDv7.generate()),
      agent_id: "chicago-brce-agent",
      principal_id: principal(),
      authority: Authority.new(principal(), capability_id),
      input: %{"label" => label}
    )
  end

  defp skill_id(name) do
    {:ok, skill} = AshA2A.Info.skill(Ledger, name)
    skill.id
  end

  defp planned_ids do
    for name <- [:advance, :unlock] do
      {:ok, skill} = AshA2A.Info.skill(Planned, name)
      skill.id
    end
  end

  defp message(data), do: A2A.Message.new_user([A2A.Part.Data.new(data)])

  defp skill_message(skill, label) do
    %{message(%{"label" => label}) | metadata: %{"skill" => skill}}
  end

  defp goal_facts(token) do
    [from, to] = ["pa#{token}", "pb#{token}"]
    [advance, unlock] = planned_ids()

    %{
      "request_id" => "chicago-brce-#{token}",
      "domain_name" => "chicago-brce-domain",
      "problem_name" => "chicago-brce-problem-#{token}",
      "objects" => [from, to],
      "init" => [%{"predicate" => "current_phase", "args" => [from]}],
      "goal" => [
        %{"predicate" => "current_phase", "args" => [to]},
        %{"predicate" => "has_key", "args" => [to]}
      ],
      "task_sequence" => [
        %{"capability_id" => advance, "args" => [from, to]},
        %{"capability_id" => unlock, "args" => [to]}
      ]
    }
  end

  defp goal_facts_message(envelope) do
    %{message(%{"goal_facts" => envelope}) | metadata: %{semantic_request: true}}
  end

  defp planned_rows(token) do
    Enum.count(Fx.ledger_labels() ++ Fx.effect_labels(), &String.contains?(&1, token))
  end

  defp token, do: Integer.to_string(System.unique_integer([:positive]))
  defp unique_label(prefix), do: "chicago-brce-#{prefix}-#{token()}"

  # --- in-run evidence (the durable verdict is re-derived from OCEL) ----------

  defp observed_attrs?(ctx, falsifier, activity, attrs) do
    ctx
    |> Context.observed(falsifier)
    |> Enum.any?(fn record ->
      record.activity == activity and
        Enum.all?(attrs, fn {k, v} -> to_string(record.attributes[k]) == v end)
    end)
  end

  defp attr_values(ctx, falsifier, activity, attr) do
    for record <- Context.observed(ctx, falsifier), record.activity == activity do
      to_string(record.attributes[attr])
    end
  end

  defp any_actuation?(ctx, falsifier) do
    Enum.any?(["dispatch.start" | @actuations], &Context.observed?(ctx, falsifier, &1))
  end

  defp any_do?(ctx, falsifier) do
    Enum.any?(@actuations, &Context.observed?(ctx, falsifier, &1))
  end

  defp unreceipted_actuation?(ctx, falsifier) do
    records = Context.observed(ctx, falsifier)
    prepares = Enum.filter(records, &(&1.activity == "brce.prepare"))

    records
    |> Enum.filter(&(&1.activity in @actuations))
    |> Enum.any?(fn actuation ->
      receipt = object_id(actuation, "receipt")
      command = object_id(actuation, "command")

      not (receipt != nil and
             Enum.any?(prepares, fn prepare ->
               prepare.seq < actuation.seq and object_id(prepare, "receipt") == receipt and
                 object_id(prepare, "command") == command
             end))
    end)
  end

  defp receipted_do?(ctx, falsifier) do
    records = Context.observed(ctx, falsifier)

    Enum.any?(@actuations, &Context.observed?(ctx, falsifier, &1)) and
      not unreceipted_actuation?(ctx, falsifier) and
      Enum.any?(
        records,
        &(&1.activity == "brce.commit" and &1.attributes["outcome"] == "committed")
      )
  end

  defp object_id(record, type) do
    Enum.find_value(record.objects, fn
      {^type, id, _qualifier} -> id
      _ -> nil
    end)
  end

  defp reply_code({:error, %{code: code}}), do: to_string(code)
  defp reply_code({:ok, _}), do: "ok"
  defp reply_code(other), do: short(other)

  defp short(term), do: inspect(term, limit: 8, printable_limit: 240)

  defp task_summary({:ok, %A2A.Task{} = task}) do
    body =
      case task.artifacts do
        [%A2A.Artifact{parts: [%A2A.Part.Data{data: data} | _]} | _] -> data
        _ -> %{}
      end

    %{
      "task_state" => to_string(task.status.state),
      "standing" => body["standing"],
      "authority" => body["authority"],
      "capability_ids" => inspect(body["capability_ids"])
    }
  end

  defp task_summary(other), do: %{"reply" => short(other)}

  defp package_summary({:ok, %AshA2A.Semantic.ExecutionPackage{} = package}),
    do: %{
      "ok" => true,
      "standing" => to_string(package.standing),
      "authority" => to_string(package.authority)
    }

  defp package_summary(other), do: %{"ok" => false, "reply" => short(other)}

  defp candidate_summary({:ok, %Planning.Candidate{} = c}),
    do: %{
      "ok" => true,
      "standing" => to_string(c.standing),
      "authority" => to_string(c.authority)
    }

  defp candidate_summary({:error, %{code: code}}), do: %{"ok" => false, "code" => to_string(code)}
  defp candidate_summary(other), do: %{"ok" => false, "reply" => short(other)}
end
