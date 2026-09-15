defmodule AshA2A.RuntimeProvidersIntegrationTest do
  @moduledoc """
  Exercises the configured runtime-provider boundaries --
  `AshA2A.Execution.FLAME` (Placement), `AshA2A.Durability.DurableServer`
  (Durability), and `AshA2A.Topology.Presence` (Topology) -- against actual
  FLAME, DurableServer, Phoenix Presence, and Phoenix PubSub
  implementations, rather than substitute provider modules.

  Each describe block also asserts the boundary that makes these adapters
  safe to compose: none of them ever carry Ash command execution, task
  completion, or authority standing of their own -- only observed provider
  evidence via `AshA2A.RuntimeReceipt`.
  """
  use ExUnit.Case, async: false

  alias AshA2A.Durability.DurableServer, as: Durability
  alias AshA2A.Execution.FLAME, as: Placement
  alias AshA2A.Identity
  alias AshA2A.Test.DurableServerFixture
  alias AshA2A.Test.PresenceFixture

  describe "Placement (AshA2A.Execution.FLAME)" do
    test "available?/0 resolves against the real flame dependency" do
      assert Placement.available?()
    end
  end

  describe "Durability (AshA2A.Durability.DurableServer)" do
    setup do
      sup_name = :"ash_a2a_test_durable_sup_#{System.unique_integer([:positive])}"

      # EKVStore is a real embedded/local durable_server storage backend,
      # backed by the real :ekv package's own on-disk durable KV store --
      # used here instead of the default ObjectStore/S3 backend so this
      # test exercises real durability semantics without requiring cloud
      # storage credentials.
      ekv_name = :"#{sup_name}_ekv"

      data_dir =
        Path.join(System.tmp_dir!(), "ash_a2a_ekv_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(data_dir)
      on_exit(fn -> File.rm_rf!(data_dir) end)

      # cluster_size: 1 -- a real single-voter CAS quorum, sufficient for a
      # single-node test; DurableServer.Backends.EKVStore requires CAS to
      # be configured (cluster_size not nil) to accept writes.
      start_supervised!({EKV, name: ekv_name, data_dir: data_dir, cluster_size: 1})

      start_supervised!(
        {DurableServer.Supervisor,
         name: sup_name,
         prefix: "ash-a2a-test/",
         backend: {DurableServer.Backends.EKVStore, name: ekv_name}}
      )

      %{sup: sup_name}
    end

    test "available?/0 resolves against the real durable_server dependency" do
      assert Durability.available?()
      assert Durability.provider() == DurableServer.Supervisor
    end

    test "ensure_task/delete_task drive an actual DurableServer-managed GenServer", %{sup: sup} do
      task_id = Identity.new(:task, "runtime-providers-#{System.unique_integer([:positive])}")

      assert {:ok,
              %AshA2A.RuntimeReceipt{provider: :durable_server, operation: :ensure_started_child}} =
               Durability.ensure_task(sup, DurableServerFixture, task_id, %{count: 0})

      {pid, _meta} = DurableServer.Supervisor.lookup(sup, Durability.key(task_id))
      assert is_pid(pid)
      assert GenServer.call(pid, :get) == 0
      assert GenServer.call(pid, :increment) == 1
      assert GenServer.call(pid, :increment) == 2

      assert {:ok, %AshA2A.RuntimeReceipt{provider: :durable_server}} =
               Durability.delete_task(sup, task_id)

      refute Process.alive?(pid)
    end

    test "receipts carry only observed provider standing, no Ash command/task completion", %{
      sup: sup
    } do
      task_id =
        Identity.new(:task, "runtime-providers-boundary-#{System.unique_integer([:positive])}")

      {:ok, receipt} = Durability.ensure_task(sup, DurableServerFixture, task_id, %{count: 0})

      assert receipt.provider == :durable_server
      assert receipt.standing == :observed
      refute Map.has_key?(receipt, :command_id)
    end
  end

  describe "Topology (AshA2A.Topology.Presence)" do
    setup do
      start_supervised!({Phoenix.PubSub, name: AshA2A.Test.PubSubFixture})
      start_supervised!(PresenceFixture)
      :ok
    end

    test "available?/1 resolves against the real phoenix/phoenix_pubsub dependencies" do
      assert AshA2A.Topology.Presence.available?(PresenceFixture)
    end

    test "track/list/untrack drive an actual Phoenix.Presence process" do
      alias AshA2A.Topology.Presence

      identity =
        Identity.new(:agent, "runtime-providers-topology-#{System.unique_integer([:positive])}")

      topic = "runtime-providers:test"

      assert {:ok, %AshA2A.RuntimeReceipt{provider: :phoenix_presence, operation: :track}} =
               Presence.track(PresenceFixture, self(), topic, identity, %{role: :test})

      present = Presence.list(PresenceFixture, topic)
      key = Presence.key(identity)
      assert Map.has_key?(present, key)

      assert {:ok, %AshA2A.RuntimeReceipt{provider: :phoenix_presence, operation: :untrack}} =
               Presence.untrack(PresenceFixture, self(), topic, identity)

      {:ok, track_receipt} = Presence.track(PresenceFixture, self(), topic, identity, %{})
      assert track_receipt.standing == :observed
      refute Map.has_key?(track_receipt, :command_id)
    end
  end
end
