# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.AgentCardSizeCapTest do
  use ExUnit.Case, async: true

  alias AshA2A.CapabilityIndex.AgentCardBuilder
  alias AshA2A.Protocol.JSON

  @cap 10240
  @url "http://localhost:4000"

  defp encoded_size(card),
    do: card |> JSON.encode_agent_card(url: card.url) |> Jason.encode!() |> byte_size()

  # ASCII padding in the description grows the encoded body byte-for-byte.
  defp opts_for(target) do
    base = AgentCardBuilder.build_agent_card([], url: @url, description: "")
    pad = target - encoded_size(base)
    [url: @url, description: String.duplicate("a", pad)]
  end

  test "builder accepts a card of exactly 10240 encoded bytes" do
    opts = opts_for(@cap)
    assert {:ok, card} = AgentCardBuilder.build_agent_card_checked([], opts)
    assert encoded_size(card) == @cap
  end

  test "builder refuses a card of 10241 encoded bytes" do
    assert {:error, {:card_too_large, size}} =
             AgentCardBuilder.build_agent_card_checked([], opts_for(@cap + 1))

    assert size == @cap + 1
  end

  test "encode accepts a card of exactly 10240 encoded bytes" do
    opts = opts_for(@cap)
    card = AgentCardBuilder.build_agent_card([], opts)
    assert {:ok, map} = JSON.encode_agent_card_checked(card, url: @url)
    assert map |> Jason.encode!() |> byte_size() == @cap
  end

  test "encode refuses a card of 10241 encoded bytes" do
    card = AgentCardBuilder.build_agent_card([], opts_for(@cap + 1))
    assert {:error, {:card_too_large, size}} = JSON.encode_agent_card_checked(card, url: @url)
    assert size == @cap + 1
  end

  test "cap constant is 10240" do
    assert JSON.max_card_bytes() == @cap
  end
end
