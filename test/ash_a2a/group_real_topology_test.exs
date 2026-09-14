defmodule AshA2A.GroupRealTopologyTest do
  @moduledoc """
  Exercises `AshA2A.Topology.Group` against a REAL `Group` registry/supervisor
  (the real `:group` hex dependency, resolved transitively through
  `durable_server` in mix.lock), started for real under this test's own
  ExUnit supervision tree.

  This is deliberately a companion to `group_topology_test.exs`, not a
  replacement for it: that file's "missing Group provider" branch is gated by
  `unless Group.available?() do ... end`, and `Group.available?/0` is real
  `true` in this repo (the `:group` module really compiles and loads), so
  that branch's body never actually executes there -- confirmed again below.
  This file supplies the real-provider coverage that gap leaves behind: a
  real `Group` supervisor is actually started, real processes actually
  register/join/leave/die against it, and real state is asserted at every
  step (never "was this called").

  No test double appears anywhere in this file: `Group` (the dependency) is a
  real, locally runnable, no-external-dependency registry -- there is no
  reason to fake it.
  """

  use ExUnit.Case, async: true

  alias AshA2A.{Identity, RuntimeReceipt, Topology.Group}

  setup do
    registry_name = :"group_real_topology_test_#{System.unique_integer([:positive, :monotonic])}"

    start_supervised!({Elixir.Group, name: registry_name, shards: 2, log: false})

    {:ok, registry: registry_name}
  end

  test "confirms the audit finding: Group.available?/0 is real true, so group_topology_test.exs's guarded branch never runs" do
    # This is the real, checked reason group_topology_test.exs's
    # `unless Group.available?() do ... end` body is dead in this repo: the
    # real `:group` dependency really compiles and loads here.
    assert Group.available?() == true
    assert Code.ensure_loaded?(Elixir.Group)
  end

  test "register/3 makes the real calling process really findable via real lookup/2", %{
    registry: registry
  } do
    identity = Identity.agent("register-worker")

    assert Group.lookup(registry, identity) == nil

    assert {:ok, %RuntimeReceipt{} = receipt} =
             Group.register(registry, identity, %{role: :worker})

    assert receipt.provider == :group
    assert receipt.operation == :register
    assert receipt.status == :completed

    assert {pid, %{role: :worker}} = Group.lookup(registry, identity)
    assert pid == self()
  end

  test "registering the same key twice from two different real processes really yields {:error, :taken}",
       %{registry: registry} do
    identity = Identity.agent("contested-worker")
    test_pid = self()

    assert {:ok, _receipt} = Group.register(registry, identity, %{owner: :test_process})

    other =
      spawn(fn ->
        result = Group.register(registry, identity, %{owner: :other_process})
        send(test_pid, {:other_register_result, result})
      end)

    assert_receive {:other_register_result, result}, 1_000
    assert result == {:error, :taken}
    assert is_pid(other)

    # the original registration is untouched
    assert {pid, %{owner: :test_process}} = Group.lookup(registry, identity)
    assert pid == test_pid
  end

  test "unregister/2 really removes the registration from real lookup/2", %{registry: registry} do
    identity = Identity.agent("unregister-worker")

    assert {:ok, _receipt} = Group.register(registry, identity, %{})
    assert {_pid, %{}} = Group.lookup(registry, identity)

    assert {:ok, %RuntimeReceipt{} = receipt} = Group.unregister(registry, identity)
    assert receipt.operation == :unregister
    assert receipt.status == :completed

    assert Group.lookup(registry, identity) == nil
  end

  test "unregistering a key nobody registered really returns a typed error, not fabricated success",
       %{
         registry: registry
       } do
    identity = Identity.agent("never-registered")

    assert {:error, _reason} = Group.unregister(registry, identity)
  end

  test "join/3 makes the real calling process really appear in real members/2, leave/2 really removes it",
       %{registry: registry} do
    group_key = "topology-real-group"

    assert Group.members(registry, group_key) == []

    assert {:ok, %RuntimeReceipt{} = join_receipt} =
             Group.join(registry, group_key, %{tag: :alpha})

    assert join_receipt.provider == :group
    assert join_receipt.operation == :join
    assert join_receipt.status == :completed

    members = Group.members(registry, group_key)
    assert [{pid, %{tag: :alpha}}] = members
    assert pid == self()

    assert {:ok, %RuntimeReceipt{} = leave_receipt} = Group.leave(registry, group_key)
    assert leave_receipt.operation == :leave
    assert leave_receipt.status == :completed

    assert Group.members(registry, group_key) == []
  end

  test "leaving a group never joined really returns a typed error", %{registry: registry} do
    assert {:error, :not_in_group} = Group.leave(registry, "never-joined-group")
  end

  test "a real joined process really disappears from real members/2 once it really dies", %{
    registry: registry
  } do
    group_key = "topology-death-group"
    test_pid = self()

    {:ok, worker} =
      Task.start(fn ->
        {:ok, _receipt} = Group.join(registry, group_key, %{role: :ephemeral})
        send(test_pid, :joined)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :joined, 1_000

    members_before = Group.members(registry, group_key)
    assert Enum.any?(members_before, fn {pid, _meta} -> pid == worker end)

    ref = Process.monitor(worker)
    send(worker, :stop)
    assert_receive {:DOWN, ^ref, :process, ^worker, _reason}, 1_000

    # Group's shard genserver removes dead-process entries via its own DOWN
    # handler, which runs after (not synchronously with) the process exit
    # this test observed -- poll real state instead of asserting instantly.
    assert wait_until(fn ->
             not Enum.any?(Group.members(registry, group_key), fn {pid, _meta} ->
               pid == worker
             end)
           end)
  end

  test "typed identities still become the same deterministic topology keys against the real provider",
       %{
         registry: registry
       } do
    assert Group.key(Identity.agent("worker-1")) == "agent:worker-1"
    assert Group.key(Identity.runtime("node-a")) == "runtime:node-a"
    assert Group.key("raw") == "raw"

    assert {:ok, _receipt} = Group.register(registry, Identity.agent("worker-1"), %{})
    assert {pid, %{}} = Group.lookup(registry, "agent:worker-1")
    assert pid == self()
  end

  test "topology adapter is structurally incapable of reading or writing canonical capability truth (AshA2A.Info)" do
    # Concrete, checked property (not just an assertion in prose): every
    # public function AshA2A.Topology.Group exports takes only
    # (registry-name, identity/group-key, metadata, opts) terms. None takes
    # or returns anything shaped like an Ash resource, changeset, query, or
    # a call into AshA2A.Info -- and the module source itself never
    # references AshA2A.Info, Ash.Query, or Ash.Changeset at all, so there is
    # no code path here that could reach canonical capability truth.
    source_path = Path.join([__DIR__, "..", "..", "lib", "ash_a2a", "topology", "group.ex"])
    {:ok, source} = File.read(source_path)

    refute source =~ "AshA2A.Info"
    refute source =~ "Ash.Query"
    refute source =~ "Ash.Changeset"

    functions = AshA2A.Topology.Group.__info__(:functions)

    assert {:register, 3} in functions
    assert {:lookup, 2} in functions
    assert {:unregister, 2} in functions
    assert {:join, 3} in functions
    assert {:members, 2} in functions
    assert {:leave, 2} in functions

    refute Enum.any?(functions, fn {name, _arity} ->
             name in [:capability, :capabilities, :info, :domain, :resource]
           end)
  end

  defp wait_until(fun, attempts \\ 40)
  defp wait_until(_fun, 0), do: false

  defp wait_until(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(25)
      wait_until(fun, attempts - 1)
    end
  end
end
