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

  This behaviour IS now reachable from the real, default `AshA2A.Agent`
  dispatch path: `AshA2A.Agent.build_command/4` calls
  `AshA2A.Authority.Grant.authorize/3`, which calls `granted?/3` on the
  configured broker to decide whether the authenticated principal may hold
  the caller-supplied capability at all, before any authority struct reaches
  `AshA2A.CommandBus.admit/2`. (Earlier releases described this behaviour as
  deliberately unreachable; that is no longer true, and the unreachability
  was itself the RFC-SA2A-001 S29 escalation -- see
  `AshA2A.Authority.Grant`.) `AshA2A.Planning.candidate_fence/1` and
  `AshA2A.Semantic.Admission.fence/1` remain unwired.

  See `AshA2A.Authority.Broker.InMemory` for a single-node reference
  implementation suitable for development and tests -- explicitly NOT a
  production identity system -- and `AshA2A.Authority.Broker.Ekv` for a
  durable one.
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

  @doc """
  Answers whether this broker holds a STANDING grant of `capability_id` to
  `subject` right now: one previously issued through `issue/3` under
  `AshA2A.Authority.grant_token_id(subject, capability_id)`, and not since
  revoked through `revoke/2`.

  This is a pure read of state the implementation already keeps for
  `issue/3`/`revoke/2` -- it must never issue, mint, or record anything. It
  is the question the real dispatch path asks
  (`AshA2A.Authority.Grant.authorize/3`), and it must FAIL CLOSED: return
  `false` for an unknown subject, an unknown capability, a revoked grant, or
  any storage/transport error the implementation cannot resolve. Returning
  `true` on uncertainty reintroduces exactly the RFC-SA2A-001 S29 escalation
  this callback exists to close.

  `issue/3` is deliberately not usable as a substitute: it has a real
  recording side effect and is not idempotent (a second `issue/3` under the
  same token id refuses with `:token_id_taken`), so calling it per dispatch
  would both mutate broker state on every request and refuse every retry.
  """
  @callback granted?(subject :: Identity.t(), capability_id :: String.t(), opts :: keyword()) ::
              boolean()

  @doc """
  The `expires_at` of the standing grant `granted?/3` would answer `true` for,
  so the authority synthesized on the dispatch path can carry the grant's real
  time bound instead of being silently permanent.

  `{:ok, nil}` means a standing grant with no time bound. `:error` means no
  standing grant (or an unanswerable question) -- the same fail-closed reading
  `granted?/3` uses.

  OPTIONAL: a broker that does not implement it is treated as `{:ok, nil}`,
  which is exactly the pre-existing behaviour, so no third-party implementation
  breaks. Implementing it is what makes `Authority.admits?/2`'s own
  `not expired?(authority)` check reachable on the real dispatch path --
  defence in depth behind `granted?/3`, which is where expiry is actually
  enforced.
  """
  @callback grant_expires_at(
              subject :: Identity.t(),
              capability_id :: String.t(),
              opts :: keyword()
            ) :: {:ok, DateTime.t() | nil} | :error

  @optional_callbacks grant_expires_at: 3
end
