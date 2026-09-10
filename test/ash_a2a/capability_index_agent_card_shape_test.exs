defmodule AshA2A.CapabilityIndexAgentCardShapeTest do
  @moduledoc """
  Pins the vendored `:a2a` 0.2.0 `A2A.AgentCard` struct shape that
  `AshA2A.CapabilityIndex.build_agent_card/2` depends on (see the moduledoc
  gap inventory in `lib/ash_a2a/capability_index.ex`).

  `build_agent_card/2` cannot introspect proto conformance itself -- it can
  only build against whatever fields the vendored dependency's struct
  actually defines today. This test makes that dependency load-bearing and
  loud: if a future `:a2a` version renames/removes/adds a field (for example
  finally adding `:signatures`, or dropping the `:url` `@enforce_keys`
  requirement to track the current a2a.proto spec), this test fails instead
  of `build_agent_card/2` silently building a card against a struct shape
  that no longer matches what this module's moduledoc documents.

  Chicago-style: exercises the real `A2A.AgentCard` struct and the real
  `AshA2A.CapabilityIndex.build_agent_card/2` against a real compiled Ash
  resource fixture (`AshA2A.Test.Fixture.Echo`, already used elsewhere in
  this suite). No Mock/mox/patch; all assertions are on real returned state.
  """

  use ExUnit.Case, async: true

  alias AshA2A.CapabilityIndex
  alias AshA2A.Test.Fixture.Echo

  describe "A2A.AgentCard struct shape (pins the known-drift inventory)" do
    test "struct defines exactly the fields this module's moduledoc documents" do
      # Real struct introspection -- not a hand-maintained duplicate list
      # copy/pasted from agent_card.ex, so this actually catches a field
      # being added/removed/renamed by a dependency bump.
      actual_fields =
        struct!(A2A.AgentCard, name: "x", description: "y", url: "z", version: "1", skills: [])
        |> Map.from_struct()
        |> Map.keys()
        |> Enum.sort()

      expected_fields =
        Enum.sort([
          :name,
          :description,
          :url,
          :version,
          :provider,
          :documentation_url,
          :icon_url,
          :protocol_version,
          :skills,
          :capabilities,
          :default_input_modes,
          :default_output_modes,
          :supported_interfaces,
          :security_schemes,
          :security
        ])

      assert actual_fields == expected_fields,
             "A2A.AgentCard field set changed -- update the drift inventory " <>
               "in AshA2A.CapabilityIndex's moduledoc (and build_agent_card/2 " <>
               "if new fields need populating). Actual: #{inspect(actual_fields)}"

      # No `:signatures` field exists on the vendored struct. This is the
      # concrete assertion behind the moduledoc's "cannot be populated"
      # claim -- if a future :a2a version adds it, this line starts failing
      # (refute becomes false) and signals build_agent_card/2 should start
      # populating it.
      refute :signatures in actual_fields
    end

    test "url remains an enforced (required) key on the vendored struct" do
      # `@enforce_keys` isn't introspectable via Map.from_struct/1, so this
      # exercises it directly: constructing the struct without `:url` must
      # raise. If a future :a2a version drops `url` from @enforce_keys to
      # track the current proto (where the analogous field is
      # absent/reserved), this test starts failing, signaling that
      # AshA2A.CapabilityIndex.build_agent_card/2's `url` default is no
      # longer structurally required and the moduledoc note is stale.
      assert_raise ArgumentError, fn ->
        struct!(A2A.AgentCard, name: "x", description: "y", version: "1", skills: [])
      end
    end

    test "build_agent_card/2 produces a real A2A.AgentCard struct with the documented shape" do
      skills = AshA2A.Info.capability_index(Echo)
      card = CapabilityIndex.build_agent_card(skills, name: "shape_test_agent")

      assert %A2A.AgentCard{} = card
      assert card.name == "shape_test_agent"
      # security/security_schemes default to the empty, non-fabricated
      # values the moduledoc's "no fabricated default scheme" section
      # documents.
      assert card.security == []
      assert card.security_schemes == %{}
    end

    test "build_agent_card/2 defaults supported_interfaces to a real, non-empty entry derived from :url" do
      skills = AshA2A.Info.capability_index(Echo)

      card =
        CapabilityIndex.build_agent_card(skills,
          name: "shape_test_agent",
          url: "https://agent.example.com"
        )

      assert card.supported_interfaces == [
               %{
                 url: "https://agent.example.com",
                 protocol_binding: "JSONRPC",
                 protocol_version: "0.3.0"
               }
             ]
    end

    test "build_agent_card/2 accepts an explicit :supported_interfaces option, overriding the derived default" do
      skills = AshA2A.Info.capability_index(Echo)

      custom_interfaces = [
        %{url: "https://grpc.example.com", protocol_binding: "GRPC", protocol_version: "0.3.0"}
      ]

      card =
        CapabilityIndex.build_agent_card(skills,
          name: "shape_test_agent",
          supported_interfaces: custom_interfaces
        )

      assert card.supported_interfaces == custom_interfaces
    end
  end
end
