# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Bidi.Stream do
  @moduledoc """
  The running skill's view of `AshA2A.Bidi`: the client→server direction as a
  lazy, consumer-driven input stream.

  The dispatcher's `{:stream, enum}` reply stays the output side — chunks flow
  out through the supervised pump exactly as before. `AshA2A.Bidi.open/2`
  inside `handle_message/2` plus a stream built here make the same enum
  bidirectional: while the pump pulls output chunks, each pull of the input
  stream blocks until the client delivers through the per-stream input
  endpoint (or the channel reports `:eof`/timeout). Inputs flow in only when
  the skill actually pulls — a slow or absent client parks the skill instead
  of flooding it.

  ## Options

    * `:timeout` — per-pull deadline in ms (default 30_000)
    * `:on_timeout` — `:halt` (default: end the input stream, letting the
      skill finalize its output — the enum ends normally, `wrap_stream`
      reports `:complete`, task `:completed`) or `:skip` (treat the timed-out
      pull as "no input yet" and pull again, for skills that wait forever)

  ## Example

      channel = AshA2A.Bidi.open(ctx.task_id)

      {:stream,
       AshA2A.Bidi.Stream.map_input(channel, fn input ->
         AshA2A.Protocol.Part.Text.new("echo: " <> AshA2A.Bidi.Stream.text(input))
       end)}
  """

  @default_timeout 30_000

  @doc """
  A lazy stream of client inputs. Ends on explicit close (`:eof`) — or on a
  pull timeout, per `:on_timeout`.
  """
  @spec input_stream(AshA2A.Bidi.Channel.t() | pid(), keyword()) :: Enumerable.t()
  def input_stream(channel, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    on_timeout = Keyword.get(opts, :on_timeout, :halt)

    Stream.resource(
      fn -> :ok end,
      fn acc ->
        case AshA2A.Bidi.Channel.pull(channel, timeout) do
          {:ok, input} -> {[input], acc}
          :eof -> {:halt, acc}
          :timeout when on_timeout == :halt -> {:halt, acc}
          :timeout -> {[], acc}
        end
      end,
      fn :ok -> :ok end
    )
  end

  @doc """
  One output part per pulled input: `fun` receives each client input (an
  `AshA2A.Protocol.Message`) and returns the output part (or parts) emitted
  for it.
  """
  @spec map_input(Enumerable.t() | pid(), (AshA2A.Protocol.Message.t() -> term()), keyword()) ::
          Enumerable.t()
  def map_input(channel, fun, opts \\ []) when is_function(fun, 1) do
    input_stream(channel, opts)
    |> Stream.map(fun)
    |> Stream.flat_map(fn
      parts when is_list(parts) -> parts
      part -> [part]
    end)
  end

  @doc """
  First text of a message's parts (`""` when there is none) — the common
  shape of an echo-style skill's input extraction.
  """
  @spec text(AshA2A.Protocol.Message.t()) :: String.t()
  def text(%AshA2A.Protocol.Message{parts: parts}) do
    Enum.find_value(parts, "", fn
      %AshA2A.Protocol.Part.Text{text: text} -> text
      _ -> nil
    end)
  end

  @doc "First text of an arbitrary list of parts, or `\"\"`."
  @spec text_of([AshA2A.Protocol.Part.t()]) :: String.t()
  def text_of(parts) when is_list(parts) do
    Enum.find_value(parts, "", fn
      %AshA2A.Protocol.Part.Text{text: text} -> text
      _ -> nil
    end)
  end
end
