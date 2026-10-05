# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Semantic.GraphLaw.WasmexHost do
  @moduledoc """
  Default `AshA2A.Semantic.GraphLaw` implementation (PERF-01): the
  application-supervised, warm, in-BEAM `AshA2A.GraphLaw.WasmexHost`
  (Wasmtime via `wasmex`) over the MANIFEST-pinned
  `priv/graphlaw/praxis_graphlaw.wasm`.

  The previous default, `AshA2A.Semantic.GraphLaw.Wasm`, spawned `node`, wrote
  a temp file and re-instantiated the 3.2 MB module on every call (~100 ms,
  measured); a warm host call is ~0.5 ms over the same bytes and returns the
  same digests. The node transport stays as the second runtime of the
  cross-runtime court (select it with `config :ash_a2a, :graph_law,
  AshA2A.Semantic.GraphLaw.Wasm` or the `:graph_law` option).

  Isolation note: calls share a long-lived instance (or a pool member), not a
  fresh one per call. Every engine export is pure over its string arguments,
  the host serializes whole transactions, recycles the instance after any
  failed call or memory high-water mark, and the engine's own replay check
  (two fresh stores per `validate_all`) still surfaces as `report["replay"]`.

  Fail-closed exactly like the node transport: an unreachable engine is
  `{:error, %{code: :graphlaw_unavailable}}`, an in-band engine error is
  `:graphlaw_engine_error`, and any other host failure keeps its typed code.
  """

  @behaviour AshA2A.Semantic.GraphLaw

  alias AshA2A.GraphLaw.WasmexHost, as: Host

  @unavailable [
    :graphlaw_not_started,
    :graphlaw_wasm_not_vendored,
    :graphlaw_wasm_unreadable,
    :graphlaw_instantiation_failed,
    :graphlaw_wasm_digest_mismatch,
    :graphlaw_import_surface_mismatch,
    :graphlaw_wasm_invalid
  ]

  @doc false
  def __sa2a_refusal_codes__,
    do: %{graphlaw_unavailable: :blocked_resource, graphlaw_engine_error: :blocked_resource}

  @impl true
  def version, do: Host.version() |> shape()

  @impl true
  def graph_hash(ttl) when is_binary(ttl), do: Host.graph_hash(ttl) |> shape()

  @impl true
  def validate(ttl, shapes) when is_binary(ttl) and is_binary(shapes) do
    ttl |> Host.validate_all("", shapes, "", "") |> shape() |> report()
  end

  @doc """
  Validates several `{ttl, shapes}` pairs in ONE host transaction sequence
  (PERF-07): no other caller's call interleaves, and the whole batch costs one
  host round trip instead of one per pair. Returns the reports in order, or
  the first failure.
  """
  @impl true
  def validate_many(pairs) when is_list(pairs) do
    calls = Enum.map(pairs, fn {ttl, shapes} -> {"validate_all", [ttl, "", shapes, "", ""]} end)

    with {:ok, raws} <- calls |> Host.raw_many() |> shape() do
      Enum.reduce_while(raws, {:ok, []}, fn raw, {:ok, acc} ->
        case decode(raw) do
          {:ok, report} -> {:cont, {:ok, [report | acc]}}
          {:error, _} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, reports} -> {:ok, Enum.reverse(reports)}
        error -> error
      end
    end
  end

  @doc "Whether the default host has loaded the pinned engine. Never spawns."
  @spec available?() :: boolean()
  def available?, do: Host.serves?(AshA2A.Semantic.GraphLaw.Wasm.wasm_path())

  defp report({:ok, %{"error" => detail}}), do: {:error, refusal(:graphlaw_engine_error, detail)}
  defp report(other), do: other

  defp decode(raw) do
    case JSON.decode(raw) do
      {:ok, %{"error" => detail}} -> {:error, refusal(:graphlaw_engine_error, detail)}
      {:ok, %{} = report} -> {:ok, report}
      {:ok, other} -> {:error, refusal(:graphlaw_bad_response, inspect(other))}
      {:error, reason} -> {:error, refusal(:graphlaw_bad_response, inspect(reason))}
    end
  end

  defp shape({:ok, _} = ok), do: ok

  defp shape({:error, {:invalid_encoding, offset}}),
    do: {:error, refusal(:invalid_encoding, "input is not valid UTF-8 at byte #{offset}")}

  defp shape({:error, %{code: :graphlaw_error} = error}),
    do: {:error, refusal(:graphlaw_engine_error, Map.get(error, :detail))}

  defp shape({:error, %{code: code} = error}) when code in @unavailable,
    do: {:error, refusal(:graphlaw_unavailable, "#{code}: #{inspect(Map.delete(error, :code))}")}

  defp shape({:error, %{code: code} = error}),
    do: {:error, refusal(code, inspect(Map.delete(error, :code)))}

  defp refusal(code, detail), do: %{code: code, detail: to_string(detail)}
end
