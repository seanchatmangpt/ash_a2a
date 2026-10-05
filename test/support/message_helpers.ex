# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Test.MessageHelpers do
  @moduledoc """
  Shared test-message builders. Wraps the same real `AshA2A.Protocol.Message.new_user/1`
  and `AshA2A.Protocol.Part.Data.new/1` calls that dispatcher tests were constructing
  inline (~20+ occurrences across `test/ash_a2a_dispatcher_*_test.exs` and
  `test/ash_a2a_test.exs`) -- no mocking, no behavior change, just removes
  textual duplication per this workspace's Chicago-style testing discipline.
  """

  @doc """
  Builds a user message containing a single `AshA2A.Protocol.Part.Data` part wrapping
  `data`. Equivalent to:

      AshA2A.Protocol.Message.new_user([AshA2A.Protocol.Part.Data.new(data)])
  """
  def data_message(data) when is_map(data) do
    AshA2A.Protocol.Message.new_user([AshA2A.Protocol.Part.Data.new(data)])
  end

  @doc """
  Same as `data_message/1`, but merges `opts` (a map) into the resulting
  `AshA2A.Protocol.Message` struct -- e.g. `data_message(%{foo: 1}, %{message_id: "m1"})`.
  """
  def data_message(data, opts) when is_map(data) and is_map(opts) do
    data
    |> data_message()
    |> Map.merge(opts)
  end
end
