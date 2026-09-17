defmodule AshA2A.Delivery.ObanAuthority do
  @moduledoc """
  Reconstruction and live re-verification of an `AshA2A.Authority` carried
  across an `AshA2A.Delivery.Oban` job -- the two halves of closing "an
  authority admitted through Oban's deferred execution path must reflect
  LIVE broker standing (revocation, expiry) at execution time," the
  Oban-specific instance of RFC-SA2A-001's "none may regain ambient DO."

  See `AshA2A.Delivery.Oban`'s moduledoc for the full shape of the gap this
  closes. In short: `reconstruct/2` restores the enqueue-time authority
  faithfully (including its real `expires_at`, previously always dropped to
  `nil`), and `verify_live!/3` is an explicit, opt-in re-query of the
  configured `AshA2A.Authority.Broker` so a worker is not left trusting a
  frozen enqueue-time snapshot for a grant the broker may since have
  revoked.
  """

  alias AshA2A.{Authority, Authority.Grant, Identity}

  @typedoc "A typed refusal reason, matching `AshA2A.Authority.Broker.refusal/0`'s shape."
  @type refusal :: map()

  @doc """
  Reconstructs the `AshA2A.Authority` carried in a real
  `AshA2A.Delivery.Oban.payload/1` map (i.e. a real, DB-persisted `Oban.Job`'s
  `args`), restoring the ORIGINAL `expires_at` rather than always
  reconstructing an unbounded (`expires_at: nil`) authority.

  `principal` may be a raw principal value (a bare string, matching this
  repo's existing `reconstruct_authority/2` convention -- see
  `AshA2A.Test.Support.CommandWorker`) or an already-tagged
  `AshA2A.Identity.t()` of kind `:principal`.

  Returns `nil` when the payload carried no authority at all
  (`command.authority == nil` at enqueue time), exactly mirroring
  `payload/1`'s own `authority_token(nil) -> nil`.
  """
  @spec reconstruct(map(), Identity.t() | term()) :: Authority.t() | nil
  def reconstruct(%{"authority_token_id" => nil}, _principal), do: nil

  def reconstruct(%{"authority_token_id" => external} = args, principal)
      when is_binary(external) do
    Authority.new(as_principal(principal), args["capability_id"],
      token_id: raw_value(external),
      expires_at: parse_expires_at(args["authority_expires_at"])
    )
  end

  def reconstruct(_args, _principal), do: nil

  @doc """
  Re-verifies a reconstructed `authority`'s standing against the configured
  `AshA2A.Authority.Broker` -- the live counterpart to `reconstruct/2`'s
  faithful-but-static replay.

  `nil` authority in, `{:ok, nil}` out: an unauthenticated/unauthorized
  command was never a candidate for a grant, and `AshA2A.CommandBus.admit/2`
  already fails `:change`/`:external_do` closed on a `nil` authority -- this
  function does not need to invent a refusal for a case that was already
  refused downstream.

  For a real authority, refuses BEFORE re-querying the broker if
  `AshA2A.Authority.expired?/1` (already live: it compares against
  `DateTime.utc_now()` at call time, so a real restored `expires_at` that has
  since passed is caught here without ever reaching the broker). Otherwise
  re-queries `AshA2A.Authority.Grant.granted?/3` (the SAME broker the
  synchronous dispatch path consults) for `(authority.subject,
  capability_id)`: a grant the broker has since revoked, or has no record of
  at all, fails closed here rather than silently admitting on the strength
  of an enqueue-time snapshot alone.

  Options are forwarded to `AshA2A.Authority.Grant.granted?/3` (`:broker`,
  `:policy` overrides), so a caller can point this at a specific broker
  instance the same way `Grant.granted?/3` already supports.
  """
  @spec verify_live!(Authority.t() | nil, String.t(), keyword()) ::
          {:ok, Authority.t() | nil} | {:error, refusal()}
  def verify_live!(authority, capability_id, opts \\ [])

  def verify_live!(nil, _capability_id, _opts), do: {:ok, nil}

  def verify_live!(%Authority{} = authority, capability_id, opts) do
    cond do
      Authority.expired?(authority) ->
        {:error,
         %{
           reason: :authority_expired,
           detail: "authority expired before Oban perform/1 re-verified it",
           token_id: authority.token_id
         }}

      Grant.granted?(authority.subject, capability_id, opts) ->
        {:ok, authority}

      true ->
        {:error,
         %{
           reason: :authority_stale,
           detail:
             "authority no longer stands at Oban perform/1 time (revoked, or unknown to " <>
               "the configured broker) -- an enqueue-time snapshot alone does not re-grant it",
           token_id: authority.token_id
         }}
    end
  end

  defp as_principal(%Identity{kind: :principal} = identity), do: identity
  defp as_principal(value), do: Identity.principal(value)

  defp parse_expires_at(nil), do: nil

  defp parse_expires_at(iso8601) when is_binary(iso8601) do
    case DateTime.from_iso8601(iso8601) do
      {:ok, datetime, _utc_offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp parse_expires_at(_other), do: nil

  # Same reversal `AshA2A.Test.Support.CommandWorker.raw_value/1` already
  # performs for every other identity field carried on an Oban payload:
  # `AshA2A.Identity.external/1` produces `"kind:value"`, and only the raw
  # value is needed here since `Authority.new/3`'s `:token_id` opt re-tags it
  # with the correct kind itself (`Identity.runtime/1`).
  defp raw_value(external) when is_binary(external) do
    case String.split(external, ":", parts: 2) do
      [_kind, value] -> value
      [value] -> value
    end
  end
end
