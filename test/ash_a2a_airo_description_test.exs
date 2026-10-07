# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.AIRoDescriptionTest do
  @moduledoc """
  Structural court for the AIRo description of the A2A protocol surface
  (`priv/ontology/ash_a2a_airo.ttl`): the file exists, parses structurally
  (prefixes declared, balanced delimiters, every subject typed), every
  cited enforcing module path exists on disk, and every legacy_compat
  warning class appears as a RiskSource.
  """

  use ExUnit.Case, async: true

  @ttl_path Path.join([File.cwd!(), "priv", "ontology", "ash_a2a_airo.ttl"])

  @airo_prefixes ["airo:", "rdf:", "rdfs:", "xsd:", "a2a:"]

  @legacy_compat_codes ~w(
    authority_broker_missing kill_switch_class_missing claim_store_missing
    claim_store_not_durable claim_store_dir_not_durable receipt_store_in_memory
    outbox_dir_not_durable outbox_key_missing receipt_store_boot_check_failed
    capability_release_mode_legacy transport_verified_policy_forbidden
  )a

  # Enforcing modules cited in the TTL as airo:RiskControl, mapped to their
  # on-disk source path relative to the repo root.
  @control_modules %{
    "AshA2A.SecurityProfile.Boot" =>
      "lib/ash_a2a/security_profile/boot.ex",
    "AshA2A.Authority.Broker.Ekv" =>
      "lib/ash_a2a/authority/broker/ekv.ex",
    "AshA2A.KillSwitch" =>
      "lib/ash_a2a/kill_switch.ex",
    "AshA2A.ConsequenceKernel.EffectClaimStore.DurableFile" =>
      "lib/ash_a2a/consequence_kernel/effect_claim_store/durable_file.ex",
    "AshA2A.ReceiptStore" =>
      "lib/ash_a2a/receipt_store.ex"
  }

  test "ttl file exists" do
    assert File.exists?(@ttl_path)
  end

  test "ttl declares all prefixes" do
    ttl = File.read!(@ttl_path)

    for p <- @airo_prefixes do
      assert ttl =~ "@prefix #{p}",
             "missing @prefix declaration for #{p}"
    end

    assert ttl =~ "<https://w3id.org/airo#>"
  end

  test "ttl is structurally balanced (parentheses, quotes, statements end with dot)" do
    ttl = File.read!(@ttl_path)
    codepoints = String.to_charlist(ttl)

    parens =
      Enum.count(codepoints, &(&1 == ?())

    assert parens == Enum.count(codepoints, &(&1 == ?)))

    quotes = Enum.count(codepoints, &(&1 == ?"))
    assert rem(quotes, 2) == 0, "unbalanced double quotes"

    # every non-comment, non-@prefix line participates in a statement; the
    # last non-blank token of the file is a statement terminator
    body =
      ttl
      |> String.split("\n")
      |> Enum.reject(fn l -> String.starts_with?(String.trim_leading(l), "#") end)
      |> Enum.reject(&(String.trim(&1) == ""))
      |> Enum.join(" ")

    assert String.ends_with?(String.trim_trailing(body), ".")
  end

  test "every subject carries a rdf:type" do
    ttl = File.read!(@ttl_path)

    subjects =
      ttl
      |> String.split("\n\n")
      |> Enum.reject(fn block -> String.starts_with?(block, "#") or block =~ "@prefix" end)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    assert length(subjects) >= 27

    for block <- subjects do
      assert block =~ ~r/\brdf:type\b/,
             "subject block missing rdf:type:\n#{block}"
    end
  end

  test "A2A protocol surface is an airo:AISystem with risk and control edges" do
    ttl = File.read!(@ttl_path)

    system_block =
      ttl
      |> String.split("\n\n")
      |> Enum.find(&(&1 =~ "a2a:A2AProtocolSurface"))

    assert system_block
    assert system_block =~ "airo:AISystem"
    assert system_block =~ "airo:hasRisk"
    assert system_block =~ "airo:hasRiskControl"
  end

  test "every legacy_compat warning class is described as a RiskSource" do
    ttl = File.read!(@ttl_path)

    for code <- @legacy_compat_codes do
      assert ttl =~ "RiskSource-#{Macro.camelize(Atom.to_string(code))}",
             "legacy_compat warning class #{code} missing as a RiskSource"
    end
  end

  test "every enforcing module cited in the ttl exists on disk" do
    ttl = File.read!(@ttl_path)
    root = File.cwd!()

    for {module, path} <- @control_modules do
      assert ttl =~ module, "TTL should cite #{module}"
      assert File.exists?(Path.join(root, path)), "missing source file #{path}"
    end
  end

  test "control blocks carry airo:detectsRiskConcept edges and controls match Boot refusal codes" do
    ttl = File.read!(@ttl_path)

    control_blocks =
      ttl
      |> String.split("\n\n")
      |> Enum.reject(&(String.starts_with?(&1, "#") or &1 =~ "@prefix"))
      |> Enum.filter(&(&1 =~ "airo:detectsRiskConcept"))

    assert length(control_blocks) == 5

    # every RiskSource named in a detectsRiskConcept edge is defined locally
    defined = MapSet.new(scan_subjects(ttl, "airo:RiskSource"))

    referenced =
      control_blocks
      |> Enum.flat_map(&Regex.scan(~r/a2a:RiskSource-[A-Za-z]+/, &1))
      |> Enum.map(&hd/1)
      |> MapSet.new()

    assert MapSet.subset?(referenced, defined)

    # the Boot module's real refusal codes are the superset family of the
    # RiskSource labels (Chicago: real module as collaborator)
    codes =
      AshA2A.SecurityProfile.Boot.__sa2a_refusal_codes__()
      |> Map.keys()
      |> MapSet.new()

    for code <- @legacy_compat_codes do
      assert code in codes, "#{code} is not a Boot refusal code"
    end

    assert MapSet.subset?(MapSet.new(@legacy_compat_codes), codes)
  end

  test "receipt durability is carried as airo:hasConsequence chains" do
    ttl = File.read!(@ttl_path)

    assert ttl =~ "airo:hasConsequence"
    assert ttl =~ "airo:Consequence"
    assert ttl =~ "Consequence-SilentClaimLoss"
    assert ttl =~ "Consequence-UnreceiptedMutation"
  end

  defp scan_subjects(ttl, type) do
    ttl
    |> String.split("\n\n")
    |> Enum.filter(&(&1 =~ type))
    |> Enum.flat_map(&Regex.scan(~r/a2a:[A-Za-z-]+/, &1))
    |> Enum.map(&hd/1)
  end
end
