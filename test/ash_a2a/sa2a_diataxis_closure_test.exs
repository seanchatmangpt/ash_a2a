# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SA2ADiataxisClosureTest do
  @moduledoc """
  Machine Diátaxis closure for ash_a2a against the engineering-standards
  CapabilityShape: every exported capability binds learnedBy / executedBy /
  specifiedBy / constrainedBy / verifiedBy / repairedBy / evidencedBy, and
  every `sa2a:path` names an existing repo artifact.
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
  # Seven edges required by engineering-standards CapabilityShape.
  @edges ~w(learnedBy executedBy specifiedBy constrainedBy verifiedBy repairedBy evidencedBy)

  test "every exported capability is typed and binds the seven Diátaxis edges" do
    text = File.read!(@ttl)

    for cap <- @capabilities do
      assert Regex.match?(~r/<#{Regex.escape(cap)}>\s+a\s+sa2a:Capability\b/, text),
             "#{cap} is not typed sa2a:Capability"

      for edge <- @edges do
        pattern =
          ~r/<#{Regex.escape(cap)}>\s+a\s+sa2a:Capability\s*[\s\S]*?sa2a:#{edge}\s+<urn:sa2a:[^>]+>/

        assert Regex.match?(pattern, text),
               "#{cap} missing sa2a:#{edge}"
      end
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

  test "closure query asks for the seven CapabilityShape edge classes" do
    rq = File.read!(Path.expand("../../semantic/sa2a-diataxis-closure.rq", __DIR__))

    for edge <- @edges do
      assert String.contains?(rq, "sa2a:#{edge}"),
             "closure query no longer checks sa2a:#{edge}"
    end

    for fragment <- [
          "COUNT(?tutorial)",
          "COUNT(?method)",
          "COUNT(?contract)",
          "COUNT(?law)",
          "COUNT(?gate)",
          "COUNT(?repair)",
          "COUNT(?receipt)"
        ] do
      assert String.contains?(rq, fragment),
             "closure HAVING no longer tracks #{fragment}"
    end
  end

  test "repository profile declares runtime role and standards authority" do
    text = File.read!(@ttl)

    assert text =~ ~r/<urn:sa2a:repo:ash_a2a>\s+a\s+sa2a:RepositoryProfile/
    assert text =~ ~s[sa2a:role "runtime"]
    assert text =~ "engineering-standards/tree/main/semantic/sa2a-diataxis"
  end
end
