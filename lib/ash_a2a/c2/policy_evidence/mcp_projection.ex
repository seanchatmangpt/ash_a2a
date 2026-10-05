# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C2.PolicyEvidence.McpProjection do
  @moduledoc """
  Projects an MCP `tools/call` request (the COAZ-MCP shape) into a powerless
  `PreparedEffect`. The projection has no authority: the result still needs a
  bound `PolicyEvidence`, admission, a certificate and actuator-local mediation.
  Principal comes from the authenticated caller, never from tool arguments.
  """

  alias AshA2A.C2.PreparedEffect

  @spec project(term(), map()) :: {:ok, PreparedEffect.t()} | {:error, atom()}
  def project(principal, %{"name" => name} = params) when is_binary(name) and name != "" do
    args = Map.get(params, "arguments", %{})

    if is_map(args) do
      PreparedEffect.build(principal, "mcp.tool:" <> name, %{"tool" => name}, args)
    else
      {:error, :mcp_arguments_malformed}
    end
  end

  def project(_principal, _params), do: {:error, :mcp_tool_name_missing}
end
