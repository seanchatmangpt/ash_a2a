defmodule AshA2A.Copilot.F8AdversarialTest do
  @moduledoc """
  Lane F8 adversarial court — AR3's five attacks as regression tests against
  the current pipeline (G4 authority hop + G5 Bridge threading present).

  Attack matrix (final):
    * A1 trade-respell ledger reset — EXPLOITED, FIXED via trade_key
      normalization in Vince (strings trimmed + case-folded; atoms pass through)
    * A2 authority hop fail-open / stage-order — DEFENDED (documented skip
      when unconfigured; fail-closed when configured)
    * A3 strain spoof via forged coordinator_id — EXPLOITED (channel-level;
      disclosed in Pipeline moduledoc, not fixed)
    * A4 retry_token redemption — DEFENDED (token not redeemable; the Vince
      ledger is the authority)
    * A5 admit-path sweep — two disclosed gaps (negative-NTE admit,
      nil coordinator_id raises); see Pipeline moduledoc
  """

  use ExUnit.Case, async: false

  alias AshA2A.Attestation.Key
  alias AshA2A.Copilot.Pipeline
  alias AshA2A.Strain.Tensor
  alias AshA2A.Twin.Tony

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

  defp signed_frame(nonce, key) do
    %{device_token: Key.sign(fresh_claims(nonce), key), nonce: nonce, key: key}
  end

  defp rested_mesh(ids) do
    Enum.reduce(ids, %{}, fn id, acc ->
      Tony.register_coordinator(acc, id, Tensor.new(%{}))
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

    assert state1.vince.challenges["hvac.drain"] == 1

    for variant <- ["hvac.drain", " hvac.drain", "HVAC.Drain "] do
      assert {_, {:refuse, :escalate_multisig}} =
               Pipeline.check(intent(%{trade: variant, nte: 1000, offer: 500}), state1)
    end
  end

  test "A1b atom trades keep exact keys (atom-keyed courts unaffected)" do
    state = state_for()

    {state1, {:challenge, _}} =
      Pipeline.check(intent(%{trade: :Trade_CH, nte: 1000, offer: 500}), state)

    assert state1.vince.challenges[:Trade_CH] == 1

    {state2, {:refuse, :escalate_multisig}} =
      Pipeline.check(intent(%{trade: :Trade_CH, nte: 1000, offer: 500}), state1)

    assert state2.vince.challenges[:Trade_CH] == 1
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

    {_state, {:refuse, %{code: :authority, reason: %{reason: :source_deny, actor_id: "attacker-p1"}}}} =
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
             Pipeline.check(intent(%{trade: "floor-ok", nte: 100, offer: 78, sensor_frame: frame}),
               state, now: @now)

    assert ticket.gpm == 0.22

    assert {_, {:challenge, %{code: :gpm_floor}}} =
             Pipeline.check(intent(%{trade: "floor-below", nte: 100, offer: 79}), state)
  end
end
