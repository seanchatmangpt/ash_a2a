# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SA2ADiataxisClosureTest do
  @moduledoc """
  Machine Diátaxis closure for ash_a2a: every exported capability must bind
  specifiedBy / executedBy / verifiedBy / repairedBy, and every `sa2a:path`
  must name an existing repo artifact.
  """

  use ExUnit.Case, async: true

  @ttl Path.expand("../../semantic/sa2a-diataxis.ttl", __DIR__)
  @capabilities ~w(
    urn:sa2a:capability:discover
    urn:sa2a:capability:select
    urn:sa2a:capability:construct
    urn:sa2a:capability:do
    urn:sa2a:capability:receipt
    urn:sa2a:capability:replay
  )
  @edges ~w(specifiedBy executedBy verifiedBy repairedBy)

  test "every exported capability binds the four Diátaxis edges" do
    text = File.read!(@ttl)

    for cap <- @capabilities, edge <- @edges do
      # capability block contains `sa2a:<edge> <urn:...>`
      pattern =
        ~r/<#{Regex.escape(cap)}>\s*[\s\S]*?sa2a:#{edge}\s+<urn:sa2a:[^>]+>/

      assert Regex.match?(pattern, text),
             "#{cap} missing sa2a:#{edge}"
    end
  end

  test "every sa2a:path names an existing workspace file" do
    text = File.read!(@ttl)
    root = Path.expand("../..", __DIR__)

    paths =
      Regex.scan(~r/sa2a:path\s+"([^"]+)"/, text)
      |> Enum.map(fn [_, path] -> path end)
      |> Enum.uniq()

    assert paths != []

    missing =
      Enum.reject(paths, fn rel ->
        File.exists?(Path.join(root, rel))
      end)

    assert missing == [], "sa2a:path targets missing: #{inspect(missing)}"
  end

  test "closure query shape still asks for the four edge classes" do
    rq = File.read!(Path.expand("../../semantic/sa2a-diataxis-closure.rq", __DIR__))

    for edge <- ~w(specifiedBy executedBy verifiedBy repairedBy) do
      assert String.contains?(rq, "sa2a:#{edge}"),
             "closure query no longer checks sa2a:#{edge}"
    end
  end
end
