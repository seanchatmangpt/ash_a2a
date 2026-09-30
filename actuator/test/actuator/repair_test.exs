defmodule Actuator.RepairTest do
  @moduledoc "UDS path-length regression, single-writer state-dir lock, truthful anchor failure."
  use ExUnit.Case, async: false
  import Bitwise
  alias Actuator.{Kit, Store}
  alias Actuator.Wire.UDS

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  # Long PARENT directory, one-byte socket name: the staging path is the binding constraint.
  defp sock_path(len) do
    root = "/tmp/a2a-uds-" <> Base.url_encode64(:crypto.strong_rand_bytes(3), padding: false)
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    pad = len - 2 - byte_size(root) - 1
    base = Path.join(root, String.duplicate("d", pad))
    File.mkdir_p!(base)
    File.chmod!(base, 0o700)
    Path.join(base, "s")
  end

  for len <- [90, 96, 97, 100, 103] do
    test "UDS binds at a #{len}-byte public path, mode 0600, connectable" do
      path = sock_path(unquote(len))
      assert byte_size(path) == unquote(len)
      dir = Kit.tmp_dir("udslen")
      {:ok, store} = Store.start_link(state_dir: dir)
      {:ok, u} = UDS.start_link(path: path, store: store, ctx_fun: fn -> {:error, :x} end)
      {:ok, st} = File.stat(path)
      assert st.type == :other
      assert (st.mode &&& 0o777) == 0o600
      assert {:ok, s} = :gen_tcp.connect({:local, path}, 0, [:binary, {:packet, 4}], 2_000)
      :gen_tcp.close(s)
      GenServer.stop(u)
    end
  end

  test "UDS path beyond the OS limit is a typed refusal, not a match crash" do
    path = sock_path(120)
    dir = Kit.tmp_dir("udslong")
    {:ok, store} = Store.start_link(state_dir: dir)

    assert {:error, {:uds_listen_failed, _}} =
             UDS.start_link(path: path, store: store, ctx_fun: fn -> {:error, :x} end)
  end

  test "a second Store on a live state_dir is refused; a stale lock is taken over" do
    dir = Kit.tmp_dir("dual")
    {:ok, a} = Store.start_link(state_dir: dir)

    assert {:error, {:store_boot_refused, {:state_dir_locked, _}}} =
             Store.start_link(state_dir: dir)

    assert Process.alive?(a)
    GenServer.stop(a)
    # released on clean stop
    {:ok, b} = Store.start_link(state_dir: dir)
    Process.unlink(b)
    Process.exit(b, :kill)
    Process.sleep(50)
    # killed holder leaves a stale lock; next boot takes it over
    assert {:ok, c} = Store.start_link(state_dir: dir)
    GenServer.stop(c)
  end

  test "an unwritable anchor refuses BEFORE any claim: caller told, nothing durable" do
    dir = Kit.tmp_dir("anch")
    one = Kit.child_fixture(dir, 1)
    {:ok, s} = Store.start_link(state_dir: dir)
    File.chmod!(dir, 0o500)
    on_exit(fn -> File.chmod(dir, 0o700) end)
    req = Kit.request(one.built)
    assert {:error, 14, :journal_unavailable} = Store.execute(s, one.built.ctx, req)
    assert :not_found = Store.status(s, req.effect.effect_instance_id)
    assert File.read!(Path.join(dir, "journal.jsonl")) == ""
    File.chmod!(dir, 0o700)
    assert {:ok, %{status: :performed}} = Store.execute(s, one.built.ctx, req)
  end
end
