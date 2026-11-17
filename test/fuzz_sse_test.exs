# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.FuzzSseTest do
  # Seeded fuzz of the SSE parser used by the client (`Client.SSE.feed/2`) and
  # of the frame shape the transports emit (`id:` + `data: <one-line JSON>`).
  use ExUnit.Case, async: true

  alias AshA2A.FuzzGen
  alias AshA2A.Protocol.Client.SSE

  @iterations FuzzGen.iterations(300)

  defp parse_whole(bytes), do: parse_chunks([bytes])

  defp parse_chunks(chunks) do
    {events, _state} =
      Enum.reduce(chunks, {[], SSE.new()}, fn chunk, {acc, st} ->
        {evs, st} = SSE.feed(st, chunk)
        {acc ++ evs, st}
      end)

    events
  end

  defp random_chunking(bytes) do
    case FuzzGen.int(3) do
      0 -> for <<b <- bytes>>, do: <<b>>
      _ -> split_random(bytes, 1 + FuzzGen.int(max(byte_size(bytes), 1)))
    end
  end

  defp split_random("", _), do: []

  defp split_random(bytes, max) do
    n = min(byte_size(bytes), 1 + FuzzGen.int(max))
    <<head::binary-size(^n), rest::binary>> = bytes
    [head | split_random(rest, max)]
  end

  # Jason cannot round-trip every extreme number; those are the JSON layer's
  # concern (fuzz_json_guard_test), not the SSE framing's.
  defp scrub(%{} = m), do: Map.new(m, fn {k, v} -> {k, scrub(v)} end)
  defp scrub(l) when is_list(l), do: Enum.map(l, &scrub/1)
  defp scrub(n) when is_integer(n) and abs(n) > 1_000_000_000_000_000_000, do: 1
  defp scrub(n) when is_float(n), do: 1.5
  defp scrub(other), do: other

  defp eol, do: FuzzGen.pick(["\n", "\r\n", "\r"])

  defp field_line(json) do
    case FuzzGen.int(8) do
      0 -> ": comment #{FuzzGen.int(99)}"
      1 -> "id: #{FuzzGen.int(1_000)}"
      2 -> "retry: #{FuzzGen.int(5_000)}"
      3 -> "event: update"
      4 -> "data:" <> json
      _ -> "data: " <> json
    end
  end

  defp random_stream do
    bom = if FuzzGen.int(6) == 0, do: "﻿", else: ""

    events =
      for _ <- 1..(1 + FuzzGen.int(6)) do
        json = Jason.encode!(FuzzGen.json_safe(FuzzGen.term(3, 3)))

        lines =
          for _ <- 1..FuzzGen.int(3)//1, do: field_line(json)

        lines = lines ++ ["data: " <> json]
        Enum.map_join(lines, &(&1 <> eol())) <> eol()
      end

    bom <> Enum.join(events)
  end

  test "parse(chunked(x)) equals parse(x) for random streams and chunkings" do
    FuzzGen.seed(1701)

    for i <- 1..@iterations do
      stream = random_stream()
      whole = parse_whole(stream)
      chunked = parse_chunks(random_chunking(stream))
      assert chunked == whole, "iteration #{i}: #{inspect(stream)}"
    end
  end

  test "parse(chunked(x)) equals parse(x) at every single split point" do
    FuzzGen.seed(1702)

    for _ <- 1..div(@iterations, 6) do
      stream = random_stream()
      whole = parse_whole(stream)

      size = byte_size(stream)

      points =
        if size <= 100,
          do: Enum.to_list(0..size),
          else: for(_ <- 1..100, do: FuzzGen.int(size + 1))

      for at <- points do
        <<a::binary-size(^at), b::binary>> = stream
        assert parse_chunks([a, b]) == whole, "split #{at} of #{inspect(stream)}"
      end
    end
  end

  test "parse(chunked(x)) equals parse(x) on hostile bytes, and nothing raises" do
    FuzzGen.seed(1703)

    for i <- 1..div(@iterations, 6) do
      bytes =
        FuzzGen.pick([
          fn -> FuzzGen.random_bytes(FuzzGen.int(200)) end,
          fn ->
            Enum.join(
              for _ <- 1..FuzzGen.int(20)//1,
                  do: FuzzGen.pick(["data: ", "\r", "\n", "{}", ":", "data:", "﻿", "\r\n"])
            )
          end,
          fn -> "data: " <> String.duplicate("x", 8_000) <> "\n\n" end,
          fn -> "data: {\"a\":" <> String.duplicate("1", 8_000) <> "}\n\n" end
        ]).()

      whole = FuzzGen.run_with_deadline(fn -> parse_whole(bytes) end)
      chunks = random_chunking(bytes)
      chunked = FuzzGen.run_with_deadline(fn -> parse_chunks(chunks) end)

      assert {:ok, w} = whole, "iteration #{i}: #{inspect(whole, limit: 4)}"
      assert {:ok, c} = chunked, "iteration #{i}: #{inspect(chunked, limit: 4)}"
      assert c == w, "iteration #{i}: #{inspect(bytes, limit: 200)}"
    end
  end

  test "the transports' frames round-trip: any JSON payload is one event, any CR/LF/CRLF" do
    FuzzGen.seed(1704)

    for _ <- 1..@iterations do
      payloads =
        for _ <- 1..(1 + FuzzGen.int(5)),
            do: %{
              "result" => scrub(FuzzGen.json_safe(FuzzGen.term(3, 3))),
              "s" => "a\nb\rc" <> <<0xE2, 0x80, 0xA8>> <> "d\r\n"
            }

      eol = eol()

      stream =
        Enum.map_join(payloads, fn p ->
          "id: #{FuzzGen.int(99)}#{eol}data: #{Jason.encode!(p)}#{eol}#{eol}" <>
            if(FuzzGen.int(3) == 0, do: ": keepalive#{eol}#{eol}", else: "")
        end)

      got = parse_chunks(random_chunking(stream))

      if got != payloads do
        bad = Enum.zip(got, payloads) |> Enum.find(fn {a, b} -> a != b end)

        flunk(
          "stream #{inspect(stream, limit: 300)} mismatch #{inspect(bad, limit: 40)} counts #{length(got)}/#{length(payloads)}"
        )
      end
    end
  end

  test "a UTF-8 BOM at the start of the stream is ignored (WHATWG SSE)" do
    assert [%{"a" => 1}] = parse_whole("﻿data: {\"a\":1}\n\n")
    assert [%{"a" => 1}] = parse_chunks(["\xEF", "\xBB", "\xBF", "data: {\"a\":1}\n\n"])
  end

  test "multi-line data is joined with newlines before decoding" do
    assert [%{"a" => 1}] = parse_whole("data: {\ndata: \"a\":\ndata: 1}\r\n\r\n")
    assert [%{"a" => 1}] = parse_whole("data:{\"a\":1}\r\r")
    assert [] = parse_whole(": only a comment\n\nretry: 5\n\nid: 3\n\n")
  end

  test "regression: a 60 KB event delivered one byte at a time is parsed in linear time" do
    stream = "data: {\"a\":\"" <> String.duplicate("x", 60_000) <> "\"}\n\n"
    chunks = for <<b <- stream>>, do: <<b>>

    assert {:ok, [%{"a" => _}]} = FuzzGen.run_with_deadline(fn -> parse_chunks(chunks) end, 5_000)
  end

  test "regression: a stream ending in CR CR delivers its last event; CRLF split across chunks is one break" do
    assert [%{"a" => 1}] = parse_chunks(["data: {\"a\":1}\r", "\r"])
    assert [%{"a" => 1}] = parse_chunks(["data: {\"a\":1}\r", "\n", "\r", "\n"])

    assert [%{"a" => 1}, %{"b" => 2}] =
             parse_chunks(["data: {\"a\":1}\r\n\r\ndata: {\"b\":2}\n\n"])
  end
end
