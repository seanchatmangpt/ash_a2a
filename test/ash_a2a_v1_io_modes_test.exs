defmodule AshA2A.V1IOModesTest.ModedAgent do
  @moduledoc """
  Real `AshA2A.Protocol.Agent` GenServer for the (e2) court: its card
  carries one skill with the spec's OPTIONAL per-skill
  `input_modes`/`output_modes` override, exactly the shape the real
  `AshA2A.CapabilityIndex.AgentCardBuilder` emits for a `:skills_opts`
  override and the real `AshA2A.Protocol.JSON` codec encodes/decodes.
  """

  use AshA2A.Protocol.Agent,
    name: "moded_io_modes_agent",
    description: "Agent advertising a per-skill IO-mode override",
    version: "0.1.0",
    skills: [
      %{
        id: "greet",
        name: "Greet",
        description: "Says hello",
        tags: [],
        input_modes: ["application/json"],
        output_modes: ["text/csv"]
      }
    ]

  @impl AshA2A.Protocol.Agent
  def handle_message(_message, _context) do
    {:reply, [AshA2A.Protocol.Part.Text.new("hello")]}
  end
end
defmodule AshA2A.V1IOModesTest do
  @moduledoc """
  W7 court: A2A v1.0 §4.4/5.1 input/output mode conformance for the real
  served AgentCard, over a real fixture resource's real card.

  ## What the spec REQUIRES (pinned from the authoritative
  `a2aproject/A2A` `specification/a2a.proto` @ main, AgentCard fields 10/11
  and AgentSkill fields 6/7)

  - `AgentCard.default_input_modes` / `default_output_modes`:
    `(google.api.field_behavior) = REQUIRED` -- "the set of interaction modes
    that the agent supports across all skills. This can be overridden per
    skill. Defined as media types."
  - `AgentSkill.input_modes` / `output_modes`: OPTIONAL (no REQUIRED
    annotation) -- "the set of supported input/output media types for this
    skill, overriding the agent's defaults."

  ## Spec-vs-reality summary (see per-court comments for detail)

  | spec requirement                              | ash_a2a reality                                  |
  |-----------------------------------------------|--------------------------------------------------|
  | card defaults REQUIRED                        | MET — struct defaults `["text/plain"]`, always encoded |
  | skill modes OPTIONAL, override card defaults  | MET — builder `:skills_opts` projects per-skill modes; codec emits/decodes `inputModes`/`outputModes` only when non-nil |

  No mocks: the card is built by the real `AshA2A.Info.agent_card/2` from a
  real `Ash.Resource` (`AshA2A.Test.PlugFixture.Greeter`), encoded/decoded by
  the real `AshA2A.Protocol.JSON` codec, and served by the real
  `AshA2A.Protocol.Plug` in front of real `AshA2A.Agent` /
  `AshA2A.Protocol.Agent` GenServers via a real `Plug.Test` GET.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Protocol.JSON
  alias AshA2A.Test.PlugFixture.{Greeter, GreeterAgent}

  @base_url "http://localhost:4000/a2a"

  # Real per-skill override used across the courts: keyed by the Greeter
  # skill's real capability id ("<Resource>.<action>", pinned by
  # `test/ash_a2a_plug_agent_card_test.exs`).
  @greeter_capability_id "AshA2A.Test.PlugFixture.Greeter.read"

  @greeter_skills_opts %{
    @greeter_capability_id => [
      input_modes: ["application/json"],
      output_modes: ["text/x-python"]
    ]
  }

  setup do
    # Real per-test agent name: parallel async runs never collide on the
    # globally-registered GenServer name.
    agent_name = :"greeter_agent_io_modes_#{System.unique_integer([:positive])}"
    {:ok, pid} = GreeterAgent.start_link(name: agent_name)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    %{agent: agent_name}
  end

  defp real_card do
    AshA2A.Info.agent_card(Greeter, name: "greeter_agent")
  end

  defp moded_card do
    # The real builder path (same compiled capability index the runtime
    # dispatches against), with the per-skill override supplied through the
    # builder's `:skills_opts` option.
    AshA2A.Info.agent_card(Greeter,
      name: "greeter_agent",
      skills_opts: @greeter_skills_opts
    )
  end

  defp mime_shape?(modes) do
    is_list(modes) and modes != [] and
      Enum.all?(modes, fn
        s when is_binary(s) and s != "" ->
          String.contains?(s, "/") and not String.contains?(s, "_")

        _ ->
          false
      end)
  end

  defp wire_skill_by_id(wire_card, id) do
    Enum.find(wire_card["skills"], &(&1["id"] == id))
  end

  describe "card-level defaultInputModes/defaultOutputModes (spec: REQUIRED)" do
    @tag :w7_io_modes
    test "(a) real fixture card carries present, non-empty, pinned defaults" do
      card = real_card()

      # Pinned values: the builder accepts no card-level mode opts and the
      # struct defaults to `["text/plain"]`, so this is the deterministic
      # reality of every card the real builder emits (per-skill overrides
      # ride on `:skills_opts`, not on the card defaults).
      assert card.default_input_modes == ["text/plain"]
      assert card.default_output_modes == ["text/plain"]

      # Media-type shape, not just presence.
      assert mime_shape?(card.default_input_modes)
      assert mime_shape?(card.default_output_modes)
    end

    @tag :w7_io_modes
    test "(a2) the real codec always emits both camelCase members with the same values" do
      wire = JSON.encode_agent_card(real_card(), url: @base_url)

      # The codec builds the card map with these two members unconditionally
      # (`json.ex` base map), so REQUIRED-on-the-wire holds for every card.
      assert Map.has_key?(wire, "defaultInputModes")
      assert Map.has_key?(wire, "defaultOutputModes")
      assert wire["defaultInputModes"] == ["text/plain"]
      assert wire["defaultOutputModes"] == ["text/plain"]
      assert mime_shape?(wire["defaultInputModes"])
      assert mime_shape?(wire["defaultOutputModes"])
    end
  end

  describe "per-skill inputModes/outputModes (spec: OPTIONAL override)" do
    @tag :w7_io_modes
    test "(b) the real builder projects a :skills_opts per-skill override onto the card struct" do
      card = moded_card()

      assert [%{id: @greeter_capability_id} = moded] = card.skills

      # The override reaches the real card struct under the spec field names.
      assert moded.input_modes == ["application/json"]
      assert moded.output_modes == ["text/x-python"]

      # A skill with no entry in `:skills_opts` carries no mode keys at all
      # (absent key = inherit the card defaults) — there is exactly one
      # skill in this fixture's index and it was overridden above, so pin
      # the nil-inheritance shape against a differently-keyed map instead.
      unmoded_card =
        AshA2A.Info.agent_card(Greeter,
          name: "greeter_agent",
          skills_opts: %{"no.such.skill" => [input_modes: ["application/json"]]}
        )

      Enum.each(unmoded_card.skills, fn skill ->
        refute Map.has_key?(skill, :input_modes)
        refute Map.has_key?(skill, :output_modes)
      end)

      # Card-level defaults are untouched by the per-skill override.
      assert unmoded_card.default_input_modes == ["text/plain"]
      assert unmoded_card.default_output_modes == ["text/plain"]
    end

    @tag :w7_io_modes
    test "(b2) skill keyed by declared name also resolves through :skills_opts" do
      card =
        AshA2A.Info.agent_card(Greeter,
          name: "greeter_agent",
          skills_opts: %{
            greet: [input_modes: ["text/x-python"], output_modes: ["application/json"]]
          }
        )

      assert [%{input_modes: ["text/x-python"], output_modes: ["application/json"]}] =
               card.skills
    end

    @tag :w7_io_modes
    test "(b3) codec emits skill inputModes/outputModes ONLY when non-nil, and decodes them back" do
      # Encode side: nil-mode skills produce no wire members (spec-optional
      # inheritance signal), moded skills produce exactly the override.
      plain_wire = JSON.encode_agent_card(real_card(), url: @base_url)

      Enum.each(plain_wire["skills"], fn wire_skill ->
        refute Map.has_key?(wire_skill, "inputModes")
        refute Map.has_key?(wire_skill, "outputModes")
      end)

      moded_wire = JSON.encode_agent_card(moded_card(), url: @base_url)

      assert wire_skill_by_id(moded_wire, @greeter_capability_id) == %{
               "id" => @greeter_capability_id,
               "name" => "greet",
               "description" => wire_skill_by_id(moded_wire, @greeter_capability_id)["description"],
               "tags" => wire_skill_by_id(moded_wire, @greeter_capability_id)["tags"],
               "inputModes" => ["application/json"],
               "outputModes" => ["text/x-python"]
             }

      # Decode side: the modes come back under the spec field names.
      {:ok, decoded} = JSON.decode_agent_card(moded_wire)

      assert Enum.find(decoded.skills, &(&1.id == @greeter_capability_id)) == %{
               id: @greeter_capability_id,
               name: "greet",
               description: Enum.find(decoded.skills, &(&1.id == @greeter_capability_id)).description,
               tags: Enum.find(decoded.skills, &(&1.id == @greeter_capability_id)).tags,
               input_modes: ["application/json"],
               output_modes: ["text/x-python"]
             }

      # And a card served without the override decodes without the keys --
      # absence on the wire is the inherit-the-defaults signal.
      {:ok, plain_decoded} = JSON.decode_agent_card(plain_wire)

      Enum.each(plain_decoded.skills, fn skill ->
        refute Map.has_key?(skill, :input_modes)
        refute Map.has_key?(skill, :output_modes)
      end)

      # Card-level defaults still survive both cycles unchanged.
      assert decoded.default_input_modes == ["text/plain"]
      assert decoded.default_output_modes == ["text/plain"]
    end

    @tag :w7_io_modes
    test "(b4) encode -> decode round-trips the per-skill override exactly" do
      wire = JSON.encode_agent_card(moded_card(), url: @base_url)
      {:ok, decoded} = JSON.decode_agent_card(wire)

      moded_skill = Enum.find(decoded.skills, &(&1.id == @greeter_capability_id))

      assert moded_skill.input_modes == ["application/json"]
      assert moded_skill.output_modes == ["text/x-python"]
      assert mime_shape?(moded_skill.input_modes)
      assert mime_shape?(moded_skill.output_modes)

      # Non-moded skills in the same card stay key-absent after the cycle.
      Enum.each(decoded.skills, fn skill ->
        unless skill.id == @greeter_capability_id do
          refute Map.has_key?(skill, :input_modes)
          refute Map.has_key?(skill, :output_modes)
        end
      end)
    end
  end

  describe "decode round-trip (spec: card defaults REQUIRED on the wire)" do
    @tag :w7_io_modes
    test "(c) encode -> decode preserves both card mode fields exactly on the real card" do
      card = real_card()

      wire = JSON.encode_agent_card(card, url: @base_url)
      {:ok, decoded} = JSON.decode_agent_card(wire)

      assert decoded.default_input_modes == card.default_input_modes
      assert decoded.default_output_modes == card.default_output_modes

      # Non-empty on both sides of the cycle: the decoder's own fallback is
      # `["text/plain"]` when a member is missing, so an encode-side drop
      # would be masked -- assert on the wire members too.
      assert wire["defaultInputModes"] == card.default_input_modes
      assert wire["defaultOutputModes"] == card.default_output_modes
    end
  end

  describe "explicit opts override through the real builder+codec path" do
    @tag :w7_io_modes
    test "(d) codec opts-first resolution overrides the card's mode defaults on the wire" do
      card = real_card()

      wire =
        JSON.encode_agent_card(card,
          url: @base_url,
          default_input_modes: ["application/json"],
          default_output_modes: ["text/x-python"]
        )

      assert wire["defaultInputModes"] == ["application/json"]
      assert wire["defaultOutputModes"] == ["text/x-python"]

      # The override is encode-time only: decoding the overridden wire card
      # recovers exactly the advertised modes.
      {:ok, decoded} = JSON.decode_agent_card(wire)
      assert decoded.default_input_modes == ["application/json"]
      assert decoded.default_output_modes == ["text/x-python"]
    end

    @tag :w7_io_modes
    test "(d2) the builder takes per-skill modes via :skills_opts but still no card-level mode opts" do
      # Card-level reality is unchanged: `AgentCardBuilder.build_agent_card/2`
      # still projects a fixed opt set for the card defaults (url, name,
      # description, version, skills, provider, capabilities,
      # security_schemes, security, supported_interfaces) and card-level mode
      # opts are not among them, so the struct defaults `["text/plain"]` are
      # the only card-level values the builder emits. The per-skill surface
      # (`:skills_opts`) is the one this W7 gap closure added.
      card =
        AshA2A.Info.agent_card(Greeter,
          name: "mode_probe",
          default_input_modes: ["application/json"],
          default_output_modes: ["text/x-python"],
          skills_opts: @greeter_skills_opts
        )

      assert card.default_input_modes == ["text/plain"]
      assert card.default_output_modes == ["text/plain"]

      # ...while the per-skill override in the same call took effect.
      assert Enum.find(card.skills, &(&1.id == @greeter_capability_id)).input_modes ==
               ["application/json"]
    end

    @tag :w7_io_modes
    test "(d3) struct-field override also reaches the wire without opts" do
      # The other real override surface: a card struct carrying its own mode
      # values flows through the same `card_field/4` resolution with no opts.
      card = %{real_card() | default_input_modes: ["text/x-python"], default_output_modes: ["application/json"]}

      wire = JSON.encode_agent_card(card, url: @base_url)

      assert wire["defaultInputModes"] == ["text/x-python"]
      assert wire["defaultOutputModes"] == ["application/json"]
    end
  end

  describe "wire shape served by the real Plug (camelCase, no snake_case)" do
    @tag :w7_io_modes
    test "(e) real Plug.Test GET serves camelCase mode members and no snake_case leakage", %{
      agent: agent
    } do
      plug_opts = AshA2A.Protocol.Plug.init(agent: agent, base_url: @base_url)

      conn =
        Plug.Test.conn(:get, "/.well-known/agent-card.json")
        |> AshA2A.Protocol.Plug.call(plug_opts)

      assert conn.status == 200
      served_card = Jason.decode!(conn.resp_body)

      # camelCase v1.0 members, present and non-empty on the served card.
      assert served_card["defaultInputModes"] == ["text/plain"]
      assert served_card["defaultOutputModes"] == ["text/plain"]
      assert mime_shape?(served_card["defaultInputModes"])
      assert mime_shape?(served_card["defaultOutputModes"])

      # No snake_case leakage on the wire.
      refute Map.has_key?(served_card, "default_input_modes")
      refute Map.has_key?(served_card, "default_output_modes")

      # Per-skill modes: absent on the served card too -- the fixture agent
      # declares no `:skills_opts`, so every skill inherits the card
      # defaults and the members are correctly omitted.
      Enum.each(served_card["skills"], fn wire_skill ->
        refute Map.has_key?(wire_skill, "inputModes")
        refute Map.has_key?(wire_skill, "outputModes")
      end)
    end

    @tag :w7_io_modes
    test "(e2) real Plug serves a moded agent's per-skill override on the wire" do
      # A real `AshA2A.Protocol.Agent` GenServer whose card carries a
      # per-skill override (the same skill shape the builder emits), served
      # through the real `AshA2A.Protocol.Plug` HTTP pipeline.
      agent_name = :"moded_agent_io_modes_#{System.unique_integer([:positive])}"
      {:ok, pid} = AshA2A.V1IOModesTest.ModedAgent.start_link(name: agent_name)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      plug_opts = AshA2A.Protocol.Plug.init(agent: agent_name, base_url: @base_url)

      conn =
        Plug.Test.conn(:get, "/.well-known/agent-card.json")
        |> AshA2A.Protocol.Plug.call(plug_opts)

      assert conn.status == 200
      served_card = Jason.decode!(conn.resp_body)

      assert Enum.find(served_card["skills"], &(&1["id"] == "greet")) == %{
               "id" => "greet",
               "name" => "Greet",
               "description" => "Says hello",
               "tags" => [],
               "inputModes" => ["application/json"],
               "outputModes" => ["text/csv"]
             }

      # The moded skill overrides; the card defaults remain REQUIRED and
      # present alongside it.
      assert served_card["defaultInputModes"] == ["text/plain"]
      assert served_card["defaultOutputModes"] == ["text/plain"]
    end
  end
end
