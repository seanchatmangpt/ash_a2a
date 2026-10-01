defmodule Actuator.CourtOracleTest do
  @moduledoc """
  Anti-vacuity for the actuator's own courts: the key-material scan checks VALUES (not field
  names) and the ledger oracle compares real entry CONTENT (not digest presence).
  """
  use ExUnit.Case, async: true
  alias Actuator.{Kit, Store}

  setup do
    Process.flag(:trap_exit, true)
    dir = Kit.tmp_dir("oracle")
    {:ok, store} = Store.start_link(state_dir: dir)
    {:ok, dir: dir, store: store}
  end

  test "key-material scan: a real flow leaves no private key value anywhere in the state dir",
       %{dir: dir, store: store} do
    b = Kit.build(state_dir: dir)

    assert {:ok, %{status: :performed}} =
             Actuator.execute(store, b.ctx, b.effect_bytes, b.cert_bytes)

    File.write!(Path.join(dir, "config.json"), Jason.encode!(%{"private_key" => "REDACTED"}))
    privs = for {_pub, priv, _kid} <- b.keys, do: priv
    assert Kit.key_material_hits(dir, privs) == []
  end

  test "key-material scan is value-checking: key bytes under an innocuous name are found; a scary name with a clean value is not",
       %{dir: dir} do
    {_pub, priv, _kid} = Kit.gen_key()
    assert Kit.key_material_hits(dir, [priv]) == []

    File.write!(Path.join(dir, "clean.json"), ~s({"private_key":"REDACTED","secret":"x"}))
    assert Kit.key_material_hits(dir, [priv]) == []

    for {name, body} <- [
          {"a.txt", "note=" <> Base.url_encode64(priv, padding: false)},
          {"b.txt", Base.encode16(priv, case: :lower)},
          {"c.bin", "xx" <> priv <> "yy"},
          {"d.txt", Base.encode64(priv)}
        ] do
      File.write!(Path.join(dir, name), body)
    end

    hit_files =
      Kit.key_material_hits(dir, [priv])
      |> Enum.map(&(elem(&1, 0) |> Path.basename()))
      |> Enum.uniq()
      |> Enum.sort()

    assert hit_files == ["a.txt", "b.txt", "c.bin", "d.txt"]
  end

  test "ledger oracle compares content: passes on the real ledger", %{dir: dir, store: store} do
    b = Kit.build(state_dir: dir)
    assert {:ok, _} = Actuator.execute(store, b.ctx, b.effect_bytes, b.cert_bytes)
    assert :ok = Kit.ledger_oracle(dir, [b.effect_bytes])
  end

  test "ledger oracle is not digest-presence: a validly re-chained ledger with altered entry text is rejected",
       %{dir: dir, store: store} do
    b = Kit.build(state_dir: dir)
    assert {:ok, _} = Actuator.execute(store, b.ctx, b.effect_bytes, b.cert_bytes)
    GenServer.stop(store)

    path = Path.join(dir, "effect_ledger.jsonl")
    [line] = path |> File.read!() |> String.split("\n", trim: true)
    e = Jason.decode!(line)
    forged_body = e |> Map.drop(["hash"]) |> Map.put("entry", "FORGED")
    h = Actuator.Ledger.hash(e["prev"], forged_body)
    File.write!(path, Jcs.encode(Map.put(forged_body, "hash", h)) <> "\n")

    # the chain itself is internally valid and the digest is still present ...
    assert {:ok, %{count: 1}} = Actuator.Ledger.verify(dir)
    assert File.read!(path) =~ e["effect_digest"]
    # ... but the content oracle refuses it
    assert {:mismatch, _} = Kit.ledger_oracle(dir, [b.effect_bytes])
  end
end
