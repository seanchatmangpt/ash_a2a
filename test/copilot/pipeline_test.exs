defmodule AshA2A.Copilot.PipelineTest do
  use ExUnit.Case, async: false

  alias AshA2A.Attestation.Key
  alias AshA2A.Copilot.Pipeline
  alias AshA2A.Strain.Bridge
  alias AshA2A.Strain.Tensor
  alias AshA2A.Twin.COO
  alias AshA2A.Twin.CEO

  @now 1_700_000_100

  defp fresh_claims(nonce, extra \\ %{}) do
    %{
      "nonce" => nonce,
      "issued_at" => @now - 5,
      "camera_make" => "Apple",
      "camera_model" => "iPhone 15",
      "gps" => %{
        "lat" => 35.6812,
        "lon" => 139.7671,
        "accuracy" => 8.0,
        "timestamp" => @now - 5
      }
    }
    |> Map.merge(extra)
  end

  defp signed_frame(nonce, claims, key) do
    token = Key.sign(claims, key)
    %{device_token: token, nonce: nonce, key: key}
  end

  defp rested_mesh(id) do
    %{} |> COO.register_coordinator(id, Tensor.new(%{}))
  end

  defp saturated_mesh(id) do
    tensor =
      Tensor.new(%{
        shift_hours_continuous: 24,
        active_leases: 12,
        error_rate: 1.0,
        heuristic_frequency: 10
      })

    %{} |> COO.register_coordinator(id, tensor)
  end

  defp intent(overrides \\ %{}) do
    Map.merge(
      %{
        trade: :trade_admit,
        nte: 1000,
        offer: 720,
        coordinator_id: :coord_a,
        sensor_frame: :unused
      },
      overrides
    )
  end

  test "admit path: GPM 0.28, fresh attestation, rested coordinator" do
    key = Key.generate()
    frame = signed_frame("nonce-admit", fresh_claims("nonce-admit"), key)

    state =
      Pipeline.init(gpm_floor: 0.22, tolerance: 0.0)
      |> then(&%{&1 | mesh: rested_mesh(:coord_a)})

    {new_state, result} =
      Pipeline.check(intent(%{sensor_frame: frame}), state, now: @now)

    assert {:ok, ticket} = result
    assert ticket.trade == :trade_admit
    assert ticket.coordinator_id == :coord_a
    assert_in_delta ticket.gpm, 0.28, 1.0e-9
    assert ticket.attestation_claims["nonce"] == "nonce-admit"

    # challenge ledger untouched by the admit
    assert new_state.ceo.challenges == %{}
  end

  test "challenge path: GPM 0.19 fires gpm_floor with retry_token; repeat escalates to refuse" do
    state = %{Pipeline.init(gpm_floor: 0.22) | mesh: rested_mesh(:coord_a)}

    low_margin = intent(%{trade: :trade_ch, nte: 1000, offer: 810})

    {state1, {:challenge, ch}} = Pipeline.check(low_margin, state)
    assert ch.code == :gpm_floor
    assert is_reference(ch.retry_token)
    assert "itemized_cost_breakdown" in ch.demanded_evidence
    assert state1.ceo.challenges[:trade_ch] == 1

    # same trade re-submitted (even with a repaired offer) escalates
    repaired = intent(%{trade: :trade_ch, nte: 1000, offer: 700})
    {_state2, {:refuse, :escalate_multisig}} = Pipeline.check(repaired, state1)
  end

  test "shed path: saturated tensor sheds to senior queue before attestation" do
    key = Key.generate()
    frame = signed_frame("nonce-shed", fresh_claims("nonce-shed"), key)

    state = %{Pipeline.init(gpm_floor: 0.22) | mesh: saturated_mesh(:coord_s)}

    {new_state, {:shed, {:senior_queue, target}}} =
      Pipeline.check(intent(%{coordinator_id: :coord_s, sensor_frame: frame}), state, now: @now)

    assert target == :coo_relief
    # shed does not touch the challenge ledger
    assert new_state.ceo.challenges == %{}
  end

  test "spoofed attestation: virtual claim refuses" do
    key = Key.generate()
    frame = signed_frame("nonce-spoof", fresh_claims("nonce-spoof", %{"is_virtual" => true}), key)

    state = %{Pipeline.init(gpm_floor: 0.22) | mesh: rested_mesh(:coord_a)}

    {_state, {:refuse, %{code: :attestation, reason: reason}}} =
      Pipeline.check(intent(%{sensor_frame: frame}), state, now: @now)

    assert reason == {:refused, :emulator_detected}
  end

  test "stale attestation refuses" do
    key = Key.generate()
    claims = fresh_claims("nonce-stale") |> put_in(["issued_at"], @now - 400)
    token = Key.sign(claims, key)
    frame = %{device_token: token, nonce: "nonce-stale", key: key}

    state = %{Pipeline.init(gpm_floor: 0.22) | mesh: rested_mesh(:coord_a)}

    {_state, {:refuse, %{code: :attestation, reason: {:refused, :stale}}}} =
      Pipeline.check(intent(%{sensor_frame: frame}), state, now: @now)
  end

  test "mechanical prior is consulted when loadable and folds its verdict" do
    defmodule DenyingPrior do
      @behaviour AshA2A.Twin.MechanicalPrior

      @impl true
      def prior_verdict(_claim, _telemetry), do: {:refuse, :blown_motor_high_ambient}
    end

    state = %{Pipeline.init(gpm_floor: 0.22) | mesh: rested_mesh(:coord_a)}

    {_state, {:refuse, %{code: :mechanical_prior, reason: :blown_motor_high_ambient}}} =
      Pipeline.check(intent(), state, prior: DenyingPrior)
  end

  test "monkey-math exact-half challenge" do
    state = %{Pipeline.init(gpm_floor: 0.22, tolerance: 0.0) | mesh: rested_mesh(:coord_a)}

    {_state, {:challenge, %{code: :monkey_math}}} =
      Pipeline.check(intent(%{nte: 1000, offer: 500}), state)
  end

  defmodule EnvPrior do
    def prior_verdict(_claim, _telemetry), do: {:admit, :env}
  end

  test "detect_prior honours Application env :copilot_mechanical_prior" do
    prev = Application.get_env(:ash_a2a, :copilot_mechanical_prior)

    on_exit(fn ->
      if prev == nil,
        do: Application.delete_env(:ash_a2a, :copilot_mechanical_prior),
        else: Application.put_env(:ash_a2a, :copilot_mechanical_prior, prev)
    end)

    Application.put_env(:ash_a2a, :copilot_mechanical_prior, EnvPrior)
    assert Pipeline.detect_prior() == EnvPrior

    Application.delete_env(:ash_a2a, :copilot_mechanical_prior)

    expected =
      case Code.ensure_loaded(TradeReticle.Plumbing) do
        {:module, _} -> TradeReticle.Plumbing
        _ -> nil
      end

    assert Pipeline.detect_prior() == expected
  end

  defmodule FixIntentHelpers do
    def state do
      Pipeline.init(
        [gpm_floor: 0.22, tolerance: 0.0],
        COO.register_coordinator(%{}, :alice, Tensor.new(%{}))
      )
    end

    def intent(over) do
      Map.merge(
        %{trade: "t-fix", nte: 1000, offer: 720, coordinator_id: :alice, sensor_frame: :unused},
        over
      )
    end
  end

  alias __MODULE__.FixIntentHelpers, as: FIH

  test "invalid intents return typed refusals (nte zero, missing keys, non-map)" do
    st = FIH.state()

    assert {^st, {:refuse, %{code: :invalid_intent, reason: :nte_zero}}} =
             Pipeline.check(FIH.intent(%{nte: 0}), st)

    assert {^st, {:refuse, %{code: :invalid_intent, reason: {:missing_keys, [:offer]}}}} =
             Pipeline.check(Map.delete(FIH.intent(%{}), :offer), st)

    assert {^st, {:refuse, %{code: :invalid_intent, reason: :intent_not_a_map}}} =
             Pipeline.check(:nope, st)
  end

  test "admit with missing or :unused sensor_frame refuses typed, no raise" do
    st = FIH.state()

    assert {_, {:refuse, %{code: :attestation, reason: {:refused, :missing_sensor_frame}}}} =
             Pipeline.check(FIH.intent(%{}), st, now: @now, prior: nil)

    assert {_, {:refuse, %{code: :attestation, reason: {:refused, :missing_sensor_frame}}}} =
             Pipeline.check(Map.delete(FIH.intent(%{}), :sensor_frame), st, now: @now, prior: nil)
  end

  defmodule BadAuthority do
    @behaviour AshA2A.Authority.Source
    @impl true
    def check(_a, _act, _ctx, _o), do: :deny
  end

  test "attention_broker accepts {module, opts}; broker opts supply default level" do
    st = FIH.state()

    {_, result} =
      Pipeline.check(FIH.intent(%{trade: "esc-tuple", nte: 1000, offer: 500}), st, prior: nil)

    assert {:challenge, _} = result

    {st2, {:challenge, _}} =
      Pipeline.check(FIH.intent(%{trade: "esc-tuple", nte: 1000, offer: 500}), st, prior: nil)

    assert {_, {:escalated, %{proposal: proposal}}} =
             Pipeline.check(FIH.intent(%{trade: "esc-tuple", nte: 1000, offer: 500}), st2,
               prior: nil,
               attention_broker: {AshA2A.Attention.Broker, [level: :supervised, now: 7]}
             )

    assert proposal.level == :supervised
    assert proposal.proposed_at == 7
  end

  test "invalid proposal_level yields typed :escalation_failed, no MatchError" do
    st = FIH.state()

    {st2, {:challenge, _}} =
      Pipeline.check(FIH.intent(%{trade: "esc-bad", nte: 1000, offer: 500}), st, prior: nil)

    assert {_, {:refuse, %{code: :escalation_failed, reason: {:invalid_level, :bogus}}}} =
             Pipeline.check(FIH.intent(%{trade: "esc-bad", nte: 1000, offer: 500}), st2,
               prior: nil,
               attention_broker: AshA2A.Attention.Broker,
               proposal_level: :bogus
             )
  end

  test ":prior opt nil does not evaluate detect_prior (lazy default)" do
    prev = Application.get_env(:ash_a2a, :copilot_mechanical_prior)

    on_exit(fn ->
      if prev == nil,
        do: Application.delete_env(:ash_a2a, :copilot_mechanical_prior),
        else: Application.put_env(:ash_a2a, :copilot_mechanical_prior, prev)
    end)

    # an env prior that would raise if consulted (module has no prior_verdict/2)
    Application.put_env(:ash_a2a, :copilot_mechanical_prior, String)

    assert {_, {:refuse, %{code: :attestation}}} =
             Pipeline.check(FIH.intent(%{}), FIH.state(), now: @now, prior: nil)
  end

  test "prior challenge is recorded on the bridge like a CEO challenge" do
    defmodule ChallengingPrior do
      def prior_verdict(_c, _t), do: {:challenge, [:photo], "need photo"}
    end

    {st, {:challenge, %{code: :mechanical_prior}}} =
      Pipeline.check(FIH.intent(%{}), FIH.state(), prior: ChallengingPrior)

    assert st.bridge[:alice].tensor.heuristic_frequency == 1
  end

  test "authority source returning garbage becomes typed refusal (catch-all)" do
    key = Key.generate()
    frame = signed_frame("nonce-fix", fresh_claims("nonce-fix"), key)

    assert {_, {:refuse, %{code: :authority}}} =
             Pipeline.check(FIH.intent(%{sensor_frame: frame, actor_id: "p"}), FIH.state(),
               now: @now,
               prior: nil,
               authority_source: BadAuthority
             )
  end

  # -- Z7 seam: Bridge observation feed + strain-first routing -----------------

  defmodule CountingCEO do
    @moduledoc "CEO-compatible wrapper counting evaluate_intent/2 calls via a named Agent."

    def start_link(name), do: Agent.start_link(fn -> 0 end, name: name)

    def count(name), do: Agent.get(name, & &1)

    def evaluate_intent(name, ceo, claim) do
      Agent.update(name, &(&1 + 1))
      CEO.evaluate_intent(ceo, claim)
    end
  end

  setup do
    # T5 unblock (disclosed, minimal): whereis-then-stop races an agent that
    # died since the whereis — GenServer.stop then raises "no process".
    case Process.whereis(:ceo_counter_z7) do
      nil ->
        :ok

      pid ->
        try do
          GenServer.stop(pid, :normal, 1_000)
        catch
          :exit, _ -> :ok
        end
    end

    {:ok, _} = CountingCEO.start_link(:ceo_counter_z7)
    :ok
  end

  defp saturated_bridge_mesh(id) do
    Bridge.new_mesh_state([])
    |> Map.put(id, %{
      tensor:
        Tensor.new(%{
          shift_hours_continuous: 24,
          active_leases: 12,
          error_rate: 1.0,
          heuristic_frequency: 10
        }),
      error_window: []
    })
  end

  test "Z7 admit: bridge mesh_state active_leases increments on admit" do
    key = Key.generate()
    frame = signed_frame("nonce-z7-admit", fresh_claims("nonce-z7-admit"), key)

    state =
      Pipeline.init(gpm_floor: 0.22, tolerance: 0.0)
      |> then(&%{&1 | mesh: rested_mesh(:coord_a)})

    {new_state, {:ok, _ticket}} = Pipeline.check(intent(%{sensor_frame: frame}), state, now: @now)

    assert new_state.bridge[:coord_a].tensor.active_leases == 1
  end

  test "Z7 challenge: heuristic_frequency increments with source :ceo" do
    state = %{Pipeline.init(gpm_floor: 0.22) | mesh: rested_mesh(:coord_a)}

    low_margin = intent(%{trade: :trade_z7, nte: 1000, offer: 810})

    {new_state, {:challenge, %{code: :gpm_floor}}} = Pipeline.check(low_margin, state)

    assert new_state.bridge[:coord_a].tensor.heuristic_frequency == 1
  end

  test "Z7 refuse/escalate: error_reported folds into the rolling window" do
    state = %{Pipeline.init(gpm_floor: 0.22) | mesh: rested_mesh(:coord_a)}

    low_margin = intent(%{trade: :trade_z7r, nte: 1000, offer: 810})
    {state1, {:challenge, _}} = Pipeline.check(low_margin, state)

    repaired = intent(%{trade: :trade_z7r, nte: 1000, offer: 700})
    {state2, {:refuse, :escalate_multisig}} = Pipeline.check(repaired, state1)

    assert Bridge.error_rate(state2.bridge, :coord_a) == 1.0
  end

  test "Z7 saturated bridge mesh: route sheds WITHOUT consulting CEO (counter == 0)" do
    mesh = saturated_bridge_mesh(:coord_s)

    # non-vacuity: the counter demonstrably counts real CEO consultations
    assert CountingCEO.count(:ceo_counter_z7) == 0

    ceo = CEO.new([])
    CountingCEO.evaluate_intent(:ceo_counter_z7, ceo, %{trade: :t, nte: 1000, offer: 700})
    assert CountingCEO.count(:ceo_counter_z7) == 1

    # route over a saturated mesh sheds without a second consultation
    ticket = %{friction: 0.5, candidates: [:coord_s]}
    assert {:shed, {:senior_queue, _reason}} = Pipeline.route(ticket, mesh)
    assert CountingCEO.count(:ceo_counter_z7) == 1
  end

  test "Z7 check with counting ceo mod: admit path consults CEO exactly once" do
    key = Key.generate()
    frame = signed_frame("nonce-z7-cv", fresh_claims("nonce-z7-cv"), key)

    state =
      Pipeline.init(gpm_floor: 0.22, tolerance: 0.0)
      |> then(&%{&1 | mesh: rested_mesh(:coord_a)})

    assert CountingCEO.count(:ceo_counter_z7) == 0

    # inject the counting module in place of CEO
    ceo_mod = fn v, claim -> CountingCEO.evaluate_intent(:ceo_counter_z7, v, claim) end

    {_state, {:ok, _}} =
      Pipeline.check(intent(%{sensor_frame: frame}), state, now: @now, ceo_mod: ceo_mod)

    assert CountingCEO.count(:ceo_counter_z7) == 1
  end

  test "Z7 route sweep: 20 tickets under rising strain — sheds appear, zero dropped" do
    # c2 carries 9 pre-held leases; c1 starts fresh. Strain math (weighted sum,
    # threshold 0.7): shift 20h -> 0.298, error_rate 1.0 -> 0.20, so base 0.498;
    # each lease adds 0.25/12. A coordinator saturates at 10 held leases.
    tensor = fn leases ->
      Tensor.new(%{
        shift_hours_continuous: 20,
        active_leases: leases,
        error_rate: 1.0,
        heuristic_frequency: 0
      })
    end

    mesh =
      Bridge.new_mesh_state([])
      |> Map.put(:c1, %{tensor: tensor.(0), error_window: []})
      |> Map.put(:c2, %{tensor: tensor.(9), error_window: []})

    {mesh, results} =
      Enum.reduce(1..20, {mesh, []}, fn i, {mesh, acc} ->
        ticket = %{friction: 0.5, candidates: [:c1, :c2]}

        case Pipeline.route(ticket, mesh) do
          {:assign, id} ->
            {Bridge.record_observation(mesh, id, %{type: :ticket_assigned}),
             acc ++ [{i, {:assign, id}}]}

          shed ->
            {mesh, acc ++ [{i, shed}]}
        end
      end)

    assigns = Enum.count(results, fn {_i, r} -> match?({:assign, _}, r) end)
    sheds = Enum.count(results, fn {_i, r} -> match?({:shed, _}, r) end)

    assert assigns + sheds == 20
    assert assigns > 0
    assert sheds > 0

    # both coordinators saturated by the assigns; overflow sheds to senior queue
    assert Pipeline.route(%{friction: 0.5, candidates: [:c1, :c2]}, mesh) ==
             {:shed, {:senior_queue, :all_saturated}}

    # zero dropped: every ticket either assigned or shed-with-reason
    assert Enum.all?(results, fn
             {_i, {:assign, _id}} -> true
             {_i, {:shed, {:senior_queue, _}}} -> true
             _ -> false
           end)
  end

  defp advance_shift(mesh, id, hours) do
    Bridge.record_observation(mesh, id, %{type: :clock_hour, hours: hours})
  end

  # -- lane G4: authority hop (last gate before admit) -------------------------

  defmodule RefusingSource do
    @moduledoc "Source that denies everything (court collaborator, real behaviour)."
    @behaviour AshA2A.Authority.Source

    @impl true
    def check(_actor_id, _action, _context, _opts), do: :deny
  end

  test "G4 authority: AllowAll source admits onward, ticket flows" do
    key = Key.generate()
    frame = signed_frame("nonce-g4-allow", fresh_claims("nonce-g4-allow"), key)

    state =
      Pipeline.init(gpm_floor: 0.22, tolerance: 0.0)
      |> then(&%{&1 | mesh: rested_mesh(:coord_a)})

    actor_intent =
      intent(%{sensor_frame: frame, actor_id: "principal-1"})

    {new_state, {:ok, ticket}} =
      Pipeline.check(actor_intent, state,
        now: @now,
        authority_source: AshA2A.Authority.Source.AllowAll
      )

    assert ticket.coordinator_id == :coord_a
    assert new_state.bridge[:coord_a].tensor.active_leases == 1
    assert new_state.ceo.challenges == %{}
  end

  test "G4 authority: configured refusing source refuses with code :authority; CEO already consulted exactly once" do
    key = Key.generate()
    frame = signed_frame("nonce-g4-deny", fresh_claims("nonce-g4-deny"), key)

    state =
      Pipeline.init(gpm_floor: 0.22, tolerance: 0.0)
      |> then(&%{&1 | mesh: rested_mesh(:coord_a)})

    assert CountingCEO.count(:ceo_counter_z7) == 0

    ceo_mod = fn v, claim -> CountingCEO.evaluate_intent(:ceo_counter_z7, v, claim) end

    {new_state, {:refuse, %{code: :authority, reason: reason}}} =
      Pipeline.check(intent(%{sensor_frame: frame, actor_id: "principal-1"}), state,
        now: @now,
        authority_source: RefusingSource,
        ceo_mod: ceo_mod
      )

    # authority is the LAST gate: CEO was already consulted (order preserved)
    assert CountingCEO.count(:ceo_counter_z7) == 1

    assert match?({:refused, :insufficient_authority, _}, reason) or is_map(reason)
    assert reason.actor_id == "principal-1"
    assert reason.reason == :source_deny

    # refusal folds into the bridge error window, no ticket assigned
    assert new_state.bridge[:coord_a].tensor.active_leases == 0
  end

  test "G4 authority: configured source with no actor_id refuses (missing_actor_id)" do
    key = Key.generate()
    frame = signed_frame("nonce-g4-noactor", fresh_claims("nonce-g4-noactor"), key)

    state =
      Pipeline.init(gpm_floor: 0.22, tolerance: 0.0)
      |> then(&%{&1 | mesh: rested_mesh(:coord_a)})

    {_state, {:refuse, %{code: :authority, reason: %{reason: :missing_actor_id}}}} =
      Pipeline.check(intent(%{sensor_frame: frame}), state,
        now: @now,
        authority_source: AshA2A.Authority.Source.AllowAll
      )
  end

  test "G4 default: no :authority_source opt — hop skipped, existing behaviour unchanged" do
    key = Key.generate()
    frame = signed_frame("nonce-g4-skip", fresh_claims("nonce-g4-skip"), key)

    state =
      Pipeline.init(gpm_floor: 0.22, tolerance: 0.0)
      |> then(&%{&1 | mesh: rested_mesh(:coord_a)})

    # no actor_id present at all — would refuse if the hop were active
    assert {_state, {:ok, _ticket}} =
             Pipeline.check(intent(%{sensor_frame: frame}), state, now: @now)
  end

  # -- lane G5: attention-broker escalation feed -------------------------------

  alias AshA2A.Attention.Broker

  # Real mechanical-prior collaborator that refuses with a GPM-floor-class code
  # (Chicago: exercises the non-multisig escalation clause for real).
  defmodule GpmRefusingPrior do
    def prior_verdict(_claim, _telemetry),
      do: {:refuse, %{code: :gpm_breach, reason: "below declared floor"}}
  end

  test "G5 escalation: broker configured — CEO repeat-challenge refuse opens a proposal with signature-required card" do
    state = %{Pipeline.init(gpm_floor: 0.22) | mesh: rested_mesh(:coord_a)}

    low_margin = intent(%{trade: :trade_g5, nte: 1000, offer: 810})
    {state1, {:challenge, _}} = Pipeline.check(low_margin, state)

    repaired = intent(%{trade: :trade_g5, nte: 1000, offer: 700})

    {new_state, {:escalated, esc}} =
      Pipeline.check(repaired, state1,
        attention_broker: Broker,
        now: @now,
        coo_triage: {["ok"], ["supervisor_review_needed"]}
      )

    assert is_reference(esc.proposal_id)
    card = esc.card
    assert card.source == :ceo_challenge
    assert card.gpm_floor_breach == true

    # B5 invariant: GPM-floor card ALWAYS requires signature on every option
    assert Enum.all?(card.options, &(&1.requires_signature == true))

    # proposal is real and owned by the intent's coordinator
    assert esc.proposal.coordinator_id == :coord_a
    assert esc.proposal.id == esc.proposal_id
    assert esc.proposal.proposed_at == @now

    # the refuse still folds into the bridge error window
    assert new_state.bridge[:coord_a].tensor.error_rate > 0.0
  end

  test "G5 default: no :attention_broker — refuse passes through unchanged, no broker call" do
    state = %{Pipeline.init(gpm_floor: 0.22) | mesh: rested_mesh(:coord_a)}

    low_margin = intent(%{trade: :trade_g5b, nte: 1000, offer: 810})
    {state1, {:challenge, _}} = Pipeline.check(low_margin, state)

    repaired = intent(%{trade: :trade_g5b, nte: 1000, offer: 700})
    {_state2, {:refuse, :escalate_multisig}} = Pipeline.check(repaired, state1)
  end

  test "G5 escalation: GPM-floor-class prior refuse also escalates when broker configured" do
    state = %{Pipeline.init(gpm_floor: 0.22) | mesh: rested_mesh(:coord_a)}
    clear_intent = intent(%{trade: :trade_g5c, nte: 1000, offer: 720})

    {_state, {:escalated, esc}} =
      Pipeline.check(clear_intent, state,
        attention_broker: Broker,
        prior: GpmRefusingPrior,
        now: @now
      )

    assert esc.card.gpm_floor_breach == true
    assert esc.card.source == :ceo_challenge
    assert Enum.all?(esc.card.options, &(&1.requires_signature == true))
    assert esc.proposal.level == :consent_by_silence
  end

  test "G5 consent-by-silence surfaces at the caller's cadence (window open → executed; supervised never auto-executes)" do
    state = %{Pipeline.init(gpm_floor: 0.22) | mesh: rested_mesh(:coord_a)}

    low_margin = intent(%{trade: :trade_g5d, nte: 1000, offer: 810})
    {state1, {:challenge, _}} = Pipeline.check(low_margin, state)
    repaired = intent(%{trade: :trade_g5d, nte: 1000, offer: 700})

    {_state2, {:escalated, esc}} =
      Pipeline.check(repaired, state1, attention_broker: Broker, now: @now)

    # window still open at proposed_at
    assert Broker.consent_by_silence(esc.proposal, 3_600_000, @now) == {:awaiting, :window_open}

    # window expired → silence consent (level :consent_by_silence)
    assert Broker.consent_by_silence(esc.proposal, 3_600_000, @now + 3_600_001) ==
             {:executed, :silence_consent}

    # supervised proposal NEVER auto-executes, whatever the clock says
    {_, {:escalated, sup_esc}} =
      Pipeline.check(intent(%{trade: :trade_g5e, nte: 1000, offer: 810}), state,
        attention_broker: Broker,
        proposal_level: :supervised,
        now: @now
      )
      |> then(fn {st, _} ->
        Pipeline.check(intent(%{trade: :trade_g5e, nte: 1000, offer: 700}), st,
          attention_broker: Broker,
          proposal_level: :supervised,
          now: @now
        )
      end)

    assert Broker.consent_by_silence(sup_esc.proposal, 1, @now + 9_999_999) ==
             {:awaiting, :supervisor}
  end
end
