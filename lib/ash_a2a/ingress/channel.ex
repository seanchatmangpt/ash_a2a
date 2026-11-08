defmodule AshA2A.Ingress.Channel do
  @moduledoc """
  Check-in / telemetry intake surface: connects the Article-10 attestation
  gate (`AshA2A.Attestation.Gate` / `AshA2A.Attestation.Key`) to event
  ingress.

  ## Shape

  `ingest/3` is **pure**: per-coordinator state (last known GPS fix, refusal
  counters) is passed in and returned, never held in a process. This keeps
  the module directly court-testable and lets any supervisor own persistence
  later.

      state = Channel.empty_state()
      {result, state} = Channel.ingest(state, event, key: key, now: now)

  `result` is `{:ok, validated_event}` or `{:refused, reason}`.

  ## Refusal vocabulary

  Typed refusals are exactly the gate's vocabulary plus channel-owned
  replay defense:
  `:bad_signature`, `:stale`, `:clock_skew`, `:non_canonical_signature`,
  `:spoofed_payload`, `:emulator_detected`, `:gps_impossible_jump`,
  `:nonce_replayed`. Gate outcomes outside that set (`:nonce_mismatch`,
  `:malformed_token`) are folded into `:spoofed_payload` — a nonce mismatch
  or structurally-broken token is a crafted-payload attack, and keeping the
  emitted vocabulary closed keeps downstream refusal statistics typed.

  ## Replay defense

  Per coordinator, the channel tracks every nonce consumed by a
  successfully-ingested event in a bounded FIFO set (oldest evicted past
  `@max_consumed_nonces`). A re-submitted token/nonce pair — including the
  malleated-signature twin of a previously accepted token — is refused with
  `{:refused, :nonce_replayed}` before any crypto work.

  ## Event shape

  A check-in event is a map with:

  - `:coordinator` — binary id (required)
  - `:nonce` / `:device_token` — attestation pair signed by `AshA2A.Attestation.Key`
  - `:timestamp` — unix seconds, event observation time
  - `:gps` — `%{"lat" =>, "lon" =>, "accuracy" =>, "timestamp" =>}`
  - `:camera_make` / `:camera_model` — sensor metadata (required strings)

  A validated event is normalized to `%{coordinator:, timestamp:, gps:,
  camera_make:, camera_model:, claims:, ingested_at:}`.
  """

  alias AshA2A.Attestation.Gate

  # Bounded replay ledger: at most this many consumed nonces are remembered
  # per coordinator (oldest evicted FIFO). Sized far above any legitimate
  # check-in rate between ledger resets; eviction only weakens defense
  # against very old replays, never the fresh-replay attack.
  @max_consumed_nonces 1024

  @type state :: %{
          required(:last_known) => %{optional(binary()) => map()} | nil,
          required(:consumed_nonces) => %{optional(binary()) => %{set: MapSet.t(), order: [binary()]}},
          required(:refusals) => %{optional(atom()) => non_neg_integer()}
        }

  @type refusal_reason ::
          :bad_signature
          | :stale
          | :clock_skew
          | :non_canonical_signature
          | :spoofed_payload
          | :emulator_detected
          | :gps_impossible_jump
          | :nonce_replayed

  @type validated_event :: %{
          required(:coordinator) => binary(),
          required(:timestamp) => integer(),
          required(:gps) => map(),
          required(:camera_make) => binary(),
          required(:camera_model) => binary(),
          required(:claims) => map(),
          required(:ingested_at) => integer()
        }

  @doc "Fresh per-coordinator state: no last-known fixes, empty replay ledger, zeroed refusal counters."
  @spec empty_state() :: state()
  def empty_state, do: %{last_known: %{}, consumed_nonces: %{}, refusals: %{}}

  @doc """
  Ingests one check-in event.

  Opts: `:key` (required, `Key.key()`), `:now` (unix seconds, defaults to
  `System.system_time(:second)`), `:max_staleness_sec` (forwarded to the gate).

  Returns `{ {:ok, validated_event}, new_state }` or
  `{ {:refused, reason}, new_state }`. `new_state` always carries the
  updated per-reason refusal counter and (on success) the coordinator's
  last-known GPS fix.
  """
  @spec ingest(state(), map(), Keyword.t()) :: {{:ok, validated_event()} | {:refused, refusal_reason()}, state()}
  def ingest(state, event, opts)

  def ingest(%{refusals: _} = state, event, opts) when is_map(event) and is_list(opts) do
    key = Keyword.fetch!(opts, :key)
    now = Keyword.get(opts, :now, System.system_time(:second))
    gate_opts = forward_gate_opts(opts, now)

    result =
      with :ok <- shape_ok?(event),
           :ok <- nonce_fresh?(state, event),
           {:ok, claims} <- attest(event, key),
           :ok <- claims_bind_event?(claims, event),
           :ok <- Gate.verify_freshness(claims, gate_opts ++ [now: event.timestamp]),
           :ok <- Gate.verify_sensor_metadata(sensor_claims(event), gate_opts),
           :ok <- teleport_ok?(state, event) do
        {:ok, normalize(event, claims, now)}
      else
        {:refused, reason} -> {:refused, fold(reason)}
        {:error, _} -> {:refused, :spoofed_payload}
      end

    {result, record(state, result)}
  end

  def ingest(_state, _event, _opts), do: raise(ArgumentError, "ingest/3 requires state map, event map, opts list")

  @doc "Refusal counters as a plain per-reason map (no persistence)."
  @spec stats(state()) :: %{optional(atom()) => non_neg_integer()}
  def stats(%{refusals: refusals}), do: refusals

  # --- checks ---

  defp shape_ok?(event) do
    if is_binary(event[:coordinator]) and event[:coordinator] != "" and
         is_binary(event[:nonce]) and is_binary(event[:device_token]) and
         is_integer(event[:timestamp]) and is_map(event[:gps]) and
         is_binary(event[:camera_make]) and event[:camera_make] != "" and
         is_binary(event[:camera_model]) and event[:camera_model] != "" do
      :ok
    else
      {:refused, :spoofed_payload}
    end
  end

  defp attest(%{nonce: nonce, device_token: device_token}, key) do
    case Gate.verify_enclave({device_token, nonce}, key) do
      {:ok, claims} -> {:ok, claims}
      other -> other
    end
  end

  # Replay defense: a nonce already consumed by an accepted ingest for this
  # coordinator is refused before any crypto work.
  defp nonce_fresh?(%{consumed_nonces: consumed}, %{coordinator: coord, nonce: nonce}) do
    case Map.get(consumed, coord) do
      %{set: set} -> if MapSet.member?(set, nonce), do: {:refused, :nonce_replayed}, else: :ok
      nil -> :ok
    end
  end

  # Signed-subset confusion defense: the device token's signature covers the
  # claims, NOT the unsigned event copy. If the signed claims carry sensor
  # fields, the event copies must agree on location and metadata — otherwise
  # an attacker could sign GPS fix X and check in with forged fix Y. The GPS
  # *timestamp* is deliberately NOT bound: the signed fix is stamped at token
  # issuance, the event fix at observation time, and those legitimately
  # diverge under device clock drift; freshness is enforced on both copies
  # independently by the gate.
  defp claims_bind_event?(claims, event) do
    with :ok <- bind_field?(claims["gps"], event[:gps]),
         :ok <- bind_scalar?(claims["camera_make"], event[:camera_make]),
         :ok <- bind_scalar?(claims["camera_model"], event[:camera_model]) do
      :ok
    else
      _ -> {:refused, :spoofed_payload}
    end
  end

  defp bind_field?(nil, _event_value), do: :ok
  defp bind_field?(signed, event_value) when is_map(signed) and is_map(event_value),
    do: if(Map.equal?(Map.take(signed, ["lat", "lon", "accuracy"]), Map.take(event_value, ["lat", "lon", "accuracy"])),
          do: :ok,
          else: {:refused, :spoofed_payload}
        )

  defp bind_field?(_, _), do: {:refused, :spoofed_payload}

  defp bind_scalar?(nil, _event_value), do: :ok
  defp bind_scalar?(signed, event_value), do: if(signed == event_value, do: :ok, else: {:refused, :spoofed_payload})

  # The event's own sensor metadata is what the sensor gate validates; the
  # signed device claims ride along as attestation context on the output.
  defp sensor_claims(event) do
    %{
      "camera_make" => event[:camera_make],
      "camera_model" => event[:camera_model],
      "gps" => event[:gps]
    }
  end

  defp teleport_ok?(%{last_known: last_known}, %{coordinator: coord} = event) do
    case Map.get(last_known, coord) do
      nil ->
        :ok

      prev ->
        Gate.verify_gps_trajectory([prev, %{"lat" => event.gps["lat"], "lon" => event.gps["lon"], "timestamp" => event.timestamp}])
    end
  end

  defp normalize(event, claims, now) do
    %{
      coordinator: event[:coordinator],
      timestamp: event[:timestamp],
      gps: event[:gps],
      camera_make: event[:camera_make],
      camera_model: event[:camera_model],
      claims: claims,
      ingested_at: now
    }
  end

  # --- state transitions ---

  defp record(state, {:ok, %{coordinator: coord} = validated}) do
    fix = %{
      "lat" => validated.gps["lat"],
      "lon" => validated.gps["lon"],
      "timestamp" => validated.timestamp
    }

    state
    |> put_in([:last_known, coord], fix)
    |> consume_nonce(coord, validated.claims["nonce"])
  end

  defp record(%{refusals: refusals} = state, {:refused, reason}) do
    %{state | refusals: Map.update(refusals, reason, 1, &(&1 + 1))}
  end

  # Bounded FIFO ledger of consumed nonces per coordinator.
  defp consume_nonce(state, _coord, nil), do: state

  defp consume_nonce(%{consumed_nonces: consumed} = state, coord, nonce) do
    entry =
      case Map.get(consumed, coord) do
        %{set: set, order: order} ->
          {order, set} = evict_oldest(order, set)
          %{set: MapSet.put(set, nonce), order: Enum.take(order ++ [nonce], -@max_consumed_nonces)}

        nil ->
          %{set: MapSet.new([nonce]), order: [nonce]}
      end

    %{state | consumed_nonces: Map.put(consumed, coord, entry)}
  end

  defp evict_oldest(order, set) when length(order) >= @max_consumed_nonces do
    [oldest | rest] = order
    {rest, MapSet.delete(set, oldest)}
  end

  defp evict_oldest(order, set), do: {order, set}

  # Fold the gate's wider vocabulary onto the channel's closed refusal set.
  defp fold(:nonce_mismatch), do: :spoofed_payload
  defp fold(:malformed_token), do: :spoofed_payload

  defp fold(reason)
       when reason in [:bad_signature, :stale, :clock_skew, :non_canonical_signature, :spoofed_payload, :emulator_detected, :gps_impossible_jump, :nonce_replayed],
       do: reason

  defp forward_gate_opts(opts, now) do
    opts
    |> Keyword.take([:max_staleness_sec])
    |> Enum.reject(&is_nil(elem(&1, 1)))
    |> Enum.concat([now: now])
  end
end
