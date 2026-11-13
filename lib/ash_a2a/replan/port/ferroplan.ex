# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.Port.Ferroplan do
  @moduledoc """
  Replan provider backed by a ferroplan server over HTTP A2A.

  ash_a2a never links ferroplan. `config :ash_a2a, :ferroplan_url, "http://host/a2a"`
  (or the `:ferroplan_url` option) falls back to `:beam4pm_url` (beam4pm fronts
  ferroplan). The `ferroplan_plan_production` skill reply is read from the task's
  first data artifact. With no URL configured the port answers the typed
  `{:error, :ferroplan_unavailable}`.
  """
  @behaviour AshA2A.Replan.Provider

  alias AshA2A.Protocol.{Client, Message, Part}

  @skill "ferroplan_plan_production"

  def supports?(f), do: f in [:hddl, :fond, :pddl]

  def propose(request, opts) do
    case url(opts) do
      url when is_binary(url) -> propose_http(url, request, opts)
      _ -> {:error, :ferroplan_unavailable}
    end
  end

  @doc "Configured endpoint (option, `:ferroplan_url`, then `:beam4pm_url`) or nil."
  def url(opts \\ []) do
    Keyword.get(opts, :ferroplan_url) || Application.get_env(:ash_a2a, :ferroplan_url) ||
      Keyword.get(opts, :beam4pm_url) || Application.get_env(:ash_a2a, :beam4pm_url)
  end

  defp propose_http(url, request, opts) do
    data = %{
      "domain" => Map.fetch!(request, :domain),
      "problem" => Map.fetch!(request, :problem),
      "extra" => jsonable(Map.get(request, :extra, %{}))
    }

    msg = struct(Message.new_user([Part.Data.new(data)]), metadata: %{"skill" => @skill})
    client = Client.new(url, Keyword.take(opts, [:plug, :headers]))

    case Client.send_message(client, msg) do
      {:ok, %AshA2A.Protocol.Task{artifacts: artifacts}} ->
        case first_data(artifacts) do
          nil -> {:error, {:invalid_ferroplan_result, :no_data_artifact}}
          %{"error" => e} -> {:error, {:ferroplan_error, e}}
          result -> {:ok, result}
        end

      {:ok, other} ->
        {:error, {:invalid_ferroplan_result, other}}

      {:error, _} = error ->
        error
    end
  end

  defp first_data(artifacts) do
    artifacts
    |> List.wrap()
    |> Enum.flat_map(&List.wrap(&1.parts))
    |> Enum.find_value(fn
      %Part.Data{data: d} when is_map(d) -> d
      _ -> nil
    end)
  end

  defp jsonable(v) when is_atom(v) and v not in [nil, true, false], do: Atom.to_string(v)
  defp jsonable(v) when is_map(v), do: Map.new(v, fn {k, x} -> {to_string(k), jsonable(x)} end)
  defp jsonable(v) when is_list(v), do: Enum.map(v, &jsonable/1)
  defp jsonable(v), do: v
end
