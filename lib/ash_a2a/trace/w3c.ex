defmodule AshA2A.Trace.W3C do
  @moduledoc """
  W3C Trace Context (traceparent / tracestate) parsing, extraction and injection.

  Pure module. `@traceparent_regex` matches the regex in `AshA2A.Dispatcher`
  (version-traceid-spanid-flags, lowercase hex); lane W11 may call
  `valid_traceparent?/1` in place of the private copy.

  Precedence: HTTP header over `message.metadata["traceparent"]`
  (see `resolve/2`).
  """

  @traceparent_regex ~r/\A[0-9a-f]{2}-[0-9a-f]{32}-[0-9a-f]{16}-[0-9a-f]{2}\z/
  @max_members 32

  @type ctx :: %{optional(:traceparent) => String.t(), optional(:tracestate) => String.t()}

  @doc "The shared traceparent regex."
  def traceparent_regex, do: @traceparent_regex

  @doc "True when `value` is a valid, non-zero, lowercase-hex traceparent."
  @spec valid_traceparent?(term) :: boolean
  def valid_traceparent?(value), do: match?({:ok, _}, parse_traceparent(value))

  @doc """
  Parse a traceparent. Version `ff` is invalid; all-zero trace/span ids are
  rejected. Version `00` must have exactly four fields; future versions may
  append `-extra` after the flags.
  """
  @spec parse_traceparent(term) ::
          {:ok, %{version: String.t(), trace_id: String.t(), span_id: String.t(), flags: String.t()}}
          | :error
  def parse_traceparent(value) when is_binary(value) do
    candidate =
      case value do
        <<"00", _::binary>> -> value
        <<v::binary-size(2), "-", _::binary>> when v != "ff" -> strip_extra(value)
        _ -> value
      end

    with true <- Regex.match?(@traceparent_regex, candidate),
         [version, trace_id, span_id, flags] <- String.split(candidate, "-"),
         true <- version != "ff",
         true <- trace_id != String.duplicate("0", 32),
         true <- span_id != String.duplicate("0", 16) do
      {:ok, %{version: version, trace_id: trace_id, span_id: span_id, flags: flags}}
    else
      _ -> :error
    end
  end

  def parse_traceparent(_), do: :error

  # Future versions (!= 00) may carry additional "-..." fields after flags.
  defp strip_extra(value) do
    case String.split(value, "-", parts: 5) do
      [v, t, s, f, _extra] -> Enum.join([v, t, s, f], "-")
      _ -> value
    end
  end

  @doc "Validate a tracestate header value (<= 32 members, valid keys/values)."
  @spec valid_tracestate?(term) :: boolean
  def valid_tracestate?(value) when is_binary(value) do
    members =
      value
      |> String.split(",")
      |> Enum.map(&String.trim(&1, " "))
      |> Enum.reject(&(&1 == ""))

    members != [] and length(members) <= @max_members and
      Enum.all?(members, &valid_member?/1) and
      unique_keys?(members)
  end

  def valid_tracestate?(_), do: false

  defp unique_keys?(members) do
    keys = Enum.map(members, fn m -> m |> String.split("=", parts: 2) |> hd() end)
    length(keys) == length(Enum.uniq(keys))
  end

  defp valid_member?(member) do
    case String.split(member, "=", parts: 2) do
      [key, val] -> valid_key?(key) and valid_value?(val)
      _ -> false
    end
  end

  defp valid_key?(key) do
    Regex.match?(~r/\A[a-z][a-z0-9_\-*\/]{0,255}\z/, key) or
      Regex.match?(~r/\A[a-z0-9][a-z0-9_\-*\/]{0,240}@[a-z][a-z0-9_\-*\/]{0,13}\z/, key)
  end

  defp valid_value?(val) do
    Regex.match?(~r/\A[\x20-\x2b\x2d-\x3c\x3e-\x7e]{0,255}[\x21-\x2b\x2d-\x3c\x3e-\x7e]\z/, val)
  end

  @doc """
  Extract trace context from a `Plug.Conn` (or any map with `:req_headers`) or
  a header list / map. Returns `%{}` when no valid traceparent is present;
  tracestate is only returned alongside a valid traceparent and when valid.
  """
  @spec extract(term) :: ctx
  def extract(%{req_headers: headers}), do: extract(headers)

  def extract(headers) when is_map(headers), do: headers |> Enum.to_list() |> extract()

  def extract(headers) when is_list(headers) do
    tp = header(headers, "traceparent")

    if is_binary(tp) and valid_traceparent?(tp) do
      ts = header(headers, "tracestate")
      base = %{traceparent: tp}
      if is_binary(ts) and valid_tracestate?(ts), do: Map.put(base, :tracestate, ts), else: base
    else
      %{}
    end
  end

  def extract(_), do: %{}

  defp header(headers, name) do
    Enum.find_value(headers, fn
      {k, v} when is_binary(k) and is_binary(v) ->
        if String.downcase(k) == name, do: v

      _ ->
        nil
    end)
  end

  @doc "Read a traceparent (and tracestate) from message metadata."
  @spec from_metadata(term) :: ctx
  def from_metadata(%{metadata: md}), do: from_metadata(md)

  def from_metadata(md) when is_map(md) do
    tp = Map.get(md, "traceparent")

    if is_binary(tp) and valid_traceparent?(tp) do
      ts = Map.get(md, "tracestate")
      base = %{traceparent: tp}
      if is_binary(ts) and valid_tracestate?(ts), do: Map.put(base, :tracestate, ts), else: base
    else
      %{}
    end
  end

  def from_metadata(_), do: %{}

  @doc "Header context wins over metadata context; no merging across sources."
  @spec resolve(ctx, ctx) :: ctx
  def resolve(header_ctx, metadata_ctx) do
    if map_size(header_ctx) > 0, do: header_ctx, else: metadata_ctx
  end

  @doc """
  Inject context into a header list (or map, returned as a map). Existing
  traceparent/tracestate headers are replaced. Invalid contexts are ignored.
  """
  @spec inject(list | map, ctx) :: list | map
  def inject(headers, ctx) when is_map(headers) do
    headers |> Enum.to_list() |> inject(ctx) |> Map.new()
  end

  def inject(headers, ctx) when is_list(headers) do
    ctx = extract([{"traceparent", Map.get(ctx, :traceparent)}, {"tracestate", Map.get(ctx, :tracestate)}])

    if map_size(ctx) == 0 do
      headers
    else
      kept =
        Enum.reject(headers, fn {k, _} ->
          String.downcase(to_string(k)) in ["traceparent", "tracestate"]
        end)

      kept ++
        [{"traceparent", ctx.traceparent}] ++
        if(ctx[:tracestate], do: [{"tracestate", ctx.tracestate}], else: [])
    end
  end
end
