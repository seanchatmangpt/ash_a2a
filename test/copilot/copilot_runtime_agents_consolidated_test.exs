# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
# SPDX-License-Identifier: MIT

# ==============================================================================
# Copilot Runtime & Agents Consolidated Suite
# Consolidated by Worker 16 from 9 original test files.
# All test modules, test cases, and tags preserved verbatim.
# ==============================================================================


# ==============================================================================
# SECTION 1/9: test/attention/broker_court_test.exs
# ==============================================================================

defmodule AshA2A.Attention.BrokerCourtTest do
  @moduledoc """
  Article-14 attention broker court. Clock injection only — zero
  `Process.sleep`. Exercises window expiry, supervised override
  semantics, override short-circuit, founder escalation, and the
  GPM-floor signature invariant on cards built from the landed
  CEO/COO stack.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Attention.Broker

  @window 5_000

  defp card(opts \\ []) do
    %{
      options: [
        %{
          option_id: :accept,
          summary: "accept",
          consequence: "trade executes",
          requires_signature: Keyword.get(opts, :requires_signature, false)
        }
      ],
      source: :manual,
      gpm_floor_breach: false
    }
  end

  defp gpm_card do
    %{
      options: [
        %{
          option_id: :accept,
          summary: "accept below floor",
          consequence: "margin breach",
          requires_signature: false
        }
      ],
      source: :gpm_floor,
      gpm_floor_breach: true
    }
  end

  describe "consent by silence" do
    test "executes after the injected clock passes the window at :consent_by_silence" do
      {:ok, p} = Broker.propose(:co_1, card(), level: :consent_by_silence, now: 1_000)

      assert {:awaiting, :window_open} =
               Broker.consent_by_silence(p, @window, 1_000 + @window - 1)

      assert {:executed, :silence_consent} =
               Broker.consent_by_silence(p, @window, 1_000 + @window)

      assert {:executed, :silence_consent} = Broker.consent_by_silence(p, @window, 9_999_999)
    end

    test "executes at :autonomous after window expiry" do
      {:ok, p} = Broker.propose(:co_1, card(), level: :autonomous, now: 0)
      assert {:executed, :silence_consent} = Broker.consent_by_silence(p, @window, @window)
    end

    test ":supervised NEVER auto-executes, regardless of elapsed window" do
      {:ok, p} = Broker.propose(:co_1, card(), level: :supervised, now: 0)
      assert {:awaiting, :supervisor} = Broker.consent_by_silence(p, @window, 10_000_000)
    end

    test "window boundary is exact: expiry at exactly window_ms" do
      {:ok, p} = Broker.propose(:co_1, card(), now: 0)
      assert {:awaiting, :window_open} = Broker.consent_by_silence(p, @window, @window - 1)
      assert {:executed, :silence_consent} = Broker.consent_by_silence(p, @window, @window)
    end
  end

  describe "override" do
    test "records a human decision in the ledger and short-circuits silence" do
      {:ok, p} = Broker.propose(:co_1, card(), now: 0)

      {:ok, ledger, entry} = Broker.override(p, "sig-founder", :reject)

      assert entry.proposal_id == p.id
      assert entry.decision == :reject

      assert {:refused, :already_decided} =
               Broker.consent_by_silence(p, @window, 10_000_000, ledger)
    end

    test "override with approval also blocks silence execution" do
      {:ok, p} = Broker.propose(:co_1, card(), now: 0)
      {:ok, ledger, _} = Broker.override(p, "sig-op", :approve)

      assert {:refused, :already_decided} =
               Broker.consent_by_silence(p, @window, 10_000_000, ledger)
    end

    test "second decision on one proposal is refused (no approve+reject)" do
      {:ok, p} = Broker.propose(:co_1, card(), now: 0)
      {:ok, ledger, _} = Broker.override(p, "sig-a", :approve)

      assert {:refused, :already_decided} = Broker.override(p, "sig-b", :reject, ledger)
      assert {:refused, :already_decided} = Broker.override(p, "sig-b", :approve, ledger)
      assert length(ledger[p.id]) == 1
    end

    test "decided ledger beats :supervised in consent_by_silence" do
      {:ok, p} = Broker.propose(:co_1, card(), level: :supervised, now: 0)
      {:ok, ledger, _} = Broker.override(p, "sig", :approve)
      assert {:refused, :already_decided} = Broker.consent_by_silence(p, @window, 0, ledger)
    end

    test "registered undecided proposal is not 'decided' and is seen by escalation" do
      {:ok, p} = Broker.propose(:co_1, card(), now: 0)
      ledger = Broker.register(%{}, p)

      assert {:executed, :silence_consent} =
               Broker.consent_by_silence(p, @window, @window, ledger)

      assert {:page, :founder} = Broker.escalation_path(ledger, unresolved_threshold: 1)
    end

    test "GPM-floor card refuses unsigned override; signed override accepted" do
      {:ok, p} = Broker.propose(:co_1, gpm_card(), now: 0)
      assert {:refused, :signature_required} = Broker.override(p, nil, :approve)
      assert {:refused, :signature_required} = Broker.override(p, "", :reject)
      assert {:ok, _, _} = Broker.override(p, "sig", :approve)
    end

    test "override accepts injected :now" do
      {:ok, p} = Broker.propose(:co_1, card(), now: 0)
      {:ok, _ledger, entry} = Broker.override(p, "sig", :approve, %{}, now: 4242)
      assert entry.recorded_at == 4242
    end
  end

  describe "propose level guard" do
    test "invalid level is a typed error; valid proposal carries at_least_one_signed" do
      assert {:error, {:invalid_level, :bogus}} = Broker.propose(:co_1, card(), level: :bogus)
      {:ok, p} = Broker.propose(:co_1, card())
      assert p.at_least_one_signed == false
    end
  end

  describe "escalation path" do
    test "pages founder when unresolved proposals reach the threshold" do
      ledger =
        1..3
        |> Enum.map(fn _ ->
          {:ok, p} = Broker.propose(:co_1, card(), now: 0)
          {p.id, []}
        end)
        |> Map.new()

      assert {:page, :founder} = Broker.escalation_path(ledger)
    end

    test "no escalation below threshold or when decisions are recorded" do
      {:ok, p1} = Broker.propose(:co_1, card(), now: 0)
      {:ok, p2} = Broker.propose(:co_1, card(), now: 0)
      {:ok, ledger, _} = Broker.override(p1, "sig", :approve)

      assert :no_escalation = Broker.escalation_path(%{p1.id => ledger[p1.id], p2.id => []})
      assert :no_escalation = Broker.escalation_path(%{p2.id => []})

      # Threshold is configurable.
      assert {:page, :founder} = Broker.escalation_path(%{p2.id => []}, unresolved_threshold: 1)
    end
  end

  describe "GPM-floor signature invariant" do
    test "propose forces requires_signature on all options of a GPM-floor card" do
      raw = gpm_card()

      assert Enum.any?(raw.options, &(&1.requires_signature == false))

      {:ok, p} = Broker.propose(:co_1, raw)
      assert Enum.all?(p.card.options, &(&1.requires_signature == true))
    end

    test "build_card/3 from a COO triage escalation edge forces signatures" do
      triage = {[], [%{ticket: %{id: "t1", warranty_status: :expired}}]}

      built = Broker.build_card(nil, triage)
      assert built.gpm_floor_breach == true
      assert Enum.all?(built.options, &(&1.requires_signature == true))

      {:ok, p} = Broker.propose(:co_1, built)
      assert Enum.all?(p.card.options, &(&1.requires_signature == true))
    end

    test "build_card/3 from a routine triage does NOT force signatures" do
      built = Broker.build_card(nil, {[%{ticket: %{id: "t1"}}], []})
      assert built.gpm_floor_breach == false
      assert Enum.all?(built.options, &(&1.requires_signature == false))
    end

    test "build_card/3 from a GPM-floor ceo challenge forces signatures" do
      challenge = %{code: :monkey_math, demanded_evidence: :cost_breakdown}
      built = Broker.build_card(challenge, nil)
      assert built.gpm_floor_breach == true
      assert Enum.all?(built.options, &(&1.requires_signature == true))
    end
  end

  describe "build_card integration with the landed stack (real collaborators)" do
    test "ceo GPM-floor breach challenge produces a signature-required card" do
      ceo = AshA2A.Twin.CEO.new()
      # offer 9000 on nte 10000 -> gpm 0.1 < floor 0.22 -> :gpm_floor challenge.
      nte = 10_000
      offer = 9_000

      assert AshA2A.Twin.CEO.gpm_breach?(nte, offer, 0.22)

      {_, {:challenge, challenge}} =
        AshA2A.Twin.CEO.evaluate_intent(ceo, %{trade: "T1", nte: nte, offer: offer})

      assert challenge.code == :gpm_floor
      assert challenge.demanded_evidence != []

      built = Broker.build_card(challenge, nil)
      assert built.source == :ceo_challenge
      assert built.gpm_floor_breach == true

      {:ok, p} = Broker.propose(:co_1, built)
      assert Enum.all?(p.card.options, &(&1.requires_signature == true))
    end

    test "coo escalation-edge triage output produces a signature-required card" do
      now = ~U[2026-11-07 12:00:00Z]

      bad_ticket = %{
        id: "t9",
        warranty_status: :expired,
        operating_hours: 100,
        sla_window: :open,
        contractor_coi_valid: true
      }

      good_ticket = %{
        id: "t1",
        warranty_status: :active,
        operating_hours: 100,
        sla_window: :open,
        contractor_coi_valid: true
      }

      {routine, edges} = AshA2A.Twin.COO.triage([bad_ticket, good_ticket], now: now)

      assert length(routine) == 1
      assert length(edges) == 1

      built = Broker.build_card(nil, {routine, edges})
      assert built.gpm_floor_breach == true
      assert Enum.all?(built.options, &(&1.requires_signature == true))
    end
  end
end


# ==============================================================================
# SECTION 2/9: test/copilot/f8_adversarial_test.exs
# ==============================================================================

defmodule AshA2A.Copilot.F8AdversarialTest do
  @moduledoc """
  Lane F8 adversarial court — AR3's five attacks as regression tests against
  the current pipeline (G4 authority hop + G5 Bridge threading present).

  Attack matrix (final):
    * A1 trade-respell ledger reset — EXPLOITED, FIXED via trade_key
      normalization in CEO (strings trimmed + case-folded; atoms pass through)
    * A2 authority hop fail-open / stage-order — DEFENDED (documented skip
      when unconfigured; fail-closed when configured)
    * A3 strain spoof via forged coordinator_id — EXPLOITED (channel-level;
      disclosed in Pipeline moduledoc, not fixed)
    * A4 retry_token redemption — DEFENDED (token not redeemable; the CEO
      ledger is the authority)
    * A5 admit-path sweep — negative-NTE admit FIXED upstream (CEO refuses nte <= 0 with
      typed :invalid_intent; asserted below); nil coordinator_id FIXED to a typed
      `:invalid_intent` refusal (asserted below)
  """

  use ExUnit.Case, async: false

  alias AshA2A.Attestation.Key
  alias AshA2A.Copilot.Pipeline
  alias AshA2A.Strain.Tensor
  alias AshA2A.Twin.COO

  @now 1_700_000_100

  defp fresh_claims(nonce) do
    %{
      "nonce" => nonce,
      "issued_at" => @now - 5,
      "camera_make" => "Apple",
      "camera_model" => "iPhone 15",
      "gps" => %{
        "lat" => 75.0,
        "lon" => 39.0,
        "accuracy" => 8.0,
        "timestamp" => @now - 5
      }
    }
  end

  defp signed_frame(nonce, key, actor \\ nil) do
    claims = fresh_claims(nonce)
    claims = if actor, do: Map.put(claims, "actor_id", actor), else: claims
    %{device_token: Key.sign(claims, key), nonce: nonce, key: key}
  end

  defp rested_mesh(ids) do
    Enum.reduce(ids, %{}, fn id, acc ->
      COO.register_coordinator(acc, id, Tensor.new(%{}))
    end)
  end

  defp intent(overrides) do
    Map.merge(
      %{
        trade: "HVAC.Drain",
        nte: 1000,
        offer: 720,
        coordinator_id: :alice,
        sensor_frame: :unused
      },
      overrides
    )
  end

  defp state_for(ids \\ [:alice]) do
    Pipeline.init([gpm_floor: 0.22, tolerance: 0.0], rested_mesh(ids))
  end

  # -- A1: trade-respell ledger reset (was EXPLOITED, fixed by trade_key) -----

  test "A1 respell variants collapse to ONE ledger identity" do
    state = state_for()

    {state1, {:challenge, _}} =
      Pipeline.check(intent(%{trade: "HVAC.Drain", nte: 1000, offer: 500}), state)

    assert state1.ceo.challenges["hvac.drain"] == 1

    for variant <- ["hvac.drain", " hvac.drain", "HVAC.Drain "] do
      assert {_, {:refuse, :escalate_multisig}} =
               Pipeline.check(intent(%{trade: variant, nte: 1000, offer: 500}), state1)
    end
  end

  test "A1b atom trades keep exact keys (atom-keyed courts unaffected)" do
    state = state_for()

    {state1, {:challenge, _}} =
      Pipeline.check(intent(%{trade: :Trade_CH, nte: 1000, offer: 500}), state)

    assert state1.ceo.challenges[:Trade_CH] == 1

    {state2, {:refuse, :escalate_multisig}} =
      Pipeline.check(intent(%{trade: :Trade_CH, nte: 1000, offer: 500}), state1)

    # CEO now counts every challenge incl. escalations (lane 05 contract)
    assert state2.ceo.challenges[:Trade_CH] == 2
  end

  # -- A2: authority hop fail-open / stage-order -------------------------------

  test "A2 configured authority source + no actor_id refuses (fail-closed)" do
    key = Key.generate()
    frame = signed_frame("nonce-a2", key)

    {_state, {:refuse, %{code: :authority, reason: %{reason: :missing_actor_id}}}} =
      Pipeline.check(intent(%{sensor_frame: frame}), state_for(),
        now: @now,
        authority_source: AshA2A.Authority.Source.AllowAll
      )
  end

  test "A2 stage order: bad attestation refuses BEFORE the authority hop" do
    key = Key.generate()
    stale_claims = fresh_claims("nonce-a2s") |> Map.put("issued_at", @now - 4000)
    frame = %{device_token: Key.sign(stale_claims, key), nonce: "nonce-a2s", key: key}

    defmodule F8DenyAll do
      @behaviour AshA2A.Authority.Source
      @impl true
      def check(_a, _act, _ctx, _o), do: :deny
    end

    {_state, {:refuse, %{code: :attestation, reason: {:refused, :stale}}}} =
      Pipeline.check(intent(%{sensor_frame: frame, actor_id: "p1"}), state_for(),
        now: @now,
        authority_source: F8DenyAll
      )
  end

  test "A2c authority bypass with clean attestation refuses (hop not skippable)" do
    key = Key.generate()
    frame = signed_frame("nonce-a2c", key)

    defmodule F8DenyAll2 do
      @behaviour AshA2A.Authority.Source
      @impl true
      def check(_a, _act, _ctx, _o), do: :deny
    end

    {_state,
     {:refuse, %{code: :authority, reason: %{reason: :source_deny, actor_id: "attacker-p1"}}}} =
      Pipeline.check(intent(%{sensor_frame: frame, actor_id: "attacker-p1"}), state_for(),
        now: @now,
        authority_source: F8DenyAll2
      )

    # forged standing fields on the intent buy nothing — refusal stays typed
    assert match?(
             {_state, {:refuse, %{code: :authority}}},
             Pipeline.check(
               intent(%{
                 sensor_frame: frame,
                 actor_id: "attacker-p1",
                 authority: :admin,
                 standing: :admin
               }),
               state_for(),
               now: @now,
               authority_source: F8DenyAll2
             )
           )
  end

  # -- A3: strain spoof via forged coordinator_id (disclosed, documented) ------

  test "A3 challenge observation credits the DECLARED coordinator_id (documents disclosed gap)" do
    state = state_for([:alice, :bob])

    {state1, {:challenge, _}} =
      Pipeline.check(
        intent(%{trade: "spoof-1", nte: 1000, offer: 500, coordinator_id: :bob}),
        state
      )

    # the disclosed gap: the observation credited the attacker-declared id
    assert state1.bridge[:bob].tensor.heuristic_frequency == 1
    assert {:assign, :bob} = Pipeline.route(%{friction: 0.5, candidates: [:bob]}, state1.bridge)
  end

  test "A3 forged coordinator_id refused via ATTESTED actor; intent.actor_id forgery buys nothing" do
    state = state_for([:alice, :bob])
    key = Key.generate()
    frame = signed_frame("nonce-a3", key, "mallory")
    binding = %{"mallory" => :alice, "bob-actor" => :bob}

    forged =
      intent(%{
        trade: "spoof-2",
        nte: 1000,
        offer: 500,
        coordinator_id: :bob,
        actor_id: "bob-actor",
        sensor_frame: frame
      })

    # intent.actor_id claims to be bob's actor; attested actor is mallory -> refused
    assert {state1, {:refuse, %{code: :coordinator_mismatch, reason: %{actor_id: "mallory"}}}} =
             Pipeline.check(forged, state, coordinator_binding: binding, now: @now)

    assert state1.bridge[:bob].tensor.heuristic_frequency == 0

    # honest bound actor passes the binding stage and is credited
    honest = %{forged | coordinator_id: :alice}

    assert {state2, {:challenge, _}} =
             Pipeline.check(honest, state, coordinator_binding: binding, now: @now)

    assert state2.bridge[:alice].tensor.heuristic_frequency == 1

    # no attested actor under explicit binding is refused
    nofr = signed_frame("nonce-a3b", key)

    assert {_, {:refuse, %{code: :coordinator_mismatch}}} =
             Pipeline.check(%{forged | sensor_frame: nofr}, state,
               coordinator_binding: binding,
               now: @now
             )
  end

  test "A3 default-on: attested actor differing from declared coordinator_id is refused without options" do
    state = state_for([:alice, :bob])
    key = Key.generate()
    frame = signed_frame("nonce-a3d", key, :alice)

    forged =
      intent(%{
        trade: "spoof-3",
        nte: 1000,
        offer: 500,
        coordinator_id: :bob,
        sensor_frame: frame
      })

    assert {state1, {:refuse, %{code: :coordinator_mismatch}}} =
             Pipeline.check(forged, state, now: @now)

    assert state1.bridge[:bob].tensor.heuristic_frequency == 0
  end

  test "unknown coordinator id is not auto-registered in the bridge" do
    state = state_for([:alice])

    {state1, _} =
      Pipeline.check(
        intent(%{trade: "ghost", nte: 1000, offer: 500, coordinator_id: :ghost}),
        state
      )

    refute Map.has_key?(state1.bridge, :ghost)
  end

  test "absent binding emits an observable stage_skipped event" do
    id = "w2-skip-#{System.unique_integer([:positive])}"
    me = self()

    :telemetry.attach(
      id,
      [:ash_a2a, :copilot, :stage_skipped],
      fn _, _, meta, _ ->
        send(me, {:skipped, meta.stage})
      end,
      nil
    )

    Pipeline.check(intent(%{trade: "skip-1"}), state_for(), prior: nil)
    :telemetry.detach(id)
    assert_received {:skipped, :coordinator_binding}
    assert_received {:skipped, :mechanical_prior}
  end

  # -- A4: retry_token is not redeemable ---------------------------------------

  test "A4 resubmitting with the retry_token attached still escalates (ledger is authority)" do
    state = state_for()

    {state1, {:challenge, ch}} =
      Pipeline.check(intent(%{trade: "HVAC.Drain", nte: 1000, offer: 500}), state)

    assert is_reference(ch.retry_token)

    {_state, {:refuse, :escalate_multisig}} =
      Pipeline.check(
        intent(%{trade: "HVAC.Drain", nte: 1000, offer: 500, retry_token: ch.retry_token}),
        state1
      )
  end

  # -- A5: admit-path sweep ----------------------------------------------------

  test "A5 gpm exactly at floor admits; just below challenges" do
    key = Key.generate()
    frame = signed_frame("nonce-a5", key)
    state = state_for()

    assert {_, {:ok, ticket}} =
             Pipeline.check(
               intent(%{trade: "floor-ok", nte: 100, offer: 78, sensor_frame: frame}),
               state,
               now: @now
             )

    assert ticket.gpm == 0.22

    assert {_, {:challenge, %{code: :gpm_floor}}} =
             Pipeline.check(intent(%{trade: "floor-below", nte: 100, offer: 79}), state)
  end

  test "A5 negative-NTE intent is refused typed by CEO (gap closed upstream)" do
    key = Key.generate()
    frame = signed_frame("nonce-a5n", key)

    assert {_, {:refuse, %{code: :invalid_intent, reason: :nte_not_positive}}} =
             Pipeline.check(
               intent(%{trade: "neg-nte", nte: -100, offer: -78, sensor_frame: frame}),
               state_for(),
               now: @now
             )
  end

  test "A5 coordinator_id nil returns typed refusal, does not raise" do
    state = state_for()

    assert {^state, {:refuse, %{code: :invalid_intent, reason: :coordinator_id_nil}}} =
             Pipeline.check(intent(%{coordinator_id: nil}), state)
  end
end


# ==============================================================================
# SECTION 3/9: test/copilot/pipeline_test.exs
# ==============================================================================

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


# ==============================================================================
# SECTION 4/9: test/dogfood/beam4pm_agent_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Dogfood.Beam4pmAgentTest do
  @moduledoc """
  Dogfood court: ash_a2a's own client against beam4pm's live A2A agent.

  beam4pm is a separate server (`scripts/beam4pm_up.sh`); ash_a2a never
  compiles it. Needs `BEAM4PM_A2A_URL` (e.g. http://127.0.0.1:4211/a2a); when
  absent or unreachable the court prints a loud `[SKIP]` and does not assert.

  beam4pm pins an older ash_a2a (git ref 99280b85), so results are
  old-server / new-client interop: a failure is a finding, not a test bug.
  """
  use ExUnit.Case, async: false

  @moduletag :external_api
  @moduletag :serial

  alias AshA2A.Protocol.{Client, Message, Part}

  setup do
    url = System.get_env("BEAM4PM_A2A_URL")

    cond do
      is_nil(url) ->
        IO.puts("[SKIP] BEAM4PM_A2A_URL unset (run scripts/beam4pm_up.sh)")
        {:ok, url: nil}

      reachable?(url) ->
        {:ok, url: url}

      true ->
        IO.puts("[SKIP] beam4pm agent not reachable at #{url}")
        {:ok, url: nil}
    end
  end

  test "discovers beam4pm's agent card with skills", %{url: url} do
    if url do
      assert {:ok, card} = Client.discover(url)
      assert card.name == "beam4pm_a2a_agent"
      assert length(card.skills) > 0

      IO.puts(
        "[dogfood] card: #{length(card.skills)} skills, protocol_version=#{inspect(Map.get(card, :protocol_version))}"
      )
    end
  end

  test "sends a :read skill and decodes a result", %{url: url} do
    if url do
      msg =
        struct(Message.new_user([Part.Text.new("go")]),
          metadata: %{"skill" => "BeamPM.Ash.Resources.OcelEvent.read"}
        )

      result = Client.send_message(url, msg)
      IO.puts("[dogfood] send_message -> #{inspect(result, limit: 6, printable_limit: 200)}")
      assert {:ok, _task_or_message} = result
    end
  end

  defp reachable?(url) do
    case Req.get(url <> "/.well-known/agent-card.json", retry: false, receive_timeout: 3_000) do
      {:ok, %{status: 200}} -> true
      _ -> false
    end
  end
end


# ==============================================================================
# SECTION 5/9: test/ingress/channel_test.exs
# ==============================================================================

defmodule AshA2A.Ingress.ChannelTest do
  use ExUnit.Case, async: true

  alias AshA2A.Attestation.Key
  alias AshA2A.Ingress.Channel

  @now 1_700_000_000

  setup do
    key = Key.generate()
    {:ok, key: key, state: Channel.empty_state()}
  end

  defp device_claims(opts \\ []) do
    now = Keyword.get(opts, :now, @now)

    gps =
      Keyword.get(opts, :gps, %{
        "lat" => 35.6812,
        "lon" => 139.7671,
        "accuracy" => 12.0,
        "timestamp" => now
      })

    %{
      "nonce" => Keyword.get(opts, :nonce, "nonce-1"),
      "issued_at" => now,
      "os_fingerprint" => "linux/x86_64",
      "installed_packages" => [],
      "is_virtual" => false,
      "gps" => gps
    }
  end

  defp event(opts) do
    now = Keyword.get(opts, :now, @now)

    %{
      coordinator: Keyword.get(opts, :coordinator, "coord-A"),
      nonce: Keyword.get(opts, :nonce, "nonce-1"),
      device_token: Keyword.fetch!(opts, :token),
      timestamp: now,
      gps:
        Keyword.get(opts, :gps, %{
          "lat" => 35.6812,
          "lon" => 139.7671,
          "accuracy" => 12.0,
          "timestamp" => now
        }),
      camera_make: Keyword.get(opts, :camera_make, "Google"),
      camera_model: Keyword.get(opts, :camera_model, "Pixel 8")
    }
  end

  test "admits a correctly-signed fresh on-site check-in and normalizes the event", %{
    key: key,
    state: state
  } do
    token = Key.sign(device_claims(), key)
    {{:ok, validated}, state2} = Channel.ingest(state, event(token: token), key: key, now: @now)

    assert validated.coordinator == "coord-A"
    assert validated.timestamp == @now
    assert validated.ingested_at == @now
    assert validated.camera_make == "Google"
    assert validated.claims["nonce"] == "nonce-1"
    assert validated.gps["lat"] == 35.6812
    assert state2.last_known["coord-A"]["timestamp"] == @now
    assert Channel.stats(state2) == %{}
  end

  test "refuses a token signed by a foreign key with :bad_signature", %{key: key, state: state} do
    rogue = Key.generate()
    token = Key.sign(device_claims(), rogue)

    {{:refused, reason}, state2} = Channel.ingest(state, event(token: token), key: key, now: @now)
    assert reason == :bad_signature
    assert Channel.stats(state2) == %{bad_signature: 1}
  end

  test "refuses an emulator-declaring device with :emulator_detected", %{key: key, state: state} do
    claims = device_claims() |> Map.put("is_virtual", true)
    token = Key.sign(claims, key)

    {{:refused, :emulator_detected}, state2} =
      Channel.ingest(state, event(token: token), key: key, now: @now)

    assert Channel.stats(state2) == %{emulator_detected: 1}
  end

  test "refuses an attestation signed in the past with :stale", %{key: key, state: state} do
    token = Key.sign(device_claims(now: @now - 3600), key)

    {{:refused, :stale}, state2} = Channel.ingest(state, event(token: token), key: key, now: @now)
    assert Channel.stats(state2) == %{stale: 1}
  end

  test "refuses sensor metadata without camera claims as :spoofed_payload", %{
    key: key,
    state: state
  } do
    token = Key.sign(device_claims(), key)

    {{:refused, :spoofed_payload}, state2} =
      Channel.ingest(state, event(token: token, camera_make: ""), key: key, now: @now)

    assert Channel.stats(state2) == %{spoofed_payload: 1}
  end

  test "refuses absurd GPS accuracy as :spoofed_payload", %{key: key, state: state} do
    token = Key.sign(device_claims(), key)

    bad_gps = %{"lat" => 35.6812, "lon" => 139.7671, "accuracy" => 500_000.0, "timestamp" => @now}

    {{:refused, :spoofed_payload}, _} =
      Channel.ingest(state, event(token: token, gps: bad_gps), key: key, now: @now)
  end

  test "refuses a nonce mismatch as :spoofed_payload (folded vocabulary)", %{
    key: key,
    state: state
  } do
    token = Key.sign(device_claims(nonce: "nonce-1"), key)

    {{:refused, reason}, state2} =
      Channel.ingest(state, event(token: token, nonce: "nonce-OTHER"), key: key, now: @now)

    assert reason == :spoofed_payload
    assert Channel.stats(state2) == %{spoofed_payload: 1}
  end

  test "refuses a structurally-broken token as :spoofed_payload", %{key: key, state: state} do
    {{:refused, :spoofed_payload}, _} =
      Channel.ingest(state, event(token: "garbage"), key: key, now: @now)
  end

  test "refuses consecutive-event GPS teleport across two ingests", %{key: key, state: state} do
    # Fix 1: Tokyo, fresh.
    t1 = Key.sign(device_claims(nonce: "n1"), key)
    e1 = event(token: t1, nonce: "n1")

    {{:ok, _}, state1} = Channel.ingest(state, e1, key: key, now: @now)

    # Fix 2: 45 seconds later, Lisbon (~11,000 km away) — physically impossible.
    t2t = @now + 45

    lisbon = %{"lat" => 38.7223, "lon" => -9.1393, "accuracy" => 15.0, "timestamp" => t2t}
    t2 = Key.sign(device_claims(nonce: "n2", now: t2t, gps: lisbon), key)
    e2 = event(token: t2, nonce: "n2", now: t2t, gps: lisbon)

    {{:refused, :gps_impossible_jump}, state2} = Channel.ingest(state1, e2, key: key, now: t2t)

    # Fix 3: a plausible short hop (Tokyo -> Yokohama, ~27 km in 60s) is admitted
    # and updates the last-known fix.
    t3t = t2t + 60

    yokohama = %{"lat" => 35.4437, "lon" => 139.6380, "accuracy" => 10.0, "timestamp" => t3t}
    t3 = Key.sign(device_claims(nonce: "n3", now: t3t, gps: yokohama), key)
    e3 = event(token: t3, nonce: "n3", now: t3t, gps: yokohama)

    {{:ok, validated}, state3} = Channel.ingest(state2, e3, key: key, now: t3t)
    assert validated.gps["lat"] == 35.4437
    assert state3.last_known["coord-A"]["lat"] == 35.4437

    assert Channel.stats(state3) == %{gps_impossible_jump: 1}
  end

  test "refusals accumulate across reasons and coordinators are independent", %{key: key} do
    state = Channel.empty_state()

    rogue = Key.generate()

    e1 = event(token: Key.sign(device_claims(nonce: "a"), rogue), nonce: "a", coordinator: "c1")

    e2 =
      event(
        token: Key.sign(device_claims(nonce: "b", now: @now - 9999), key),
        nonce: "b",
        coordinator: "c2"
      )

    {_, state1} = Channel.ingest(state, e1, key: key, now: @now)
    {_, state2} = Channel.ingest(state1, e2, key: key, now: @now)

    assert Channel.stats(state2) == %{:bad_signature => 1, :stale => 1}
    assert state2.last_known == %{}
  end

  test "a missing signature key raises KeyError (fail-loud configuration error)", %{state: state} do
    assert_raise KeyError, fn ->
      Channel.ingest(state, event(token: "x"), now: @now)
    end
  end

  # --- F7 defenses ---

  describe "nonce replay (per-coordinator consumed-nonce ledger)" do
    test "a successfully-ingested event replayed verbatim is {:refused, :nonce_replayed}", %{
      key: key,
      state: state
    } do
      token = Key.sign(device_claims(nonce: "n1"), key)
      e = event(token: token, nonce: "n1")

      {{:ok, _}, state1} = Channel.ingest(state, e, key: key, now: @now)
      {{:refused, :nonce_replayed}, state2} = Channel.ingest(state1, e, key: key, now: @now + 1)

      assert Channel.stats(state2) == %{nonce_replayed: 1}
    end

    test "replay of a DIFFERENT token under an already-consumed nonce is refused", %{
      key: key,
      state: state
    } do
      t1 = Key.sign(device_claims(nonce: "n1"), key)

      {{:ok, _}, state1} =
        Channel.ingest(state, event(token: t1, nonce: "n1"), key: key, now: @now)

      t2 = Key.sign(device_claims(nonce: "n1", now: @now + 10), key)

      {{:refused, :nonce_replayed}, _} =
        Channel.ingest(state1, event(token: t2, nonce: "n1"), key: key, now: @now + 10)
    end

    test "replay refusal happens BEFORE crypto work (forged twin of consumed nonce refused identically)",
         %{key: key, state: state} do
      t1 = Key.sign(device_claims(nonce: "n1"), key)

      {{:ok, _}, state1} =
        Channel.ingest(state, event(token: t1, nonce: "n1"), key: key, now: @now)

      rogue = Key.generate()

      {{:refused, :nonce_replayed}, _} =
        Channel.ingest(
          state1,
          event(token: Key.sign(device_claims(nonce: "n1"), rogue), nonce: "n1"),
          key: key,
          now: @now
        )
    end

    test "nonce ledgers are per-coordinator (same nonce from another coordinator is fresh)", %{
      key: key,
      state: state
    } do
      t1 = Key.sign(device_claims(nonce: "n1", now: @now), key)

      {{:ok, _}, state1} =
        Channel.ingest(state, event(token: t1, nonce: "n1", coordinator: "c1"),
          key: key,
          now: @now
        )

      t2 = Key.sign(device_claims(nonce: "n1", now: @now), key)

      {{:ok, _}, _} =
        Channel.ingest(state1, event(token: t2, nonce: "n1", coordinator: "c2"),
          key: key,
          now: @now
        )
    end

    test "a refused ingest does not consume its nonce (retry with corrected metadata is allowed)",
         %{key: key, state: state} do
      token = Key.sign(device_claims(), key)

      {{:refused, :spoofed_payload}, state1} =
        Channel.ingest(state, event(token: token, camera_make: ""), key: key, now: @now)

      {{:ok, _}, _} = Channel.ingest(state1, event(token: token), key: key, now: @now)
    end
  end

  test "future-issued attestation beyond skew is {:refused, :clock_skew}", %{
    key: key,
    state: state
  } do
    token = Key.sign(device_claims(now: @now + 60), key)

    {{:refused, :clock_skew}, state2} =
      Channel.ingest(state, event(token: token), key: key, now: @now)

    assert Channel.stats(state2) == %{clock_skew: 1}
  end

  test "malleated-signature token is {:refused, :non_canonical_signature} (not :bad_signature)",
       %{key: key, state: state} do
    token = Key.sign(device_claims(nonce: "nm"), key)
    twin = malleate(token)

    {{:refused, :non_canonical_signature}, state2} =
      Channel.ingest(state, event(token: twin, nonce: "nm"), key: key, now: @now)

    assert Channel.stats(state2) == %{non_canonical_signature: 1}
  end

  # Platform law (OTP 28): NaN floats are unconstructible — float bit-pattern
  # matches, :math domain errors, and arithmetic overflow all raise. The
  # reachable form of the "non-finite coordinate" attack on this substrate is
  # an adversarially huge integer, which the gate must refuse without letting
  # :math crash the caller.
  test "adversarially huge integer coordinate is {:refused, :spoofed_payload} without crashing",
       %{key: key, state: state} do
    huge = String.duplicate("9", 400) |> String.to_integer()
    bad_gps = %{"lat" => huge, "lon" => 139.7671, "accuracy" => 12.0, "timestamp" => @now}
    token = Key.sign(device_claims(), key)

    {{:refused, :spoofed_payload}, _} =
      Channel.ingest(state, event(token: token, gps: bad_gps), key: key, now: @now)
  end

  test "coordinate supplied as a string is {:refused, :spoofed_payload}", %{
    key: key,
    state: state
  } do
    string_gps = %{"lat" => "35.6812", "lon" => 139.7671, "accuracy" => 12.0, "timestamp" => @now}
    token = Key.sign(device_claims(), key)

    {{:refused, :spoofed_payload}, _} =
      Channel.ingest(state, event(token: token, gps: string_gps), key: key, now: @now)
  end

  test "signed-subset confusion: event GPS disagreeing with signed claims GPS is {:refused, :spoofed_payload}",
       %{key: key, state: state} do
    # Token signed over a Tokyo fix; attacker submits the same token with a
    # Lisbon event fix — the signature does not cover the event, so the
    # channel must bind them.
    lisbon = %{"lat" => 38.7223, "lon" => -9.1393, "accuracy" => 15.0, "timestamp" => @now}
    token = Key.sign(device_claims(), key)

    {{:refused, :spoofed_payload}, state2} =
      Channel.ingest(state, event(token: token, gps: lisbon), key: key, now: @now)

    assert Channel.stats(state2) == %{spoofed_payload: 1}
    # no last-known fix was recorded from the forged geometry
    assert state2.last_known == %{}
  end

  test "signed claims without sensor fields do not bind (backward-compatible)", %{
    key: key,
    state: state
  } do
    claims = device_claims() |> Map.delete("gps")
    token = Key.sign(claims, key)
    {{:ok, _}, _} = Channel.ingest(state, event(token: token), key: key, now: @now)
  end

  # --- test-local crypto helpers ---

  @n 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551

  defp malleate(token) do
    [pfx, payload, sig] = String.split(token, ".", parts: 3)
    der = Base.url_decode64!(sig, padding: false)
    <<0x30, _len, body::binary>> = der
    <<0x02, rlen, r::binary-size(rlen), 0x02, slen, s_bin::binary-size(slen)>> = body

    s = :binary.decode_unsigned(s_bin)
    s2_bin = der_int(@n - s)
    body2 = <<0x02, byte_size(r), r::binary, 0x02, byte_size(s2_bin), s2_bin::binary>>
    der2 = <<0x30, byte_size(body2), body2::binary>>

    Enum.join([pfx, payload, Base.url_encode64(der2, padding: false)], ".")
  end

  defp der_int(v) do
    bin = :binary.encode_unsigned(v)

    case bin do
      <<first, _::binary>> when first >= 128 -> <<0, bin::binary>>
      _ -> bin
    end
  end
end


# ==============================================================================
# SECTION 6/9: test/ingress/lane01_ingress_hardening_test.exs
# ==============================================================================

defmodule AshA2A.Ingress.Lane01IngressHardeningTest do
  use ExUnit.Case, async: true

  alias AshA2A.Attestation.Key
  alias AshA2A.Ingress.Channel

  @now 1_700_000_000

  defp gps(lat, lon, ts), do: %{"lat" => lat, "lon" => lon, "accuracy" => 12.0, "timestamp" => ts}

  defp checkin(key, nonce, now, g) do
    claims = %{
      "nonce" => nonce,
      "issued_at" => now,
      "os_fingerprint" => "linux",
      "installed_packages" => [],
      "is_virtual" => false,
      "gps" => g
    }

    %{
      coordinator: "c",
      nonce: nonce,
      device_token: Key.sign(claims, key),
      timestamp: now,
      gps: g,
      camera_make: "Google",
      camera_model: "Pixel 8"
    }
  end

  setup do: {:ok, key: Key.generate()}

  test "nonce ledger is FIFO-bounded at 1024", %{key: key} do
    state =
      Enum.reduce(1..1025, Channel.empty_state(), fn i, st ->
        {{:ok, _}, st} =
          Channel.ingest(st, checkin(key, "n#{i}", @now, gps(35.0, 139.0, @now)),
            key: key,
            now: @now
          )

        st
      end)

    assert length(state.consumed_nonces["c"].order) == 1024
    # n1 evicted: no longer replay-refused (ledger weakening documented); n1025 still refused.
    {{:refused, :nonce_replayed}, _} =
      Channel.ingest(state, checkin(key, "n1025", @now, gps(35.0, 139.0, @now)),
        key: key,
        now: @now
      )

    refute MapSet.member?(state.consumed_nonces["c"].set, "n1")
  end

  test "unknown refusal shape folds to :spoofed_payload instead of crashing", %{key: key} do
    event = %{checkin(key, "x", @now, gps(35.0, 139.0, @now)) | device_token: "v1.!!!.@@@"}

    assert {{:refused, :spoofed_payload}, _} =
             Channel.ingest(Channel.empty_state(), event, key: key, now: @now)
  end

  test "approved grants flow through ingest/3 to the trajectory check", %{key: key} do
    grant = %{
      grant_id: "g",
      org_id: "o",
      identifier_or_cidr: "i",
      ttl_hours: 24,
      approved_at: @now - 60,
      area: %{"lat" => 37.0, "lon" => -122.0, "radius_km" => 2000.0}
    }

    {{:ok, _}, st} =
      Channel.ingest(Channel.empty_state(), checkin(key, "a", @now, gps(37.0, -122.0, @now)),
        key: key,
        now: @now
      )

    t2 = @now + 30
    ev = checkin(key, "b", t2, gps(47.0, -115.0, t2))

    assert {{:refused, :gps_impossible_jump}, _} = Channel.ingest(st, ev, key: key, now: t2)
    assert {{:ok, _}, _} = Channel.ingest(st, ev, key: key, now: t2, approved_grants: [grant])
  end

  test "unsigned far-future/stale event timestamp cannot skip the jump check", %{key: key} do
    {{:ok, _}, st} =
      Channel.ingest(Channel.empty_state(), checkin(key, "a", @now, gps(37.0, -122.0, @now)),
        key: key,
        now: @now
      )

    t2 = @now + 30
    ev = %{checkin(key, "b", t2, gps(47.0, -115.0, t2)) | timestamp: t2 + 10_000}
    assert {{:refused, :clock_skew}, _} = Channel.ingest(st, ev, key: key, now: t2)
  end

  test "out-of-order older event does not overwrite last_known", %{key: key} do
    {{:ok, _}, st} =
      Channel.ingest(Channel.empty_state(), checkin(key, "a", @now, gps(37.0, -122.0, @now)),
        key: key,
        now: @now
      )

    older = @now - 20

    {{:ok, _}, st} =
      Channel.ingest(st, checkin(key, "b", older, gps(37.0, -122.0, older)), key: key, now: @now)

    assert st.last_known["c"]["timestamp"] == @now
  end
end


# ==============================================================================
# SECTION 7/9: test/negotiation/negotiation_engine_court_test.exs
# ==============================================================================

defmodule AshA2A.Negotiation.EngineCourtTest do
  use ExUnit.Case, async: true

  alias AshA2A.Negotiation.{DefaultStrategy, Engine, Strategy}

  # A fake strategy is a hand-written real interface implementation, not a
  # mock — used only for the typed contract-violation court cell.
  defmodule ViolentStrategy do
    @behaviour AshA2A.Negotiation.Strategy

    @impl true
    def evaluate_offers(_claim, _ctx), do: {:threaten, "pay up"}
  end

  defmodule NilOfferStrategy do
    @behaviour AshA2A.Negotiation.Strategy

    @impl true
    def evaluate_offers(_claim, _ctx), do: {:accept, "not a map"}
  end

  describe "liquidity_zone/1" do
    test "thin when vendor_count <= 1" do
      assert Engine.liquidity_zone(0) == :thin
      assert Engine.liquidity_zone(1) == :thin
      assert Engine.liquidity_zone(2) == :liquid
    end
  end

  describe "thin market + above-baseline quote" do
    test "escalates to counter with factual leverage terms" do
      claim = %{
        "price" => 9_500,
        "cost_baseline" => 8_000,
        "portfolio_leverage" => "12 scheduled-maintenance units",
        "compliance_exposure" => %{permit_status: :current, epa_608: :certified, findings: 0}
      }

      offers = [%{"vendor" => "monopoly-hvac", "price" => 9_500}]

      assert {:counter, offer, leverage: terms} =
               Engine.run(claim, offers, DefaultStrategy)

      assert offer["price"] == 8_000
      assert offer["round"] == 1

      assert terms == [
               {:portfolio_volume, "12 scheduled-maintenance units"},
               {:compliance_status, %{permit_status: :current, epa_608: :certified, findings: 0}}
             ]
    end
  end

  describe "stall" do
    test "negotiation past max_rounds parks as escrow" do
      claim = %{"price" => 9_500, "cost_baseline" => 8_000}
      offers = [%{"vendor" => "monopoly-hvac", "price" => 9_500}]

      assert {:escrow, {:parked, {:stalled, 4, 3}}} =
               Engine.run(claim, offers, DefaultStrategy, round: 4, max_rounds: 3)

      # Vocabulary mapping: parked matches the Steps.Await {:parked, :waiting}
      # shape documented in the Engine moduledoc (Providers.PPlan vocabulary).
      assert match?({:parked, _}, {:parked, {:stalled, 4, 3}})
    end
  end

  describe "liquid market" do
    test "above-baseline quote accepts plainly — no counter in a liquid market" do
      claim = %{"price" => 9_500, "cost_baseline" => 8_000}
      offers = [%{"v1" => 1}, %{"v2" => 2}]

      assert {:accept, offer} = Engine.run(claim, offers, DefaultStrategy)
      assert offer["price"] == 9_500
    end

    test "thin market with below-baseline quote accepts" do
      claim = %{"price" => 7_000, "cost_baseline" => 8_000}
      offers = [%{"vendor" => "solo"}]

      assert {:accept, offer} = Engine.run(claim, offers, DefaultStrategy)
      assert offer["price"] == 7_000
    end
  end

  describe "strategy contract violations" do
    test "non-lawful return is typed as a parked strategy_contract_violation" do
      assert {:escrow, {:parked, {:strategy_contract_violation, {:threaten, "pay up"}}}} =
               Engine.run(%{}, [%{}], ViolentStrategy)
    end

    test "accept with a non-map offer is typed as a violation" do
      assert {:escrow, {:parked, {:strategy_contract_violation, {:accept, "not a map"}}}} =
               Engine.run(%{}, [%{}], NilOfferStrategy)
    end
  end

  test "strategy behaviour is loaded and documents the leverage law" do
    assert [evaluate_offers: 2] = Strategy.behaviour_info(:callbacks)

    assert String.contains?(
             File.read!(Path.join(File.cwd!(), "lib/ash_a2a/negotiation/strategy.ex")),
             "Leverage = factual compliance status, never threats"
           )
  end
end


# ==============================================================================
# SECTION 8/9: test/strain/bridge_test.exs
# ==============================================================================

defmodule AshA2A.Strain.BridgeTest do
  use ExUnit.Case, async: true

  alias AshA2A.Strain.{Bridge, Tensor}

  describe "record_observation/3 dimension mapping" do
    test "ticket_assigned increments active_leases" do
      ms = Bridge.new_mesh_state([:a])

      ms = Bridge.record_observation(ms, :a, %{type: :ticket_assigned})
      ms = Bridge.record_observation(ms, :a, %{type: :ticket_assigned})

      assert ms[:a].tensor.active_leases == 2
    end

    test "ticket_completed decrements active_leases with floor at 0" do
      ms = Bridge.new_mesh_state([:a])

      ms = Bridge.record_observation(ms, :a, %{type: :ticket_completed})

      assert ms[:a].tensor.active_leases == 0

      ms = Bridge.record_observation(ms, :a, %{type: :ticket_assigned})
      ms = Bridge.record_observation(ms, :a, %{type: :ticket_completed})

      assert ms[:a].tensor.active_leases == 0
    end

    test "challenge_received from CEO increments heuristic_frequency" do
      ms = Bridge.new_mesh_state([:a])

      ms =
        Enum.reduce(1..3, ms, fn _, acc ->
          Bridge.record_observation(acc, :a, %{
            type: :challenge_received,
            source: :ceo,
            heuristic: :gaslight_pattern
          })
        end)

      assert ms[:a].tensor.heuristic_frequency == 3
    end

    test "error_reported feeds the rolling window and error_rate" do
      ms = Bridge.new_mesh_state([:a])

      ms =
        ms
        |> Bridge.record_observation(:a, %{type: :error_reported, error: true})
        |> Bridge.record_observation(:a, %{type: :error_reported, error: false})
        |> Bridge.record_observation(:a, %{type: :error_reported, error: true})

      assert ms[:a].error_window == [1, 0, 1]
      assert_in_delta Bridge.error_rate(ms, :a), 2 / 3, 1.0e-9
    end

    test "error window is capped at 20 entries" do
      ms =
        Enum.reduce(1..25, Bridge.new_mesh_state([:a]), fn _, acc ->
          Bridge.record_observation(acc, :a, %{type: :error_reported, error: true})
        end)

      assert length(ms[:a].error_window) == 20
      assert ms[:a].tensor.error_rate == 1.0
    end

    test "clock_hour advances shift_hours via the decay input" do
      ms = Bridge.new_mesh_state([:a])

      ms =
        Enum.reduce(1..8, ms, fn _, acc ->
          Bridge.record_observation(acc, :a, %{type: :clock_hour, hours: 1})
        end)

      assert ms[:a].tensor.shift_hours_continuous == 8
      # circadian decay 1 - exp(-8/4) ~= 0.8647
      decay = Bridge.circadian_decay(ms, :a)
      assert decay > 0.85 and decay < 0.87
    end

    test "unknown event type raises" do
      ms = Bridge.new_mesh_state([:a])

      assert_raise ArgumentError, ~r/unknown observation type/, fn ->
        Bridge.record_observation(ms, :a, %{type: :mystery_event})
      end
    end
  end

  describe "route/2" do
    test "picks the min-strain coordinator among candidates" do
      fresh = Bridge.new_mesh_state([:fresh, :loaded])

      loaded =
        Enum.reduce(1..6, fresh, fn _, acc ->
          Bridge.record_observation(acc, :loaded, %{type: :ticket_assigned})
        end)

      assert {:assign, :fresh} = Bridge.route(%{candidates: [:fresh, :loaded]}, loaded)
    end

    test "sheds with reason when all candidates are saturated" do
      ms =
        Enum.reduce(1..12, Bridge.new_mesh_state([:a]), fn _, acc ->
          acc
          |> Bridge.record_observation(:a, %{type: :ticket_assigned})
          |> Bridge.record_observation(:a, %{type: :clock_hour, hours: 1})
          |> Bridge.record_observation(:a, %{type: :error_reported, error: true})
        end)

      assert {:shed, {:senior_queue, :all_saturated}} =
               Bridge.route(%{candidates: [:a]}, ms)
    end

    test "unknown candidate ids are skipped, not crashed" do
      ms = Bridge.new_mesh_state([:a])
      assert {:assign, :a} = Bridge.route(%{candidates: [:ghost, :a]}, ms)

      assert {:shed, {:senior_queue, _}} = Bridge.route(%{candidates: [:ghost]}, ms)
    end
  end

  describe "fatigue-diversion invariant court" do
    setup do
      # tired: shift past the 0.85 decay threshold, error drift rising
      tired =
        Enum.reduce(1..12, Bridge.new_mesh_state([:tired, :fresh]), fn _, acc ->
          Bridge.record_observation(acc, :tired, %{type: :ticket_assigned})
        end)

      tired =
        Enum.reduce(1..14, tired, fn i, acc ->
          acc
          |> Bridge.record_observation(:tired, %{type: :clock_hour, hours: 0.65})
          |> Bridge.record_observation(:tired, %{type: :error_reported, error: i > 4})
        end)

      assert Bridge.circadian_decay(tired, :tired) > 0.85
      assert Bridge.error_drift_rising?(tired, :tired)

      tired =
        Enum.reduce(1..3, tired, fn _, acc ->
          Bridge.record_observation(acc, :tired, %{type: :ticket_completed})
        end)

      %{mesh: tired}
    end

    test "deep decay + rising drift diverts high-friction ticket to fresh coordinator", %{
      mesh: mesh
    } do
      ticket = %{friction: 0.9, candidates: [:tired, :fresh]}

      assert {:assign, :fresh} = Bridge.route(ticket, mesh)
    end

    test "deep decay alone (stable errors) does NOT divert", %{mesh: mesh} do
      # settle the window: half errors, uniform -> drift not rising
      mesh =
        Enum.reduce(1..20, mesh, fn _, acc ->
          Bridge.record_observation(acc, :tired, %{type: :error_reported, error: true})
        end)

      # 12 leases -> saturated; complete 4 to drop below the gate
      mesh =
        Enum.reduce(1..4, mesh, fn _, acc ->
          Bridge.record_observation(acc, :tired, %{type: :ticket_completed})
        end)

      assert Bridge.circadian_decay(mesh, :tired) > 0.85
      refute Bridge.error_drift_rising?(mesh, :tired)
      assert Tensor.hyperplane_check(mesh[:tired].tensor) == :ok

      # eligibility invariant: non-fatigued deep-decay coordinator may receive
      # the ticket (min-strain may still prefer :fresh, which is lawful)
      assert {:assign, :tired} = Bridge.route(%{friction: 0.9, candidates: [:tired]}, mesh)
    end

    test "50-ticket sweep: every ticket ends assigned or shed-with-reason, none dropped", %{
      mesh: mesh
    } do
      # seeded: deterministic across runs (no global :rand state)
      seed = :rand.seed_s(:exsss, {101, 102, 103})

      {tickets, _} =
        Enum.map_reduce(1..50, seed, fn i, st ->
          {f, st2} = :rand.uniform_s(st)
          {%{id: i, friction: f, candidates: [:tired, :fresh]}, st2}
        end)

      outcomes = Enum.map(tickets, &Bridge.route(&1, mesh))

      assert length(outcomes) == 50

      Enum.each(outcomes, fn
        {:assign, id} -> assert id in [:tired, :fresh]
        {:shed, {:senior_queue, reason}} -> assert not is_nil(reason)
      end)

      assert Enum.all?(outcomes, fn
               {:assign, _} -> true
               {:shed, _} -> true
               _ -> false
             end)
    end

    test "all-fatigued high-friction sheds with the friction-specific reason" do
      ms =
        Enum.reduce(1..14, Bridge.new_mesh_state([:only]), fn i, acc ->
          acc
          |> Bridge.record_observation(:only, %{type: :clock_hour, hours: 0.65})
          |> Bridge.record_observation(:only, %{type: :error_reported, error: i > 4})
        end)

      assert Bridge.circadian_decay(ms, :only) > 0.85
      assert Bridge.error_drift_rising?(ms, :only)

      assert {:shed, {:senior_queue, {:all_saturated_or_fatigued, :high_friction}}} =
               Bridge.route(%{friction: 0.95, candidates: [:only]}, ms)
    end
  end

  test "termination by construction: routing 200 tickets over a finite mesh returns exactly 200 outcomes" do
    ms = Bridge.new_mesh_state([:a, :b, :c])

    outcomes =
      Enum.map(1..200, fn i ->
        Bridge.route(%{id: i, friction: rem(i, 4) / 4, candidates: [:a, :b, :c]}, ms)
      end)

    assert length(outcomes) == 200

    assert Enum.all?(outcomes, fn
             {:assign, _} -> true
             {:shed, {:senior_queue, _}} -> true
           end)
  end

  describe "event contract and validation" do
    test "error flag: true/1 count, false/0/nil/missing do not; other values raise" do
      ms = Bridge.new_mesh_state([:c])

      rate = fn events ->
        events
        |> Enum.reduce(
          ms,
          &Bridge.record_observation(&2, :c, Map.put(&1, :type, :error_reported))
        )
        |> Bridge.error_rate(:c)
      end

      assert rate.([%{error: true}, %{error: 1}]) == 1.0
      assert rate.([%{error: false}, %{error: 0}, %{error: nil}, %{}]) == 0.0
      assert rate.([%{error: true}, %{}]) == 0.5

      assert_raise ArgumentError, ~r/invalid error flag/, fn -> rate.([%{error: "yes"}]) end
    end

    test "clock_hour :hours validation" do
      ms = Bridge.new_mesh_state([:c])

      for bad <- [-1, "2", nil, :x] do
        assert_raise ArgumentError, ~r/non-negative number/, fn ->
          Bridge.record_observation(ms, :c, %{type: :clock_hour, hours: bad})
        end
      end

      ms2 = Bridge.record_observation(ms, :c, %{type: :clock_hour})
      assert ms2[:c].tensor.shift_hours_continuous == 1
      ms3 = Bridge.record_observation(ms2, :c, %{type: :clock_hour, hours: 0})
      assert ms3[:c].tensor.shift_hours_continuous == 1
    end

    test "unregistered ids read consistently as zero/false" do
      ms = Bridge.new_mesh_state([:known])
      assert Bridge.circadian_decay(ms, :ghost) == 0.0
      assert Bridge.error_rate(ms, :ghost) == 0.0
      refute Bridge.error_drift_rising?(ms, :ghost)
    end

    test "empty candidates shed with :no_candidates, distinct from saturation" do
      ms = Bridge.new_mesh_state([:a])
      assert {:shed, {:senior_queue, :no_candidates}} = Bridge.route(%{candidates: []}, ms)

      assert {:shed, {:senior_queue, :no_candidates}} =
               Bridge.route(%{friction: 0.9, candidates: []}, ms)

      # only-unknown candidates keep the generic reason
      assert {:shed, {:senior_queue, :all_saturated}} = Bridge.route(%{candidates: [:ghost]}, ms)
      # empty mesh, default candidates
      assert {:shed, {:senior_queue, :no_candidates}} = Bridge.route(%{}, Bridge.new_mesh_state())
    end
  end

  describe "error_drift_rising?/2 direct" do
    defp with_errors(flags) do
      Enum.reduce(flags, Bridge.new_mesh_state([:c]), fn f, acc ->
        Bridge.record_observation(acc, :c, %{type: :error_reported, error: f})
      end)
    end

    test "needs at least 4 outcomes" do
      refute Bridge.error_drift_rising?(with_errors([false, false, true]), :c)
      assert Bridge.error_drift_rising?(with_errors([false, false, true, true]), :c)
    end

    test "rising when recent half has more errors than older half" do
      assert Bridge.error_drift_rising?(with_errors([false, false, false, true, true, true]), :c)
    end

    test "falling or flat is not rising" do
      refute Bridge.error_drift_rising?(with_errors([true, true, true, false, false, false]), :c)
      refute Bridge.error_drift_rising?(with_errors([true, false, true, false]), :c)
      refute Bridge.error_drift_rising?(with_errors([false, false, false, false]), :c)
    end
  end

  describe "fatigue gate: negatives and breach" do
    defp tired_mesh(error_flags) do
      ms = Bridge.new_mesh_state([:tired, :fresh])

      ms =
        Enum.reduce(1..14, ms, fn _, acc ->
          Bridge.record_observation(acc, :tired, %{type: :clock_hour, hours: 0.65})
        end)

      Enum.reduce(error_flags, ms, fn f, acc ->
        Bridge.record_observation(acc, :tired, %{type: :error_reported, error: f})
      end)
    end

    test "fatigued + high friction diverts; fatigued + low friction does NOT" do
      ms = tired_mesh(List.duplicate(false, 4) ++ List.duplicate(true, 8))
      assert Bridge.circadian_decay(ms, :tired) > 0.85
      assert Bridge.error_drift_rising?(ms, :tired)

      # low friction: tired coordinator is eligible; min-strain still picks the
      # zero-load :fresh, so offer :tired alone to prove eligibility
      assert {:assign, :tired} = Bridge.route(%{friction: 0.7, candidates: [:tired]}, ms)
      assert {:assign, :tired} = Bridge.route(%{friction: 0.1, candidates: [:tired]}, ms)
      assert {:assign, :tired} = Bridge.route(%{candidates: [:tired]}, ms)

      # high friction: diverted
      assert {:assign, :fresh} = Bridge.route(%{friction: 0.71, candidates: [:tired, :fresh]}, ms)
    end

    test "saturation breach sheds even for low friction" do
      ms =
        Enum.reduce(1..30, tired_mesh(List.duplicate(true, 6)), fn _, acc ->
          Bridge.record_observation(acc, :tired, %{type: :ticket_assigned})
        end)

      assert {:breach, _} = Tensor.hyperplane_check(ms[:tired].tensor)

      assert {:shed, {:senior_queue, :all_saturated}} =
               Bridge.route(%{friction: 0.0, candidates: [:tired]}, ms)
    end
  end
end


# ==============================================================================
# SECTION 9/9: test/strain/tensor_test.exs
# ==============================================================================

defmodule AshA2A.Strain.TensorTest do
  use ExUnit.Case, async: true

  alias AshA2A.Strain.Tensor

  describe "circadian decay curve (shift_hours_continuous)" do
    test "numerically asserted values: 0h, 4h, 8h" do
      t0 = Tensor.new(%{shift_hours_continuous: 0})
      t4 = Tensor.new(%{shift_hours_continuous: 4})
      t8 = Tensor.new(%{shift_hours_continuous: 8})

      assert Tensor.strain(t0, :shift_hours_continuous) == 0.0
      # 1 - exp(-4/4) = 0.6321...
      assert_in_delta Tensor.strain(t4, :shift_hours_continuous), 0.6321, 0.0005
      # 1 - exp(-8/4) = 0.8646...
      assert_in_delta Tensor.strain(t8, :shift_hours_continuous), 0.8646, 0.0005
    end

    test "monotonic within shift" do
      strains =
        for half_hour <- 0..16 do
          h = half_hour * 0.5

          h
          |> then(&Tensor.new(%{shift_hours_continuous: &1}))
          |> Tensor.strain(:shift_hours_continuous)
        end

      assert strains == Enum.sort(strains)
    end

    test "reset at shift boundary via caller passing 0" do
      mid_shift = Tensor.new(%{shift_hours_continuous: 10})
      reset = Tensor.update(mid_shift, %{shift_hours_continuous: 0})

      assert Tensor.strain(mid_shift, :shift_hours_continuous) > 0.9
      assert Tensor.strain(reset, :shift_hours_continuous) == 0.0
    end
  end

  describe "per-dimension normalization" do
    test "active_leases: count/12, capped" do
      assert Tensor.new(%{active_leases: 6}) |> Tensor.strain(:active_leases) == 0.5
      assert Tensor.new(%{active_leases: 24}) |> Tensor.strain(:active_leases) == 1.0
    end

    test "error_rate: identity, clamped" do
      assert Tensor.new(%{error_rate: 0.17}) |> Tensor.strain(:error_rate) == 0.17
      assert Tensor.new(%{error_rate: 1.5}) |> Tensor.strain(:error_rate) == 1.0
    end

    test "heuristic_frequency: count/10" do
      assert Tensor.new(%{heuristic_frequency: 5}) |> Tensor.strain(:heuristic_frequency) == 0.5
      assert Tensor.new(%{heuristic_frequency: 10}) |> Tensor.strain(:heuristic_frequency) == 1.0
    end

    test "attestation_age_sec: age/3600" do
      assert Tensor.new(%{attestation_age_sec: 1800}) |> Tensor.strain(:attestation_age_sec) ==
               0.5

      assert Tensor.new(%{attestation_age_sec: 7200}) |> Tensor.strain(:attestation_age_sec) ==
               1.0
    end

    test "financial_risk_exposure: exposure/50_000" do
      assert Tensor.new(%{financial_risk_exposure: 25_000})
             |> Tensor.strain(:financial_risk_exposure) == 0.5

      assert Tensor.new(%{financial_risk_exposure: 100_000})
             |> Tensor.strain(:financial_risk_exposure) == 1.0
    end

    test "unknown dimension raises" do
      assert_raise ArgumentError, ~r/unknown strain dimension/, fn ->
        Tensor.new(%{vibes: 1})
      end
    end
  end

  describe "hyperplane_check/2 (saturation gate)" do
    test "zero tensor is :ok" do
      assert Tensor.new(%{}) |> Tensor.hyperplane_check() == :ok
    end

    test "weighted sum above 0.7 breaches with reason" do
      # 0.30*0.865 (8h) + 0.25*1.0 (12+ leases) + 0.20*0.5 = 0.2595+0.25+0.10 = 0.6095 < 0.7
      below =
        Tensor.new(%{
          shift_hours_continuous: 8,
          active_leases: 12,
          error_rate: 0.5,
          heuristic_frequency: 0,
          attestation_age_sec: 0,
          financial_risk_exposure: 0
        })

      assert Tensor.hyperplane_check(below) == :ok

      above =
        Tensor.update(below, %{error_rate: 0.9})
        # +0.30*0.15 more -> 0.6545... push leases to saturation too
        |> Tensor.update(%{active_leases: 24})

      # leases strain still 1.0; error now 0.9*0.20=0.18 -> 0.2595+0.25+0.18=0.6895 < 0.7

      assert Tensor.hyperplane_check(above) == :ok

      breach =
        Tensor.update(above, %{heuristic_frequency: 10})

      # +0.10*1.0 -> 0.7895 > 0.7

      assert {:breach, {:saturation_gate, total, 0.7}} = Tensor.hyperplane_check(breach)
      assert_in_delta total, 0.7895, 0.0005
    end

    test "gate list halts on first breach" do
      saturated = Tensor.new(%{heuristic_frequency: 10, attestation_age_sec: 7200})
      # 0.10*1.0 + 0.05*1.0 = 0.15 -> saturation ok, but gate list works mechanically
      assert Tensor.hyperplane_check(saturated, [:saturation_gate]) == :ok
    end
  end

  describe "validation and typed errors" do
    test "new/update reject negative and non-number values" do
      for bad <- [-1, "3", nil, :x] do
        assert_raise ArgumentError, ~r/non-negative number/, fn ->
          Tensor.new(%{active_leases: bad})
        end

        assert_raise ArgumentError, ~r/non-negative number/, fn ->
          Tensor.update(Tensor.new(%{}), %{error_rate: bad})
        end
      end
    end

    test "update rejects unknown dimension" do
      assert_raise ArgumentError, ~r/unknown strain dimension/, fn ->
        Tensor.update(Tensor.new(%{}), %{vibes: 1})
      end
    end

    test "strain/2 on unknown dimension is a typed ArgumentError" do
      assert_raise ArgumentError, ~r/unknown strain dimension: :vibes/, fn ->
        Tensor.strain(Tensor.new(%{}), :vibes)
      end
    end

    test "strain/2 on a corrupted stored value raises typed" do
      assert_raise ArgumentError, ~r/non-negative number/, fn ->
        Tensor.strain(%{active_leases: -4}, :active_leases)
      end
    end

    test "unknown gate raises typed; gate list halts on a real breach before reaching it" do
      t = Tensor.new(%{shift_hours_continuous: 100, active_leases: 24, error_rate: 1.0})

      assert_raise ArgumentError, ~r/unknown strain gate/, fn ->
        Tensor.hyperplane_check(t, :nope)
      end

      assert {:breach, {:saturation_gate, total, 0.7}} = Tensor.hyperplane_check(t)
      assert total > 0.7
      # :bogus is never consulted: the first gate already breached
      assert {:breach, {:saturation_gate, ^total, 0.7}} =
               Tensor.hyperplane_check(t, [:saturation_gate, :bogus])

      # whereas a non-breaching tensor reaches the bogus gate
      assert_raise ArgumentError, fn ->
        Tensor.hyperplane_check(Tensor.new(%{}), [:saturation_gate, :bogus])
      end

      assert Tensor.hyperplane_check(t, []) == :ok
    end

    test "partial tensor map reads missing dimensions as zero-observation defaults" do
      assert Tensor.strain(%{}, :active_leases) == 0.0
      assert Tensor.strain(%{active_leases: 6}, :active_leases) == 0.5
      assert Tensor.hyperplane_check(%{}) == :ok

      assert {:breach, _} =
               Tensor.hyperplane_check(%{
                 shift_hours_continuous: 1000,
                 active_leases: 100,
                 error_rate: 1.0
               })
    end
  end
end

