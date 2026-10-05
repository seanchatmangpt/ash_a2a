# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SemanticExtensionTest do
  @moduledoc """
  RFC-SA2A-001 S9 -- Semantic A2A profile negotiation over the real A2A
  extension mechanism.

  Everything here runs against the real, unmodified in-repo `AshA2A.Protocol.*`
  codec: the real `AshA2A.Protocol.JSON` encoder/decoder, a real `AshA2A.Protocol.Agent` GenServer, and a
  real `AshA2A.Protocol.Plug` HTTP pipeline driven by `Plug.Test.conn/3`. No mock, no
  stub, no patched transport -- the assertions are on real encoded JSON and
  real HTTP response bodies.

  One of these tests asserts a *measured* fact about the codec (whether
  `capabilities.extensions` survives the wire). That is measured here rather
  than assumed, because `AshA2A.Semantic.Extension`'s choice of advertisement
  site depends on it and the reason must stay checkable.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Semantic.Extension
  alias AshA2A.Test.SemanticPeerFixture.PeerB

  @base_url "http://localhost:4100/a2a"

  setup do
    agent_name = :"sa2a_ext_peer_#{System.unique_integer([:positive])}"
    {:ok, pid} = PeerB.start_link(name: agent_name)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      PeerB.deconfigure(agent_name)
    end)

    %{agent: agent_name}
  end

  describe "profile identity" do
    test "the profile identifier is exactly the one the RFC names" do
      assert Extension.profile_id() == "SA2A-PROFILE-v26.9.20"
      assert Extension.profile_version() == "v26.9.20"
      assert Extension.profile_uri() == "urn:sa2a:profile:v26.9.20"
    end

    test "the capability declaration is A2A-specification shaped" do
      declaration = Extension.capability_declaration()

      assert %{uri: uri, description: description, required: required, params: params} =
               declaration

      assert uri == Extension.profile_uri()
      assert is_binary(description) and description != ""

      # Deliberately not required: a Semantic A2A agent must still answer
      # ordinary A2A traffic (S75), it simply grants it no standing.
      assert required == false
      assert params["profileId"] == Extension.profile_id()
      assert params["messageExtensionKey"] == Extension.extension_key()
    end
  end

  describe "measured constraint: where the advertisement can actually ride" do
    test "the ported encoder PRESERVES capabilities.extensions (a2a 0.3.0 semantics)" do
      card = %AshA2A.Protocol.AgentCard{
        name: "probe",
        description: "probe",
        url: @base_url,
        version: "0.1.0",
        skills: []
      }

      declaration = Extension.capability_declaration()

      encoded =
        AshA2A.Protocol.JSON.encode_agent_card(card,
          url: @base_url,
          capabilities: %{
            streaming: true,
            extensions: [
              struct(AshA2A.Protocol.AgentExtension, Map.to_list(declaration))
            ]
          }
        )

      # The real, measured behavior of `AshA2A.Protocol.JSON.encode_capabilities/1`
      # after the 0.3.0 port: `capabilities.extensions` rides the wire. The
      # encoder accepts only `%AshA2A.Protocol.AgentExtension{}` structs
      # (a plain declaration map raises FunctionClauseError), so the
      # spec-shaped declaration is carried as the struct.
      assert encoded["capabilities"]["streaming"] == true

      assert encoded["capabilities"]["extensions"] == [
               %{
                 "uri" => Extension.profile_uri(),
                 "description" => declaration.description,
                 "required" => false,
                 "params" => declaration.params
               }
             ]

      # And it makes a real JSON round trip: the decoded card carries the
      # declaration back as an `AshA2A.Protocol.AgentExtension` struct.
      {:ok, decoded} =
        encoded |> Jason.encode!() |> Jason.decode!() |> AshA2A.Protocol.JSON.decode_agent_card()

      assert [%AshA2A.Protocol.AgentExtension{} = carried] = decoded.capabilities.extensions

      assert carried.uri == Extension.profile_uri()
      assert carried.description == declaration.description
      assert carried.required == false
      assert carried.params == declaration.params
    end

    test "supportedInterfaces DOES survive a real encode/decode round trip" do
      card = %AshA2A.Protocol.AgentCard{
        name: "probe",
        description: "probe",
        url: @base_url,
        version: "0.1.0",
        skills: []
      }

      opts = Extension.advertise(url: @base_url)
      encoded = AshA2A.Protocol.JSON.encode_agent_card(card, opts)

      assert %{"protocolBinding" => "SA2A-PROFILE-v26.9.20", "protocolVersion" => "v26.9.20"} =
               Enum.find(
                 encoded["supportedInterfaces"],
                 &(&1["protocolBinding"] == Extension.profile_id())
               )

      # Round trip through the real JSON codec, exactly as a remote peer
      # fetching the card over HTTP would.
      {:ok, decoded} =
        encoded |> Jason.encode!() |> Jason.decode!() |> AshA2A.Protocol.JSON.decode_agent_card()

      assert Extension.advertised?(decoded)
    end

    test "advertise/1 preserves the default JSONRPC interface and is idempotent" do
      once = Extension.advertise(url: @base_url)
      twice = Extension.advertise(once)

      assert Keyword.fetch!(once, :supported_interfaces) ==
               Keyword.fetch!(twice, :supported_interfaces)

      bindings =
        once |> Keyword.fetch!(:supported_interfaces) |> Enum.map(& &1.protocol_binding)

      assert "JSONRPC" in bindings
      assert Extension.profile_id() in bindings
    end
  end

  describe "the advertisement over a real AshA2A.Protocol.Plug HTTP pipeline" do
    test "a real GET to the agent-card path serves the SA2A profile advertisement", %{
      agent: agent
    } do
      plug_opts =
        AshA2A.Protocol.Plug.init(
          agent: agent,
          base_url: @base_url,
          agent_card_opts: Extension.advertise(url: @base_url)
        )

      conn =
        Plug.Test.conn(:get, "/.well-known/agent-card.json")
        |> AshA2A.Protocol.Plug.call(plug_opts)

      assert conn.status == 200
      served = Jason.decode!(conn.resp_body)

      assert Extension.advertised?(served)

      {:ok, card} = AshA2A.Protocol.JSON.decode_agent_card(served)
      assert Extension.advertised?(card)
    end

    test "an agent that does NOT advertise serves a card with no SA2A binding", %{agent: agent} do
      plug_opts = AshA2A.Protocol.Plug.init(agent: agent, base_url: @base_url)

      conn =
        Plug.Test.conn(:get, "/.well-known/agent-card.json")
        |> AshA2A.Protocol.Plug.call(plug_opts)

      served = Jason.decode!(conn.resp_body)
      refute Extension.advertised?(served)
    end
  end

  describe "negotiate/2 requires BOTH peers (S9)" do
    setup do
      advertising =
        AshA2A.Protocol.JSON.encode_agent_card(
          %AshA2A.Protocol.AgentCard{
            name: "a",
            description: "a",
            url: @base_url,
            version: "1",
            skills: []
          },
          Extension.advertise(url: @base_url)
        )

      plain =
        AshA2A.Protocol.JSON.encode_agent_card(
          %AshA2A.Protocol.AgentCard{
            name: "b",
            description: "b",
            url: @base_url,
            version: "1",
            skills: []
          },
          url: @base_url
        )

      {:ok, advertising_card} = AshA2A.Protocol.JSON.decode_agent_card(advertising)
      {:ok, plain_card} = AshA2A.Protocol.JSON.decode_agent_card(plain)

      %{advertising: advertising_card, plain: plain_card}
    end

    test "both advertising negotiates", %{advertising: card} do
      assert {:ok, "SA2A-PROFILE-v26.9.20"} = Extension.negotiate(card, card)
    end

    test "remote silent refuses with :unsupported_profile", %{
      advertising: advertising,
      plain: plain
    } do
      assert {:error, %{code: :unsupported_profile, detail: detail}} =
               Extension.negotiate(advertising, plain)

      assert detail =~ "remote peer"
    end

    test "local silent refuses with :unsupported_profile", %{
      advertising: advertising,
      plain: plain
    } do
      assert {:error, %{code: :unsupported_profile, detail: detail}} =
               Extension.negotiate(plain, advertising)

      assert detail =~ "local peer"
    end

    test "neither advertising refuses", %{plain: plain} do
      assert {:error, %{code: :unsupported_profile}} = Extension.negotiate(plain, plain)
    end
  end

  describe "ordinary A2A traffic is NEVER silently semantic" do
    test "a plain text message is not activated" do
      refute Extension.activated?(AshA2A.Protocol.Message.new_user("place an order"))
    end

    test "a message whose text happens to be Turtle is still not activated" do
      turtle = "@prefix ex: <http://example.org/> .\nex:a ex:p ex:b .\n"
      refute Extension.activated?(AshA2A.Protocol.Message.new_user(turtle))
    end

    test "a message carrying some OTHER A2A extension is not activated" do
      message = %{AshA2A.Protocol.Message.new_user("hi") | extensions: %{"some-other-ext" => %{"x" => 1}}}
      refute Extension.activated?(message)
      assert {:error, %{code: :profile_not_activated}} = Extension.payload(message)
    end

    test "activate/1 marks a message and preserves other extensions" do
      message =
        %{AshA2A.Protocol.Message.new_user("hi") | extensions: %{"other" => %{"keep" => true}}}
        |> Extension.activate(%{"profile" => Extension.profile_id()})

      assert Extension.activated?(message)
      assert message.extensions["other"] == %{"keep" => true}
      assert {:ok, %{"profile" => "SA2A-PROFILE-v26.9.20"}} = Extension.payload(message)
    end

    test "activation survives a real AshA2A.Protocol.JSON message encode/decode round trip" do
      message =
        Extension.activate(AshA2A.Protocol.Message.new_user("hi"), %{"profile" => Extension.profile_id()})

      {:ok, encoded} = AshA2A.Protocol.JSON.encode(message)
      {:ok, decoded} = encoded |> Jason.encode!() |> Jason.decode!() |> AshA2A.Protocol.JSON.decode(:message)

      assert Extension.activated?(decoded)
      assert {:ok, %{"profile" => "SA2A-PROFILE-v26.9.20"}} = Extension.payload(decoded)
    end
  end
end
