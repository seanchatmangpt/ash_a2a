# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Sim.RequiredExtension do
  @moduledoc """
  The one extension the simulation server's required-extension mounts demand:
  `https://example.com/ext/sim-required/v1`, declared `required: true`.

  `AshA2A.Sim.Server` mounts it on a second JSON-RPC mount
  (`/required/a2a`), a second HTTP+JSON mount (`/required/rest`) and a second
  gRPC listener (`required_grpc_target` in `AshA2A.Sim.Server.info/1`). A call
  to one of them that does not list the URI in `A2A-Extensions` is refused
  with `ExtensionSupportRequiredError` (`-32008`); a call that lists it runs
  and the answer echoes the URI in the `A2A-Extensions` response header. An
  extra URI the server neither requires nor serves is ignored (spec 4.6.3).

  The extension changes nothing about the task: it is a data-only extension
  whose only effect is to be required. The standing mounts (`/a2a`,
  `/jsonrpc`, `/rest` and the main gRPC listener) declare no extension, so no
  client of those has to send the header.
  """

  @behaviour AshA2A.Protocol.Extension

  @uri "https://example.com/ext/sim-required/v1"

  @doc "The URI of the required extension."
  @spec uri() :: String.t()
  def uri, do: @uri

  @impl AshA2A.Protocol.Extension
  def declaration(_state) do
    %AshA2A.Protocol.AgentExtension{
      uri: @uri,
      description: "Simulation extension: clients of the required mounts must activate it.",
      required: true,
      params: %{"purpose" => "required-extension refusal"}
    }
  end

  @impl AshA2A.Protocol.Extension
  def activate(_requested_uris, _ctx, _state), do: {:ok, :active}
end
