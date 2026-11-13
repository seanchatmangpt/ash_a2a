defmodule AshA2A.W17TraceW3CTest do
  use ExUnit.Case, async: true

  alias AshA2A.Trace.W3C
  alias AshA2A.Protocol.Telemetry.OTel

  @tp "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"

  test "valid and invalid traceparent vectors" do
    assert {:ok, %{trace_id: "0af7651916cd43dd8448eb211c80319c", flags: "01"}} =
             W3C.parse_traceparent(@tp)

    assert {:ok, _} = W3C.parse_traceparent("cc-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01-what-the-future-will-be-like")

    for bad <- [
          "ff-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01",
          "00-00000000000000000000000000000000-b7ad6b7169203331-01",
          "00-0af7651916cd43dd8448eb211c80319c-0000000000000000-01",
          "00-0AF7651916CD43DD8448EB211C80319C-b7ad6b7169203331-01",
          "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01-extra",
          "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331",
          "",
          nil
        ] do
      assert W3C.parse_traceparent(bad) == :error, inspect(bad)
    end
  end

  test "tracestate limits" do
    assert W3C.valid_tracestate?("congo=t61rcWkgMzE,rojo=00f067aa0ba902b7")
    assert W3C.valid_tracestate?("tenant@vendor=abc")
    refute W3C.valid_tracestate?("Bad=1")
    refute W3C.valid_tracestate?("novalue")
    refute W3C.valid_tracestate?("a=1,a=2")

    ok = Enum.map_join(1..32, ",", &"k#{&1}=v")
    too_many = Enum.map_join(1..33, ",", &"k#{&1}=v")
    assert W3C.valid_tracestate?(ok)
    refute W3C.valid_tracestate?(too_many)
  end

  test "extract from conn and headers; invalid yields empty" do
    conn = Plug.Test.conn(:post, "/") |> Plug.Conn.put_req_header("traceparent", @tp) |> Plug.Conn.put_req_header("tracestate", "a=1")
    assert W3C.extract(conn) == %{traceparent: @tp, tracestate: "a=1"}
    assert W3C.extract([{"Traceparent", @tp}]) == %{traceparent: @tp}
    assert W3C.extract([{"traceparent", "junk"}, {"tracestate", "a=1"}]) == %{}
    assert W3C.extract([{"traceparent", @tp}, {"tracestate", "BAD"}]) == %{traceparent: @tp}
  end

  test "header wins over metadata" do
    other = "00-11111111111111111111111111111111-2222222222222222-00"
    meta = W3C.from_metadata(%{metadata: %{"traceparent" => other}})
    assert meta == %{traceparent: other}
    hdr = W3C.extract([{"traceparent", @tp}])
    assert W3C.resolve(hdr, meta) == hdr
    assert W3C.resolve(%{}, meta) == meta
    assert W3C.from_metadata(%{metadata: %{"traceparent" => "bad"}}) == %{}
  end

  test "inject round trip replaces existing headers" do
    ctx = %{traceparent: @tp, tracestate: "a=1"}
    headers = W3C.inject([{"x", "y"}, {"Traceparent", "old"}], ctx)
    assert {"x", "y"} in headers
    refute {"Traceparent", "old"} in headers
    assert W3C.extract(headers) == ctx
    assert W3C.inject([{"x", "y"}], %{traceparent: "bad"}) == [{"x", "y"}]
  end

  test "OTel bridge is safe whether or not the API is loaded" do
    if Code.ensure_loaded?(OpenTelemetry.Tracer) do
      assert OTel.available?()
    else
      refute OTel.available?()
      assert OTel.attach() == {:error, :opentelemetry_not_loaded}
      assert OTel.attach_remote_context([{"traceparent", @tp}]) == :ok
    end
  end
end
