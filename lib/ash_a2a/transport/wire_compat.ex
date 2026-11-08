defmodule AshA2A.Transport.WireCompat do
  @moduledoc """
  Wire (`A2A.*`, the `a2a` hex package structs) <-> protocol
  (`AshA2A.Protocol.*`) struct conversion at the ash_a2a boundary.

  ## Why this module exists (Q6 wire gap, lane V8-Q6-f, 2026-11-08)

  The hex `A2A.Plug` (`a2a` 0.3.0) decodes `message/send` bodies into wire
  `%A2A.Message{}` structs and hands them to the agent GenServer, but
  `AshA2A.Agent.__dispatch__/4` only matches `%AshA2A.Protocol.Message{}` ->
  typed `:invalid_message` failure; the failed protocol task then hits
  `A2A.JSONRPC.encode_send_result/2` (no clause for protocol task structs) ->
  FunctionClauseError -> empty 200 body. No conversion existed in either dep.

  ## Directionality law

  Conversion is driven by the INBOUND shape: wire in -> wire out; protocol in
  -> protocol out. In-process protocol callers (qualification Q1-Q5,
  owner-scope and proto-fidelity courts, elicitation) are unchanged; only
  `A2A.Plug`-fronted traffic sees wire structs on the way back out.

  The `a2a` hex package is NOT a dependency of ash_a2a. All wire-struct
  references stay runtime atoms (map matching on `:__struct__` plus
  `struct/2`), so this module compiles and is a no-op when `a2a` is absent,
  and activates when a host application (beam4pm) supplies the package.
  """

  alias AshA2A.Protocol.Message
  alias AshA2A.Protocol.Task

  @wire_prefix "Elixir.A2A."
  @protocol_prefix "Elixir.AshA2A.Protocol."

  # -- inbound ---------------------------------------------------------------

  @doc """
  Converts an inbound wire `%A2A.Message{}` to `%AshA2A.Protocol.Message{}`.
  Protocol messages pass through unchanged; anything else passes through
  unchanged (the `:invalid_message` dispatch clause still guards garbage).
  """
  @spec to_protocol(term()) :: term()
  def to_protocol(%Message{} = message), do: message

  def to_protocol(term), do: convert(term)

  @doc "Whether `term` is a wire-shaped `%A2A.Message{}` (runtime check)."
  @spec wire_message?(term()) :: boolean()
  def wire_message?(%{__struct__: struct_name}) when is_atom(struct_name) do
    struct_name == A2A.Message and wire_structs_loaded?()
  end

  def wire_message?(_), do: false

  # -- outbound (encode clause) ----------------------------------------------

  @doc """
  Converts an outbound reply so wire-originated requests get wire structs
  back: `{:ok, %Task{}}` -> `{:ok, %A2A.Task{}}` and `{:ok, %Message{}}` ->
  `{:ok, %A2A.Message{}}`. `{:error, reason}` replies pass through unchanged
  (the plug maps `{:error, reason}` to a JSON-RPC error with no struct
  clause needed). Other reply shapes pass through unchanged.
  """
  @spec to_wire(term()) :: term()
  def to_wire({:ok, %Task{} = task}) do
    {:ok, maybe_convert(task)}
  end

  def to_wire({:ok, %Message{} = message}) do
    {:ok, maybe_convert(message)}
  end

  def to_wire(other), do: other

  # -- internals -------------------------------------------------------------

  defp maybe_convert(value) do
    if wire_structs_loaded?(), do: convert(value), else: value
  end

  # Uniform mirror-name mapping: `A2A.X` <-> `AshA2A.Protocol.X` (the two
  # struct families are field-identical mirrors by construction).
  defp convert(%{__struct__: struct_name} = value) when is_atom(struct_name) do
    case struct_name |> Atom.to_string() |> mirrored_name() do
      ^struct_name ->
        # Same family (or a non-mirror struct): keep the struct, recurse.
        value
        |> Map.from_struct()
        |> convert_map()
        |> then(&struct(struct_name, &1))

      target ->
        if struct_available?(target) do
          value
          |> Map.from_struct()
          |> convert_map()
          |> then(&struct(target, &1))
        else
          # Host app carries the wire structs; if absent, degrade to the
          # protocol struct rather than raising.
          value
        end
    end
  end

  defp convert(%{} = map), do: convert_map(map)

  defp convert(term) when is_list(term), do: Enum.map(term, &convert/1)

  defp convert(term) when is_tuple(term), do: convert_tuple(term)

  defp convert(term), do: term

  defp convert_map(map), do: Map.new(map, fn {k, v} -> {k, convert(v)} end)

  defp convert_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&convert/1)
    |> List.to_tuple()
  end

  defp mirrored_name(<<"Elixir.A2A." <> rest::binary>>),
    do: String.to_atom(@protocol_prefix <> rest)

  defp mirrored_name(<<"Elixir.AshA2A.Protocol." <> rest::binary>>),
    do: String.to_atom(@wire_prefix <> rest)

  defp mirrored_name(name), do: name

  defp struct_available?(name) when is_atom(name) do
    Code.ensure_loaded?(name) and function_exported?(name, :__struct__, 0)
  end

  defp struct_available?(_binary_or_other), do: false

  defp wire_structs_loaded? do
    Code.ensure_loaded?(A2A.Message)
  end
end
