defmodule AshA2A.ToA2AError.Wire do
  @moduledoc false

  # Shared serialization helpers for the `AshA2A.ToA2AError` protocol
  # implementations at the bottom of this file. Kept in a sibling module
  # because a `defprotocol` body cannot carry ordinary function definitions,
  # and the implementations need one shared envelope/ErrorInfo builder so
  # every code is serialized with exactly the same `Error.to_map/1`
  # semantics the live transport already puts on the wire
  # (`AshA2A.Protocol.JSONRPC.Error.to_map/1`).

  alias AshA2A.Protocol.JSONRPC.Error

  @error_info_type "type.googleapis.com/google.rpc.ErrorInfo"
  @a2a_domain "a2a-protocol.org"

  # -- Envelope ----------------------------------------------------------

  @doc """
  Builds the full JSON-RPC 2.0 error response envelope for `id`, serializing
  the error through `AshA2A.Protocol.JSONRPC.Error.to_map/1` so the wire
  shape (including the `google.rpc.ErrorInfo` wrapping for A2A-specific
  codes) is byte-identical to what `AshA2A.Protocol.Plug` emits today.

  For codes in the A2A range (-32001..-32009) `data` MUST already be the
  wrapped ErrorInfo list (`error_info/2`). `to_map/1` is idempotent only for
  pre-wrapped data, and its built-in code-to-reason table stamps unwrapped
  data with a single default reason per code — but -32001 serves two distinct
  failure classes in A2A v1.0.0 (task-not-found AND policy denial), so the
  reason must be chosen by the failure class at this layer and passed
  pre-wrapped, never derived from the numeric code alone.
  """
  @spec envelope(AshA2A.Protocol.JSONRPC.Request.id(), integer(), String.t(), term()) :: map()
  def envelope(id, code, message, data) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => Error.to_map(%Error{code: code, message: message, data: data})
    }
  end

  @doc """
  Builds one `google.rpc.ErrorInfo` object (as a plain map) with an explicit
  reason string and optional caller-actionable `detail` in its metadata.
  """
  @spec error_info(String.t(), String.t() | nil) :: map()
  def error_info(reason, detail) when is_binary(reason) do
    base = %{"@type" => @error_info_type, "domain" => @a2a_domain, "reason" => reason}

    if is_binary(detail) and detail != "" do
      Map.put(base, "metadata", %{"detail" => detail})
    end || base
  end
end

defprotocol AshA2A.ToA2AError do
  @moduledoc """
  Maps a failed Ash execution outcome to an A2A JSON-RPC 2.0 error response
  envelope (`%{"jsonrpc" => "2.0", "id" => id, "error" => %{...}}`), by
  protocol dispatch on the error's own struct/class — never by matching on
  stringified messages at the call site.

  Code assignment (A2A v1.0.0, lane V3):

    * `Ash.Error.Query.NotFound` — a well-shaped primary key named a record
      that does not (or no longer) exists → `-32001` `TaskNotFoundError`,
      ErrorInfo reason `TASK_NOT_FOUND`.
    * `Ash.Error.Forbidden` (the Splode class) and `Ash.Error.Forbidden.Policy`
      (a direct policy denial) → `-32001` as well, ErrorInfo reason
      `POLICY_FORBIDDEN`. NOTE the deliberate collision: in the A2A v1.0.0
      code registry -32001 is nominally `TaskNotFoundError`, so a
      policy-denial refusal shares the numeric code with task-not-found and
      is distinguished on the wire only by the `ErrorInfo.reason`. Clients
      that switch on the bare code cannot tell the two apart; the reason
      string is the authoritative discriminator.
    * validation / invalid-argument — the `Ash.Error.Invalid` class and its
      caller-input members (`Ash.Error.Invalid.NoSuchInput`,
      `Ash.Error.Changes.InvalidArgument`, `Ash.Error.Changes.InvalidAttribute`,
      `Ash.Error.Changes.Required`) → `-32602` `InvalidParamsError` (its
      ErrorInfo carries reason `INVALID_PARAMS`, stamped by
      `Error.to_map/1`). Precondition failures such as
      `TaskNotCancelableError` are -32002, disabled push is -32003
      `PushNotificationNotSupportedError`, and missing capability /
      unsupported operation is -32004 `UnsupportedOperationError` — those
      are raised by the transport layer (`AshA2A.A2ATransport.*`), not
      mapped from Ash errors here.
    * everything else — `Any` fallback → `-32603`, with the reason logged
      server-side under an opaque `ref` (`AshA2A.Transport.SafeError.internal/3`)
      and the caller shown only `ref` (full detail restored by
      `config :ash_a2a, :expose_error_detail, true`). -32603 carries no
      ErrorInfo by design: its `data` stays ref-only/redacted.

  The envelope is built through `AshA2A.Protocol.JSONRPC.Error.to_map/1`, so
  A2A-specific codes carry a `google.rpc.ErrorInfo` object inside `"data"`
  exactly as the A2A spec requires. For the -32001 assignments above the
  ErrorInfo is built here with an explicit reason (`TASK_NOT_FOUND` /
  `POLICY_FORBIDDEN`) and passed pre-wrapped, so the reason is fixed by the
  failure class rather than by `Error.to_map/1`'s default stamp for the
  numeric code.

  ## Examples

      iex> envelope = AshA2A.ToA2AError.to_a2a_error(%Ash.Error.Forbidden{}, 7)
      iex> envelope["id"]
      7
      iex> envelope["error"]["code"]
      -32001

      iex> envelope = AshA2A.ToA2AError.to_a2a_error(%Ash.Error.Query.NotFound{}, "a")
      iex> envelope["error"]["code"]
      -32001

  """

  @fallback_to_any true

  @doc """
  Returns the JSON-RPC 2.0 error response envelope for `error`, addressed to
  JSON-RPC id `id`.
  """
  @spec to_a2a_error(t(), AshA2A.Protocol.JSONRPC.Request.id()) :: map()
  def to_a2a_error(error, id)
end

defimpl AshA2A.ToA2AError, for: Ash.Error.Query.NotFound do
  # `Ash.Error.Query.NotFound` (deps/ash/lib/ash/error/query/not_found.ex)
  # declares `class: :invalid`, so without this direct implementation it
  # would be classified -32602 by the `Ash.Error.Invalid` class impl below.
  # It is deliberately NOT: the shape of the request was fine; the record it
  # named does not exist (or was concurrently destroyed). Signaling
  # "invalid params" would tell a well-behaved A2A client to resubmit
  # identical input forever against a record that will never exist.
  #
  # A2A v1.0.0 (lane V3 remap): NotFound is -32001 `TaskNotFoundError` with
  # reason TASK_NOT_FOUND — owner-scope refusal and record-absence are the
  # same task-scoped "not found" signal at this code. -32001 is shared with
  # the policy-denial impls above (reason POLICY_FORBIDDEN); the ErrorInfo
  # reason is the discriminator, never the bare code.
  def to_a2a_error(error, id) do
    AshA2A.ToA2AError.Wire.envelope(
      id,
      -32_001,
      "Task not found",
      [AshA2A.ToA2AError.Wire.error_info("TASK_NOT_FOUND", Exception.message(error))]
    )
  end
end

defimpl AshA2A.ToA2AError, for: Ash.Error.Forbidden do
  # The Splode error class Ash returns for a failed authorization check
  # (deps/ash/lib/ash/error/forbidden.ex, `class: :forbidden`); its nested
  # `errors` list carries the policy explainers.
  def to_a2a_error(error, id) do
    AshA2A.ToA2AError.Wire.envelope(
      id,
      -32_001,
      "Forbidden",
      [AshA2A.ToA2AError.Wire.error_info("POLICY_FORBIDDEN", Exception.message(error))]
    )
  end
end

defimpl AshA2A.ToA2AError, for: Ash.Error.Forbidden.Policy do
  # A policy denial dispatched directly (not wrapped in the class struct):
  # deps/ash/lib/ash/error/forbidden/policy.ex, `class: :forbidden`.
  def to_a2a_error(error, id) do
    AshA2A.ToA2AError.Wire.envelope(
      id,
      -32_001,
      "Forbidden",
      [AshA2A.ToA2AError.Wire.error_info("POLICY_FORBIDDEN", Exception.message(error))]
    )
  end
end

defimpl AshA2A.ToA2AError, for: Ash.Error.Invalid do
  # The Splode class Ash returns for any validation failure: unknown inputs
  # (`NoSuchInput`), failed attribute casts (`InvalidAttribute`), missing
  # required arguments (`Required`), bad manual arguments
  # (`InvalidArgument`) — all nested in `errors`. Message via
  # `Exception.message/1` is caller-actionable (SafeError's `actionable/1`
  # keeps `:invalid` messages for the same reason).
  def to_a2a_error(error, id) do
    AshA2A.ToA2AError.Wire.envelope(id, -32_602, "Invalid parameters", Exception.message(error))
  end
end

defimpl AshA2A.ToA2AError, for: Ash.Error.Invalid.NoSuchInput do
  # Direct dispatch of the individual caller-input error (normally reached
  # via the `Ash.Error.Invalid` class impl above).
  def to_a2a_error(error, id) do
    AshA2A.ToA2AError.Wire.envelope(id, -32_602, "Invalid parameters", Exception.message(error))
  end
end

defimpl AshA2A.ToA2AError, for: Ash.Error.Changes.InvalidArgument do
  def to_a2a_error(error, id) do
    AshA2A.ToA2AError.Wire.envelope(id, -32_602, "Invalid parameters", Exception.message(error))
  end
end

defimpl AshA2A.ToA2AError, for: Ash.Error.Changes.InvalidAttribute do
  def to_a2a_error(error, id) do
    AshA2A.ToA2AError.Wire.envelope(id, -32_602, "Invalid parameters", Exception.message(error))
  end
end

defimpl AshA2A.ToA2AError, for: Ash.Error.Changes.Required do
  def to_a2a_error(error, id) do
    AshA2A.ToA2AError.Wire.envelope(id, -32_602, "Invalid parameters", Exception.message(error))
  end
end

defimpl AshA2A.ToA2AError, for: Any do
  # Fail-closed fallback: any term that is not one of the caller-actionable
  # Ash errors above (framework/unknown class errors, gate refusal maps,
  # tuples, atoms, arbitrary reasons) is logged server-side under a fresh
  # opaque `ref` (AshA2A.Transport.SafeError.internal/3) and the caller sees
  # only -32603 plus that ref. Detail is restored verbatim only under
  # `config :ash_a2a, :expose_error_detail, true` (SafeError.expose_detail?/0).
  def to_a2a_error(error, id) do
    wire = AshA2A.Transport.SafeError.internal(:internal_error, error)

    data =
      case Map.fetch(wire, :detail) do
        {:ok, detail} -> %{"ref" => wire.ref, "detail" => detail}
        :error -> %{"ref" => wire.ref}
      end

    AshA2A.ToA2AError.Wire.envelope(id, -32_603, "Internal error", data)
  end
end
