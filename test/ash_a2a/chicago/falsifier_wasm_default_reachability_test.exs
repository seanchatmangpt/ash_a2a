# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Chicago.FalsifierWasmDefaultReachabilityTest do
  @moduledoc """
  Falsifier (`errc/ash-a2a-format`, lens: falsifier) for the claim that the
  praxis-graphlaw engine is "unreachable on the hosted runner", which was the
  stated reason 103 tests were excluded under `:graphlaw_engine` instead of
  running (ash_a2a#27).

  Real files only: the repo's own git-tracked `priv/graphlaw/` tree and the
  `lib/` sources, read from disk. No collaborator is faked.

  1. Positive control: the wasm every hosted checkout contains,
     `priv/graphlaw/praxis_graphlaw.wasm`, is byte-identical to the digest
     `priv/graphlaw/MANIFEST.json` pins (and, on a machine that has the praxis
     checkout, to that build). The engine is reachable from a bare checkout;
     no exclusion is forced by absence of the artifact.
  2. Falsifier: no module under `lib/` defaults a wasm resolver to an absolute
     path under a developer home. At 55753a5 it FAILED: six `@default_*wasm*`
     offenders (`graph_law/wasm.ex`, `graph_law/wasm_driver.ex`,
     `sa2a/graphlaw.ex`, `semantic/graph_law/wasm.ex`,
     `semantic/graph_law_bridge.ex`, `semantic/root_manifest/engine_probe.ex`)
     plus, under the `~/praxis` pattern added afterwards, `graph_law/runtime.ex`.
     That default, not the absence of the engine, made the 103 hosted-runner
     tests fail. It is retained as the permanent guard against reintroducing
     such a default. The resolved-state counterpart is
     `AshA2A.Chicago.WasmDefaultResolutionTest`.
  """

  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)
  @vendored Path.join(@root, "priv/graphlaw/praxis_graphlaw.wasm")
  @manifest Path.join(@root, "priv/graphlaw/MANIFEST.json")

  test "positive control: the git-tracked vendored wasm exists and matches the digest MANIFEST.json pins" do
    assert File.regular?(@vendored)

    pinned = @manifest |> File.read!() |> Jason.decode!() |> get_in(["artifact", "sha256"])
    actual = :crypto.hash(:sha256, File.read!(@vendored)) |> Base.encode16(case: :lower)

    assert actual == pinned

    {tracked, 0} =
      System.cmd("git", ["ls-files", "--error-unmatch", "priv/graphlaw/praxis_graphlaw.wasm"],
        cd: @root
      )

    assert String.trim(tracked) == "priv/graphlaw/praxis_graphlaw.wasm"
  end

  test "falsifier: no lib module defaults a wasm resolver to an absolute path under a developer home" do
    offenders =
      @root
      |> Path.join("lib/**/*.ex")
      |> Path.wildcard()
      |> Enum.flat_map(fn file ->
        file
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _n} ->
          # An attribute default under a developer home, or an expanded `~/praxis`
          # default (GraphLaw.Runtime used the latter, which the attribute form
          # alone would not catch).
          Regex.match?(~r/@default_\w*wasm\w*\s+"\/(Users|home)\//, line) or
            Regex.match?(~r/Path\.expand\("~\/praxis/, line)
        end)
        |> Enum.map(fn {_line, n} -> "#{Path.relative_to(file, @root)}:#{n}" end)
      end)

    assert offenders == [],
           "wasm resolvers whose default is a developer-home path although the identical " <>
             "artifact is vendored at priv/graphlaw/praxis_graphlaw.wasm: #{inspect(offenders)}"
  end
end
