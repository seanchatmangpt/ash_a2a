defmodule AshA2a.SelfCardTest do
  @moduledoc """
  Real-run court for the self agent card: builds the card from the compiled
  capability surface, encodes it with the shipped codec, and round-trips the
  on-disk artifact through `AshA2A.Protocol.JSON.decode_agent_card/1`.
  """

  use ExUnit.Case, async: false

  @output "priv/sa2a/self-agent-card.json"

  test "generated card decodes through the shipped codec (round-trip)" do
    card = Mix.Tasks.AshA2a.SelfCard.build_self_card()

    map = AshA2A.Protocol.JSON.encode_agent_card(card, url: card.url)

    assert %{} = map
    assert map["protocolVersion"] == "1.0" or map["protocolVersion"] == nil

    assert {:ok, %AshA2A.Protocol.AgentCard{} = decoded} =
             AshA2A.Protocol.JSON.decode_agent_card(map)

    assert decoded.name == "ash_a2a"
    assert decoded.url == "http://localhost:4000"
    assert length(decoded.skills) == 4

    ids = decoded.skills |> Enum.map(& &1.id) |> Enum.sort()
    assert ids == ["capability_index.compile", "card.sign_verify", "codec.encode_decode", "plug.serve_a2a"]

    Enum.each(decoded.skills, fn skill ->
      assert is_binary(skill.description) and skill.description != ""
      assert skill.tags != []
    end)

    # served-shape v1.0: every supported_interface carries protocolVersion 1.0
    Enum.each(decoded.supported_interfaces, fn iface ->
      assert iface.protocol_version == "1.0"
      assert iface.protocol_binding == "JSONRPC"
    end
    )
  end

  test "on-disk artifact exists, parses as JSON, and round-trips" do
    assert File.exists?(@output), "run `mix ash_a2a.self_card` to generate #{@output}"

    assert {:ok, map} = @output |> File.read!() |> Jason.decode()

    assert {:ok, %AshA2A.Protocol.AgentCard{} = decoded} =
             AshA2A.Protocol.JSON.decode_agent_card(map)

    assert decoded.skills != []
    assert length(decoded.skills) == 4
  end

  test "generation is deterministic (byte-stable on regeneration)" do
    before = File.read!(@output)

    Mix.Tasks.AshA2a.SelfCard.run(["--output", "priv/sa2a/self-agent-card.json.tmp"])

    after_ = File.read!("priv/sa2a/self-agent-card.json.tmp")
    File.rm("priv/sa2a/self-card.tmp")
    File.rm("priv/sa2a/self-agent-card.json.tmp")

    assert before == self_card_regenerated()
  end

  defp self_card_regenerated do
    Mix.Tasks.AshA2a.SelfCard.run(["--output", "priv/sa2a/self-agent-card.json.tmp"])
    body = File.read!("priv/sa2a/self-agent-card.json.tmp")
    File.rm("priv/sa2a/self-agent-card.json.tmp")
    body
  end
end
