defmodule AshA2A.GraphLaw.EngineTelemetry do
  @moduledoc """
  Boundary telemetry for one completed call into the vendored praxis-graphlaw
  wasm engine: `[:ash_a2a, :graphlaw, :engine, :call]`.

  Emitted by the in-BEAM hosts (`AshA2A.GraphLaw.WasmexHost`,
  `AshA2A.GraphLaw.WasmexSession`) after the engine call returns or traps,
  regardless of what the engine decided. It is observational only: the
  value the host returns is unchanged, and the engine output is summarised
  (never re-judged) only while a handler is attached.

  Measurements: `system_time`. Metadata:

    * `host`, `function`, `wasm_sha256` (sha256 of the bytes the host
      instantiated)
    * `outcome` -- `:returned` (the export returned a string), `:trapped`,
      `:exited`, or `:host_error`; `code` for the non-returned outcomes
    * `output_sha256`, `output_bytes` -- identity of the returned string
    * `engine_status` -- `"error"` when the engine returned `{"error": ...}`,
      `"ok"` otherwise
    * `run_hooks`: `hooks_status`, `verdict_count`, `receipt_count`,
      `schedule_count`
    * `validate_all`: `<dialect>_status` and `<dialect>_triples_out` for
      every reported dialect (`datalog`, `n3_denial`, `shacl`, `shex`,
      `owl_rl`) and `replay_status`
  """

  @event [:ash_a2a, :graphlaw, :engine, :call]

  @doc "The emitted event name."
  @spec event() :: [atom()]
  def event, do: @event

  @doc "Emits the event for `result` of `function` when any handler is attached."
  @spec emit(String.t(), String.t() | nil, String.t(), term()) :: :ok
  def emit(host, wasm_sha256, function, result) do
    if :telemetry.list_handlers(@event) != [] do
      :telemetry.execute(
        @event,
        %{system_time: System.system_time()},
        metadata(host, wasm_sha256, function, result)
      )
    end

    :ok
  end

  @doc "Metadata for one call result (public for direct inspection)."
  @spec metadata(String.t(), String.t() | nil, String.t(), term()) :: map()
  def metadata(host, wasm_sha256, function, result) do
    base = %{host: host, function: function, wasm_sha256: wasm_sha256}

    case result do
      {:ok, raw} when is_binary(raw) ->
        base
        |> Map.merge(%{
          outcome: :returned,
          output_sha256: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower),
          output_bytes: byte_size(raw)
        })
        |> Map.merge(summary(function, raw))

      {:error, %{code: code}} ->
        Map.merge(base, %{outcome: outcome_of(code), code: code})

      other ->
        Map.merge(base, %{outcome: :host_error, code: inspect(other, limit: 5)})
    end
  end

  defp outcome_of(:graphlaw_call_trapped), do: :trapped
  defp outcome_of(:graphlaw_call_exited), do: :exited
  defp outcome_of(:graphlaw_timeout), do: :exited
  defp outcome_of(_code), do: :host_error

  @doc "Summary of an engine output string for `function`."
  @spec summary(String.t(), binary()) :: map()
  def summary(function, raw) when function in ["run_hooks", "validate_all"] do
    case JSON.decode(raw) do
      {:ok, %{"error" => _}} -> %{engine_status: "error"}
      {:ok, %{} = doc} -> Map.put(decoded(function, doc), :engine_status, "ok")
      _ -> %{engine_status: "non_json"}
    end
  end

  def summary(_function, raw) do
    case JSON.decode(raw) do
      {:ok, %{"error" => _}} -> %{engine_status: "error"}
      _ -> %{engine_status: "ok"}
    end
  end

  defp decoded("run_hooks", doc) do
    %{
      hooks_status: doc["status"],
      verdict_count: count(doc["verdicts"]),
      receipt_count: count(doc["receipts"]),
      schedule_count: count(doc["schedule"])
    }
  end

  defp decoded("validate_all", doc) do
    dialects =
      for %{"dialect" => name} = d when is_binary(name) <- List.wrap(doc["dialects"]),
          key = String.downcase(name),
          pair <- [{"#{key}_status", d["status"]}, {"#{key}_triples_out", d["triples_out"]}],
          into: %{},
          do: pair

    Map.put(dialects, "replay_status", get_in(doc, ["replay", "status"]))
  end

  defp count(list) when is_list(list), do: length(list)
  defp count(_), do: nil
end
