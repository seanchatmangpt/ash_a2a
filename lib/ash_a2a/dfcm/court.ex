# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.DfCM.Court do
  @moduledoc """
  Loader and structural validator for DfCM-generated fleet courts.

  Courts qualify evidence only. They never grant standing beyond what the
  normal semantic standing machinery admits, and they never grant DO authority.
  """

  alias AshA2A.DfCM.FleetIntake

  @court_dir Path.expand("../../../priv/dfcm/fleet/courts", __DIR__)

  @spec load(String.t()) :: {:ok, map()} | {:error, map()}
  def load(id) when is_binary(id) do
    path = Path.join(@court_dir, id <> ".json")

    with {:ok, raw} <- File.read(path),
         {:ok, decoded} <- Jason.decode(raw),
         :ok <- validate(id, decoded) do
      {:ok, decoded}
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error, %{code: :invalid_dfcm_court_json, donor: id, detail: Exception.message(error)}}

      {:error, reason} when is_atom(reason) ->
        {:error, %{code: :missing_dfcm_court, donor: id, detail: reason}}

      {:error, _} = error ->
        error
    end
  end

  @spec validate_all() :: :ok | {:error, map()}
  def validate_all do
    Enum.reduce_while(FleetIntake.ids(), :ok, fn id, :ok ->
      case load(id) do
        {:ok, _} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp validate(id, court) when is_map(court) do
    donor = FleetIntake.fetch!(id)

    cond do
      court["schema"] != "ash-a2a.dfcm-court.v1" ->
        refusal(id, :schema)

      court["donor"] != id ->
        refusal(id, :donor)

      court["subject"] != donor["subject"] ->
        refusal(id, :subject)

      court["authority"] != "NONE" ->
        refusal(id, :authority)

      court["consequence"] != "EVIDENCE_ONLY" ->
        refusal(id, :consequence)

      court["falsifier"] != donor["falsifier"] ->
        refusal(id, :falsifier)

      court["expected"] not in ["REFUSED", "UNKNOWN", "UNSUPPORTED"] ->
        refusal(id, :expected)

      true ->
        :ok
    end
  end

  defp validate(id, _), do: refusal(id, :shape)

  defp refusal(id, field), do: {:error, %{code: :invalid_dfcm_court, donor: id, field: field}}
end
