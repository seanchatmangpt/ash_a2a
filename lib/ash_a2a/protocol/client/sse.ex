if Code.ensure_loaded?(Req) do
  defmodule AshA2A.Protocol.Client.SSE do
    @moduledoc false

    # Pure stateful SSE line parser for consuming Server-Sent Events streams.
    #
    # Accumulates incoming chunks, splits on double-newline event boundaries,
    # extracts `data:` lines, and JSON-decodes each complete event.
    #
    # ## Usage
    #
    #     state = AshA2A.Protocol.Client.SSE.new()
    #     {events, state} = AshA2A.Protocol.Client.SSE.feed(state, chunk)

    @type state :: %{buffer: String.t()}

    @doc """
    Creates a new SSE parser state.
    """
    @spec new() :: state()
    def new, do: %{buffer: ""}

    @doc """
    Feeds a chunk of data into the parser.

    Returns `{decoded_events, new_state}` where `decoded_events` is a list
    of JSON-decoded maps from complete SSE events.
    """
    @spec feed(state(), binary()) :: {[map()], state()}
    def feed(state, chunk) when is_binary(chunk) do
      # SSE line terminators are LF, CRLF, or CR. Normalize CR variants to LF
      # before splitting, but hold a trailing "\r" back: a chunk boundary
      # between "\r" and "\n" must not manufacture an event break early.
      buffer = normalize_newlines(state.buffer <> chunk)
      {events, rest} = extract_events(buffer)
      decoded = decode_events(events)
      {decoded, %{state | buffer: rest}}
    end

    defp normalize_newlines(""), do: ""

    defp normalize_newlines(buffer) do
      {body, trail} =
        if String.ends_with?(buffer, "\r") do
          {binary_part(buffer, 0, byte_size(buffer) - 1), "\r"}
        else
          {buffer, ""}
        end

      body
      |> String.replace("\r\n", "\n")
      |> String.replace("\r", "\n")
      |> Kernel.<>(trail)
    end

    # Split buffer on double-newline boundaries. The last segment is
    # always kept as the remaining buffer (it may be incomplete).
    defp extract_events(buffer) do
      case String.split(buffer, "\n\n") do
        [incomplete] -> {[], incomplete}
        parts -> {Enum.slice(parts, 0..-2//1), List.last(parts)}
      end
    end

    # Extract `data:` lines from each raw event block, join them, and
    # JSON-decode. Non-data lines (event:, id:, retry:, comments) are ignored.
    defp decode_events(raw_events) do
      Enum.flat_map(raw_events, fn raw ->
        data =
          raw
          |> String.split("\n")
          |> Enum.filter(&String.starts_with?(&1, "data:"))
          |> Enum.map_join("\n", fn "data:" <> rest -> String.trim_leading(rest, " ") end)

        case Jason.decode(data) do
          {:ok, decoded} -> [decoded]
          {:error, _} -> []
        end
      end)
    end
  end
end
