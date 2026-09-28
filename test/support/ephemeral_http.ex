# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Test.EphemeralHttp do
  @moduledoc """
  Starts a real Bandit HTTP listener on an OS-assigned ephemeral port
  (`port: 0`) bound to loopback, and reads the actually-bound port back via
  `ThousandIsland.listener_info/1`.

  Replaces the `Enum.random(22_000..22_999)`-style port picking (TQ-07):
  `:serial_shard` files run as several `MIX_TEST_PARTITION` OS processes in
  parallel, so two shards drawing from the same fixed range could collide
  and crash with `{:error, :eaddrinuse}`. The kernel never hands the same
  ephemeral port to two live listeners, so this cannot collide.
  """

  @doc """
  Starts `plug` on `127.0.0.1:<ephemeral>` linked to the caller. Returns
  `%{pid: pid, port: port, base_url: "http://127.0.0.1:<port>"}`.
  """
  @spec start!(module() | {module(), term()}, keyword()) :: %{
          pid: pid(),
          port: :inet.port_number(),
          base_url: String.t()
        }
  def start!(plug, extra_opts \\ []) do
    opts = Keyword.merge([plug: plug, port: 0, ip: {127, 0, 0, 1}], extra_opts)
    {:ok, pid} = Bandit.start_link(opts)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    true = is_integer(port) and port > 0

    %{pid: pid, port: port, base_url: "http://127.0.0.1:#{port}"}
  end
end
