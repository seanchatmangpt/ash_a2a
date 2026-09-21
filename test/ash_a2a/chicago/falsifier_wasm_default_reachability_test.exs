# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Chicago.FalsifierWasmDefaultReachabilityTest do
  @moduledoc """
  Falsifier (`errc/ash-a2a-format`, lens: falsifier) for the claim recorded in
  `test/test_helper.exs` and `docs/streams/ash-a2a-format.md` that the
  praxis-graphlaw engine is "unreachable on the hosted runner", which is the
  stated reason 103 tests are excluded under `:graphlaw_engine` instead of
  running.

  Real files only: the repo's own git-tracked `priv/graphlaw/` tree and the
  `lib/` sources, read from disk. No collaborator is faked.

  1. The positive control PASSES: the wasm every hosted checkout contains,
     `priv/graphlaw/praxis_graphlaw.wasm`, is byte-identical to the digest
     `priv/graphlaw/MANIFEST.json` pins (and, on a machine that has the praxis
     checkout, to that build). The engine is therefore reachable from a bare
     checkout; the exclusion is not forced by absence of the artifact.
  2. The falsifier FAILS on this branch: six modules under `lib/` default
     their wasm resolver to an absolute path under the author's home
     (`/Users/sac/praxis/...`) instead of the vendored artifact. That default,
     not the absence of the engine, is what made the 103 hosted-runner tests
     fail, and hiding those tests behind `:graphlaw_engine` leaves the default
     in place while dropping the only coverage that would catch a regression.
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
          Regex.match?(~r/@default_\w*wasm\w*\s+"\/(Users|home)\//, line)
        end)
        |> Enum.map(fn {_line, n} -> "#{Path.relative_to(file, @root)}:#{n}" end)
      end)

    assert offenders == [],
           "wasm resolvers whose default is a developer-home path although the identical " <>
             "artifact is vendored at priv/graphlaw/praxis_graphlaw.wasm: #{inspect(offenders)}"
  end
end
