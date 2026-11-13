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

    assert map["protocolVersion"] == AshA2A.Protocol.Version.protocol_version() or
             map["protocolVersion"] == nil

    assert {:ok, %AshA2A.Protocol.AgentCard{} = decoded} =
             AshA2A.Protocol.JSON.decode_agent_card(map)

    assert decoded.name == "ash_a2a"
    assert decoded.url == "http://localhost:4000"
    assert length(decoded.skills) == 7

    ids = decoded.skills |> Enum.map(& &1.id) |> Enum.sort()

    assert ids == [
             "capability_index.compile",
             "card.sign_verify",
             "codec.encode_decode",
             "plug.serve_a2a",
             "semantic.admission",
             "semantic.graphlaw",
             "semantic.graphlaw_engine"
           ]

    Enum.each(decoded.skills, fn skill ->
      assert is_binary(skill.description) and skill.description != ""
      assert skill.tags != []
      refute skill.description =~ "`"
      refute skill.description =~ "\n"
    end)

    # served-shape: every supported_interface carries the current protocol version
    Enum.each(decoded.supported_interfaces, fn iface ->
      assert iface.protocol_version == AshA2A.Protocol.Version.protocol_version()
      assert iface.protocol_binding == "JSONRPC"
    end)
  end

  test "on-disk artifact exists, parses as JSON, and round-trips" do
    assert File.exists?(@output), "run `mix ash_a2a.self_card` to generate #{@output}"

    assert {:ok, map} = @output |> File.read!() |> Jason.decode()

    assert {:ok, %AshA2A.Protocol.AgentCard{} = decoded} =
             AshA2A.Protocol.JSON.decode_agent_card(map)

    assert decoded.skills != []
    assert length(decoded.skills) == 7
  end

  test "generation is deterministic (byte-stable across two real regenerations)" do
    dir = Path.join(System.tmp_dir!(), "self_card_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    one = Path.join(dir, "one.json")
    two = Path.join(dir, "two.json")

    Mix.Tasks.AshA2a.SelfCard.run(["--output", one])
    Mix.Tasks.AshA2a.SelfCard.run(["--output", two])

    assert File.read!(one) == File.read!(two)
    assert File.read!(one) == File.read!(@output)
  end
end
