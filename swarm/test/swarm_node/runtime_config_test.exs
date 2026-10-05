defmodule SwarmNode.RuntimeConfigTest do
  @moduledoc """
  DEP-02/03/04/12: evaluates the real `config/runtime.exs` for `:prod` with
  `Config.Reader` and real OS environment variables. Missing or malformed
  variables must raise (boot fails closed); a complete environment must yield
  the durable, strict, keyed configuration. `async: false`: mutates OS env.
  """

  use ExUnit.Case, async: false

  @runtime Path.expand("../../config/runtime.exs", __DIR__)
  @manifest Path.expand("../../rel/overlays/capability_release.json", __DIR__)

  @vars ~w(ASH_A2A_EKV_CLUSTER_SIZE ASH_A2A_RECEIPT_DATA_DIR ASH_A2A_BROKER_DATA_DIR
           ASH_A2A_OUTBOX_DIR ASH_A2A_CAPABILITY_RELEASE_MANIFEST ASH_A2A_CAPABILITY_RELEASE_DIGEST
           ASH_A2A_STANDING_ARTIFACTS_DIR
           ASH_A2A_RECEIPT_BINDING_KEY ASH_A2A_STANDING_LEDGER_KEY SWARM_REQUIRE_GRAPHLAW
           SWARM_K8S_SERVICE SWARM_K8S_NAMESPACE SWARM_A2A_HTTP SWARM_MIN_PEERS)

  setup do
    saved = Map.new(@vars, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)

    Enum.each(@vars, &System.delete_env/1)
    :ok
  end

  defp complete_env do
    digest =
      SwarmNode.ReleaseClosure.load!(@manifest, nil,
        standing_artifacts_dir: Path.expand("../../rel/overlays/standing", __DIR__)
      ).portable_digest

    %{
      "ASH_A2A_EKV_CLUSTER_SIZE" => "3",
      "ASH_A2A_RECEIPT_DATA_DIR" => "/var/lib/ash_a2a/receipts",
      "ASH_A2A_BROKER_DATA_DIR" => "/var/lib/ash_a2a/broker",
      "ASH_A2A_OUTBOX_DIR" => "/var/lib/ash_a2a/outbox",
      "ASH_A2A_CAPABILITY_RELEASE_MANIFEST" => @manifest,
      "ASH_A2A_CAPABILITY_RELEASE_DIGEST" => digest,
      "ASH_A2A_STANDING_ARTIFACTS_DIR" =>
        Path.expand("../../rel/overlays/standing", __DIR__),
      "ASH_A2A_RECEIPT_BINDING_KEY" => Base.encode64(:crypto.strong_rand_bytes(32)),
      "ASH_A2A_STANDING_LEDGER_KEY" => Base.encode64(:crypto.strong_rand_bytes(32))
    }
  end

  defp read_prod(env) do
    Enum.each(env, fn {k, v} -> System.put_env(k, v) end)
    Config.Reader.read!(@runtime, env: :prod, target: :host)
  end

  test "a complete prod environment yields the durable, strict, keyed config" do
    env = complete_env()
    config = read_prod(env)
    ash = config[:ash_a2a]

    assert ash[:receipt_store] == AshA2A.ReceiptStore.Ekv
    assert ash[:receipt_store_ekv_opts][:data_dir] == "/var/lib/ash_a2a/receipts"
    assert ash[:receipt_store_ekv_opts][:cluster_size] == 3

    assert {AshA2A.Authority.Broker.Ekv, broker_opts} = ash[:authority_broker]
    assert broker_opts[:data_dir] == "/var/lib/ash_a2a/broker"
    assert broker_opts[:cluster_size] == 3

    assert ash[:receipt_outbox_dir] == "/var/lib/ash_a2a/outbox"
    assert ash[:capability_release_mode] == :strict

    assert ash[:capability_release_closure].portable_digest ==
             env["ASH_A2A_CAPABILITY_RELEASE_DIGEST"]

    assert byte_size(ash[:receipt_binding_key]) == 32
    assert ash[:standing_ledger_key] == Base.decode64!(env["ASH_A2A_STANDING_LEDGER_KEY"])

    assert config[:swarm_node][:require_graphlaw] == true
    assert config[:swarm_node][:admin_http] == true
    assert config[:swarm_node][:a2a_http][:enabled] == false
    assert {SwarmNode.JsonLogFormatter, _} = config[:logger][:default_handler][:formatter]
  end

  for var <- ~w(ASH_A2A_EKV_CLUSTER_SIZE ASH_A2A_RECEIPT_DATA_DIR ASH_A2A_BROKER_DATA_DIR
                ASH_A2A_OUTBOX_DIR ASH_A2A_CAPABILITY_RELEASE_MANIFEST
                ASH_A2A_CAPABILITY_RELEASE_DIGEST ASH_A2A_RECEIPT_BINDING_KEY
                ASH_A2A_STANDING_LEDGER_KEY) do
    test "missing #{var} refuses to boot" do
      env = Map.delete(complete_env(), unquote(var))
      assert_raise ArgumentError, ~r/#{unquote(var)}/, fn -> read_prod(env) end
    end
  end

  test "a relative data dir, a short key and a wrong closure digest each refuse" do
    assert_raise ArgumentError, ~r/absolute path/, fn ->
      read_prod(%{complete_env() | "ASH_A2A_RECEIPT_DATA_DIR" => "tmp/receipts"})
    end

    assert_raise ArgumentError, ~r/STANDING_LEDGER_KEY must decode to 32..32/, fn ->
      read_prod(%{
        complete_env()
        | "ASH_A2A_STANDING_LEDGER_KEY" => Base.encode64(:crypto.strong_rand_bytes(16))
      })
    end

    assert_raise ArgumentError, ~r/digest mismatch/, fn ->
      read_prod(%{
        complete_env()
        | "ASH_A2A_CAPABILITY_RELEASE_DIGEST" => "sha256:" <> String.duplicate("1", 64)
      })
    end
  end

  test "readiness peer floor defaults to, and may not go below, the EKV quorum peers" do
    assert read_prod(complete_env())[:swarm_node][:min_peers] == 1

    assert read_prod(Map.put(complete_env(), "ASH_A2A_EKV_CLUSTER_SIZE", "5"))[:swarm_node][
             :min_peers
           ] == 2

    assert read_prod(Map.put(complete_env(), "SWARM_MIN_PEERS", "2"))[:swarm_node][:min_peers] ==
             2

    assert_raise ArgumentError, ~r/SWARM_MIN_PEERS must be an integer >= 1/, fn ->
      read_prod(Map.put(complete_env(), "SWARM_MIN_PEERS", "0"))
    end

    assert_raise ArgumentError, ~r/SWARM_MIN_PEERS/, fn ->
      read_prod(Map.put(complete_env(), "SWARM_MIN_PEERS", "x"))
    end
  end

  test "libcluster strategy follows SWARM_K8S_SERVICE / SWARM_K8S_NAMESPACE" do
    assert Config.Reader.read!(@runtime, env: :test)[:libcluster] == nil

    System.put_env("SWARM_K8S_SERVICE", "ash-a2a-swarm-headless")
    [swarm: dns] = Config.Reader.read!(@runtime, env: :test)[:libcluster][:topologies]
    assert dns[:strategy] == Cluster.Strategy.Kubernetes.DNS

    System.put_env("SWARM_K8S_NAMESPACE", "ash-a2a-swarm")
    [swarm: srv] = Config.Reader.read!(@runtime, env: :test)[:libcluster][:topologies]
    assert srv[:strategy] == Cluster.Strategy.Kubernetes.DNSSRV
    assert srv[:config][:namespace] == "ash-a2a-swarm"
    assert srv[:config][:service] == "ash-a2a-swarm-headless"
  end

  test "dev/test evaluation does not require the production environment" do
    config = Config.Reader.read!(@runtime, env: :test, target: :host)
    assert config[:ash_a2a][:agents] == [SwarmNode.EchoAgent]
    refute Keyword.has_key?(config[:ash_a2a], :receipt_store)
  end
end
