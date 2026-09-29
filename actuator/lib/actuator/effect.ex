defmodule Actuator.Effect do
  @moduledoc """
  A typed PreparedEffect decoded from canonical (RFC 8785) JSON with a TOTAL schema:
  exact key set, exact types, closed `effect_type`, no floats, integers within +/-(2^53-1),
  byte length bounded, and the input MUST already be canonical (re-encoding equals the
  bytes), so the digest the certificate signed is the digest of exactly these bytes.
  """
  alias Actuator.EffectorRegistry

  @keys ~w(v principal subject capability consequence_class effect_type effect_instance_id
           resource_bounds policy_epoch params)
  @enforce_keys Enum.map(@keys, &String.to_atom/1)
  defstruct @enforce_keys

  @max_bytes 16_384
  @max_int 9_007_199_254_740_991

  @type t :: %__MODULE__{}

  @spec decode(binary()) :: {:ok, t()} | {:error, atom()}
  def decode(bytes) when is_binary(bytes) and byte_size(bytes) <= @max_bytes do
    with {:ok, map} <- json(bytes),
         :ok <- canonical(map, bytes),
         :ok <- no_floats(map),
         :ok <- shape(map),
         {:ok, eff} <- EffectorRegistry.fetch(map["effect_type"]) |> unknown_type(),
         :ok <- eff.module.validate_params(map["params"]) |> params() do
      {:ok, struct!(__MODULE__, Map.new(map, fn {k, v} -> {String.to_existing_atom(k), v} end))}
    end
  end

  def decode(_), do: {:error, :malformed_effect}

  @doc "`sha256:<hex>` of the canonical bytes."
  def digest(bytes), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp json(bytes) do
    case Jason.decode(bytes) do
      {:ok, m} when is_map(m) -> {:ok, m}
      _ -> {:error, :malformed_effect}
    end
  end

  defp canonical(map, bytes) do
    if Jcs.encode(map) == bytes, do: :ok, else: {:error, :non_canonical_effect}
  rescue
    _ -> {:error, :non_canonical_effect}
  end

  defp no_floats(v) when is_float(v), do: {:error, :malformed_effect}

  defp no_floats(v) when is_integer(v),
    do: if(abs(v) <= @max_int, do: :ok, else: {:error, :malformed_effect})

  defp no_floats(v) when is_list(v), do: Enum.find_value(v, :ok, &err(no_floats(&1)))

  defp no_floats(v) when is_map(v),
    do: Enum.find_value(v, :ok, fn {_, x} -> err(no_floats(x)) end)

  defp no_floats(_), do: :ok

  defp err(:ok), do: nil
  defp err(e), do: e

  defp shape(m) do
    bounds = m["resource_bounds"]

    cond do
      Enum.sort(Map.keys(m)) != Enum.sort(@keys) ->
        {:error, :malformed_effect}

      not (is_integer(m["v"]) and m["v"] >= 0) ->
        {:error, :malformed_effect}

      not (is_integer(m["policy_epoch"]) and m["policy_epoch"] >= 0) ->
        {:error, :malformed_effect}

      not Enum.all?(
        ~w(principal subject capability consequence_class effect_type effect_instance_id),
        &str?(m[&1])
      ) ->
        {:error, :malformed_effect}

      not (is_map(bounds) and Map.keys(bounds) == ["max_bytes"] and
             is_integer(bounds["max_bytes"]) and bounds["max_bytes"] >= 0) ->
        {:error, :malformed_effect}

      not is_map(m["params"]) ->
        {:error, :malformed_effect}

      true ->
        :ok
    end
  end

  defp str?(s), do: is_binary(s) and s != "" and byte_size(s) <= 256

  defp unknown_type({:ok, e}), do: {:ok, e}
  defp unknown_type(:error), do: {:error, :unknown_effect_type}

  defp params(:ok), do: :ok
  defp params(_), do: {:error, :malformed_effect}
end
