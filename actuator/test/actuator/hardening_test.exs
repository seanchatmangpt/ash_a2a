defmodule Actuator.HardeningTest do
  @moduledoc "Fail-open quorum default, socket permission window, duplicate JSON keys."
  use ExUnit.Case, async: false
  import Bitwise
  alias Actuator.{Certificate, Config, Context, Kit, Store}
  alias Actuator.Wire.UDS

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  # -- quorum ------------------------------------------------------------------

  defp config_file(over) do
    dir = Kit.tmp_dir("hcfg")
    b = Kit.build(state_dir: dir)

    registry =
      for r <- b.records do
        %{
          "kid" => r.kid,
          "alg" => r.alg,
          "public_key" => Base.url_encode64(r.public_key, padding: false),
          "custodian_id" => r.custodian_id,
          "state" => "active"
        }
      end

    base = %{"state_dir" => dir, "audience" => "a", "policy_epoch" => 1, "registry" => registry}
    path = Path.join(dir, "a.json")
    File.write!(path, Jason.encode!(Map.merge(base, over)))
    path
  end

  test "config without an explicit quorum_default refuses to load (no fail-open default of 1)" do
    assert {:error, :config_unavailable} = Config.load(config_file(%{}))
  end

  test "config refuses non-positive or non-integer quorum values" do
    for bad <- [0, -1, "1", 1.5, nil] do
      assert {:error, :config_unavailable} = Config.load(config_file(%{"quorum_default" => bad}))
    end

    assert {:error, :config_unavailable} =
             Config.load(config_file(%{"quorum_default" => 2, "quorum" => %{"x" => 0}}))
  end

  test "explicit quorum_default loads and is honoured" do
    assert {:ok, %Context{quorum_default: 2}} = Config.load(config_file(%{"quorum_default" => 2}))
  end

  test "a Context cannot be built without an explicit quorum_default" do
    assert_raise ArgumentError, fn ->
      struct!(Context, state_dir: "d", registry: nil, audience: "a", policy_epoch: 1)
    end
  end

  test "quorum_for never returns a value below 1 (a 0 in a class map cannot open the gate)" do
    ctx = Kit.build().ctx
    assert Context.quorum_for(%{ctx | quorum: %{"c" => 0}, quorum_default: 2}, "c") >= 1
    assert Context.quorum_for(%{ctx | quorum: %{}, quorum_default: 0}, "c") >= 1
  end

  # -- socket window -----------------------------------------------------------

  test "UDS: the socket path is never observable with a mode other than 0600" do
    dir = Kit.tmp_dir("win")
    {:ok, store} = Store.start_link(state_dir: dir)
    b = Kit.build(state_dir: dir)
    path = Path.join(dir, "w.sock")
    me = self()

    poller =
      spawn_link(fn ->
        poll = fn poll, bad ->
          receive do
            :stop -> send(me, {:bad_modes, bad})
          after
            0 ->
              case File.stat(path) do
                {:ok, %{mode: m}} when (m &&& 0o777) != 0o600 -> poll.(poll, [m &&& 0o777 | bad])
                _ -> poll.(poll, bad)
              end
          end
        end

        poll.(poll, [])
      end)

    for _ <- 1..300 do
      {:ok, u} = UDS.start_link(path: path, store: store, ctx_fun: fn -> {:ok, b.ctx} end)
      GenServer.stop(u)
    end

    send(poller, :stop)
    assert_receive {:bad_modes, bad}, 5_000
    assert bad == []
  end

  test "UDS: no stray staging directory is left next to the socket" do
    dir = Kit.tmp_dir("stage")
    {:ok, store} = Store.start_link(state_dir: dir)
    b = Kit.build(state_dir: dir)
    path = Path.join(dir, "s.sock")
    {:ok, u} = UDS.start_link(path: path, store: store, ctx_fun: fn -> {:ok, b.ctx} end)
    assert (File.stat!(path).mode &&& 0o777) == 0o600
    assert File.ls!(dir) |> Enum.filter(&String.starts_with?(&1, ".u")) == []
    GenServer.stop(u)
  end

  # -- duplicate keys ----------------------------------------------------------

  test "Certificate.decode rejects duplicate JSON keys (top level and inside a signature)" do
    b = Kit.build()
    assert {:ok, _} = Certificate.decode(b.cert_bytes)

    top = String.replace(b.cert_bytes, ~s("v":1), ~s("v":1,"v":1), global: false)
    assert top != b.cert_bytes
    assert {:error, :malformed_certificate} = Certificate.decode(top)

    sig =
      String.replace(b.cert_bytes, ~s("alg":"ES256"), ~s("alg":"ES256","alg":"ES256"),
        global: false
      )

    assert sig != b.cert_bytes
    assert {:error, :malformed_certificate} = Certificate.decode(sig)

    # a key spelled with an escape is the same key
    esc = String.replace(b.cert_bytes, ~s("v":1), ~s("v":1,"\\u0076":1), global: false)
    assert {:error, :malformed_certificate} = Certificate.decode(esc)
  end

  test "wire frames with duplicate keys are malformed_request" do
    dir = Kit.tmp_dir("dup")
    {:ok, store} = Store.start_link(state_dir: dir)
    b = Kit.build(state_dir: dir)
    fun = fn -> {:ok, b.ctx} end

    assert Jason.decode!(Actuator.Wire.handle(store, fun, ~s({"op":"health","op":"health"}))) ==
             %{"ok" => false, "stage" => "parse", "refusal" => "malformed_request"}

    assert %{"ok" => true} = Jason.decode!(Actuator.Wire.handle(store, fun, ~s({"op":"health"})))
  end

  test "config files with duplicate keys refuse to load" do
    path = config_file(%{"quorum_default" => 2})
    raw = File.read!(path)
    dup = String.replace(raw, ~s("quorum_default":2), ~s("quorum_default":2,"quorum_default":1))
    assert dup != raw
    File.write!(path, dup)
    assert {:error, :config_unavailable} = Config.load(path)
  end
end
