# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.AuthZEN.Wire do
  @moduledoc """
  Wire encoding for OpenID AuthZEN Authorization API 1.0: `entity/1`, `action/1`, and
  `request/1` render `AshA2A.AuthZEN.Types` structs, and `decode_decision/1` decodes raw
  decision payloads. Transport shapes only; decoded decisions remain evidence.
  """

  alias AshA2A.AuthZEN.Types

  def entity(%Types.Entity{} = e) do
    %{"type" => e.type, "id" => e.id}
    |> then(fn m ->
      if e.properties in [nil, %{}], do: m, else: Map.put(m, "properties", e.properties)
    end)
  end

  def action(%Types.Action{} = a) do
    %{"name" => a.name}
    |> then(fn m ->
      if a.properties in [nil, %{}], do: m, else: Map.put(m, "properties", a.properties)
    end)
  end

  def request(%Types.Request{} = r) do
    %{
      "subject" => entity(r.subject),
      "action" => action(r.action),
      "resource" => entity(r.resource),
      "context" => r.context || %{}
    }
  end

  def decode_decision(raw) when is_map(raw) do
    decision = Map.get(raw, "decision", Map.get(raw, :decision))

    if is_boolean(decision) do
      {:ok,
       %Types.Decision{
         decision: decision,
         context: Map.get(raw, "context", Map.get(raw, :context, %{})),
         source: Map.get(raw, "source", Map.get(raw, :source)),
         observed_at: Map.get(raw, "observed_at", Map.get(raw, :observed_at))
       }}
    else
      {:error, :invalid_decision}
    end
  end

  def decode_decision(_), do: {:error, :invalid_decision}
end
