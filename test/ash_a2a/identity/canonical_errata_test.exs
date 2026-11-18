# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Identity.CanonicalErrataTest do
  use ExUnit.Case, async: true
  alias AshA2A.Identity.Canonical

  @max 9_007_199_254_740_991

  test "ERR7-F-1 vectors are byte-equal to an independent python3 recompute" do
    case System.find_executable("python3") do
      nil ->
        IO.puts("[SKIP] python3 not on PATH; ERR7-F-1 independent recompute not run")

      py ->
        vectors = [
          %{"b" => 1, "a" => [1, 2, %{"z" => nil, "y" => true}], "é" => "x"},
          %{"" => "", "10" => 1, "9" => 2, "a" => "€\"\\\n"},
          [@max, -@max, 0]
        ]

        for v <- vectors do
          {:ok, ours} = Canonical.encode(v)
          path = Path.join(System.tmp_dir!(), "lane19_#{System.unique_integer([:positive])}.json")
          File.write!(path, Jason.encode!(v))
          {out, 0} = run_py(py, path)
          File.rm(path)
          assert out == ours
        end
    end
  end

  defp run_py(py, path) do
    code =
      "import sys,json;sys.stdout.write(json.dumps(json.load(open(sys.argv[1],encoding='utf-8'))," <>
        "sort_keys=True,separators=(',',':'),ensure_ascii=False))"

    System.cmd(py, ["-c", code, path])
  end

  test "ERR7-F-2 floats are rejected with a typed error" do
    assert {:error, :canonical_float_forbidden} = Canonical.encode(%{"a" => 1.5})
    assert {:error, :canonical_float_forbidden} = Canonical.digest([1.0])
  end

  test "ERR7-F-3 2^53 integer as number refused, as string accepted" do
    assert {:error, :canonical_integer_out_of_range} = Canonical.encode(%{"n" => @max + 1})
    assert {:error, :canonical_integer_out_of_range} = Canonical.encode(%{"n" => -@max - 1})
    assert {:ok, _} = Canonical.encode(%{"n" => @max})
    assert {:ok, ~s({"n":"9007199254740992"})} = Canonical.encode(%{"n" => "9007199254740992"})
  end

  test "ERR7-F-2 atom/string key collision rejected" do
    assert {:error, :canonical_key_collision} = Canonical.encode(%{:a => 1, "a" => 2})
  end

  test "ERR7-F-2 non-JSON terms rejected" do
    assert {:error, :canonical_type_forbidden} = Canonical.encode(%{"a" => {1, 2}})
    assert {:error, :canonical_type_forbidden} = Canonical.encode(%{"a" => self()})
  end

  test "ERR7-F-4 over-deep input refused" do
    deep = Enum.reduce(1..40, 1, fn _, acc -> [acc] end)
    assert {:error, :canonical_depth_exceeded} = Canonical.encode(deep)
    ok = Enum.reduce(1..20, 1, fn _, acc -> [acc] end)
    assert {:ok, _} = Canonical.encode(ok)
  end

  test "ERR7-F-4 oversize input refused before hashing" do
    big = %{"p" => String.duplicate("a", 1_048_577)}
    assert {:error, :canonical_size_exceeded} = Canonical.encode(big)
    assert {:error, :canonical_size_exceeded} = Canonical.digest(big)
  end
end
