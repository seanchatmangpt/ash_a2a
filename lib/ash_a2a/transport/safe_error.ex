defmodule AshA2A.Transport.SafeError do
  @moduledoc """
  Wire-safe error shaping for everything the agent/transport sends to a
  remote caller (SEC-08).

  Internal exception text (Ash framework errors, data-layer/SQL detail,
  semantic-compiler exceptions, `inspect/1` of arbitrary reasons) never
  reaches a remote caller by default. Instead the caller receives a typed
  code plus an opaque `ref`, and the full detail is logged server-side under
  that same `ref`, so an operator can correlate a caller's report with the
  log line without the caller ever seeing the internals.

  `config :ash_a2a, :expose_error_detail, true` restores verbatim detail for
  development; it defaults to `false`.
  """

  require Logger

  # Keys whose values carry free-form internal text or whole internal
  # structures (`inspect/1` output, exit reasons, receipts). `:reason` and
  # `:receipt` are produced by `AshA2A.CommandBus` refusals (e.g.
  # `:dispatch_lost` carries `reason: inspect(exit_reason)`, actuation
  # refusals carry the full `%AshA2A.Receipt{}`) and never reach the wire.
  @sensitive_keys [:detail, :exception, :stacktrace, :message, :error, :reason, :receipt]

  @doc "Whether verbatim error detail may be sent to callers (default `false`)."
  @spec expose_detail?() :: boolean()
  def expose_detail?, do: Application.get_env(:ash_a2a, :expose_error_detail, false) == true

  @doc "Fresh opaque correlation reference (16 hex chars, CSPRNG)."
  @spec new_ref() :: String.t()
  def new_ref, do: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  @doc """
  Logs `exception`/`reason` with a fresh ref and returns the typed wire error
  `%{code: code, ref: ref}` (plus `detail:` only when `expose_detail?/0`).
  """
  @spec internal(atom(), term(), list()) :: %{
          required(:code) => atom(),
          required(:ref) => String.t()
        }
  def internal(code, error, stacktrace \\ []) when is_atom(code) do
    ref = new_ref()
    detail = describe(error)

    Logger.error(
      "ash_a2a #{code} ref=#{ref}: " <>
        detail <>
        if(stacktrace == [], do: "", else: "\n" <> Exception.format_stacktrace(stacktrace))
    )

    if expose_detail?(),
      do: %{code: code, ref: ref, detail: detail},
      else: %{code: code, ref: ref}
  end

  @doc """
  Redacts a reply reason before it is rendered onto the wire.

  Typed maps keep every field except `#{inspect(@sensitive_keys)}` (nested
  values redacted recursively; non-exception structs become `:redacted`); tuples
  keep atom/number elements and Ash `:forbidden`/`:invalid` error messages
  (caller-actionable) and replace everything else with `:redacted`; atoms
  pass through; any other term becomes `:redacted`. Verbatim when
  `expose_detail?/0`.

      iex> AshA2A.Transport.SafeError.redact(%{code: :invalid_input, detail: "SELECT secret"})
      %{code: :invalid_input}

      iex> AshA2A.Transport.SafeError.redact(%{code: :dispatch_lost, reason: "{:badarg, pw}", receipt: %URI{}})
      %{code: :dispatch_lost}

      iex> AshA2A.Transport.SafeError.redact(%{code: :x, nested: %{detail: "sql", at: %URI{}}})
      %{code: :x, nested: %{at: :redacted}}

      iex> AshA2A.Transport.SafeError.redact({:skill_lookup, :skill_not_found})
      {:skill_lookup, :skill_not_found}

      iex> AshA2A.Transport.SafeError.redact({:action_resolution, "pg: relation x"})
      {:action_resolution, :redacted}
  """
  @spec redact(term()) :: term()
  def redact(reason) do
    if expose_detail?(), do: reason, else: do_redact(reason)
  end

  defp do_redact(%{__exception__: true} = error), do: actionable(error)
  defp do_redact(%{__struct__: _} = _struct), do: :redacted

  defp do_redact(%{} = reason) do
    reason
    |> Map.drop(@sensitive_keys)
    |> Map.new(fn {key, value} -> {key, redact_value(value)} end)
  end

  defp do_redact(reason) when is_atom(reason) or is_number(reason), do: reason
  defp do_redact(reason) when is_binary(reason), do: actionable_text(reason)

  defp do_redact(reason) when is_tuple(reason) do
    reason
    |> Tuple.to_list()
    |> Enum.map(fn
      value when is_atom(value) or is_number(value) -> value
      %{__exception__: true} = error -> actionable(error)
      value when is_binary(value) -> actionable_text(value)
      _value -> :redacted
    end)
    |> List.to_tuple()
  end

  defp do_redact(_reason), do: :redacted

  # Values inside a typed refusal map: server-built scalars (atoms, numbers,
  # label strings such as `capability_id`) stay; nested maps/tuples/lists are
  # redacted recursively; structs, pids, refs, funs never reach the wire.
  defp redact_value(value) when is_atom(value) or is_number(value) or is_binary(value),
    do: value

  defp redact_value(%{__exception__: true} = error), do: actionable(error)
  defp redact_value(%{__struct__: _}), do: :redacted
  defp redact_value(%{} = map), do: do_redact(map)
  defp redact_value(list) when is_list(list), do: Enum.map(list, &redact_value/1)
  defp redact_value(tuple) when is_tuple(tuple), do: do_redact(tuple)
  defp redact_value(_other), do: :redacted

  # Ash `:forbidden`/`:invalid` errors are caller-actionable (wrong input,
  # missing permission/tenant) and keep their message; every other exception
  # class (framework, data layer, unknown) is redacted.
  defp actionable(error) do
    if Ash.Error.to_class(error).class in [:forbidden, :invalid],
      do: Exception.message(error),
      else: :redacted
  rescue
    _ -> :redacted
  end

  # `AshA2A.Dispatcher` folds Ash error classes into "<class>: message"
  # strings. The caller-actionable classes keep their text; framework,
  # unknown and any unlabelled text is redacted.
  @actionable_prefixes ["forbidden: ", "invalid: ", "invalid_config: ", "not_found: "]

  defp actionable_text(text) do
    if String.starts_with?(text, @actionable_prefixes), do: text, else: :redacted
  end

  defp describe(%{__exception__: true} = exception), do: Exception.message(exception)
  defp describe(reason), do: inspect(reason, limit: 50, printable_limit: 4096)
end
