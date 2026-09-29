Code.require_file("helper.exs", __DIR__)

defmodule Sa2aCrypto.NonceStoreTest do
  use ExUnit.Case, async: true
  alias Sa2aCrypto.{NonceStore, RegistryHelper}

  defp log(name), do: Path.join(RegistryHelper.tmp_dir(name), "nonces.log")

  test "first use is accepted, second is a replay; scoping is (kid, nonce)" do
    {:ok, s} = NonceStore.start_link(log("basic"))
    assert :ok = NonceStore.check_and_set(s, "kid-1", "n1", 1000)
    assert {:error, :replayed} = NonceStore.check_and_set(s, "kid-1", "n1", 1000)
    assert :ok = NonceStore.check_and_set(s, "kid-1", "n2", 1000)
    assert :ok = NonceStore.check_and_set(s, "kid-2", "n1", 1000)
    assert {:error, :bad_nonce} = NonceStore.check_and_set(s, :kid, "n", 1)
  end

  test "a replay is refused across a process restart" do
    path = log("restart")
    {:ok, s} = NonceStore.start_link(path)
    :ok = NonceStore.check_and_set(s, "kid-1", "n1", 1000)
    :ok = GenServer.stop(s)
    {:ok, s2} = NonceStore.start_link(path)
    assert NonceStore.seen?(s2, "kid-1", "n1")
    assert {:error, :replayed} = NonceStore.check_and_set(s2, "kid-1", "n1", 1000)
  end

  test "a killed (not gracefully stopped) store still refuses the acknowledged nonce" do
    path = log("kill")
    {:ok, s} = NonceStore.start_link(path)
    Process.unlink(s)
    :ok = NonceStore.check_and_set(s, "kid-1", "n1", 1000)
    ref = Process.monitor(s)
    Process.exit(s, :kill)
    assert_receive {:DOWN, ^ref, _, _, _}
    {:ok, s2} = NonceStore.start_link(path)
    assert {:error, :replayed} = NonceStore.check_and_set(s2, "kid-1", "n1", 1000)
  end

  test "prune keeps an entry until now > expires + skew, then it may be reused" do
    {:ok, s} = NonceStore.start_link(log("prune"), skew: 30)
    :ok = NonceStore.check_and_set(s, "k", "n", 1000)
    assert {:ok, 0} = NonceStore.prune(s, 1000)
    assert {:ok, 0} = NonceStore.prune(s, 1030)
    assert {:error, :replayed} = NonceStore.check_and_set(s, "k", "n", 1000)
    assert {:ok, 1} = NonceStore.prune(s, 1031)
    assert NonceStore.size(s) == 0
    assert :ok = NonceStore.check_and_set(s, "k", "n", 2000)
  end

  test "pruning compacts the durable log; kept entries still refuse after restart" do
    path = log("compact")
    {:ok, s} = NonceStore.start_link(path, skew: 0)
    :ok = NonceStore.check_and_set(s, "k", "old", 10)
    :ok = NonceStore.check_and_set(s, "k", "live", 5000)
    assert {:ok, 1} = NonceStore.prune(s, 100)
    :ok = NonceStore.check_and_set(s, "k", "after", 5000)
    :ok = GenServer.stop(s)
    {:ok, s2} = NonceStore.start_link(path, skew: 0)
    assert NonceStore.size(s2) == 2
    assert {:error, :replayed} = NonceStore.check_and_set(s2, "k", "live", 5000)
    assert {:error, :replayed} = NonceStore.check_and_set(s2, "k", "after", 5000)
    assert :ok = NonceStore.check_and_set(s2, "k", "old", 5000)
  end

  test "concurrent check-and-set on one (kid, nonce): exactly one winner" do
    {:ok, s} = NonceStore.start_link(log("race"))

    results =
      1..60
      |> Task.async_stream(fn _ -> NonceStore.check_and_set(s, "k", "same", 1000) end,
        max_concurrency: 60
      )
      |> Enum.map(fn {:ok, r} -> r end)

    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &(&1 == {:error, :replayed})) == 59
  end

  test "a torn final line is ignored; corruption elsewhere refuses to start" do
    path = log("torn")
    {:ok, s} = NonceStore.start_link(path)
    :ok = NonceStore.check_and_set(s, "k", "n1", 1000)
    :ok = GenServer.stop(s)

    File.write!(path, ["[\"k\",\"torn"], [:append])
    {:ok, s2} = NonceStore.start_link(path)
    assert {:error, :replayed} = NonceStore.check_and_set(s2, "k", "n1", 1000)
    :ok = GenServer.stop(s2)

    File.write!(path, "garbage\n[\"k\",\"n9\",5]\n")
    Process.flag(:trap_exit, true)
    assert {:error, :nonce_log_corrupt} = NonceStore.start_link(path)
  end
end
