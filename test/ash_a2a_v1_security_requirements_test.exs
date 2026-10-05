defmodule AshA2A.V1SecurityRequirementsTest do
  @moduledoc """
  Z24 — card security-requirements decode/encode name-fidelity court.

  Closes X6 finding F3: the card decoder read only the v0.3 `security` key and
  silently dropped the v1.0 `securityRequirements` member (lf.a2a.v1
  AgentCard.security_requirements = 9, protojson name "securityRequirements" —
  `priv/a2a_v1_spec_corpus/a2a.proto:384`; the vendored v1 spec example
  `v1_spec_examples.json` examples[1].wire carries "securityRequirements" in
  the protojson wrapper shape %{"schemes" => %{name => %{"list" => scopes}}}).

  The codec now:
  - decodes BOTH spellings into the struct's flat `%{name => scopes}` entries
    (v1.0 "securityRequirements" preferred, legacy "security" accepted);
  - emits ONLY the v1.0 spelling "securityRequirements" (wrapper shape), the
    v0.3 "security" spelling is deprecated on encode;
  - a real served card (real `AshA2A.Protocol.Plug` + real agent GenServer via
    `Plug.Test`) carries the v1.0 member.

  No mocks anywhere: real codec, real struct round-trips, real Plug pipeline.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Protocol.{AgentCard, JSON}
  alias AshA2A.Test.PlugFixture.{Greeter, GreeterAgent}

  # Real `AshA2A.Protocol.Agent` GenServer whose served card exercises BOTH
  # halves of the per-skill security falsifier: one skill WITH per-skill
  # `security_requirements` and one WITHOUT. `agent_card/0` is the
  # `defoverridable` seam `use AshA2A.Agent` deliberately exposes for exactly
  # this kind of card-content declaration (the card is test data; the Plug
  # pipeline, the GenServer, the codec and the HTTP semantics are all real).
  defmodule SecuredSkillAgent do
    use AshA2A.Agent, resource_or_domain: AshA2A.Test.PlugFixture.Greeter, name: "secured_skill_agent"

    @impl AshA2A.Protocol.Agent
    def agent_card do
      %{
        name: "secured-skill-agent",
        description: "Agent with one security-scoped skill and one unscoped skill",
        version: "1.0.0",
        skills: [
          %{
            id: "Greeter.read",
            name: "read",
            description: "Reads greetings (requires api_key)",
            tags: ["read"],
            security_requirements: [%{"api_key" => ["greet:read"]}]
          },
          %{
            id: "Greeter.unscoped",
            name: "unscoped",
            description: "Unscoped companion skill",
            tags: ["read"]
          }
        ]
      }
    end
  end

  # The vendored official IDL names the member securityRequirements.
  @proto_path Path.join(__DIR__, "../priv/a2a_v1_spec_corpus/a2a.proto")

  describe "spec fidelity" do
    @describetag :z24

    test "the vendored v1 proto pins the wire name securityRequirements" do
      src = File.read!(@proto_path)

      assert src =~
               ~s(repeated SecurityRequirement security_requirements = 9;),
             "AgentCard.security_requirements field 9 missing from the vendored IDL"

      refute src =~ ~r/repeated SecurityRequirement\s+security\s*=/,
             "the proto spells the card member `security`, not `securityRequirements`"
    end
  end

  describe "decode" do
    @describetag :z24

    test "v1.0 securityRequirements (protojson wrapper shape) decodes to flat entries" do
      {:ok, card} =
        JSON.decode_agent_card(%{
          "name" => "test",
          "description" => "A test agent",
          "version" => "1.0.0",
          "skills" => [
            %{"id" => "s1", "name" => "Skill", "description" => "Does things", "tags" => []}
          ],
          "securityRequirements" => [
            %{"schemes" => %{"google" => %{"list" => ["openid", "profile", "email"]}}}
          ]
        })

      assert card.security == [%{"google" => ["openid", "profile", "email"]}]
    end

    test "v1.0 securityRequirements (flat shape) decodes unchanged" do
      {:ok, card} =
        JSON.decode_agent_card(%{
          "name" => "test",
          "description" => "A test agent",
          "version" => "1.0.0",
          "skills" => [
            %{"id" => "s1", "name" => "Skill", "description" => "Does things", "tags" => []}
          ],
          "securityRequirements" => [%{"google" => ["openid"]}]
        })

      assert card.security == [%{"google" => ["openid"]}]
    end

    test "legacy v0.3 security key still decodes" do
      {:ok, card} =
        JSON.decode_agent_card(%{
          "name" => "test",
          "description" => "A test agent",
          "version" => "0.3.0",
          "skills" => [
            %{"id" => "s1", "name" => "Skill", "description" => "Does things", "tags" => []}
          ],
          "security" => [%{"api_key" => ["scope1"]}]
        })

      assert card.security == [%{"api_key" => ["scope1"]}]
    end

    test "when both spellings are present, v1.0 wins" do
      {:ok, card} =
        JSON.decode_agent_card(%{
          "name" => "test",
          "description" => "A test agent",
          "version" => "1.0.0",
          "skills" => [
            %{"id" => "s1", "name" => "Skill", "description" => "Does things", "tags" => []}
          ],
          "securityRequirements" => [%{"google" => ["openid"]}],
          "security" => [%{"legacy" => ["scope"]}]
        })

      assert card.security == [%{"google" => ["openid"]}]
    end

    test "absent member decodes to the empty default" do
      {:ok, card} =
        JSON.decode_agent_card(%{
          "name" => "test",
          "description" => "A test agent",
          "version" => "1.0.0",
          "skills" => [
            %{"id" => "s1", "name" => "Skill", "description" => "Does things", "tags" => []}
          ]
        })

      assert card.security == []
      assert %AgentCard{} = card
    end
  end

  describe "encode" do
    @describetag :z24

    test "flat struct security encodes to the v1.0 wrapper shape; v0.3 spelling is never emitted" do
      card = %AgentCard{
        name: "Agent",
        description: "A test agent",
        url: "https://agent.example",
        version: "1.0.0",
        skills: [%{id: "s1", name: "Skill", description: "Does things", tags: ["t"]}]
      }

      wire =
        JSON.encode_agent_card(%AgentCard{card | security: [%{"api_key" => ["scope1"]}]},
          url: "https://agent.example"
        )

      assert wire["securityRequirements"] == [
               %{"schemes" => %{"api_key" => %{"list" => ["scope1"]}}}
             ]

      refute Map.has_key?(wire, "security"),
             "encode emitted the deprecated v0.3 spelling \"security\""
    end

    test "round-trip: encode(flat struct) -> decode returns the same entries" do
      card = %AgentCard{
        name: "Agent",
        description: "A test agent",
        url: "https://agent.example",
        version: "1.0.0",
        skills: [%{id: "s1", name: "Skill", description: "Does things", tags: ["t"]}],
        security: [%{"api_key" => ["scope1"]}, %{"oidc" => []}]
      }

      round_tripped =
        card
        |> JSON.encode_agent_card(url: "https://agent.example")
        |> JSON.decode_agent_card()

      # The security entries survive the wire round-trip with values intact.
      # (Full-struct equality is out of scope here: encode synthesizes
      # supportedInterfaces from :url, so unrelated fields legitimately differ.)
      assert {:ok, round_tripped_card} = round_tripped
      assert round_tripped_card.security == card.security
    end

    test "empty security emits no member" do
      card = %AgentCard{
        name: "Agent",
        description: "A test agent",
        url: "https://agent.example",
        version: "1.0.0",
        skills: [%{id: "s1", name: "Skill", description: "Does things", tags: ["t"]}]
      }

      wire = JSON.encode_agent_card(card, url: "https://agent.example")

      refute Map.has_key?(wire, "securityRequirements")
      refute Map.has_key?(wire, "security")
    end
  end

  describe "served card (real Plug)" do
    @describetag :z24

    setup do
      agent_name = :"greeter_agent_z24_#{System.unique_integer([:positive])}"
      {:ok, pid} = GreeterAgent.start_link(name: agent_name)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      %{agent: agent_name}
    end

    test "a real served agent card carries the v1.0 securityRequirements member", %{
      agent: agent
    } do
      base_url = "http://localhost:4000/a2a"

      plug_opts =
        AshA2A.Protocol.Plug.init(
          agent: agent,
          base_url: base_url,
          agent_card_opts: [
            security: [%{"api_key" => ["scope1"]}],
            security_schemes: %{
              "api_key" => %AshA2A.Protocol.SecurityScheme.APIKey{name: "X-Api-Key", in: "header"}
            }
          ]
        )

      conn =
        Plug.Test.conn(:get, "/.well-known/agent-card.json")
        |> AshA2A.Protocol.Plug.call(plug_opts)

      assert conn.status == 200

      served = Jason.decode!(conn.resp_body)

      assert served["securityRequirements"] == [
               %{"schemes" => %{"api_key" => %{"list" => ["scope1"]}}}
             ]

      refute Map.has_key?(served, "security")

      # Cross-check: the served card is exactly the codec's output for the same
      # agent's card + opts.
      expected =
        agent
        |> GenServer.call(:get_agent_card)
        |> JSON.encode_agent_card(
          url: base_url,
          security: [%{"api_key" => ["scope1"]}],
          security_schemes: %{
            "api_key" => %AshA2A.Protocol.SecurityScheme.APIKey{name: "X-Api-Key", in: "header"}
          }
        )
        |> Jason.encode!()

      assert served == Jason.decode!(expected)
    end
  end

  describe "capability-index card shape (downstream reader)" do
    @describetag :z24

    test "the card builder still populates the flat :security struct field" do
      card = AshA2A.Info.agent_card(Greeter, name: "greeter_agent")

      assert is_list(card.security)
      assert %AgentCard{} = card
    end
  end

  describe "per-skill security requirements (AgentSkill.security_requirements = 8)" do
    @describetag :z24

    @skill_proto_snippet "repeated SecurityRequirement security_requirements = 8;"

    test "the vendored v1 proto pins the per-skill wire name securityRequirements" do
      src = File.read!(@proto_path)

      assert src =~ @skill_proto_snippet,
             "AgentSkill.security_requirements field 8 missing from the vendored IDL"

      # The AgentSkill message (not AgentCard) carries field 8.
      skill_block =
        src
        |> String.split("message AgentSkill {", parts: 2)
        |> List.last()
        |> String.split("}", parts: 2)
        |> List.first()

      assert skill_block =~ @skill_proto_snippet,
             "field 8 exists but not inside message AgentSkill"
    end

    test "encode: a skill with security_requirements emits the v1.0 wrapper shape; unset skills emit no member" do
      card = %AgentCard{
        name: "Agent",
        description: "A test agent",
        url: "https://agent.example",
        version: "1.0.0",
        skills: [
          %{id: "s1", name: "Scoped", description: "Scoped skill", tags: ["t"],
            security_requirements: [%{"api_key" => ["greet:read"]}]},
          %{id: "s2", name: "Unscoped", description: "Unscoped skill", tags: ["t"]}
        ]
      }

      wire = JSON.encode_agent_card(card, url: "https://agent.example")
      [scoped, unscoped] = wire["skills"]

      assert scoped["securityRequirements"] == [
               %{"schemes" => %{"api_key" => %{"list" => ["greet:read"]}}}
             ]

      refute Map.has_key?(unscoped, "securityRequirements"),
             "encode emitted per-skill securityRequirements for a skill with none set"

      refute Map.has_key?(wire, "security"),
             "encode emitted the deprecated v0.3 card spelling via a skill"
    end

    test "encode: per-skill entries normalize through the card-level encoder (already-wire-shaped pass through)" do
      card = %AgentCard{
        name: "Agent",
        description: "A test agent",
        url: "https://agent.example",
        version: "1.0.0",
        skills: [
          %{id: "s1", name: "Scoped", description: "Scoped skill", tags: ["t"],
            security_requirements: [
              %{"schemes" => %{"oidc" => %{"list" => ["openid"]}}},
              %{"api_key" => []}
            ]}
        ]
      }

      wire = JSON.encode_agent_card(card, url: "https://agent.example")
      [skill] = wire["skills"]

      assert skill["securityRequirements"] == [
               %{"schemes" => %{"oidc" => %{"list" => ["openid"]}}},
               %{"schemes" => %{"api_key" => %{"list" => []}}}
             ]
    end

    test "decode: per-skill wrapper shape (and flat entries) normalize to flat %{name => scopes}" do
      {:ok, card} =
        JSON.decode_agent_card(%{
          "name" => "test",
          "description" => "A test agent",
          "version" => "1.0.0",
          "skills" => [
            %{"id" => "s1", "name" => "Scoped", "description" => "d", "tags" => [],
              "securityRequirements" => [
                %{"schemes" => %{"google" => %{"list" => ["openid", "email"]}}}
              ]},
            %{"id" => "s2", "name" => "FlatScoped", "description" => "d", "tags" => [],
              "securityRequirements" => [%{"api_key" => ["scope1"]}]},
            %{"id" => "s3", "name" => "Unscoped", "description" => "d", "tags" => []}
          ]
        })

      [s1, s2, s3] = card.skills

      assert s1.security_requirements == [%{"google" => ["openid", "email"]}]
      assert s2.security_requirements == [%{"api_key" => ["scope1"]}]

      # Absent on the wire = the "inherit card-level security" signal: NO key.
      refute Map.has_key?(s3, :security_requirements),
             "decoder synthesized a nil-placeholder :security_requirements key"
    end

    test "round-trip: per-skill security_requirements survives encode -> decode intact" do
      requirements = [%{"api_key" => ["greet:read"]}, %{"oidc" => []}]

      card = %AgentCard{
        name: "Agent",
        description: "A test agent",
        url: "https://agent.example",
        version: "1.0.0",
        skills: [
          %{id: "s1", name: "Scoped", description: "Scoped skill", tags: ["t"],
            security_requirements: requirements}
        ],
        security: [%{"api_key" => ["card:scope"]}]
      }

      assert {:ok, round_tripped} =
               card
               |> JSON.encode_agent_card(url: "https://agent.example")
               |> JSON.decode_agent_card()

      [skill] = round_tripped.skills
      assert skill.security_requirements == requirements
      # Card-level entries are untouched by the per-skill projection.
      assert round_tripped.security == card.security
    end

    test "a real served card shows the per-skill member ONLY on the skill that sets it" do
      agent_name = :"secured_skill_agent_z24_#{System.unique_integer([:positive])}"
      {:ok, pid} = SecuredSkillAgent.start_link(name: agent_name)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      base_url = "http://localhost:4000/a2a"

      conn =
        Plug.Test.conn(:get, "/.well-known/agent-card.json")
        |> AshA2A.Protocol.Plug.call(
          AshA2A.Protocol.Plug.init(agent: agent_name, base_url: base_url)
        )

      assert conn.status == 200
      served = Jason.decode!(conn.resp_body)

      by_id = Map.new(served["skills"], fn skill -> {skill["id"], skill} end)

      assert by_id["Greeter.read"]["securityRequirements"] == [
               %{"schemes" => %{"api_key" => %{"list" => ["greet:read"]}}}
             ]

      refute Map.has_key?(by_id["Greeter.unscoped"], "securityRequirements")

      # The served card round-trips: a client decoding it sees the same
      # per-skill requirements the server declared.
      assert {:ok, decoded} = JSON.decode_agent_card(served)
      decoded_by_id = Map.new(decoded.skills, fn skill -> {skill.id, skill} end)

      assert decoded_by_id["Greeter.read"].security_requirements == [%{"api_key" => ["greet:read"]}]
      refute Map.has_key?(decoded_by_id["Greeter.unscoped"], :security_requirements)
    end

    test "the real builder path still emits no per-skill member (builder opts are the declaration surface)" do
      card = AshA2A.Info.agent_card(Greeter, name: "greeter_agent")

      Enum.each(card.skills, fn skill ->
        refute Map.has_key?(skill, :security_requirements),
               "builder-synthesized skill #{skill.id} unexpectedly carries :security_requirements"
      end)
    end
  end
end
