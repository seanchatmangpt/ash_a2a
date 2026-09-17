defmodule AshA2A.Authority.Broker.Ekv do
  @moduledoc """
  Durable, single-node-or-cluster reference implementation of
  `AshA2A.Authority.Broker`, backed by the same real, on-disk `EKV` instance
  (`:ekv`, hex `~> 0.4`) already integrated for
  `AshA2A.ReceiptStore.Ekv` (`lib/ash_a2a/receipt_store/ekv.ex`) -- not a new
  Postgres/Ecto dependency. This library is deliberately a "pure library"
  with no owned production database (see `swarm/Dockerfile`'s own comments
  and `test/support/repo.ex`, which is explicitly test-only); introducing
  Postgres/Ecto ownership here would be architecturally wrong. Reusing the
  already-integrated `:ekv` dependency, and its exact `EKV.get/EKV.put`
  `if_vsn:` CAS idiom from `AshA2A.ReceiptStore.Ekv`, is the real, consistent
  choice.

  Where `AshA2A.Authority.Broker.InMemory` keeps issued/revoked token ids in
  one `GenServer`'s process state -- gone the moment that process or its BEAM
  node dies -- this module keeps per-`token_id` revocation state in a real
  `EKV` entry on disk, keyed by `Identity.external(authority.token_id)`. That
  state survives both a process restart (a fresh `EKV.get`/`EKV.put` against
  the same `data_dir` sees the same entry) and a real node restart, which is
  the concrete advantage over `InMemory` this module exists to provide.

  Like `AshA2A.ReceiptStore.Ekv`, this module does not start or supervise
  `EKV` itself -- a real, already-running `EKV` instance under the configured
  `:name` must already exist (started via a supervision tree, or
  `start_supervised!/1` in tests) before `issue/3`, `revoke/2`, or `verify/2`
  are called. Every call accepts a `:name` option (default `__MODULE__`),
  matching the same named-process convention `InMemory` and
  `AshA2A.ReceiptStore.Ekv` both already use, so more than one independently
  configured `Ekv` broker can run against distinct `EKV` instances without
  colliding on revocation state.

  NOT Sybil-resistant. NOT distributed identity issuance. Exactly like
  `InMemory`, this module has no notion of a principal being who they claim
  to be beyond whatever the caller already decided before invoking `issue/3`,
  and it has no way to detect one real actor presenting as many distinct
  principals -- Sybil-resistant identity issuance across untrusted,
  decentralized participants is a genuinely unsolved, published-
  impossible-in-general problem (Douceur, "The Sybil Attack," IPTPS 2002).
  "Durable" here means exactly one thing: previously recorded issue/revoke
  state for a `token_id` survives a process or node restart. It does not mean
  this broker is a trustworthy identity source, and it must never be read
  that way -- the identity/principal question is entirely out of scope,
  exactly as `InMemory`'s own moduledoc says of itself.

  `issue/3`, `revoke/2`, and `verify/2` reuse `AshA2A.Authority.new/3` and
  `AshA2A.Authority.expired?/1` exactly as `InMemory` does -- this module
  reimplements neither authority construction nor expiry logic, only durable
  storage of issue/revoke state.
  """

  @behaviour AshA2A.Authority.Broker

  alias AshA2A.{Authority, Identity}

  # Revocation's terminal state (`status: :revoked`) is the same regardless
  # of which racing attempt wins the CAS -- unlike
  # `AshA2A.ReceiptStore.Ekv.claim/2`, which has a definite alternative
  # terminal state (`:command_conflict`) for a losing racer to land on
  # instead. A revoke racer that loses a CAS round simply re-reads the
  # current entry and retries the exact same write it already intended,
  # bounded here so a pathological, unceasing write storm on one `token_id`
  # fails closed with a typed refusal instead of looping forever.
  @max_cas_attempts 10

  @impl AshA2A.Authority.Broker
  @spec issue(Identity.t(), String.t(), keyword()) ::
          {:ok, Authority.t()} | {:error, AshA2A.Authority.Broker.refusal()}
  def issue(%Identity{kind: :principal} = subject, capability_id, opts \\ [])
      when is_binary(capability_id) do
    authority =
      Authority.new(subject, capability_id, Keyword.put_new(opts, :source, :authority_broker))

    name = ekv_name(opts)
    key = Identity.external(authority.token_id)
    # `expires_at` is stored, not discarded: without it the durable record
    # cannot represent a time-bounded grant at all, so `granted?/3` below
    # could never enforce one and an hour-expired grant still authorized a
    # real `:external_do` actuation.
    #
    # `subject` is stored too, added for `list_grants/2`: the key itself is
    # `Authority.grant_token_id/2`, a one-way SHA256 hash of
    # `{subject.value, capability_id}` -- it cannot be reversed back into a
    # subject to answer "every grant this principal holds" by inspecting
    # keys alone. A durable entry written before this field existed simply
    # has no `:subject` key and is invisible to `list_grants/2` (though
    # `granted?/3`/`verify/2`, which key directly on `token_id`, are
    # unaffected) -- the same forward-compatible-only trade-off
    # `grant_expires_at/3`'s own `Map.get(entry, :expires_at)` already makes
    # for entries written before that field existed.
    entry = %{
      status: :issued,
      capability_id: capability_id,
      expires_at: authority.expires_at,
      subject: Identity.external(subject)
    }

    # Insert-if-absent CAS (`if_vsn: nil`), the same idiom
    # `AshA2A.ReceiptStore.Ekv.attempt_fresh_claim/3` uses for a fresh
    # command id: only one `if_vsn: nil` put wins for a given key. A losing
    # `issue/3` here means the caller-supplied (or, vanishingly unlikely for
    # the default `Ash.UUIDv7.generate()` token_id, freshly generated)
    # `token_id` was already durably recorded by a prior real `issue/3` --
    # the same `:token_id_taken` refusal shape `InMemory` returns for its own
    # in-process equivalent.
    case EKV.put(name, key, entry, if_vsn: nil) do
      {:ok, _vsn} ->
        {:ok, authority}

      {:error, reason} when reason in [:conflict, :unconfirmed] ->
        {:error, %{reason: :token_id_taken, token_id: authority.token_id}}
    end
  end

  @impl AshA2A.Authority.Broker
  @spec revoke(Authority.t(), keyword()) :: :ok | {:error, AshA2A.Authority.Broker.refusal()}
  def revoke(%Authority{} = authority, opts \\ []) do
    name = ekv_name(opts)
    key = Identity.external(authority.token_id)
    mark_revoked(name, key, authority.token_id, 0)
  end

  @impl AshA2A.Authority.Broker
  @spec verify(Authority.t(), keyword()) ::
          {:ok, Authority.t()} | {:error, AshA2A.Authority.Broker.refusal()}
  def verify(%Authority{} = authority, opts \\ []) do
    cond do
      # Reuses `AshA2A.Authority.expired?/1` -- never reimplemented here,
      # exactly as `AshA2A.Authority.Broker`'s own `@callback` doc requires.
      Authority.expired?(authority) ->
        {:error, %{reason: :expired, token_id: authority.token_id}}

      revoked?(ekv_name(opts), Identity.external(authority.token_id)) ->
        {:error, %{reason: :revoked, token_id: authority.token_id}}

      true ->
        {:ok, authority}
    end
  end

  @impl AshA2A.Authority.Broker
  @spec granted?(Identity.t(), String.t(), keyword()) :: boolean()
  def granted?(%Identity{kind: :principal} = subject, capability_id, opts \\ [])
      when is_binary(capability_id) do
    key = Identity.external(Identity.runtime(Authority.grant_token_id(subject, capability_id)))

    # A pure read of the exact durable entry `issue/3` writes
    # (`%{status: :issued, capability_id: capability_id}`) and `revoke/2`
    # rewrites (`status: :revoked`). `capability_id` is re-checked against the
    # stored entry as well as being folded into the key, so a grant durably
    # recorded for a different capability can never satisfy this one even if
    # the key derivation were ever weakened.
    # Expiry is enforced HERE, not only in `verify/2`: `granted?/3` is the
    # only callback the real dispatch path asks, so an expiry honoured
    # elsewhere is an expiry never enforced on a real request.
    #
    # An entry written before this fix has no `:expires_at` key at all;
    # `Map.get/2` yields `nil`, which reads as "no time bound" -- the exact
    # behaviour that entry was issued under, so an existing durable grant
    # keeps working rather than silently becoming unusable.
    status =
      case EKV.get(ekv_name(opts), key) do
        %{status: :issued, capability_id: ^capability_id} = entry ->
          if past?(Map.get(entry, :expires_at)), do: :expired, else: :standing

        %{status: :revoked} ->
          :revoked

        _other ->
          :absent
      end

    AshA2A.Authority.Broker.emit_lookup(__MODULE__, subject, capability_id, status) == :standing
  rescue
    # A stopped EKV instance RAISES (its reader connections live in
    # `:persistent_term`, erased on shutdown -> `ArgumentError`) rather than
    # exiting. Uncaught, that crashed the calling `A2A.Agent` process on the
    # dispatch path instead of refusing (RFC-SA2A-002 §67/§130, court
    # SA2A-AUTH-GRANT-008).
    _exception ->
      AshA2A.Authority.Broker.emit_lookup(__MODULE__, subject, capability_id, :unavailable)
      false
  catch
    # An EKV instance that is not running, or any other storage failure, is
    # an unanswerable grant question -- refuse, never admit.
    :exit, _reason ->
      AshA2A.Authority.Broker.emit_lookup(__MODULE__, subject, capability_id, :unavailable)
      false
  end

  @impl AshA2A.Authority.Broker
  @spec grant_expires_at(Identity.t(), String.t(), keyword()) ::
          {:ok, DateTime.t() | nil} | :error
  def grant_expires_at(%Identity{kind: :principal} = subject, capability_id, opts \\ [])
      when is_binary(capability_id) do
    key = Identity.external(Identity.runtime(Authority.grant_token_id(subject, capability_id)))

    case EKV.get(ekv_name(opts), key) do
      %{status: :issued, capability_id: ^capability_id} = entry ->
        expires_at = Map.get(entry, :expires_at)
        if past?(expires_at), do: :error, else: {:ok, expires_at}

      _other ->
        :error
    end
  rescue
    _exception -> :error
  catch
    :exit, _reason -> :error
  end

  @impl AshA2A.Authority.Broker
  @spec list_grants(Identity.t(), keyword()) ::
          {:ok, [AshA2A.Authority.Broker.grant_entry()]} | :error
  def list_grants(%Identity{kind: :principal} = subject, opts \\ []) do
    subject_external = Identity.external(subject)
    name = ekv_name(opts)

    # A real full scan of every durably-stored entry this broker itself
    # wrote, not a targeted lookup: the key is a one-way hash the subject
    # cannot be recovered from (see the comment on `issue/3`'s `entry`), so
    # there is no key-prefix DERIVED FROM THE SUBJECT that would let this
    # scan just the entries for one subject.
    #
    # `EKV.scan/2` genuinely cannot take an empty-string prefix -- verified
    # directly against this dependency, not assumed: `EKV.Store.
    # next_binary_prefix("")` pattern-matches `<<head::binary-size(-1),
    # last_byte>> = ""` to compute the scan's exclusive upper bound, which
    # raises a real `MatchError` for every caller, library-wide, not a
    # defect specific to this broker. The real, always-true invariant this
    # broker relies on instead: `AshA2A.Authority.new/3` wraps every
    # `token_id` via `Identity.runtime/1` (`Keyword.get(opts, :token_id,
    # Ash.UUIDv7.generate())` is the only source of the wrapped value, and
    # it is always wrapped), so `Identity.external/1` on any authority this
    # broker's own `issue/3` produced a key for is ALWAYS `"runtime:" <>
    # something` -- verified empirically against this real EKV instance
    # (fixed-random UUIDv7 token ids from a bare `issue/3` call and
    # deterministic SHA256-hex token ids from `Authority.grant_token_id/2`
    # both landed under the literal `"runtime:"` prefix). Scanning that
    # fixed, non-empty prefix is therefore a real full scan of this
    # broker's own key space, not a heuristic guess at one.
    #
    # Filters to `status: :issued` entries whose stored `:subject` matches
    # AND have not expired -- the same fail-closed "standing" reading
    # `granted?/3` uses, so a revoked or expired entry (or one written
    # before `:subject` was recorded) is never reported.
    grants =
      name
      |> EKV.scan("runtime:")
      |> Enum.filter(fn {_key, entry, _vsn} ->
        match?(%{status: :issued, subject: ^subject_external}, entry) and
          not past?(Map.get(entry, :expires_at))
      end)
      |> Enum.map(fn {_key, entry, _vsn} ->
        %{capability_id: entry.capability_id, expires_at: Map.get(entry, :expires_at)}
      end)

    {:ok, grants}
  rescue
    # Same rationale as `granted?/3`: a stopped EKV instance raises
    # (`ArgumentError`) rather than exiting.
    _exception -> :error
  catch
    :exit, _reason -> :error
  end

  defp past?(nil), do: false

  defp past?(%DateTime{} = expires_at),
    do: DateTime.compare(DateTime.utc_now(), expires_at) != :lt

  # An `expires_at` this module cannot interpret is an unanswerable grant
  # question -- refuse, never admit.
  defp past?(_other), do: true

  defp revoked?(name, key) do
    case EKV.get(name, key) do
      %{status: :revoked} -> true
      _ -> false
    end
  end

  defp mark_revoked(_name, _key, token_id, attempt) when attempt >= @max_cas_attempts do
    {:error, %{reason: :revoke_conflict, token_id: token_id}}
  end

  defp mark_revoked(name, key, token_id, attempt) do
    case EKV.lookup(name, key) do
      nil ->
        # No prior durable entry for this token_id (an authority revoked
        # without ever having been `issue/3`-d through this same broker, for
        # example one minted via `Authority.new/3` directly, or issued by a
        # different broker instance) -- still recorded durably and fail
        # closed, matching `InMemory.revoke/2`'s own unconditional
        # `MapSet.put/2` regardless of prior `issued` membership.
        case EKV.put(name, key, %{status: :revoked}, if_vsn: nil) do
          {:ok, _vsn} ->
            :ok

          {:error, reason} when reason in [:conflict, :unconfirmed] ->
            mark_revoked(name, key, token_id, attempt + 1)
        end

      {entry, vsn} ->
        case EKV.put(name, key, Map.put(entry, :status, :revoked), if_vsn: vsn) do
          {:ok, _vsn} ->
            :ok

          {:error, reason} when reason in [:conflict, :unconfirmed] ->
            mark_revoked(name, key, token_id, attempt + 1)
        end
    end
  end

  defp ekv_name(opts), do: Keyword.get(opts, :name, __MODULE__)
end
