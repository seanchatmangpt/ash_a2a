# SPDX-FileCopyrightText: 2026 ash_a2a contributors
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Dogfood.Beam4pmAgentTest do
  @moduledoc """
  Dogfood court: ash_a2a's own client against beam4pm's live A2A agent.

  beam4pm is a separate server (`scripts/beam4pm_up.sh`); ash_a2a never
  compiles it. Needs `BEAM4PM_A2A_URL` (e.g. http://127.0.0.1:4211/a2a); when
  absent or unreachable the court prints a loud `[SKIP]` and does not assert.

  beam4pm pins an older ash_a2a (git ref 99280b85), so results are
  old-server / new-client interop: a failure is a finding, not a test bug.
  """
  use ExUnit.Case, async: false

  @moduletag :external_api
  @moduletag :serial

  alias AshA2A.Protocol.{Client, Message, Part}

  setup do
    url = System.get_env("BEAM4PM_A2A_URL")

    cond do
      is_nil(url) ->
        IO.puts("[SKIP] BEAM4PM_A2A_URL unset (run scripts/beam4pm_up.sh)")
        {:ok, url: nil}

      reachable?(url) ->
        {:ok, url: url}

      true ->
        IO.puts("[SKIP] beam4pm agent not reachable at #{url}")
        {:ok, url: nil}
    end
  end

  test "discovers beam4pm's agent card with skills", %{url: url} do
    if url do
      assert {:ok, card} = Client.discover(url)
      assert card.name == "beam4pm_a2a_agent"
      assert length(card.skills) > 0
      IO.puts("[dogfood] card: #{length(card.skills)} skills, protocol_version=#{inspect(Map.get(card, :protocol_version))}")
    end
  end

  test "sends a :read skill and decodes a result", %{url: url} do
    if url do
      msg =
        struct(Message.new_user([Part.Text.new("go")]),
          metadata: %{"skill" => "BeamPM.Ash.Resources.OcelEvent.read"}
        )

      result = Client.send_message(url, msg)
      IO.puts("[dogfood] send_message -> #{inspect(result, limit: 6, printable_limit: 200)}")
      assert {:ok, _task_or_message} = result
    end
  end

  defp reachable?(url) do
    case Req.get(url <> "/.well-known/agent-card.json", retry: false, receive_timeout: 3_000) do
      {:ok, %{status: 200}} -> true
      _ -> false
    end
  end
end
