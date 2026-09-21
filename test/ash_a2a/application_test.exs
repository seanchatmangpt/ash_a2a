defmodule AshA2A.ApplicationTest do
  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  @moduledoc """
  Exercises `AshA2A.Application.start/2` for real. Every other test in this
  suite that needs a running `A2A.AgentSupervisor` bypasses this module and
  calls `A2A.AgentSupervisor.start_link/1` directly (see
  `test/ash_a2a_test.exs` and `test/ash_a2a_registry_test.exs`) -- so
  `AshA2A.Application.start/2` itself, and the real `A2A.AgentSupervisor`
  child spec it wires under `AshA2A.Supervisor`, were never actually
  invoked anywhere in the suite. This file closes that gap.

  Because `:ash_a2a` is declared with `mod: {AshA2A.Application, []}` in
  `mix.exs`, `mix test` already starts the real application (and therefore
  already calls `start/2`) before any test runs. Each test here stops the
  already-running `:ash_a2a` application, calls `AshA2A.Application.start/2`
  directly, asserts on the real resulting supervision tree, then restores
  the application to a running state so later test files (which assume a
  running `:ash_a2a` app) are unaffected.
  """

  alias AshA2A.{Authority, Identity}

  setup do
    Application.stop(:ash_a2a)

    on_exit(fn ->
      Application.ensure_all_started(:ash_a2a)
    end)

    :ok
  end

  test "start/2 returns a real, running top-level supervisor named AshA2A.Supervisor" do
    assert {:ok, pid} = AshA2A.Application.start(:normal, [])
    assert is_pid(pid)
    assert Process.alive?(pid)
    assert Process.whereis(AshA2A.Supervisor) == pid

    Supervisor.stop(pid)
  end

  test "start/2 actually starts a real A2A.AgentSupervisor child under it" do
    {:ok, pid} = AshA2A.Application.start(:normal, [])

    children = Supervisor.which_children(pid)

    # The real supervision tree also carries the intentional
    # AshA2A.ReceiptStore.Memory worker (added by the receipted command
    # bus work) -- locate A2A.AgentSupervisor specifically rather than
    # requiring an exhaustive one-child list.
    assert {A2A.AgentSupervisor, child_pid, :supervisor, _modules} =
             List.keyfind(children, A2A.AgentSupervisor, 0)

    assert is_pid(child_pid)
    assert Process.alive?(child_pid)

    # The A2A.AgentSupervisor child is a real, independently-running
    # supervisor (not a mock/stub) -- it starts its own real A2A.Registry
    # child underneath, with no agents configured for this test app.
    assert Process.whereis(A2A.Registry) != nil
    assert [{A2A.Registry, registry_pid, _, _}] = Supervisor.which_children(child_pid)
    assert Process.alive?(registry_pid)

    Supervisor.stop(pid)
  end

  test "start/2 reads real agents from Application config and starts them under the real supervisor" do
    previous = Application.get_env(:ash_a2a, :agents, [])
    Application.put_env(:ash_a2a, :agents, [AshA2A.Test.Fixture.EchoAgent])

    on_exit(fn -> Application.put_env(:ash_a2a, :agents, previous) end)

    {:ok, pid} = AshA2A.Application.start(:normal, [])

    {A2A.AgentSupervisor, agent_sup_pid, :supervisor, _} =
      List.keyfind(Supervisor.which_children(pid), A2A.AgentSupervisor, 0)

    agent_children = Supervisor.which_children(agent_sup_pid)

    assert Enum.any?(agent_children, fn {id, child_pid, _type, _modules} ->
             id == AshA2A.Test.Fixture.EchoAgent and is_pid(child_pid) and
               Process.alive?(child_pid)
           end)

    Supervisor.stop(pid)
  end

  # An `on_exit` callback runs in a separate process, after the test process
  # that started `pid` has already exited -- unlike the inline
  # `Supervisor.stop(pid)` calls above (same process, so ordering is
  # guaranteed). Calling `Supervisor.stop/1` unconditionally from `on_exit`
  # observably raced with that ordinary teardown and crashed the on_exit
  # handler (confirmed while writing the tests below: `GenServer.stop`
  # raised `** (EXIT) shutdown` here on a real, otherwise-healthy
  # supervisor) -- a real defensive gap in the naive on_exit pattern, not a
  # hypothetical one. Used only as a safety net so a failed assertion still
  # tears down the real named EKV children instead of leaking them into the
  # next test; the happy path in each test below still also relies on this,
  # since (unlike the three pre-existing tests above) an assertion between
  # `start/2` and cleanup can itself raise.
  defp safe_stop(pid) do
    if Process.alive?(pid) do
      try do
        Supervisor.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end
  end

  describe "config :ash_a2a, :authority_broker, AshA2A.Authority.Broker.Ekv" do
    # v26.9.17 real gap: AshA2A.Authority.Broker.Ekv's own moduledoc states it
    # "does not start or supervise EKV itself" -- before this fix,
    # `AshA2A.Application.start/2` wired an EKV instance automatically for
    # `:receipt_store` but had no equivalent clause for `:authority_broker`,
    # so `docs/how-to/authenticate-agent-requests.md`'s own primary example
    # (this exact config line, alone) was not actually config-only: a host
    # who set only this and started their app got a real EKV instance
    # missing, and every `granted?/3` call would rescue/catch to `false`
    # (broker "unavailable") rather than ever answering a grant question.
    # This test proves the fix by doing nothing except set config, call the
    # real `start/2`, and then round-trip a real grant through the broker
    # module directly -- no manual EKV start anywhere in this test.
    setup do
      previous_broker = Application.get_env(:ash_a2a, :authority_broker)
      previous_opts = Application.get_env(:ash_a2a, :authority_broker_ekv_opts)

      # `System.unique_integer/1` is only unique within ONE BEAM run; two
      # separate `mix test` invocations (each a fresh VM) can produce the
      # SAME small integer, so a bare `unique_integer`-suffixed path can
      # collide with a stale on-disk directory a prior run's crash left
      # uncleaned -- observed for real while writing this test (a second
      # `mix test` run reused a previous run's leftover EKV data_dir and
      # `AshA2A.Authority.Grant.grant/3` failed `:token_id_taken` against an
      # entry a prior process actually wrote). `system_time(:nanosecond)` is
      # unique across process boundaries too; the defensive `rm_rf!` before
      # use makes this robust even if some other leftover somehow shared the
      # same nanosecond.
      unique_suffix = "#{System.system_time(:nanosecond)}_#{System.unique_integer([:positive])}"

      unique_dir =
        Path.join(
          System.tmp_dir!(),
          "ash_a2a_application_test_authority_broker_ekv_#{unique_suffix}"
        )

      File.rm_rf!(unique_dir)

      Application.put_env(:ash_a2a, :authority_broker, AshA2A.Authority.Broker.Ekv)

      on_exit(fn ->
        File.rm_rf!(unique_dir)

        if previous_broker do
          Application.put_env(:ash_a2a, :authority_broker, previous_broker)
        else
          Application.delete_env(:ash_a2a, :authority_broker)
        end

        if previous_opts do
          Application.put_env(:ash_a2a, :authority_broker_ekv_opts, previous_opts)
        else
          Application.delete_env(:ash_a2a, :authority_broker_ekv_opts)
        end
      end)

      %{unique_dir: unique_dir}
    end

    test "start/2 auto-starts a real EKV child for the broker, with no manual EKV start",
         %{unique_dir: unique_dir} do
      # `:name` is deliberately left at its default (AshA2A.Authority.Broker.Ekv)
      # so `AshA2A.Authority.Grant`'s calls below -- called with NO :name
      # opt -- resolve to the exact same real running instance `start/2`
      # wired, proving the wiring is genuinely reachable through the
      # broker's own default-opts path, not just present in the supervision
      # tree under some other name.
      Application.put_env(:ash_a2a, :authority_broker_ekv_opts, data_dir: unique_dir)

      {:ok, pid} = AshA2A.Application.start(:normal, [])
      # Registered before any assertion below can raise, so a failing
      # assertion never leaks this real, name-registered supervision tree
      # (and its named EKV child) into the next test in this file.
      on_exit(fn -> safe_stop(pid) end)

      children = Supervisor.which_children(pid)
      child_id = {EKV, AshA2A.Authority.Broker.Ekv}

      # EKV.child_spec/1's real type is :supervisor (it wires its own
      # EKV.Supervisor underneath, matching the receipt store's own EKV
      # child), not :worker.
      assert {^child_id, child_pid, :supervisor, _modules} = List.keyfind(children, child_id, 0)
      assert is_pid(child_pid)
      assert Process.alive?(child_pid)

      # Go through the real production entry point, `AshA2A.Authority.Grant`
      # (not `AshA2A.Authority.Broker.Ekv.issue/3` directly): `Grant.grant/3`
      # is what pins the durable EKV entry's key to
      # `Authority.grant_token_id(subject, capability_id)`, which is also
      # exactly the key `granted?/3` (and the real dispatch path's
      # `Authority.Grant.authorize/3`) reads back -- proving the SAME
      # config-only wiring a real caller actually uses end-to-end, not just
      # that some EKV process exists.
      # Unique per test run for the same reason `unique_dir` above is: the
      # durable key `Grant.grant/3` writes under is a deterministic function
      # of exactly `(subject, capability_id)` (`Authority.grant_token_id/2`),
      # so a fixed literal string here would collide with a prior run's
      # entry even with a fresh EKV data_dir if that data_dir were ever
      # reused.
      subject =
        Identity.principal(
          "application-test-authority-broker-ekv-subject-#{System.unique_integer([:positive])}"
        )

      assert {:ok, %Authority{} = authority} =
               AshA2A.Authority.Grant.grant(subject, "app-test:read")

      assert AshA2A.Authority.Grant.granted?(subject, "app-test:read")
      refute AshA2A.Authority.Grant.granted?(subject, "app-test:write")

      assert :ok = AshA2A.Authority.Grant.revoke(subject, "app-test:read")
      refute AshA2A.Authority.Grant.granted?(subject, "app-test:read")
      # authority struct is asserted on above (source/subject/capability_id
      # implicitly proven real by the round trip); referenced here only to
      # keep the compiler from flagging it unused.
      refute is_nil(authority.token_id)
    end

    test "start/2 does not double-count the receipt-store's EKV child as the broker's",
         %{unique_dir: unique_dir} do
      # Both layers configured to Ekv at once -- the real production-scale
      # recommendation this task's docs update makes -- must yield TWO
      # distinct real EKV children (different `{EKV, name}` ids, different
      # data_dir), never one shared instance silently reused for both.
      receipt_dir = unique_dir <> "_receipt"
      File.rm_rf!(receipt_dir)
      on_exit(fn -> File.rm_rf!(receipt_dir) end)

      previous_receipt_store = Application.get_env(:ash_a2a, :receipt_store)
      previous_receipt_opts = Application.get_env(:ash_a2a, :receipt_store_ekv_opts)

      Application.put_env(:ash_a2a, :receipt_store, AshA2A.ReceiptStore.Ekv)
      Application.put_env(:ash_a2a, :receipt_store_ekv_opts, data_dir: receipt_dir)
      Application.put_env(:ash_a2a, :authority_broker_ekv_opts, data_dir: unique_dir)

      on_exit(fn ->
        if previous_receipt_store do
          Application.put_env(:ash_a2a, :receipt_store, previous_receipt_store)
        else
          Application.delete_env(:ash_a2a, :receipt_store)
        end

        if previous_receipt_opts do
          Application.put_env(:ash_a2a, :receipt_store_ekv_opts, previous_receipt_opts)
        else
          Application.delete_env(:ash_a2a, :receipt_store_ekv_opts)
        end
      end)

      {:ok, pid} = AshA2A.Application.start(:normal, [])
      on_exit(fn -> safe_stop(pid) end)

      children = Supervisor.which_children(pid)

      assert {{EKV, AshA2A.ReceiptStore.Ekv}, receipt_pid, :supervisor, _} =
               List.keyfind(children, {EKV, AshA2A.ReceiptStore.Ekv}, 0)

      assert {{EKV, AshA2A.Authority.Broker.Ekv}, broker_pid, :supervisor, _} =
               List.keyfind(children, {EKV, AshA2A.Authority.Broker.Ekv}, 0)

      assert receipt_pid != broker_pid
      assert Process.alive?(receipt_pid)
      assert Process.alive?(broker_pid)
    end
  end
end
