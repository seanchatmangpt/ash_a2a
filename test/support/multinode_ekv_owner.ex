defmodule AshA2A.Test.MultinodeEkvOwner do
  @moduledoc """
  Real helper executed ON a real peer BEAM node by
  `AshA2A.ReceiptStoreEkvCrossnodeTest`, via `Node.spawn/4` -- the same
  MFA-remote-spawn pattern `test/support/distributed_node_loss_owner.ex` and
  `test/support/horde_poc_owner.ex` use, and for the identical,
  empirically-established reason documented on both of those modules:
  `EKV.start_link/1` calls `EKV.Supervisor.start_link/3` internally, which
  links the CALLING process to the new supervisor for the supervisor's
  entire lifetime. A transient `:erpc.call/:rpc.call` executes the remote
  MFA inside a short-lived ephemeral worker process that terminates the
  instant it replies to its caller, and that termination is itself a
  non-`:normal` exit signal delivered to everything it is linked to --
  which would crash a freshly `EKV.start_link/1`-started supervisor
  immediately (this is the exact, already-diagnosed failure mode
  `AshA2A.Test.HordePocOwner`'s @moduledoc documents for `Horde.Registry`/
  `Horde.DynamicSupervisor`, and it applies identically here since both
  ultimately call `Supervisor.start_link/3`). Starting the EKV member from a
  process that stays alive for the test's duration (this one, parked in a
  `receive do :stop -> :ok end` loop after reporting back) avoids that
  entirely -- the fix is which real process owns the link, not a stand-in
  for either collaborator.

  This module lives under `test/support/` (not inline in the test file)
  specifically so it IS compiled to a real, on-disk `.beam` file a freshly
  started `:peer` node can load from the extended code path the test gives
  it (`:code.add_pathsz/1`) -- an anonymous closure defined directly in a
  `*_test.exs` file would be unloadable there, per the same real,
  previously-diagnosed reason `AshA2A.Test.DistributedNodeLossOwner`'s
  @moduledoc documents (`test/**/*_test.exs` files are compiled in-memory
  only by `mix test`, never written to `_build/test/lib/ash_a2a/ebin/*.beam`).

  `Application.ensure_all_started(:ekv)` runs first for the same real reason
  `AshA2A.Test.HordePocOwner` runs it for `:horde`: a bare `:peer`-started
  BEAM node never ran this project's own `mix`/`Application.ensure_all_started`
  boot sequence, so `:ekv`'s own OTP application (`EKV.Application`, per
  `deps/ekv/mix.exs`'s `mod:` entry) has never been started there -- code
  being loadable on the extended path is not the same as its application
  tree being up.
  """

  @spec start_ekv_member_and_wait(keyword(), pid()) :: no_return()
  def start_ekv_member_and_wait(ekv_opts, reply_to) do
    {:ok, _apps} = Application.ensure_all_started(:ekv)

    case EKV.start_link(ekv_opts) do
      {:ok, sup_pid} ->
        send(reply_to, {:ekv_member_started, node(), sup_pid})

      {:error, reason} ->
        send(reply_to, {:ekv_member_start_failed, node(), reason})
    end

    receive do
      :stop -> :ok
    end
  end
end
