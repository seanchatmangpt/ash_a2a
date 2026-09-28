defmodule SwarmNode.JsonLogFormatterTest do
  @moduledoc "DEP-12: one JSON object per line, whitelisted metadata only."
  use ExUnit.Case, async: true

  test "formats a real logger event as one JSON line" do
    event = %{
      level: :info,
      msg: {:string, "dispatched"},
      meta: %{time: 1_790_000_000_000_000, request_id: "r-1", pid: self(), secret: "x"}
    }

    line =
      event
      |> SwarmNode.JsonLogFormatter.format(%{metadata: [:request_id]})
      |> IO.iodata_to_binary()

    assert String.ends_with?(line, "\n")
    decoded = JSON.decode!(line)

    assert %{"level" => "info", "msg" => "dispatched", "request_id" => "r-1", "time" => _} =
             decoded

    refute Map.has_key?(decoded, "secret")
    refute Map.has_key?(decoded, "pid")
  end

  test "formats format/args messages" do
    event = %{level: :warning, msg: {~c"x=~p", [42]}, meta: %{}}

    assert %{"msg" => "x=42"} =
             event
             |> SwarmNode.JsonLogFormatter.format(%{})
             |> IO.iodata_to_binary()
             |> JSON.decode!()
  end
end
