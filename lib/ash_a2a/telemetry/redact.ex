defmodule AshA2A.Telemetry.Redact do
  @moduledoc """
  Shape-only projections of terms that are about to leave the calling
  process as observational evidence (`:telemetry` metadata, OCEL event
  bodies POSTed to an external ingest, log lines).

  Raw error terms from a dispatch (`Ash.Error.Invalid` carrying input
  values, crash banners, changeset errors, actor structs) can hold
  credentials and PII. Every function here returns a bounded summary that
  names *what kind* of thing happened without carrying *its data*:

    * `error_summary/1` -- `%{kind: atom()}` plus, where it is a type name
      rather than data, `:exception` (the exception module) or `:stage`.
    * `endpoint/1` -- a URL with userinfo, query and fragment removed.
    * `actor_id/1` -- an actor's `:id` (or identity value), never the struct.
    * `term_shape/1` -- the term's type name (`:map`, `:tuple`, ...).

  A host that genuinely needs raw error terms in its own `:telemetry`
  handlers (for example an in-VM debugger in dev) can opt back in with
  `config :ash_a2a, :telemetry_raw_errors, true`; the default is redacted.
  Redaction applies to OCEL egress unconditionally.
  """

  @typedoc "Bounded, data-free error description."
  @type summary :: %{required(:kind) => atom(), optional(atom()) => atom()}

  @doc """
  Summarizes an error reason as data-free metadata.

      iex> AshA2A.Telemetry.Redact.error_summary(:not_found)
      %{kind: :not_found}

      iex> AshA2A.Telemetry.Redact.error_summary({:unknown_skill, "secret-input"})
      %{kind: :unknown_skill}

      iex> AshA2A.Telemetry.Redact.error_summary(%{code: :dispatch_crashed, detail: "banner"})
      %{kind: :dispatch_crashed}

      iex> AshA2A.Telemetry.Redact.error_summary(%ArgumentError{message: "token=abc"})
      %{kind: :exception, exception: ArgumentError}

      iex> AshA2A.Telemetry.Redact.error_summary("free text with a password")
      %{kind: :other, shape: :binary}
  """
  @spec error_summary(term()) :: summary()
  def error_summary(%{__exception__: true, __struct__: module}),
    do: %{kind: :exception, exception: module}

  def error_summary(%{code: code}) when is_atom(code) and not is_nil(code), do: %{kind: code}
  def error_summary(%{kind: kind}) when is_atom(kind) and not is_nil(kind), do: %{kind: kind}
  def error_summary(reason) when is_atom(reason) and not is_nil(reason), do: %{kind: reason}

  def error_summary({tag, _detail}) when is_atom(tag) and not is_nil(tag), do: %{kind: tag}

  def error_summary(tuple) when is_tuple(tuple) and tuple_size(tuple) > 2 do
    case elem(tuple, 0) do
      tag when is_atom(tag) and not is_nil(tag) -> %{kind: tag}
      _ -> %{kind: :other, shape: :tuple}
    end
  end

  def error_summary(other), do: %{kind: :other, shape: term_shape(other)}

  @doc """
  Returns the error term a `:telemetry` handler should see: the redacted
  summary by default, the raw term only when the host opted in with
  `config :ash_a2a, :telemetry_raw_errors, true`.
  """
  @spec telemetry_error(term()) :: term()
  def telemetry_error(reason) do
    if Application.get_env(:ash_a2a, :telemetry_raw_errors, false) == true,
      do: reason,
      else: error_summary(reason)
  end

  @doc """
  Strips credentials and query data from a URL so it can be logged or put
  into telemetry metadata.

      iex> AshA2A.Telemetry.Redact.endpoint("https://user:token@ingest.example/p?k=secret#f")
      "https://ingest.example/p"

      iex> AshA2A.Telemetry.Redact.endpoint(nil)
      nil
  """
  @spec endpoint(String.t() | nil) :: String.t() | nil
  def endpoint(nil), do: nil

  def endpoint(url) when is_binary(url) do
    url
    |> URI.parse()
    |> Map.merge(%{userinfo: nil, query: nil, fragment: nil})
    |> URI.to_string()
  rescue
    _ -> "<unparseable-endpoint>"
  end

  def endpoint(_other), do: "<non-binary-endpoint>"

  @doc """
  An actor's identity value, never the actor itself.

      iex> AshA2A.Telemetry.Redact.actor_id(%{id: "u-1", token: "secret"})
      "u-1"

      iex> AshA2A.Telemetry.Redact.actor_id(nil)
      nil
  """
  @spec actor_id(term()) :: term()
  def actor_id(nil), do: nil
  def actor_id(%{id: id}) when is_binary(id) or is_integer(id), do: id
  def actor_id(%{value: value}) when is_binary(value), do: value
  def actor_id(%{principal: principal}), do: actor_id(principal)
  def actor_id(_other), do: nil

  @doc """
  The type name of a term, never its content.

      iex> AshA2A.Telemetry.Redact.term_shape(%{a: 1})
      :map
  """
  @spec term_shape(term()) :: atom()
  def term_shape(%{__struct__: module}) when is_atom(module), do: module
  def term_shape(term) when is_map(term), do: :map
  def term_shape(term) when is_list(term), do: :list
  def term_shape(term) when is_tuple(term), do: :tuple
  def term_shape(term) when is_binary(term), do: :binary
  def term_shape(term) when is_atom(term), do: :atom
  def term_shape(term) when is_integer(term), do: :integer
  def term_shape(term) when is_float(term), do: :float
  def term_shape(term) when is_pid(term), do: :pid
  def term_shape(term) when is_reference(term), do: :reference
  def term_shape(term) when is_function(term), do: :function
  def term_shape(_term), do: :other
end
