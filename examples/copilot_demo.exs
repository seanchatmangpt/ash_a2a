# examples/copilot_demo.exs
#
# End-to-end demonstration of the Communicating Digital Twins copilot stack:
# CEO (adversarial intent evaluation) -> COO (coordinator strain gate)
# -> Attestation.Gate (Article-10 on-site attestation).
#
# Chicago discipline: every stage calls the REAL landed modules, no mocks.
# The only environmental input is the wall clock, which the pipeline would
# read itself anyway; here it is captured once and injected so the whole
# transcript is a replayable single run.
#
# Run:
#   MIX_BUILD_ROOT=_build-demo mix run examples/copilot_demo.exs

now = System.system_time(:second)

defmodule CopilotDemo do
  @moduledoc false

  alias AshA2A.Attestation.Gate
  alias AshA2A.Attestation.Key
  alias AshA2A.Copilot.Pipeline
  alias AshA2A.Strain.Tensor
  alias AshA2A.Twin.COO

  @gpm_floor 0.22

  # ---- helpers -------------------------------------------------------------

  def print_stage(n, title) do
    IO.puts("")
    IO.puts("== Stage #{n}: #{title} " <> String.duplicate("=", max(1, 58 - String.length(title))) <> "")
  end

  def print_result(tag, result) do
    IO.puts("  #{tag} -> " <> inspect(result, limit: 15, printable_limit: 120))
  end

  # Legit on-site claims: honest camera/GPS metadata, fresh, non-virtual.
  def legit_claims(now, nonce) do
    %{
      "nonce" => nonce,
      "issued_at" => now - 5,
      "camera_make" => "Apple",
      "camera_model" => "iPhone 15",
      "gps" => %{
        "lat" => 35.6812,
        "remote" => false,
        "lon" => 31.2357,
        "accuracy" => 8.0,
        "timestamp" => now - 5
      }
    }
  end

  # Sign claims and package the sensor frame the pipeline expects:
  # %{device_token, nonce, key} — key is the verification key material.
  def signed_frame(claims, key) do
    token = Key.sign(claims, key)
    %{device_token: token, nonce: claims["nonce"], key: key}
  end

  def rested_mesh(id) do
    %{} |> COO.register_coordinator(id, Tensor.new(%{}))
  end

  def intent(trade, nte, offer, coord, frame) do
    %{trade: trade, nte: nte, offer: offer, coordinator_id: coord, sensor_frame: frame}
  end

  # ---- stages ---------------------------------------------------------------

  def run(now) do
    IO.puts("Copilot pipeline demo — CEO -> COO -> Attestation.Gate")
    IO.puts("gpm_floor=#{@gpm_floor}  now=#{now}")

    # Stage 0: crypto substrate — mint a real ECDSA P-256 keypair.
    print_stage(0, "Mint ECDSA keypair (Attestation.Key)")
    key = Key.generate()
    IO.puts("  curve=#{key.curve}  priv=#{byte_size(key.priv)}B DER  pub=#{byte_size(key.pub)}B DER")
    token0 = Key.sign(%{"ping" => now}, key)
    roundtrip = Key.verify(token0, key)
    IO.puts("  sign/verify roundtrip -> #{inspect(roundtrip)}")

    # Stage 1: exact-half monkey-math challenge (no attestation burned).
    print_stage(1, "CHALLENGE: monkey-math exact-half (nte=1000, offer=500)")
    state = Pipeline.init(gpm_floor: @gpm_floor, tolerance: 0.0)
    state = %{state | mesh: rested_mesh("c1")}

    intent1 = intent("plumbing.drain", 1000, 500, "c1", :not_reached)
    {state1, result1} = Pipeline.check(intent1, state, now: now)
    print_result("pipeline", result1)
    IO.puts("  ceo.challenges=#{inspect(state1.ceo.challenges)}")

    # Stage 2: the lawful retry. CEO's challenge ledger is keyed by trade:
    # resubmitting the SAME trade escalates to :escalate_multisig
    # (challenge-as-state). The retry is therefore a NEW dispute file
    # (plumbing.drain.r2) with a repaired offer (GPM 0.30) and a fresh token.
    print_stage(2, "ADMIT: repaired offer via new dispute file (nte=1000, offer=700, GPM 0.30)")
    nonce2 = "onsite-drain-r2"
    frame2 = now |> legit_claims(nonce2) |> signed_frame(key)
    intent2 = intent("plumbing.drain.r2", 1000, 700, "c1", frame2)
    {state2, result2} = Pipeline.check(intent2, state1, now: now)
    print_result("pipeline", result2)
    claims2 = elem(result2, 1).attestation_claims
    IO.puts("  verified nonce in claims: #{claims2["nonce"]}  issued_at=#{claims2["issued_at"]}")

    # Stage 3: what happens if the supplier just resubmits the SAME trade.
    print_stage(3, "ESCALATE: same-trade resubmission -> :escalate_multisig")
    intent3 = intent("plumbing.drain", 1000, 700, "c1", :not_reached)
    {_state3, result3} = Pipeline.check(intent3, state1, now: now)
    print_result("pipeline", result3)

    # Stage 4: spoofed attestation on an otherwise-good intent.
    print_stage(4, "REFUSE: spoofed attestation -> :emulator_detected")
    spoof_claims =
      now
      |> legit_claims("onsite-drain-spoof")
      |> Map.put("is_virtual", true)

    frame4 = signed_frame(spoof_claims, key)
    intent4 = intent("plumbing.drain.ok", 1000, 700, "c1", frame4)
    {_state4, result4} = Pipeline.check(intent4, state2, now: now)
    print_result("pipeline", result4)

    # Stage 5: saturated coordinator sheds before any evaluation burns.
    print_stage(5, "SHED: saturated coordinator -> senior queue (route-first)")
    saturated =
      Tensor.new(%{
        shift_hours_continuous: 24,
        active_leases: 12,
        error_rate: 1.0,
        heuristic_frequency: 10
      })

    mesh5 = %{} |> COO.register_coordinator("c-burned", saturated)
    state5 = %{Pipeline.init(gpm_floor: @gpm_floor) | mesh: mesh5}
    intent5 = intent("plumbing.drain.rush", 1000, 700, "c-burned", :not_reached)
    {_state5, result5} = Pipeline.check(intent5, state5, now: now)
    print_result("pipeline", result5)

    IO.puts("")
    IO.puts("Demo complete: challenge -> admit (repaired, fresh token) -> escalate -> refuse -> shed.")
    :ok
  end
end

case CopilotDemo.run(now) do
  :ok -> System.halt(0)
  other ->
    IO.puts(:stderr, "demo failed: #{inspect(other)}")
    System.halt(1)
end
