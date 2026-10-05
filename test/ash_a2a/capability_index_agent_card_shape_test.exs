# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.CapabilityIndexAgentCardShapeTest do
  @moduledoc """
  Pins the A2A v1.0 (spec §4.4/8.2, Appendix A.2.2) `AshA2A.Protocol.AgentCard`
  struct shape that `AshA2A.CapabilityIndex.build_agent_card/2` depends on
  (see the drift inventory in `lib/ash_a2a/capability_index.ex`).

  `build_agent_card/2` cannot introspect proto conformance itself -- it can
  only build against whatever fields the struct actually defines today. This
  test makes that dependency load-bearing and loud: if a future change
  renames/removes/adds a field, this test fails instead of
  `build_agent_card/2` silently building a card against a struct shape that
  no longer matches what this module's moduledoc documents.

  Also pins the `AshA2A.Protocol.JSON` encode/decode round-trip for the v1.0
  struct field set, including the two members that are absent from the
  top-level wire card by spec, not by codec omission: top-level
  `protocolVersion` (per-interface in v1.0) and `preferred_transport`
  (struct-only -- see the Z33b-consistent inventory below).

  Chicago-style: exercises the real `AshA2A.Protocol.AgentCard` struct, the
  real codec (`encode_agent_card`/`decode_agent_card`) and the real
  `AshA2A.CapabilityIndex.build_agent_card/2` against a real compiled Ash
  resource fixture (`AshA2A.Test.Fixture.Echo`, already used elsewhere in
  this suite). No Mock/mox/patch; all assertions are on real returned state.
  """

  use ExUnit.Case, async: true

  alias AshA2A.CapabilityIndex
  alias AshA2A.Protocol.JSON
  alias AshA2A.Test.Fixture.Echo

  @v1_0_fields [
    :name,
    :description,
    :url,
    :version,
    :provider,
    :documentation_url,
    :icon_url,
    :protocol_version,
    :preferred_transport,
    :skills,
    :capabilities,
    :default_input_modes,
    :default_output_modes,
    :supported_interfaces,
    :security_schemes,
    :security,
    :signatures
  ]

  describe "AshA2A.Protocol.AgentCard struct shape (pins the v1.0 field inventory)" do
    test "struct defines exactly the v1.0 field set" do
      # Real struct introspection -- not a hand-maintained duplicate list
      # copy/pasted from agent_card.ex, so this actually catches a field
      # being added/removed/renamed.
      actual_fields =
        struct!(AshA2A.Protocol.AgentCard, name: "x", description: "y", url: "z", version: "1", skills: [])
        |> Map.from_struct()
        |> Map.keys()
        |> Enum.sort()

      expected_fields = Enum.sort(@v1_0_fields)

      assert actual_fields == expected_fields,
             "AshA2A.Protocol.AgentCard field set changed -- update @v1_0_fields " <>
               "here and build_agent_card/2 if new fields need populating. " <>
               "Actual: #{inspect(actual_fields)}"

      # v1.0 members that must be present.
      assert :signatures in actual_fields
      assert :preferred_transport in actual_fields
      assert :supported_interfaces in actual_fields
    end

    test "protocol_version defaults to AshA2A.Protocol.Version.protocol_version/0" do
      card = struct!(AshA2A.Protocol.AgentCard, name: "x", description: "y", url: "z", version: "1", skills: [])

      assert card.protocol_version == AshA2A.Protocol.Version.protocol_version()
      assert card.protocol_version == "1.0"
    end

    test "capabilities.extended_agent_card is a capabilities member, not a top-level field" do
      # extendedAgentCard lives under `capabilities` on the wire (spec §4.4);
      # the struct reflects that -- there is no top-level :extended_agent_card.
      refute :extended_agent_card in
               Map.from_struct(
                 struct!(AshA2A.Protocol.AgentCard,
                   name: "x",
                   description: "y",
                   url: "z",
                   version: "1",
                   skills: []
                 )
               )

      card =
        struct!(AshA2A.Protocol.AgentCard,
          name: "x",
          description: "y",
          url: "z",
          version: "1",
          skills: [],
          capabilities: %{extended_agent_card: true}
        )

      assert card.capabilities.extended_agent_card == true
    end

    test "url remains an enforced (required) key on the struct" do
      # `@enforce_keys` isn't introspectable via Map.from_struct/1, so this
      # exercises it directly: constructing the struct without `:url` must
      # raise. The codec's decode synthesizes `url` from the preferred
      # interface when the wire card omits it, so the field itself stays
      # structurally required for builders.
      assert_raise ArgumentError, fn ->
        struct!(AshA2A.Protocol.AgentCard, name: "x", description: "y", version: "1", skills: [])
      end
    end
  end

  describe "AshA2A.Protocol.JSON agent-card round-trip (v1.0 members)" do
    test "encode/decode round-trips the v1.0 field set" do
      card = %AshA2A.Protocol.AgentCard{
        name: "rt_agent",
        description: "round-trip fixture",
        url: "https://rt.example.com",
        version: "1.0.0",
        skills: [%{id: "s1", name: "Skill One", description: "does things", tags: ["t1"]}],
        capabilities: %{
          streaming: true,
          push_notifications: false,
          extended_agent_card: true,
          extensions: [
            %AshA2A.Protocol.AgentExtension{
              uri: "https://example.com/ext",
              description: "demo",
              required: false,
              params: %{"k" => "v"}
            }
          ]
        },
        default_input_modes: ["text/plain"],
        default_output_modes: ["application/json"],
        provider: %{organization: "Example Org", url: "https://org.example.com"},
        documentation_url: "https://docs.example.com",
        icon_url: "https://cdn.example.com/icon.png",
        protocol_version: "1.0",
        preferred_transport: "JSONRPC",
        supported_interfaces: [
          %{url: "https://rt.example.com", protocol_binding: "JSONRPC", protocol_version: "1.0"},
          %{url: "https://grpc.example.com", protocol_binding: "GRPC", protocol_version: "1.0"},
          %{url: "https://http.example.com", protocol_binding: "HTTP+JSON", protocol_version: "1.0"}
        ],
        security_schemes: %{
          "apiKey" => %AshA2A.Protocol.SecurityScheme.APIKey{name: "api_key", in: "header"}
        },
        security: [%{"apiKey" => ["read", "write"]}],
        signatures: [%{"protected" => "b64payload", "signature" => "sig-bytes"}]
      }

      wire = JSON.encode_agent_card(card, url: card.url)
      {:ok, decoded} = JSON.decode_agent_card(wire)

      # Scalars and optional members that survive the cycle.
      assert decoded.name == card.name
      assert decoded.description == card.description
      assert decoded.version == card.version
      assert decoded.documentation_url == card.documentation_url
      assert decoded.icon_url == card.icon_url
      assert decoded.provider == %{organization: "Example Org", url: "https://org.example.com"}
      assert decoded.default_input_modes == card.default_input_modes
      assert decoded.default_output_modes == card.default_output_modes
      assert decoded.security == card.security
      assert decoded.security_schemes == card.security_schemes
      assert decoded.signatures == card.signatures
      assert decoded.skills == card.skills

      # `url` is per-interface in v1.0; the codec reconstructs the top-level
      # struct field from the first (preferred) interface.
      assert decoded.url == "https://rt.example.com"

      # capabilities, including extendedAgentCard and extensions.
      # `state_transition_history` is intentionally NOT set on the fixture
      # card: v1 dropped it from AgentCapabilities (Z16-F3, see
      # encode_capabilities/1 in lib/ash_a2a/protocol/json.ex) — the struct
      # key may exist internally but is never emitted on the wire, so a
      # round-trip cannot preserve it. Pinned loud:
      refute Map.has_key?(decoded.capabilities, :state_transition_history)
      assert decoded.capabilities == card.capabilities

      # supported_interfaces, with transport identification intact.
      assert decoded.supported_interfaces == card.supported_interfaces

      # --- spec-correct wire absences (pinned loud) ---
      # v1.0 drops the top-level `url`/`protocolVersion` members (both are
      # per-interface), so encode never emits a top-level "protocolVersion"
      # and decode's explicit Map.get backfills nil. Not a codec gap -- the
      # same v1.0-correct absence the Z33b wire-properties court pins.
      assert decoded.protocol_version == nil

      # preferred_transport is neither encoded nor decoded -- struct-only by
      # spec (the v1.0 proto has no such member; pinned by Z33b).
      assert decoded.preferred_transport == nil
    end

    test "wire map carries extendedAgentCard under capabilities, not top-level" do
      card =
        struct!(AshA2A.Protocol.AgentCard,
          name: "x",
          description: "y",
          url: "https://x.example.com",
          version: "1",
          skills: [],
          capabilities: %{extended_agent_card: true}
        )

      wire = JSON.encode_agent_card(card, url: card.url)

      refute Map.has_key?(wire, "extendedAgentCard")
      assert get_in(wire, ["capabilities", "extendedAgentCard"]) == true
    end

    test "interface protocol_binding values carry v1.0 transport identification" do
      card =
        struct!(AshA2A.Protocol.AgentCard,
          name: "x",
          description: "y",
          url: "https://x.example.com",
          version: "1",
          skills: [],
          supported_interfaces: [
            %{url: "https://x.example.com", protocol_binding: "JSONRPC", protocol_version: "1.0"},
            %{url: "https://grpc.example.com", protocol_binding: "GRPC", protocol_version: "1.0"},
            %{url: "https://http.example.com", protocol_binding: "HTTP+JSON", protocol_version: "1.0"}
          ]
        )

      wire = JSON.encode_agent_card(card, url: card.url)

      assert %{"protocolBinding" => "JSONRPC"} =
               Enum.find(wire["supportedInterfaces"], &(&1["url"] == "https://x.example.com"))

      assert %{"protocolBinding" => "GRPC"} =
               Enum.find(wire["supportedInterfaces"], &(&1["url"] == "https://grpc.example.com"))

      assert %{"protocolBinding" => "HTTP+JSON"} =
               Enum.find(wire["supportedInterfaces"], &(&1["url"] == "https://http.example.com"))

      {:ok, decoded} = JSON.decode_agent_card(wire)
      assert Enum.map(decoded.supported_interfaces, & &1.protocol_binding) == ["JSONRPC", "GRPC", "HTTP+JSON"]
    end
  end

  describe "build_agent_card/2 (real CapabilityIndex projection)" do
    test "build_agent_card/2 produces a real AshA2A.Protocol.AgentCard struct with the documented shape" do
      skills = AshA2A.Info.capability_index(Echo)
      card = CapabilityIndex.build_agent_card(skills, name: "shape_test_agent")

      assert %AshA2A.Protocol.AgentCard{} = card
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
                 protocol_version: "1.0"
               }
             ]
    end

    test "build_agent_card/2 accepts an explicit :supported_interfaces option, overriding the derived default" do
      skills = AshA2A.Info.capability_index(Echo)

      custom_interfaces = [
        %{url: "https://grpc.example.com", protocol_binding: "GRPC", protocol_version: "1.0"}
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
