# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.GraphLawFenceTest do
  use ExUnit.Case, async: true

  alias AshA2A.GraphLaw

  test "in-corpus function is admitted" do
    assert :ok = GraphLaw.fence("graph_hash")
  end

  test "out-of-corpus function gets a typed refusal, not an admit" do
    assert {:error, %{code: :graphlaw_out_of_corpus, function: "validate_shacl_full"} = r} =
             GraphLaw.fence("validate_shacl_full")

    assert "graph_hash" in r.corpus
  end

  test "conformance fenced_call refuses out-of-corpus export before dispatch" do
    assert {:error, %{code: :graphlaw_out_of_corpus, function: "validate_all"}} =
             AshA2A.SA2A.Conformance.fenced_call(__MODULE__, nil, :validate_all, [])
  end

  test "manifest self-consistency: wasm sha256 appears in MANIFEST.json" do
    {:ok, path} = GraphLaw.resolve_wasm_path()
    sha = :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)
    assert File.read!(GraphLaw.manifest_path()) =~ sha
  end
end
