# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Domain.Mount do
  @moduledoc """
  Introspection target for `mount` declarations in `AshA2A.Domain`'s
  `transport` section.

  Two declaration forms:

      transport do
        # path-only: the domain-level default mount path (feeds
        # `AshA2A.Domain.Info.mount/1` and the derived card endpoint)
        default_mount "/a2a"

        # per-agent: one agent served at one path over one binding
        mount agent: MyApp.EchoAgent, path: "/echo", binding: :jsonrpc
        mount agent: MyApp.RestAgent, path: "/rest", binding: :rest
      end

  Per-agent mounts are recorded under the persisted
  `ash_a2a_domain_mounts` key and served by `AshA2A.Domain.Router`;
  the path-only form is the `transport.default_mount` option and sets the
  domain's default mount path.
  """

  defstruct [:agent, :path, :binding, :__spark_metadata__]

  @type t :: %__MODULE__{
          agent: module() | nil,
          path: String.t(),
          binding: :jsonrpc | :rest | :grpc,
          __spark_metadata__: map() | nil
        }

  @typedoc "Transport binding of a mount."
  @type binding :: :jsonrpc | :rest | :grpc

  @doc "The set of transport bindings a mount may declare."
  @spec bindings() :: [:jsonrpc | :rest | :grpc]
  def bindings, do: [:jsonrpc, :rest, :grpc]

  @doc "Whether this mount declares a per-agent mount (as opposed to the path-only default)."
  @spec agent_mount?(__MODULE__.t()) :: boolean()
  def agent_mount?(%__MODULE__{agent: agent}), do: not is_nil(agent)

  @doc """
  The A2A `protocolBinding` string (spec §4.4/8.2, `"JSONRPC" | "GRPC" |
  "HTTP+JSON"`) for a mount's binding.

  Accepts a binding atom or a mount struct.

      iex> AshA2A.Domain.Mount.protocol_binding(:jsonrpc)
      "JSONRPC"

      iex> AshA2A.Domain.Mount.protocol_binding(:rest)
      "HTTP+JSON"

      iex> AshA2A.Domain.Mount.protocol_binding(:grpc)
      "GRPC"
  """
  @spec protocol_binding(binding() | __MODULE__.t()) :: String.t()
  def protocol_binding(%__MODULE__{binding: binding}), do: protocol_binding(binding)

  def protocol_binding(:jsonrpc), do: "JSONRPC"
  def protocol_binding(:rest), do: "HTTP+JSON"
  def protocol_binding(:grpc), do: "GRPC"
end
