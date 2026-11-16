defmodule Actuator.L10RedTeamTest do
  @moduledoc """
  L10 regressions.
  T4: the context is resolved inside the serialized store step, so a revocation that lands
  while a request is queued is honoured. Minor: UDS listener has a connection cap.
  """
  use ExUnit.Case, async: false
  alias Actuator.{Kit, Store}
  alias Actuator.Wire.UDS

  setup do
    Process.flag(:trap_exit, true)
    dir = Kit.tmp_dir("l10")
    {:ok, store} = Store.start_link(state_dir: dir)
    {:ok, dir: dir, store: store}
  end

  defp frame(b) do
    Jason.encode!(%{
      "op" => "execute",
      "effect" => Base.url_encode64(b.effect_bytes, padding: false),
      "certificate" => Base.url_encode64(b.cert_bytes, padding: false)
    })
  end

  defp uds_call(path, payload) do
    {:ok, s} = :gen_tcp.connect({:local, path}, 0, [:binary, {:packet, 4}, {:active, false}])
    :ok = :gen_tcp.send(s, payload)
    {:ok, resp} = :gen_tcp.recv(s, 0, 5_000)
    :gen_tcp.close(s)
    Jason.decode!(resp)
  end

  test "T4: a revocation landing after the request is queued still refuses over the real wire",
       %{dir: dir, store: store} do
    b = Kit.build(state_dir: dir)
    kid = hd(b.records).kid
    path = Path.join(dir, "t4.sock")
    flag = :atomics.new(1, [])
    parent = self()

    # Runs inside the store process. It announces itself, then blocks until released, so the
    # frame is provably parsed and being served before the revocation lands (no sleeps).
    ctx_fun = fn ->
      send(parent, {:ctx_reached, self()})

      receive do
        :release -> :ok
      end

      if :atomics.get(flag, 1) == 1 do
        {:ok, %{b.ctx | revocation: %{b.ctx.revocation | revoked: MapSet.new([kid])}}}
      else
        {:ok, b.ctx}
      end
    end

    {:ok, _} = UDS.start_link(path: path, store: store, ctx_fun: ctx_fun)
    client = Task.async(fn -> uds_call(path, frame(b)) end)

    assert_receive {:ctx_reached, ^store}, 5_000
    :atomics.put(flag, 1, 1)
    send(store, :release)

    assert %{"ok" => false, "refusal" => "key_revoked"} = Task.await(client, 5_000)

    ledger = Path.join(dir, "effect_ledger.jsonl")
    refute File.exists?(ledger) and File.read!(ledger) != ""
  end

  test "T4: Store resolves a context function inside the store process", %{
    dir: dir,
    store: store
  } do
    b = Kit.build(state_dir: dir)
    {:ok, req} = Actuator.Fence.parse(b.effect_bytes, b.cert_bytes)
    parent = self()

    f = fn ->
      send(parent, {:resolved_in, self()})
      {:ok, b.ctx}
    end

    assert {:ok, %{status: :performed}} = Store.execute(store, f, req)
    assert_receive {:resolved_in, pid}
    assert pid == store

    assert {:error, "config", :config_unavailable} =
             Store.execute(store, fn -> {:error, :config_unavailable} end, req)
  end

  test "minor: UDS connections beyond the cap are closed, the listener survives", %{
    dir: dir,
    store: store
  } do
    b = Kit.build(state_dir: dir)
    path = Path.join(dir, "cap.sock")
    {:ok, _} = UDS.start_link(path: path, store: store, ctx_fun: fn -> {:ok, b.ctx} end)
    opts = [:binary, {:packet, 4}, {:active, false}]

    # Each held connection completes a round trip, so it is known to be accepted and counted:
    # a bare connect() can sit in (or be dropped from) the listen backlog without ever reaching
    # the acceptor, which would leave the listener below its cap.
    held =
      for _ <- 1..UDS.max_conns() do
        {:ok, s} = :gen_tcp.connect({:local, path}, 0, opts)
        :ok = :gen_tcp.send(s, ~s({"op":"health"}))
        assert {:ok, _} = :gen_tcp.recv(s, 0, 2_000)
        s
      end

    {:ok, extra} = :gen_tcp.connect({:local, path}, 0, opts)
    _ = :gen_tcp.send(extra, ~s({"op":"health"}))
    assert {:error, _} = :gen_tcp.recv(extra, 0, 2_000)

    Enum.each(held, &:gen_tcp.close/1)
    Process.sleep(300)
    assert %{"ok" => true} = uds_call(path, ~s({"op":"health"}))
  end
end
