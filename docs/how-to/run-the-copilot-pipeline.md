# Run the Copilot Pipeline

Run a dispatch intent through the Copilot membrane's interception path with
real modules and observe the typed verdicts.

Architecture context: see [Copilot membrane](../explanation/copilot-membrane.md).

## Prerequisites

- ash_a2a checkout with deps fetched (`mix deps.get`).
- Optional mechanical priors: trade reticle packs live in `ggen-marketplace`
  (`packs/trade-reticle-plumbing`, generated module `TradeReticle.Plumbing`)
  and implement the `AshA2A.Twin.MechanicalPrior` behaviour. They load via
  the `MechanicalPrior` behaviour contract: put the generated module on the
  code path and set `Application.put_env(:ash_a2a, :copilot_mechanical_prior,
  TradeReticle.Plumbing)`, or pass `prior: MyPrior` to `Pipeline.check/3`.
  When nothing is loadable, `Pipeline.detect_prior/0` returns `nil` and the
  prior stage is skipped.

## 1. Build a key and sign an attestation token

`AshA2A.Attestation.Key` generates ECDSA P-256 keypairs and signs
`v1.`-prefixed compact tokens:

```elixir
key = AshA2A.Attestation.Key.generate()

claims = %{
  "nonce" => "nonce-admit",
  "issued_at" => now - 5,
  "camera_make" => "Apple",
  "camera_model" => "iPhone 15",
  "gps" => %{
    "lat" => 35.6812,
    "lon" => 139.7671,
    "accuracy" => 8.0,
    "timestamp" => now - 5
  }
}

token = AshA2A.Attestation.Key.sign(claims, key)
```

The sensor frame pairs the token with its nonce and the verification key:

```elixir
frame = %{device_token: token, nonce: "nonce-admit", key: key}
```

## 2. Construct the intent and pipeline state

An intent carries `{trade, nte, offer, coordinator_id, sensor_frame}`:

```elixir
intent = %{
  trade: :trade_admit,
  nte: 1000,
  offer: 720,
  coordinator_id: :coord_a,
  sensor_frame: frame
}
```

Build the pipeline state: `Pipeline.init/2` returns
`%{vince: Vince.new(opts), mesh: mesh}`, and the mesh registers coordinator
tensor snapshots (`AshA2A.Twin.Tony.register_coordinator/3` over
`AshA2A.Strain.Tensor.new/1`):

```elixir
mesh =
  %{}
  |> AshA2A.Twin.Tony.register_coordinator(
    :coord_a,
    AshA2A.Strain.Tensor.new(%{})
  )

state = %{AshA2A.Copilot.Pipeline.init(gpm_floor: 0.22, tolerance: 0.0) | mesh: mesh}
```

For an optional Bridge mesh_state (strain observation feed), build one with
`AshA2A.Strain.Bridge.new_mesh_state/1` and fold verdicts back with
`record_observation/3` — the pipeline does not populate `:bridge` itself.

## 3. Run the pipeline

Invoke `Pipeline.check/3` (inject `:now` for determinism):

```elixir
{new_state, result} =
  AshA2A.Copilot.Pipeline.check(intent, state, now: now)
```

## 4. Observe the verdicts

The invocations below are copied from `test/copilot/pipeline_test.exs` —
that test file is the ground truth for behavior; run it with
`mix test test/copilot/pipeline_test.exs`.

### Admit (GPM 0.28, fresh attestation, rested coordinator)

```elixir
{new_state, {:ok, ticket}} =
  Pipeline.check(intent(%{sensor_frame: frame}), state, now: @now)

ticket.trade              #=> :trade_admit
ticket.coordinator_id     #=> :coord_a
ticket.gpm                #=> 0.28 (= (1000 - 720) / 1000)
ticket.attestation_claims["nonce"] #=> "nonce-admit"
new_state.vince.challenges       #=> %{} (admit leaves the ledger untouched)
```

### Challenge (GPM 0.19 fires gpm_floor; repeat escalates)

```elixir
low_margin = %{intent | trade: :trade_ch, nte: 1000, offer: 810}

{state1, {:challenge, ch}} = Pipeline.check(low_margin, state)
ch.code                      #=> :gpm_floor
ch.retry_token               #=> reference()
ch.demanded_evidence         #=> ["itemized_cost_breakdown", "subcontractor_quote_doc"]
state1.vince.challenges[:trade_ch] #=> 1

# same trade re-submitted (even with a repaired offer) escalates:
repaired = %{intent | trade: :trade_ch, nte: 1000, offer: 700}
{_, {:refuse, :escalate_multisig}} = Pipeline.check(repaired, state1)
```

### Monkey-math challenge (exact-half)

```elixir
{_, {:challenge, %{code: :monkey_math}}} =
  Pipeline.check(%{intent | nte: 1000, offer: 500}, state)
```

### Shed (saturated tensor sheds before attestation)

```elixir
tensor =
  AshA2A.Strain.Tensor.new(%{
    shift_hours_continuous: 24,
    active_leases: 12,
    error_rate: 1.0,
    heuristic_frequency: 10
  })

mesh = %{} |> Tony.register_coordinator(:coord_s, tensor)
state = %{Pipeline.init(gpm_floor: 0.22) | mesh: mesh}

{_, {:shed, {:senior_queue, :tony_relief}}} =
  Pipeline.check(%{intent | coordinator_id: :coord_s, sensor_frame: frame}, state, now: @now)
```

The shed path leaves the challenge ledger untouched
(`new_state.vince.challenges == %{}`).

### Attestation refusals

Spoofed (virtual-device claim):

```elixir
frame = signed_frame("nonce-spoof", %{fresh_claims("nonce-spoof") | "is_virtual" => true})

{_, {:refuse, %{code: :attestation, reason: {:refused, :emulator_detected}}}} =
  Pipeline.check(intent(%{sensor_frame: frame}), state, now: @now)
```

Stale (`issued_at` 400 s old, default staleness 90 s):

```elixir
{_, {:refuse, %{code: :attestation, reason: {:refused, :stale}}}} =
  Pipeline.check(intent(%{sensor_frame: stale_frame}), state, now: @now)
```

Mechanical prior refusal (test defines its own prior):

```elixir
defmodule DenyingPrior do
  @behaviour AshA2A.Twin.MechanicalPrior

  @impl true
  def prior_verdict(_claim, _telemetry), do: {:refuse, :blown_motor_high_ambient}
end

{_, {:refuse, %{code: :mechanical_prior, reason: :blown_motor_high_ambient}}} =
  Pipeline.check(intent(), state, prior: DenyingPrior)
```

## 5. Mesh-level routing (strain-first)

Before `check/3`, route at the mesh level with `AshA2A.Copilot.Pipeline.route/2`
(it delegates to `AshA2A.Strain.Bridge.route/2`; both forms are shown below)
— the moduledoc's strain-first order decision: shed saturated coordinators
before spending a Vince interrogation. Fold verdicts back as observations:

```elixir
bridge = AshA2A.Strain.Bridge.new_mesh_state([:coord_a])

case AshA2A.Strain.Bridge.route(%{friction: 0.0}, bridge) do
  {:assign, id} ->
    # proceed to Pipeline.check/3, then record the verdict:
    bridge = AshA2A.Strain.Bridge.record_observation(bridge, id, %{type: :ticket_assigned})

  {:shed, {:senior_queue, reason}} ->
    # no candidate coordinator can take the ticket; skip Vince entirely
end
```

## Verify

```console
$ mix test test/copilot/pipeline_test.exs
...
22 tests, 0 failures
```

If the attestation cases fail with `:stale` on fresh tokens, check that you
injected `:now` consistently in both the claim timestamps and the check
opts.
