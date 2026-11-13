# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.Port.Beam4pm do
  @behaviour AshA2A.Replan.Provider

  def supports?(formalism), do: formalism in [:hddl, :fond, :powl, :pddl]

  @moduledoc """
  Replan provider backed by beam4pm.

  beam4pm is a separate server: ash_a2a never compiles or links it. The
  transport is A2A over HTTP -- `config :ash_a2a, :beam4pm_url, "http://host/a2a"`
  (or the `:beam4pm_url` option) sends the request to beam4pm's
  `beam4pm_replan` skill and reads the candidate from the task's first data
  artifact. The in-process path (`:beam4pm_module`) is retained only for an
  explicitly supplied module; no default module is assumed.
  """

  alias AshA2A.Protocol.{Client, Message, Part}

  @skill "beam4pm_replan"

  def propose(request, opts) do
    url = Keyword.get(opts, :beam4pm_url) || Application.get_env(:ash_a2a, :beam4pm_url)

    cond do
      is_binary(url) -> propose_http(url, request, opts)
      Keyword.has_key?(opts, :beam4pm_module) -> propose_local(request, opts)
      true -> {:error, :beam4pm_unavailable}
    end
  end

  defp propose_http(url, request, opts) do
    data = request |> Map.new(fn {k, v} -> {to_string(k), jsonable(v)} end)
    msg = struct(Message.new_user([Part.Data.new(data)]), metadata: %{"skill" => @skill})
    client = Client.new(url, Keyword.take(opts, [:plug, :headers]))

    case Client.send_message(client, msg) do
      {:ok, %AshA2A.Protocol.Task{artifacts: artifacts}} ->
        case first_data(artifacts) do
          nil -> {:error, {:invalid_beam4pm_result, :no_data_artifact}}
          result -> normalize_wire(result, request)
        end

      {:ok, other} ->
        {:error, {:invalid_beam4pm_result, other}}

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

  defp normalize_wire(%{"outcome" => "recompile_required"} = r, request),
    do:
      {:ok,
       %{subject: request[:subject], outcome: :recompile_required, evidence: r["evidence"] || %{}}}

  defp normalize_wire(%{"error" => e}, _request), do: {:error, {:beam4pm_error, e}}

  defp normalize_wire(%{} = r, request),
    do:
      {:ok,
       r
       |> Map.new(fn {k, v} -> {known_atom(k), v} end)
       |> Map.put_new(:subject, request[:subject])}

  defp known_atom(k) do
    String.to_existing_atom(k)
  rescue
    ArgumentError -> k
  end

  defp jsonable(v) when is_atom(v) and v not in [nil, true, false], do: Atom.to_string(v)
  defp jsonable(v) when is_map(v), do: Map.new(v, fn {k, x} -> {to_string(k), jsonable(x)} end)
  defp jsonable(v) when is_list(v), do: Enum.map(v, &jsonable/1)
  defp jsonable(v), do: v

  defp propose_local(request, opts) do
    mod = Keyword.fetch!(opts, :beam4pm_module)

    if Code.ensure_loaded?(mod) and function_exported?(mod, :execute, 4) do
      result =
        apply(mod, :execute, [
          Map.get(request, :decision, :hddl_replan),
          Map.get(request, :handle, 0),
          request,
          Keyword.drop(opts, [:beam4pm_module, :beam4pm_url])
        ])

      normalize(result, request)
    else
      {:error, :beam4pm_unavailable}
    end
  end

  defp normalize({:ok, candidate}, request),
    do: {:ok, Map.put_new(candidate, :subject, Map.get(request, :subject))}

  defp normalize({:recompile_required, evidence}, request),
    do:
      {:ok,
       %{subject: Map.get(request, :subject), outcome: :recompile_required, evidence: evidence}}

  defp normalize({:error, _} = error, _request), do: error
  defp normalize(other, _request), do: {:error, {:invalid_beam4pm_result, other}}
end
