# SPDX-FileCopyrightText: 2026 ash_a2a contributors
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.TckAssertScriptTest do
  @moduledoc """
  Court for `scripts/tck_assert.py` (real python3 subprocess, real fixture),
  plus doc/CI/version coherence checks owned by lane W13.
  """
  use ExUnit.Case, async: true

  @script Path.expand("../scripts/tck_assert.py", __DIR__)
  @fixture Path.expand("fixtures/tck/compatibility_sample.json", __DIR__)
  @root Path.expand("..", __DIR__)

  defp python, do: System.find_executable("python3")

  defp run_script(path) do
    case python() do
      nil -> {:skip, "python3 not on PATH"}
      py -> System.cmd(py, [@script, path], stderr_to_stdout: true)
    end
  end

  defp tmp_json(map) do
    path = Path.join(System.tmp_dir!(), "w13_tck_#{System.unique_integer([:positive])}.json")
    File.write!(path, Jason.encode!(map))
    on_exit(fn -> File.rm(path) end)
    path
  end

  test "fixture: SHOULD failure and not_tested do not fail; counts printed" do
    case run_script(@fixture) do
      {:skip, why} ->
        IO.puts("[SKIP] #{why}")

      {out, status} ->
        assert status == 0, out
        assert out =~ "pass=2 fail=1 not_tested=1 skipped=1 manual=1 must_fail=0"
    end
  end

  test "a failed MUST requirement exits 1" do
    path =
      tmp_json(%{"requirements" => [%{"id" => "X", "level" => "MUST", "status" => "FAILED"}]})

    case run_script(path) do
      {:skip, why} -> IO.puts("[SKIP] #{why}")
      {out, status} -> assert {status, out =~ "must_fail=1"} == {1, true}
    end
  end

  test "aggregate count schema with MUST failures exits 1, clean exits 0" do
    bad = tmp_json(%{"MUST" => %{"PASS" => 3, "FAILED" => 1}})
    ok = tmp_json(%{"MUST" => %{"PASS" => 3, "FAILED" => 0}, "SHOULD" => %{"FAILED" => 2}})

    case {run_script(bad), run_script(ok)} do
      {{:skip, why}, _} ->
        IO.puts("[SKIP] #{why}")

      {{_, bad_status}, {_, ok_status}} ->
        assert bad_status == 1
        assert ok_status == 0
    end
  end

  test "unrecognized schema and missing file fail closed (exit 2)" do
    junk = tmp_json(%{"hello" => "world"})

    case {run_script(junk), run_script("/nonexistent/compat.json")} do
      {{:skip, why}, _} ->
        IO.puts("[SKIP] #{why}")

      {{_, s1}, {_, s2}} ->
        assert s1 == 2
        assert s2 == 2
    end
  end

  test "TCK pin: ci.yml single variable is the one tck-suite.md cites" do
    ci = File.read!(Path.join(@root, ".github/workflows/ci.yml"))
    [_, sha] = Regex.run(~r/^\s+TCK_PIN_SHA:\s*"?([0-9a-f]{40})"?/m, ci)
    assert length(Regex.scan(~r/#{sha}/, ci)) == 1, "pin SHA must appear once in ci.yml"
    docs = File.read!(Path.join(@root, "docs/reference/tck-suite.md"))
    assert docs =~ "TCK_PIN_SHA"
    assert docs =~ binary_part(sha, 0, 8)
    refute ci =~ "requirements.txt"
    assert ci =~ "reports/compatibility.json"
    assert ci =~ "jsonrpc,http_json,grpc"
  end

  test "upstream spec release 1.0.1 is stated in conformance docs" do
    conf = File.read!(Path.join(@root, "docs/reference/a2a-v1-conformance.md"))
    claim = File.read!(Path.join(@root, "docs/reference/conformance-claim.md"))
    ready = File.read!(Path.join(@root, "docs/reference/a2a-v1_1-readiness.md"))
    for doc <- [conf, claim, ready], do: assert(doc =~ "v1.0.1")
    refute conf =~ "A2A v1.0.0**"
  end

  test "release version: mix.exs, README, tutorials, spec mapping, CITATION, CHANGELOG agree" do
    mix = File.read!(Path.join(@root, "mix.exs"))
    [_, version] = Regex.run(~r/@version "(\d+\.\d+\.\d+)"/, mix)

    assert File.read!(Path.join(@root, "README.md")) =~ ~s({:ash_a2a, "~> #{version}"})

    assert File.read!(Path.join(@root, "docs/tutorials/getting-started.md")) =~
             ~s("~> #{version}")

    for livemd <- Path.wildcard(Path.join(@root, "documentation/tutorials/*.livemd")) do
      assert File.read!(livemd) =~ ~s({:ash_a2a, "~> #{version}"}), livemd
    end

    assert File.read!(Path.join(@root, "CITATION.cff")) =~ ~s(version: "#{version}")

    assert File.read!(Path.join(@root, "docs/reference/a2a-spec-version-mapping.md")) =~
             "Version: v#{version}"

    changelog = File.read!(Path.join(@root, "CHANGELOG.md"))
    assert changelog =~ "## [#{version}] - "
    assert changelog =~ "## [Unreleased]"
  end

  test "court count claims match the census (files on disk minus exclusions)" do
    Code.ensure_loaded!(Mix.Tasks.AshA2a.V1ConformanceReport)
    listed = Mix.Tasks.AshA2a.V1ConformanceReport.v1_courts()
    excluded = Mix.Tasks.AshA2a.V1ConformanceReport.excluded_v1_files()

    on_disk =
      @root
      |> Path.join("test/ash_a2a_v1_*_test.exs")
      |> Path.wildcard()
      |> Enum.map(&Path.relative_to(&1, @root))

    assert Enum.sort(listed) == Enum.sort(on_disk -- excluded)

    n = length(listed)
    conf = File.read!(Path.join(@root, "docs/reference/a2a-v1-conformance.md"))
    tck = File.read!(Path.join(@root, "docs/reference/tck-suite.md"))
    assert conf =~ "#{n} court files"
    assert tck =~ "Court inventory (#{n} courts)"
  end
end
