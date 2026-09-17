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

  @typedoc "One standing grant, as `list_grants/2` reports it."
  @type grant_entry :: %{capability_id: String.t(), expires_at: DateTime.t() | nil}

  @doc """
  Lists every STANDING grant this broker currently holds for `subject` --
  the enumeration `granted?/3` cannot provide, since `granted?/3` only
  answers a single, caller-known `(subject, capability_id)` pair. Needed
  for admin tooling, audit review, and proactive expiry sweeps, none of
  which can enumerate every capability id in existence just to probe each
  one with `granted?/3`.

  Returns `{:ok, grants}` where each entry is a `grant_entry/0` -- MUST
  include only grants that are currently standing (issued, not revoked,
  not expired), the same fail-closed reading `granted?/3` uses, so a
  caller cannot mistake a torn-down or expired grant for a real one. A
  principal with zero standing grants is `{:ok, []}`, never `:error`.
  `:error` means the question itself could not be answered (the broker's
  storage is unavailable), matching `granted?/3`'s own `:unavailable`
  lookup status.

  OPTIONAL: a broker that does not implement it is treated as `:error` by
  `AshA2A.Authority.Grant.list_grants/2` (the same
  `Code.ensure_loaded?/1` + `function_exported?/3` idiom already used for
  `grant_expires_at/3`), so no third-party implementation breaks by
  gaining this callback.
  """
  @callback list_grants(subject :: Identity.t(), opts :: keyword()) ::
              {:ok, [grant_entry()]} | :error

  @optional_callbacks grant_expires_at: 3, list_grants: 2

  @typedoc "What a `granted?/3` lookup found (RFC-SA2A-002 §67 evidence)."
  @type lookup_status :: :standing | :absent | :expired | :revoked | :unavailable

  @doc false
  # Emits `[:ash_a2a, :authority, :broker, :lookup]` from inside a broker's
  # `granted?/3`, naming WHY the answer was what it was -- so a refusal caused
  # by an unavailable broker is distinguishable from one caused by an absent,
  # expired or revoked grant (RFC-SA2A-002 §12: the request must be shown to
  # have reached the broker). Observation only; returns `status`.
  @spec emit_lookup(module(), Identity.t(), String.t(), lookup_status()) :: lookup_status()
  def emit_lookup(broker, %Identity{} = subject, capability_id, status) do
    :telemetry.execute(
      [:ash_a2a, :authority, :broker, :lookup],
      %{system_time: System.system_time()},
      %{
        outcome: status,
        broker: inspect(broker),
        principal_id: subject.value,
        capability_id: capability_id
      }
    )

    status
  end
end
