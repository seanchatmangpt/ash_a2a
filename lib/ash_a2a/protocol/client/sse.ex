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

    @bom <<0xEF, 0xBB, 0xBF>>

    # `pending` is the current incomplete event as reversed iodata WITHOUT a
    # (a "\n" opening the next chunk is the rest of that CRLF); `head` collects the
    # (a "\n" opening the next chunk is the rest of that CRLF); `head`
    # first bytes while they could still be a UTF-8 BOM (ignored at stream
    # start, WHATWG SSE). Per-chunk work is proportional to the chunk, so a
    # stream delivered one byte at a time is linear overall.
    @type state :: %{
            pending: iodata(),
            nl?: boolean(),
            skip_lf?: boolean(),
            head: binary() | nil
          }

    @doc """
    Creates a new SSE parser state.
    """
    @spec new() :: state()
    def new, do: %{pending: [], nl?: false, skip_lf?: false, head: ""}

    @doc """
    Feeds a chunk of data into the parser.

    Returns `{decoded_events, new_state}` where `decoded_events` is a list
    of JSON-decoded maps from complete SSE events.
    """
    @spec feed(state(), binary()) :: {[map()], state()}
    def feed(%{head: head} = state, chunk) when is_binary(chunk) and is_binary(head) do
      data = head <> chunk

      cond do
        String.starts_with?(data, @bom) ->
          feed(%{state | head: nil}, binary_part(data, 3, byte_size(data) - 3))

        byte_size(data) < 3 and String.starts_with?(@bom, data) ->
          {[], %{state | head: data}}

        true ->
          feed(%{state | head: nil}, data)
      end
    end

    def feed(state, chunk) when is_binary(chunk) do
      # SSE line terminators are LF, CRLF, or CR. A chunk ending in "\r" ends
      # its line at once; if the next chunk starts with "\n" that is the second
      # half of the same CRLF and is dropped (`skip_lf?`).
      raw = chunk

      chunk =
        if state.skip_lf? and String.starts_with?(chunk, "\n"),
          do: binary_part(chunk, 1, byte_size(chunk) - 1),
          else: chunk

      cr? =
        cond do
          raw == "" -> state.skip_lf?
          chunk == "" and raw == "\n" -> false
          true -> String.ends_with?(raw, "\r")
        end

      norm =
        chunk
        |> String.replace("\r\n", "\n")
        |> String.replace("\r", "\n")

      scan = if state.nl?, do: "\n" <> norm, else: norm

      case :binary.split(scan, "\n\n", [:global]) do
        [only] ->
          {[], %{state | skip_lf?: cr?} |> keep(only)}

        [first | rest] ->
          {complete, [last]} = Enum.split(rest, -1)
          head_event = IO.iodata_to_binary(Enum.reverse([first | state.pending]))
          events = decode_events([head_event | complete])
          {events, %{state | pending: [], nl?: false, skip_lf?: cr?} |> keep(last)}
      end
    end

    # Stores `text` as the pending tail, peeling a trailing "\n" into `nl?`.
    defp keep(state, text) do
      if String.ends_with?(text, "\n") do
        %{
          state
          | pending: [binary_part(text, 0, byte_size(text) - 1) | state.pending],
            nl?: true
        }
      else
        %{state | pending: [text | state.pending], nl?: false}
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
