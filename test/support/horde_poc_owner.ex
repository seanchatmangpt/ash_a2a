defmodule AshA2A.Test.HordePocOwner do
  @moduledoc """
  Real helper executed ON a real peer BEAM node by
  `AshA2A.LibclusterHordePocTest`, via `Node.spawn/4` -- the same
  MFA-remote-spawn pattern, and for the same reason, as
  `test/support/distributed_node_loss_owner.ex` uses for the real `group`
  hex package: `Horde.Registry.start_link/1` and
  `Horde.DynamicSupervisor.start_link/1` both call `Supervisor.start_link/3`
  internally, which links the CALLING process to the new supervisor for its
  entire lifetime. A transient `:rpc.call`/`:erpc.call` executes inside a
  short-lived ephemeral worker process that terminates the instant it
  replies, and that termination is itself delivered as a non-`:normal` exit
  signal to everything it is linked to -- which would crash both freshly
  started Horde supervisors immediately. Starting them from a process that
  stays alive for the test's duration (this one) avoids that; the fix is
  which real process owns the link, not a stand-in for either collaborator.

  Also real, and required specifically because this process runs on a bare
  `:peer`-started BEAM node that never ran `mix`/`Application.ensure_all_started`
  for this OTP release: `Horde`'s own runtime dependencies (`:delta_crdt`,
  `:libring`, `:telemetry`, `:telemetry_poller`) are pulled onto this node's
  code path (`test/ash_a2a/libcluster_horde_poc_test.exs` already copied the
  primary node's real `:code.get_path()` here before this function runs),
  but code being *loadable* is not the same as its OTP application being
  *started* -- `Horde.DynamicSupervisorTelemetryPoller` genuinely needs the
  real `:telemetry_poller` application running. `Application.ensure_all_started/1`
  is the real, standard way any node (including a `mix release` boot script)
  brings a dependency's own application tree up before using it.
  """

  @spec start_horde_and_wait(atom(), atom(), pid()) :: no_return()
  def start_horde_and_wait(registry_name, dynsup_name, reply_to) do
    {:ok, _apps} = Application.ensure_all_started(:horde)

    {:ok, registry_pid} =
      Horde.Registry.start_link(name: registry_name, keys: :unique, members: [])

    {:ok, dynsup_pid} =
      Horde.DynamicSupervisor.start_link(
        name: dynsup_name,
        strategy: :one_for_one,
        members: []
      )

    send(reply_to, {:horde_started, registry_pid, dynsup_pid})

    receive do
      :stop -> :ok
    end
  end
end
