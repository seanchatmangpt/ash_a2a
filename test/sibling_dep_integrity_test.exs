# SPDX-FileCopyrightText: 2026 ash_a2a contributors
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SiblingDepIntegrityTest do
  @moduledoc """
  Sibling-dependency integrity courts.

    * the resolved `ash_graphlaw` artifact either carries a wasm whose SHA-256
      matches its own MANIFEST, or the court states loudly why it cannot run
      (the Hex package ships no wasm);
    * ash_atlassian / ash_planning_center are CANDIDATE intake rows only -
      no `lib/` module may reference them until an adapter is admitted.
  """
  use ExUnit.Case, async: true

  @lib Path.expand("../lib", __DIR__)

  test "ash_graphlaw wasm digest matches its MANIFEST (or loud skip)" do
    dir = :code.priv_dir(:ash_graphlaw) |> to_string() |> Path.join("graphlaw")
    wasm = Path.join(dir, "graphlaw.wasm")
    manifest = Path.join(dir, "MANIFEST.json")

    if File.exists?(wasm) and File.exists?(manifest) do
      expected = manifest |> File.read!() |> Jason.decode!() |> get_in(["artifact", "sha256"])
      actual = :crypto.hash(:sha256, File.read!(wasm)) |> Base.encode16(case: :lower)
      assert actual == expected
    else
      IO.puts(
        "[SKIP] ash_graphlaw wasm not vendored in #{dir} " <>
          "(Hex package); use ASH_GRAPHLAW_PATH or the sibling checkout"
      )
    end
  end

  test "ash_atlassian / ash_planning_center are not referenced by lib/ (CANDIDATE only)" do
    offenders =
      @lib
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.filter(fn f -> File.read!(f) =~ ~r/AshAtlassian|AshPlanningCenter/ end)

    assert offenders == []
  end
end
