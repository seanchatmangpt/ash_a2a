# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.TransportRpcBinding.StreamAgent do
  @moduledoc false
  # Real AshA2A.Protocol.Agent GenServer whose handle_message/2 returns a lazy
  # three-part stream (no sleeps: the parts are produced as fast as pumped).
  use AshA2A.Protocol.Agent, name: "lane17-stream", description: "streams three parts"

  @impl AshA2A.Protocol.Agent
  def handle_message(_message, _context) do
    {:stream, Stream.map(1..3, fn i -> AshA2A.Protocol.Part.Text.new("part #{i}") end)}
  end
end
