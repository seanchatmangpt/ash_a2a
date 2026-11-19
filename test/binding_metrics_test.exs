defmodule AshA2A.BindingMetricsTest do
  use ExUnit.Case, async: false

  alias AshA2A.Protocol.Telemetry, as: T
  alias AshA2A.Telemetry.Metrics

  test "definitions carry a binding tag for request count, duration and errors" do
    reqs =
      Enum.filter(
        Metrics.definitions(),
        &(&1.event |> Enum.take(3) == [:ash_a2a, :transport, :request])
      )

    assert length(reqs) == 3
    assert Enum.all?(reqs, &(:binding in &1.tags))
  end

  test "request_span emits stop with binding and error event on failure" do
    ref = make_ref()
    me = self()
    id = "w15-#{inspect(ref)}"

    :telemetry.attach_many(
      id,
      [[:ash_a2a, :transport, :request, :stop], [:ash_a2a, :transport, :request, :error]],
      fn ev, m, meta, _ -> send(me, {ref, ev, m, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)

    for b <- [:jsonrpc, :http_json, :grpc] do
      assert :done = T.request_span(b, fn -> {:done, false} end)
      assert_receive {^ref, [:ash_a2a, :transport, :request, :error], %{count: 1}, %{binding: ^b}}

      assert_receive {^ref, [:ash_a2a, :transport, :request, :stop], %{duration: _},
                      %{binding: ^b}}
    end
  end
end
