# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.DurableClaimStore.DurableFileTest do
  @moduledoc """
  Court for the durable `AshA2A.C2.ClaimStore` (`EffectClaimStore.DurableFile`).

  Chicago style: real filesystem under the build path (never tmp, so the
  durable-path guard is exercised for real), real concurrent processes and a
  real second BEAM (`elixir` subprocess) standing in for a restart. The
  verifier check `c1.durable_claim_store` is run against the real module.
  """
  use ExUnit.Case, async: false

  alias AshA2A.ConsequenceKernel.EffectClaimStore.DurableFile, as: Store
  alias AshA2A.SA2A.Conformance.Checks.C1

  @key :binary.copy(<<7>>, 32)

  setup do
    prev = Application.get_env(:ash_a2a, :claim_store_key)
    Application.put_env(:ash_a2a, :claim_store_key, @key)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:ash_a2a, :claim_store_key, prev),
        else: Application.delete_env(:ash_a2a, :claim_store_key)
    end)
  end

  defp dir do
    d =
      Path.join([
        Mix.Project.build_path(),
        "durable_courts",
        "claims_#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(d)
    on_exit(fn -> File.rm_rf!(d) end)
    d
  end

  defp other_beam(code) do
    paths = :code.get_path() |> Enum.flat_map(&["-pa", to_string(&1)])
    System.cmd("elixir", paths ++ ["-e", code], stderr_to_stdout: true)
  end

  test "is durable and passes the verifier check" do
    assert Store.durable?()
    assert {:pass, _} = C1.durable_claim_store(%{claim_store: Store})
  end

  test "claim is compare-and-set: second claim of the same digest is refused" do
    d = dir()
    assert :ok = Store.claim("digest-a", 1, d)
    assert {:error, :already_claimed} = Store.claim("digest-a", 1, d)
    assert {:error, :already_claimed} = Store.claim("digest-a", 7, d)
    assert :ok = Store.claim("digest-b", 1, d)
  end

  test "complete records the result once; a completed claim stays claimed" do
    d = dir()
    assert {:error, :not_claimed} = Store.complete("nope", :r, d)
    :ok = Store.claim("c1", 1, d)
    assert :ok = Store.complete("c1", {:done, 1}, d)
    assert {:error, {:already_complete, {:done, 1}}} = Store.complete("c1", {:done, 2}, d)
    assert {:error, :already_claimed} = Store.claim("c1", 1, d)
    assert {:ok, %{state: :complete, result: {:done, 1}, generation: 1}} = Store.fetch("c1", d)
  end

  test "fence: a generation below the highest ever claimed is refused, atomically with the write" do
    d = dir()
    :ok = Store.claim("g5", 5, d)
    assert {:error, :stale_generation} = Store.claim("g3", 3, d)
    assert :not_found = Store.fetch("g3", d)
    assert :ok = Store.claim("g5b", 5, d)
    assert :ok = Store.claim("g9", 9, d)
    assert {:error, :stale_generation} = Store.claim("g5c", 5, d)
  end

  test "exactly one of many concurrent claimers wins" do
    d = dir()

    results =
      1..40
      |> Task.async_stream(fn _ -> Store.claim("race", 1, d) end,
        max_concurrency: 40,
        timeout: 120_000
      )
      |> Enum.map(fn {:ok, r} -> r end)

    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &(&1 == {:error, :already_claimed})) == 39
  end

  test "survives a real BEAM restart in both directions" do
    d = dir()
    :ok = Store.claim("parent-claim", 2, d)

    {out, 0} =
      other_beam("""
      alias AshA2A.ConsequenceKernel.EffectClaimStore.DurableFile, as: S
      Application.put_env(:ash_a2a, :claim_store_key, #{inspect(@key)})
      dir = #{inspect(d)}
      IO.puts("parent:" <> inspect(S.claim("parent-claim", 2, dir)))
      IO.puts("child:" <> inspect(S.claim("child-claim", 2, dir)))
      IO.puts("stale:" <> inspect(S.claim("late", 1, dir)))
      """)

    assert out =~ "parent:{:error, :already_claimed}"
    assert out =~ "child::ok"
    assert out =~ "stale:{:error, :stale_generation}"
    assert {:error, :already_claimed} = Store.claim("child-claim", 2, d)
    assert {:ok, %{state: :claimed}} = Store.fetch("child-claim", d)
  end

  test "a tampered claim record is refused, never trusted" do
    d = dir()
    :ok = Store.claim("t", 1, d)
    [file] = Path.wildcard(Path.join([d, "claims", "*"]))
    bin = File.read!(file)
    File.write!(file, binary_part(bin, 0, byte_size(bin) - 1) <> <<0>>)
    assert {:error, :claim_record_corrupt} = Store.fetch("t", d)
    assert {:error, :claim_record_corrupt} = Store.claim("t", 1, d)
    assert {:error, :claim_record_corrupt} = Store.complete("t", :x, d)
  end

  test "a directory under tmp is refused (guard; anti-vacuity for the durable-path rule)" do
    tmp = Path.join(System.tmp_dir!(), "claims_tmp_#{System.unique_integer([:positive])}")
    assert {:error, :claim_store_dir_not_durable} = Store.claim("x", 1, tmp)
    refute File.exists?(tmp)
    assert {:error, :claim_store_dir_not_durable} = Store.claim("x", 1, nil)
  end

  test "the arity-2 ClaimStore callbacks read :claim_store_dir from app env" do
    d = dir()
    prev = Application.get_env(:ash_a2a, :claim_store_dir)
    Application.put_env(:ash_a2a, :claim_store_dir, d)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:ash_a2a, :claim_store_dir, prev),
        else: Application.delete_env(:ash_a2a, :claim_store_dir)
    end)

    assert :ok = Store.claim("env-digest", 1)
    assert {:error, :already_claimed} = Store.claim("env-digest", 1)
    assert :ok = Store.complete("env-digest", :ok)
  end

  defp claim_file(d, digest),
    do: Path.join([d, "claims", Base.encode16(:crypto.hash(:sha256, digest), case: :lower)])

  test "D1: a record forged with a recomputed unkeyed SHA-256 is refused" do
    d = dir()
    :ok = Store.claim("f1", 1, d)
    path = claim_file(d, "f1")

    body =
      :erlang.term_to_binary(%{state: :complete, generation: 1, result: :forged}, [:deterministic])

    File.write!(path, [:crypto.hash(:sha256, body), body])
    assert {:error, :claim_record_corrupt} = Store.fetch("f1", d)
    assert {:error, :claim_record_corrupt} = Store.complete("f1", :x, d)
  end

  test "D1: a record forged under a different key is refused" do
    d = dir()
    :ok = Store.claim("f2", 1, d)
    path = claim_file(d, "f2")
    good = File.read!(path)
    Application.put_env(:ash_a2a, :claim_store_key, :binary.copy(<<9>>, 32))
    assert {:error, :claim_record_corrupt} = Store.fetch("f2", d)
    Application.put_env(:ash_a2a, :claim_store_key, @key)
    assert {:ok, %{state: :claimed}} = Store.fetch("f2", d)
    assert File.read!(path) == good
  end

  test "D1: a record copied onto another digest's path is refused" do
    d = dir()
    :ok = Store.claim("src", 1, d)
    :ok = Store.claim("dst", 1, d)
    :ok = Store.complete("src", :real, d)
    File.cp!(claim_file(d, "src"), claim_file(d, "dst"))
    assert {:error, :claim_record_corrupt} = Store.fetch("dst", d)
  end

  test "D1: no key configured refuses with claim_key_missing / claim_key_unavailable" do
    d = dir()
    Application.delete_env(:ash_a2a, :claim_store_key)
    Application.delete_env(:ash_a2a, :receipt_outbox_key)
    Application.delete_env(:ash_a2a, :receipt_binding_key)
    assert {:error, :claim_key_missing} = Store.claim("k", 1, d)
    Application.put_env(:ash_a2a, :claim_store_key, "short")
    assert {:error, :claim_key_unavailable} = Store.claim("k", 1, d)
  end

  test "D2: deleting a claim record does not re-open the claim" do
    d = dir()
    :ok = Store.claim("gone", 1, d)
    File.rm!(claim_file(d, "gone"))
    assert {:error, :claim_log_corrupt} = Store.claim("gone", 1, d)
    assert {:error, :claim_log_corrupt} = Store.fetch("gone", d)
  end

  test "D2: deleting the head/fence while claims exist is refused" do
    d = dir()
    :ok = Store.claim("h", 1, d)
    File.rm!(Path.join(d, "fence"))
    assert {:error, :claim_log_corrupt} = Store.claim("h2", 1, d)
  end

  test "D2: deleting a completed record is refused too" do
    d = dir()
    :ok = Store.claim("c", 1, d)
    :ok = Store.complete("c", :r, d)
    File.rm!(claim_file(d, "c"))
    assert {:error, :claim_log_corrupt} = Store.claim("c", 1, d)
  end

  test "D2: rolling a completed record back to its claimed state is refused" do
    d = dir()
    :ok = Store.claim("rb", 1, d)
    old = File.read!(claim_file(d, "rb"))
    :ok = Store.complete("rb", :r, d)
    File.write!(claim_file(d, "rb"), old)
    assert {:error, :claim_log_corrupt} = Store.complete("rb", :other, d)
  end
end
