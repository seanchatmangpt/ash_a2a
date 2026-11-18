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
