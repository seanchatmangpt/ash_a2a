# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Test.LaneL06DurableServerPeerOwner do
  @moduledoc """
  Helper run ON a real `:peer` BEAM node (via `Node.spawn/4`) by
  `AshA2A.LaneL06DurableServerCrossnodeRehomeTest`. It starts one EKV cluster
  member plus one `DurableServer.Supervisor` under a supervisor owned by a
  process that stays alive until told to stop (same ownership reason as
  `AshA2A.Test.MultinodeEkvOwner`: a transient `:erpc` worker would take the
  linked supervisor down when it exits). Lives in `test/support/` so the peer
  can load its compiled `.beam`.
  """

  @spec start_and_wait(keyword(), keyword(), pid()) :: no_return()
  def start_and_wait(ekv_opts, sup_opts, reply_to) do
    {:ok, _apps} = Application.ensure_all_started(:durable_server)
    {:ok, _apps} = Application.ensure_all_started(:ekv)

    children = [
      {EKV, ekv_opts},
      Supervisor.child_spec({DurableServer.Supervisor, sup_opts}, id: :durable_server_sup)
    ]

    case Supervisor.start_link(children, strategy: :one_for_one) do
      {:ok, sup_pid} -> send(reply_to, {:l06_peer_started, node(), sup_pid})
      {:error, reason} -> send(reply_to, {:l06_peer_start_failed, node(), reason})
    end

    receive do
      :stop -> :ok
    end
  end
end
