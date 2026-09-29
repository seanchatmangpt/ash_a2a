defmodule AshA2A.C2Compromise.CatalogIntegrityTest do
  @moduledoc """
  Structural court over the harness itself, no processes started: the attack catalog covers
  every RFC-SA2A-006 s26 item that is meaningful against the real actuator/authority, every
  fence check is reached and (except the declared-redundant check 10) has an attack that
  must fail when the check is removed, and the mutation hooks of the actuator host script
  still match the actuator's sources exactly once (a refactor of fence.ex/store.ex must not
  silently turn mutants or fault points into no-ops).
  """
  use ExUnit.Case, async: true
  alias C2Harness.{Attack, Court}

  @root Path.expand("../../..", __DIR__)
  defp catalog, do: Court.catalog()
  defp everything, do: Court.catalog() ++ C2Harness.Entrypoint.attacks()

  test "attack ids are unique and every attack carries an RFC s26 mapping and a CAPEC/ATT&CK id" do
    ids = Enum.map(everything(), & &1.id)
    assert ids == Enum.uniq(ids)
    assert length(catalog()) >= 30

    for %Attack{} = a <- everything() do
      assert a.s26 != [], "#{a.id} names no s26 item"
      assert a.mapping.attck != [], "#{a.id} has no ATT&CK id"
      assert a.mapping.capec != [], "#{a.id} has no CAPEC id"
      assert a.mapping.atlas != [], "#{a.id} has no ATLAS id"
      assert Enum.all?(a.mapping.attck, &String.starts_with?(&1, "T")), "#{a.id} bad ATT&CK id"

      assert Enum.all?(a.mapping.capec, &String.starts_with?(&1, "CAPEC-")),
             "#{a.id} bad CAPEC id"

      assert Enum.all?(a.mapping.atlas, &String.starts_with?(&1, "AML.T")), "#{a.id} bad ATLAS id"
    end
  end

  test "every attack that can observe a refusal declares what it must observe (anti-vacuity)" do
    for %Attack{} = a <- catalog(), a.id not in ["C2C-F04"] do
      assert a.expect != [] or a.expect_any != [], "#{a.id} declares no expected observation"
    end
  end

  test "every fence check 1..16 is reached by at least one attack" do
    reached = catalog() |> Enum.flat_map(& &1.checks) |> MapSet.new()
    assert MapSet.subset?(MapSet.new(1..16), reached)
  end

  test "every fence check except the declared-redundant check 10 has a killer attack" do
    killers = catalog() |> Enum.flat_map(& &1.killers_for) |> MapSet.new()
    assert MapSet.difference(MapSet.new(1..16), killers) == MapSet.new([10])
  end

  test "the s26 list is covered: each required item is named by at least one attack" do
    named = catalog() |> Enum.flat_map(& &1.s26) |> MapSet.new()

    required = [
      "forged capability",
      "forged PreparedEffect",
      "forged internal receipt",
      "fake standing",
      "mutated exact subject",
      "mutated canonical input",
      "fresh request id for an existing effect instance",
      "replay of a valid certificate",
      "expired certificate",
      "stale policy epoch",
      "revoked authority",
      "insufficient quorum",
      "single compromised signer below quorum",
      "duplicated DO",
      "worker crash before DO",
      "crash during uncertain DO",
      "restart after unknown outcome",
      "resource-budget amplification",
      "policy-option removal",
      "alternate adapter path",
      "path substitution",
      "arbitrary URL substitution",
      "command injection",
      "arbitrary deserialization payload"
    ]

    assert required -- MapSet.to_list(named) == []
  end

  test "the actuator host script's patch needles occur exactly once in the actuator sources" do
    fence = File.read!(Path.join(@root, "actuator/lib/actuator/fence.ex"))
    store = File.read!(Path.join(@root, "actuator/lib/actuator/store.ex"))

    for {src, needle} <- [
          {fence, "skip = Keyword.get(opts, :skip, [])"},
          {store, ":erlang.halt(137, flush: false)"},
          {store, "@fault Application.compile_env(:actuator, :fault_hook, false)"}
        ] do
      assert length(String.split(src, needle)) == 2, "needle #{inspect(needle)} is not unique"
    end
  end

  test "the fence still has exactly the 16 numbered checks the mutation court knows" do
    fence = File.read!(Path.join(@root, "actuator/lib/actuator/fence.ex"))

    nums =
      Regex.scan(~r/def check_(\d\d)_/, fence)
      |> Enum.map(fn [_, n] -> String.to_integer(n) end)
      |> Enum.uniq()
      |> Enum.sort()

    assert nums == Enum.to_list(1..16)
  end
end
