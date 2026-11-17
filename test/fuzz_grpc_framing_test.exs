# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.FuzzGrpcFramingTest do
  # Seeded fuzz of the gRPC length-prefixed framing codec.
  use ExUnit.Case, async: true

  alias AshA2A.FuzzGen
  alias AshA2A.Transport.Grpc.Framing

  @iterations FuzzGen.iterations(2_000)

  defp frames(n), do: for(_ <- 1..n//1, do: FuzzGen.random_bytes(FuzzGen.int(40)))

  test "truncated header is returned as rest, never an error" do
    for n <- 0..4, h <- [<<0, 0, 0, 0, 5>>, <<1, 0, 0, 0, 5>>, <<9, 255, 255, 255, 255>>] do
      data = binary_part(h, 0, n)
      assert {:ok, [], ^data} = Framing.decode_frames(data)
    end
  end

  test "length larger than the remaining bytes is a partial frame returned whole" do
    FuzzGen.seed(1501)

    for _ <- 1..@iterations do
      payload = FuzzGen.random_bytes(1 + FuzzGen.int(64))
      cut = FuzzGen.int(byte_size(payload))
      full = Framing.encode_frame(payload)
      data = binary_part(full, 0, 5 + cut)
      assert {:ok, [], ^data} = Framing.decode_frames(data)
    end
  end

  test "regression: the declared length (not a rebound variable) sizes each chunk" do
    # An exact-length frame, a frame followed by a trailing partial frame, and a
    # frame whose payload begins with bytes that look like a different header.
    inner = <<0, 0, 0, 0, 1, 99>>
    a = Framing.encode_frame(inner)
    b = Framing.encode_frame("xy")
    assert {:ok, [^inner], ""} = Framing.decode_frames(a)
    assert {:ok, [^inner, "xy"], ""} = Framing.decode_frames(a <> b)
    part = binary_part(b, 0, 6)
    assert {:ok, [^inner], ^part} = Framing.decode_frames(a <> part)

    # a gzip-compressed frame uses the same length discipline
    gz = :zlib.gzip("hello")
    f = Framing.encode_frame(gz, compressed: true) <> Framing.encode_frame("tail")

    assert {:ok, ["hello", "tail"], ""} =
             Framing.decode_frames(f, decompress: Framing.gzip_decompressor())
  end

  test "length 2^32-1 is refused before any payload is touched" do
    data = <<0, 0xFFFFFFFF::32, "abc">>
    assert {:error, {:frame_too_large, 4_294_967_295}} = Framing.decode_frames(data)

    assert {:error, {:frame_too_large, 4_294_967_295}} =
             Framing.decode_frames(<<1, 0xFFFFFFFF::32>>, decompress: & &1)

    assert {:ok, [], <<0, 0xFFFFFFFF::32>>} =
             Framing.decode_frames(<<0, 0xFFFFFFFF::32>>, max_frame_bytes: 4_294_967_295)
  end

  test "compressed flag with no codec is refused; unknown flags are refused" do
    assert {:error, :compression_unsupported} = Framing.decode_frames(<<1, 0, 0, 0, 1, 0>>)

    for flag <- 2..255 do
      assert {:error, :bad_compressed_flag} = Framing.decode_frames(<<flag, 0, 0, 0, 0>>)
    end

    assert {:error, :decompress_failed} =
             Framing.decode_frames(<<1, 0, 0, 0, 3, "abc">>, decompress: fn _ -> raise "x" end)

    assert {:error, :decompress_failed} =
             Framing.decode_frames(<<1, 0, 0, 0, 3, "abc">>,
               decompress: Framing.gzip_decompressor()
             )

    assert {:error, :decompress_failed} =
             Framing.decode_frames(<<1, 0, 0, 0, 3, "abc">>, decompress: fn _ -> :nope end)
  end

  test "empty stream and many tiny frames" do
    assert {:ok, [], ""} = Framing.decode_frames("")
    tiny = for _ <- 1..50_000, into: <<>>, do: Framing.encode_frame("")
    assert {:ok, list, ""} = Framing.decode_frames(tiny)
    assert length(list) == 50_000
  end

  test "decode is total on random bytes and round-trips encoded frames under any chunking" do
    FuzzGen.seed(1502)

    for i <- 1..@iterations do
      data = FuzzGen.random_bytes(FuzzGen.int(64))

      case FuzzGen.run_with_deadline(fn ->
             Framing.decode_frames(data, max_frame_bytes: 1_000)
           end) do
        {:ok, {:ok, l, rest}} when is_list(l) and is_binary(rest) -> :ok
        {:ok, {:error, _}} -> :ok
        other -> flunk("iteration #{i}: #{inspect(other)} for #{inspect(data)}")
      end
    end

    for _ <- 1..div(@iterations, 4) do
      payloads = frames(1 + FuzzGen.int(6))
      stream = IO.iodata_to_binary(Enum.map(payloads, &Framing.encode_frame/1))
      {got, rest} = feed_chunked(stream)
      assert got == payloads
      assert rest == ""
    end
  end

  defp feed_chunked(stream), do: feed_chunked(stream, "", [])

  defp feed_chunked("", buf, acc), do: {acc, buf}

  defp feed_chunked(stream, buf, acc) do
    n = min(byte_size(stream), 1 + FuzzGen.int(12))
    <<chunk::binary-size(^n), rest::binary>> = stream
    {:ok, got, buf} = Framing.decode_frames(buf <> chunk)
    feed_chunked(rest, buf, acc ++ got)
  end

  test "trailers: parse_trailers is total over random text" do
    FuzzGen.seed(1503)

    for _ <- 1..@iterations do
      text = FuzzGen.random_bytes(FuzzGen.int(60))

      case FuzzGen.run_with_deadline(fn -> Framing.parse_trailers(text) end) do
        {:ok, {:ok, m}} when is_map(m) -> :ok
        {:ok, {:error, _}} -> :ok
        other -> flunk("#{inspect(other)} for #{inspect(text)}")
      end
    end
  end
end
