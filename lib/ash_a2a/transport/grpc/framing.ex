defmodule AshA2A.Transport.Grpc.Framing do
  @default_max 4 * 1024 * 1024
  @header_size 5

  @moduledoc """
  gRPC length-prefixed message codec for the A2A v1.0 gRPC binding.

  **Scope: ALIVE (wire layer).** The HTTP/2 server transport is
  `AshA2A.Transport.GRPC.Server` (cowboy via the `:grpc_server` package),
  which owns the socket, TLS and trailers. This module is the standalone,
  in-process-tested length-prefixed wire layer a host's own gRPC server (or a
  test client) can consume:

    * length-prefixed message framing: 1-byte compressed flag + 4-byte
      big-endian length + payload
    * multi-message frame splitting with a caller-owned byte buffer: a
      partial frame is returned as `rest` for the next `decode_frames/2`
      call (TCP/HTTP/2 is a byte stream, not a message stream)
    * per-message compressed-flag handling: refusal without a negotiated
      `grpc-encoding`, real decompression when the host supplies one
    * `grpc-status` / `grpc-message` trailer maps, encoded/parsed in the
      HTTP/2 trailer-block line format (`"key: value\\r\\n"`)

  The host's gRPC server owns the socket, HTTP/2 and TLS. A unary call on
  the wire is then:

      out = Framing.encode_frame(Jason.encode!(proto_json_request))
      # ... host server writes `out` over HTTP/2 and reads the response ...
      {:ok, [body], ""} = Framing.decode_frames(response_bytes)

      # trailers, on error:
      Framing.encode_trailers(Dispatch.trailers(reply))

  ## `decode_frames/2` options

    * `:max_frame_bytes` (default #{@default_max} bytes, the gRPC default
      max receive message size) bounds a single frame's declared length. A
      frame declaring more is refused `{:error, {:frame_too_large, n}}`
      before any payload bytes are consumed, so a hostile 4 GiB length
      prefix cannot force allocation.
    * `:decompress` — a 1-arity fun applied to a compressed payload. The
      host passes the fun matching its negotiated `grpc-encoding`; absent
      a fun, a compressed frame is refused `:compression_unsupported` (the
      same UNIMPLEMENTED answer a gRPC server gives an un-negotiated
      encoding).

  ## Trailer format

  Each entry is one HTTP/2 trailer line, `key: value`, CRLF-terminated, in
  the order of the input map. `grpc-status` round-trips as an integer.
  `grpc-message` is kept verbatim in-process; the host's HTTP/2 layer
  percent-encodes it on the wire per the gRPC HTTP/2 spec. A non-integer
  `grpc-status` value parses as `{:error, {:bad_grpc_status, value}}`.
  """

  @type decode_error ::
          :compression_unsupported
          | :bad_compressed_flag
          | :decompress_failed
          | {:frame_too_large, pos_integer()}

  @doc "The 5-byte gRPC frame for `payload`: flag byte + big-endian length + payload."
  def encode_frame(payload, opts \\ []) do
    flag = if Keyword.get(opts, :compressed, false), do: 1, else: 0
    payload = IO.iodata_to_binary(payload)
    <<flag::size(8), byte_size(payload)::unsigned-big-integer-size(32), payload::binary>>
  end

  def decode_frames(data, opts \\ []) do
    max = Keyword.get(opts, :max_frame_bytes, @default_max)
    decompress = Keyword.get(opts, :decompress)
    do_decode(data, max, decompress, [])
  end

  defp do_decode(<<>>, _max, _decompress, acc), do: {:ok, Enum.reverse(acc), <<>>}

  defp do_decode(data, _max, _decompress, acc) when byte_size(data) < @header_size do
    {:ok, Enum.reverse(acc), data}
  end

  defp do_decode(
         <<flag::size(8), len::unsigned-big-integer-size(32), rest::binary>> = data,
         max,
         decompress,
         acc
       ) do
    cond do
      flag == 1 and is_function(decompress, 1) ->
        with {:ok, chunk, remaining} <- take(len, rest, max),
             {:ok, plain} <- run_decompress(decompress, chunk, max) do
          do_decode(remaining, max, decompress, [plain | acc])
        else
          {:partial, _} -> {:ok, Enum.reverse(acc), data}
          other -> other
        end

      flag == 1 ->
        {:error, :compression_unsupported}

      flag != 0 ->
        {:error, :bad_compressed_flag}

      true ->
        case take(len, rest, max) do
          {:ok, chunk, remaining} -> do_decode(remaining, max, decompress, [chunk | acc])
          # A partial payload is not an error: TCP/HTTP2 is a byte stream, the
          # whole frame (header included) is returned as `rest`.
          {:partial, _} -> {:ok, Enum.reverse(acc), data}
          {:error, _} = error -> error
        end
    end
  end

  defp take(len, _rest, max) when len > max, do: {:error, {:frame_too_large, len}}

  defp take(len, rest, _max) do
    case rest do
      <<chunk::binary-size(len), remaining::binary>> -> {:ok, chunk, remaining}
      _ -> {:partial, len}
    end
  end

  # The decompressed size is bounded by `max` as well: a tiny compressed frame
  # must not inflate to an unbounded buffer. Hosts should pass
  # `gzip_decompressor/1`, which stops inflating at the bound; any other fun is
  # additionally checked after the fact.
  defp run_decompress(fun, chunk, max) do
    case fun.(chunk) do
      plain when is_binary(plain) and byte_size(plain) <= max -> {:ok, plain}
      plain when is_binary(plain) -> {:error, {:frame_too_large, byte_size(plain)}}
      {:error, _} = error -> error
      _other -> {:error, :decompress_failed}
    end
  rescue
    _ -> {:error, :decompress_failed}
  end

  @doc """
  A `:decompress` fun for `grpc-encoding: gzip` that stops inflating once the
  output exceeds `max` bytes (default #{@default_max}) and answers
  `{:error, {:frame_too_large, n}}` instead of materializing the bomb.
  """
  @spec gzip_decompressor(pos_integer()) :: (binary() -> binary() | {:error, term()})
  def gzip_decompressor(max \\ @default_max) do
    fn chunk ->
      z = :zlib.open()

      try do
        :ok = :zlib.inflateInit(z, 31)
        inflate_bounded(z, :zlib.safeInflate(z, chunk), [], 0, max)
      catch
        _, _ -> {:error, :decompress_failed}
      after
        :zlib.close(z)
      end
    end
  end

  defp inflate_bounded(z, {kind, out}, acc, size, max) do
    out = IO.iodata_to_binary(out)
    size = size + byte_size(out)

    cond do
      size > max -> {:error, {:frame_too_large, size}}
      kind == :finished -> IO.iodata_to_binary(Enum.reverse([out | acc]))
      true -> inflate_bounded(z, :zlib.safeInflate(z, []), [out | acc], size, max)
    end
  end

  def encode_trailers(trailers) when is_map(trailers) do
    Enum.map(trailers, fn {k, v} -> ["#{k}: ", to_string(v), "\r\n"] end)
  end

  def parse_trailers(data) when is_binary(data) do
    data
    |> String.split(["\r\n", "\n"])
    |> Enum.reject(&(&1 == ""))
    |> parse_lines(%{})
  end

  defp parse_lines([], acc), do: {:ok, acc}

  defp parse_lines([line | rest], acc) do
    case String.split(line, ":", parts: 2) do
      [k, v] ->
        key = String.trim(k)
        value = String.trim(v)

        case normalize_trailer(key, value) do
          {:ok, normalized} -> parse_lines(rest, Map.put(acc, key, normalized))
          error -> error
        end

      _ ->
        {:error, {:bad_trailer_line, line}}
    end
  end

  defp normalize_trailer("grpc-status", value) do
    case Integer.parse(value) do
      {int, ""} -> {:ok, int}
      _ -> {:error, {:bad_grpc_status, value}}
    end
  end

  defp normalize_trailer(_key, value), do: {:ok, value}
end
