defmodule AshA2A.Test.MessageHelpers do
  @moduledoc """
  Shared test-message builders. Wraps the same real `A2A.Message.new_user/1`
  and `A2A.Part.Data.new/1` calls that dispatcher tests were constructing
  inline (~20+ occurrences across `test/ash_a2a_dispatcher_*_test.exs` and
  `test/ash_a2a_test.exs`) -- no mocking, no behavior change, just removes
  textual duplication per this workspace's Chicago-style testing discipline.
  """

  @doc """
  Builds a user message containing a single `A2A.Part.Data` part wrapping
  `data`. Equivalent to:

      A2A.Message.new_user([A2A.Part.Data.new(data)])
  """
  def data_message(data) when is_map(data) do
    A2A.Message.new_user([A2A.Part.Data.new(data)])
  end

  @doc """
  Same as `data_message/1`, but merges `opts` (a map) into the resulting
  `A2A.Message` struct -- e.g. `data_message(%{foo: 1}, %{message_id: "m1"})`.
  """
  def data_message(data, opts) when is_map(data) and is_map(opts) do
    data
    |> data_message()
    |> Map.merge(opts)
  end
end
