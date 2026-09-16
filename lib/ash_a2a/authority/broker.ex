defmodule AshA2A.Authority.Broker do
  @moduledoc """
  Behaviour for the "transport or host authority broker" that
  `AshA2A.Authority`'s own moduledoc has always named but never given a
  shape.

  `AshA2A.Authority.new/3` accepts `source: :authority_broker` as its
  default value, and `AshA2A.Authority`'s moduledoc says a struct must be
  "construct[ed] only after a transport or host authority broker has
  admitted the caller" -- but until this module, no `Broker` behaviour,
  contract, or reference implementation existed anywhere in this codebase.
  The concept was named in an atom and a sentence, never given a shape a
  caller could implement against. This module formalizes that shape.

  A `Broker` implementation is the thing that decides whether a principal
  may hold a capability at all, tracks whether a previously-issued
  authority has since been revoked, and re-verifies an authority's
  standing on demand. `AshA2A.Authority.admits?/2` and
  `AshA2A.Authority.expired?/1` remain the single source of truth for what
  an authority struct itself means once it exists; a `Broker` only decides
  whether one should be issued, should continue to stand, or should be
  torn down.

  This behaviour is additive and, as of the release that introduces it,
  unreachable from `AshA2A.CommandBus`, `AshA2A.Planning.candidate_fence/1`,
  or `AshA2A.Semantic.Admission.fence/1` -- wiring a `Broker`
  implementation into any real dispatch or admission path is explicitly
  out of scope here (see `docs/jira/v26.9.16/PRFAQ.md`, item 2). Nothing in
  this codebase calls `issue/3`, `revoke/2`, or `verify/2` yet; this module
  exists so a caller (or a future ash_a2a release) has a real contract to
  implement against instead of guessing at the `:authority_broker` atom.

  See `AshA2A.Authority.Broker.InMemory` for a single-node reference
  implementation suitable for development and tests -- explicitly NOT a
  production identity system.
  """

  alias AshA2A.{Authority, Identity}

  @typedoc """
  A typed refusal reason. Implementations should include at least a
  `:reason` atom key so callers can pattern-match without parsing a
  free-form message.
  """
  @type refusal :: map()

  @doc """
  Issues a fresh `AshA2A.Authority` for `subject` and `capability_id`.

  `subject` MUST be an `AshA2A.Identity.t()` of `kind: :principal` -- the
  same shape `AshA2A.Authority.new/3` itself requires, since a compliant
  implementation constructs its successful result via that function rather
  than by hand.

  Implementations may refuse (`{:error, refusal()}`) instead of always
  succeeding -- for example because the principal is unknown to this
  broker, the capability does not exist, or the broker's own admission
  policy declines the grant. A successful issue MUST return an
  `AshA2A.Authority.t()` built via `AshA2A.Authority.new/3`, normally with
  `source: :authority_broker` (or an implementation-specific source),
  never a struct assembled by hand outside that constructor.
  """
  @callback issue(subject :: Identity.t(), capability_id :: String.t(), opts :: keyword()) ::
              {:ok, Authority.t()} | {:error, refusal()}

  @doc """
  Revokes a previously-issued `authority`, keyed by its own `token_id`.

  After a successful revoke, a subsequent `verify/2` call against any
  authority sharing that same `token_id` MUST fail-closed (`{:error,
  refusal()}`), not merely against the exact struct passed to `revoke/2`.
  """
  @callback revoke(authority :: Authority.t(), opts :: keyword()) :: :ok | {:error, refusal()}

  @doc """
  Re-checks `authority`'s standing against this broker's real state.

  MUST fail-closed on `AshA2A.Authority.expired?/1` -- reusing that
  function, never reimplementing expiry -- and on any revocation this
  broker has recorded for the authority's `token_id`. On success, returns
  the same authority (`{:ok, authority}`) unchanged: `verify/2` observes
  standing, it does not mint new authority or extend expiry.
  """
  @callback verify(authority :: Authority.t(), opts :: keyword()) ::
              {:ok, Authority.t()} | {:error, refusal()}
end
