defmodule AshA2A.Authority.Grant do
  @moduledoc """
  The capability-GRANT decision that sits between "this caller's identity was
  verified by the transport" and "this caller holds authority for this
  capability".

  ## The escalation this closes (RFC-SA2A-001 S29)

  `AshA2A.Agent.build_command/4` builds a real `AshA2A.Command` from an
  inbound `A2A.Message`, taking `capability_id` straight from the message's
  own `skill` metadata -- a CALLER-SUPPLIED value. Before this module, it
  handed that value directly to
  `AshA2A.Authority.from_verified_identity/2`, which is a pure constructor:
  it mints a full `%AshA2A.Authority{}` for whatever capability id it is
  given, with `source: :transport_verified`. `AshA2A.CommandBus.admit/2`
  then checked `AshA2A.Authority.admits?/2`, which compares the authority's
  own `capability_id` against the command's -- and therefore passed by
  construction, always.

  Net effect on the real, default dispatch path: **any** transport-
  authenticated caller held authority for **every** skill on the agent card,
  including every `:change` and `:external_do` skill. RFC-SA2A-001 S29
  ("Authentication does NOT imply Authority") was false in production.
  Reproduced before this fix with a real agent call and a real actuation
  counter: an authenticated principal with no grant of any kind actuated
  both an `:external_do` and a `:change` skill (2 real actuations).

  `authorize/3` is the missing decision. It asks the configured
  `AshA2A.Authority.Broker` whether THIS principal holds a standing grant for
  THIS capability, and only then synthesizes the authority struct. With no
  grant it returns `nil`, and `AshA2A.CommandBus.admit/2`'s existing
  `:authority_required` refusal fails the dispatch closed before any
  actuation. `:observe` skills are untouched: `admit/2` returns `:ok` for
  them regardless of authority, by design.

  ## Policy modes

  Configured as `config :ash_a2a, :authority_policy, mode`:

    * `:broker` (**default**) -- fail-closed and RFC-conformant. Consults
      `AshA2A.Authority.Broker.granted?/3` on the broker configured as
      `config :ash_a2a, :authority_broker, MyBroker` (or
      `{MyBroker, opts}`). No broker configured means no grant can be
      proven, which means no authority: every consequential capability is
      refused, and a real `Logger.warning` (once per VM) names the missing
      config so the refusals are never silent.

    * `:transport_verified_grants_capability` -- the pre-fix behavior,
      preserved verbatim for compatibility. **This mode violates
      RFC-SA2A-001 S29**: it grants every authenticated caller authority for
      every capability they name. Selecting it emits a real
      `Logger.warning` (once per VM) naming the escalation. It exists so an
      existing deployment can upgrade without an outage while it wires a
      real broker, not as a supported steady state.

  ### Why `:broker` is the default

  Deliberate, and the more disruptive of the two choices. This repository's
  own doctrine is fail-closed (`UNKNOWN` is not `ADMITTED`), the defect is a
  confirmed privilege escalation rather than a hypothetical one, and the
  alternative default is a library that ships a known-false security
  property switched on. A caller who upgrades and does nothing gets loud,
  typed `:authority_required` refusals on consequential skills -- a visible,
  diagnosable failure -- rather than a silent, invisible escalation. The
  migration is one `Application.put_env` (or a config line) away in either
  direction, and both directions are named, documented, and warned about.
  See `CHANGELOG.md` and `docs/how-to/authenticate-agent-requests.md`.

  ## Replay is preserved

  `AshA2A.Command.fingerprint/1` hashes `authority.token_id`. A fresh random
  token id per dispatch would make every retry of an identical command
  fingerprint differently and break `AshA2A.CommandBus` replay detection for
  authenticated callers -- a real, previously reproduced regression
  (`AshA2A.Authority.from_verified_identity/2`'s own comment records it).
  `authorize/3` therefore never mints a fresh token id: it still builds the
  authority through `from_verified_identity/2`, whose token id is
  `AshA2A.Authority.grant_token_id/2` -- deterministic in
  `(subject, capability_id)`. The grant decision changes *whether* an
  authority is produced, never *which* one. Two dispatches of the same real
  command by the same granted principal fingerprint identically and replay,
  exactly as before.
  """

  require Logger

  alias AshA2A.{Authority, Identity}

  @default_policy :broker
  @policies [:broker, :transport_verified_grants_capability]

  @typedoc "The configured capability-grant policy."
  @type policy :: :broker | :transport_verified_grants_capability

  @doc """
  Decides whether `auth_identity` may hold `capability_id`, returning the
  real `AshA2A.Authority` it holds or `nil`.

  `nil` in, `nil` out: an unauthenticated caller was never a candidate for a
  grant, and `AshA2A.CommandBus.admit/2` already fails `:change`/
  `:external_do` closed on a `nil` authority.

  Options (all defaulting to the application environment, and all present so
  tests and multi-tenant hosts can decide per call rather than globally):

    * `:policy` - overrides `config :ash_a2a, :authority_policy`.
    * `:broker` - overrides `config :ash_a2a, :authority_broker`; a module
      or `{module, opts}`.
  """
  @spec authorize(term(), String.t(), keyword()) :: Authority.t() | nil
  def authorize(auth_identity, capability_id, opts \\ [])

  def authorize(nil, _capability_id, _opts), do: nil

  def authorize(auth_identity, capability_id, opts) when is_binary(capability_id) do
    policy = policy(opts)
    authority = decide(policy, auth_identity, capability_id, opts)

    # Boundary telemetry (RFC-SA2A-002 §12/§18): the grant decision is observed
    # where it is made, so a court can prove an authority probe really reached
    # this boundary. Observational only -- the returned authority is unchanged.
    :telemetry.execute(
      [:ash_a2a, :authority, :grant, :decision],
      %{system_time: System.system_time()},
      %{
        policy: policy,
        broker: broker_module(opts),
        capability_id: capability_id,
        principal_id: Identity.principal(auth_identity).value,
        outcome: if(authority, do: :granted, else: :denied)
      }
    )

    authority
  end

  defp decide(policy, auth_identity, capability_id, opts) do
    case policy do
      :transport_verified_grants_capability ->
        warn_once(
          :legacy_policy,
          "ash_a2a: :authority_policy is set to :transport_verified_grants_capability. " <>
            "Every transport-authenticated caller therefore holds authority for EVERY " <>
            "capability on the agent card, including :change and :external_do skills. " <>
            "This violates RFC-SA2A-001 S29 (Authentication does NOT imply Authority) and " <>
            "is a privilege escalation, preserved only for compatibility during migration. " <>
            "Configure `config :ash_a2a, authority_policy: :broker` and an " <>
            ":authority_broker with real grants (see AshA2A.Authority.Grant)."
        )

        Authority.from_verified_identity(auth_identity, capability_id)

      :broker ->
        broker_authorize(auth_identity, capability_id, opts)
    end
  end

  @doc """
  Issues a real, standing capability grant for `subject` through the
  configured broker.

  Keyed on `AshA2A.Authority.grant_token_id/2`, which is exactly the token id
  `authorize/3` will later look for -- so a grant issued here is the grant
  found there. A second `grant/3` for the same `(subject, capability_id)`
  legitimately refuses with the broker's own `:token_id_taken`, because the
  grant already stands; use `granted?/3` to ask rather than re-issuing.

      subject = AshA2A.Identity.principal("user-1")
      {:ok, _authority} = AshA2A.Authority.Grant.grant(subject, "create_item")
  """
  @spec grant(Identity.t(), String.t(), keyword()) ::
          {:ok, Authority.t()} | {:error, AshA2A.Authority.Broker.refusal()}
  def grant(%Identity{kind: :principal} = subject, capability_id, opts \\ [])
      when is_binary(capability_id) do
    case resolve_broker(opts) do
      {:ok, module, broker_opts} ->
        # The CALLER's `opts` are merged over the configured broker opts, not
        # discarded: dropping them meant `grant(subject, cap, expires_at: t)`
        # silently produced a PERMANENT grant, so the only in-library
        # grant-issuing API could not express a time bound at all.
        # `:token_id` stays last and non-overridable -- `authorize/3` looks the
        # grant up by exactly `grant_token_id/2`, and a caller-chosen token id
        # would file the grant where nothing ever reads it.
        issue_opts =
          broker_opts
          |> Keyword.merge(Keyword.drop(opts, [:policy, :broker, :broker_opts]))
          |> Keyword.put(:token_id, Authority.grant_token_id(subject, capability_id))

        module.issue(subject, capability_id, issue_opts)

      :error ->
        {:error, %{reason: :no_authority_broker_configured, capability_id: capability_id}}
    end
  end

  @doc """
  Whether the configured broker holds a standing grant of `capability_id` to
  `subject`. Fails closed (`false`) when no broker is configured.
  """
  @spec granted?(Identity.t(), String.t(), keyword()) :: boolean()
  def granted?(%Identity{kind: :principal} = subject, capability_id, opts \\ [])
      when is_binary(capability_id) do
    case resolve_broker(opts) do
      {:ok, module, broker_opts} -> module.granted?(subject, capability_id, broker_opts)
      :error -> false
    end
  end

  @doc """
  The currently configured policy. Falls back to `#{inspect(@default_policy)}`
  and refuses an unrecognized value by falling back to it too (with a real
  warning) rather than admitting under a policy nobody defined.
  """
  @spec policy(keyword()) :: policy()
  def policy(opts \\ []) do
    configured =
      Keyword.get(opts, :policy) ||
        Application.get_env(:ash_a2a, :authority_policy, @default_policy)

    if configured in @policies do
      configured
    else
      warn_once(
        {:unknown_policy, configured},
        "ash_a2a: unknown :authority_policy #{inspect(configured)}; expected one of " <>
          "#{inspect(@policies)}. Falling back to the fail-closed default " <>
          "#{inspect(@default_policy)}."
      )

      @default_policy
    end
  end

  # `grant_expires_at/3` is an OPTIONAL broker callback. A broker that does not
  # implement it is read as "standing grant, no time bound" -- exactly the
  # pre-existing behaviour -- so no third-party implementation breaks. The same
  # `Code.ensure_loaded?/1` + `function_exported?/3` idiom this repo already
  # uses for `AshA2A.ReceiptStore.Ekv.durable?/0` and
  # `AshA2A.Execution.FLAME.available?/0`.
  defp grant_expires_at(module, subject, capability_id, broker_opts) do
    if Code.ensure_loaded?(module) and function_exported?(module, :grant_expires_at, 3) do
      case module.grant_expires_at(subject, capability_id, broker_opts) do
        {:ok, expires_at} -> expires_at
        :error -> nil
      end
    end
  end

  defp broker_authorize(auth_identity, capability_id, opts) do
    subject = Identity.principal(auth_identity)

    case resolve_broker(opts) do
      {:ok, module, broker_opts} ->
        if module.granted?(subject, capability_id, broker_opts) do
          # Deliberately the same constructor, and therefore the same
          # deterministic `grant_token_id/2` token id, as before this fix --
          # `AshA2A.Command.fingerprint/1` stability, and with it CommandBus
          # replay detection for authenticated callers, depends on it.
          #
          # The grant's real `expires_at` is carried onto the synthesized
          # authority. Without it the minted authority was always
          # `expires_at: nil`, which made `Authority.admits?/2`'s own
          # `not expired?(authority)` check structurally unreachable on the
          # dispatch path -- a time bound that could never fail. Expiry is
          # ENFORCED by `granted?/3` above; carrying it here is defence in
          # depth, and it keeps the token id untouched so replay is unaffected.
          Authority.from_verified_identity(
            auth_identity,
            capability_id,
            grant_expires_at(module, subject, capability_id, broker_opts)
          )
        end

      :error ->
        warn_once(
          :no_broker,
          "ash_a2a: :authority_policy is :broker (the fail-closed default) but no " <>
            ":authority_broker is configured, so no capability grant can be proven and " <>
            "every :change/:external_do dispatch will be refused with :authority_required. " <>
            "Configure `config :ash_a2a, authority_broker: AshA2A.Authority.Broker.InMemory` " <>
            "(or your own AshA2A.Authority.Broker implementation) and issue grants with " <>
            "AshA2A.Authority.Grant.grant/3."
        )

        nil
    end
  end

  defp broker_module(opts) do
    case resolve_broker(opts) do
      {:ok, module, _broker_opts} -> module
      :error -> nil
    end
  end

  defp resolve_broker(opts) do
    case Keyword.get(opts, :broker) || Application.get_env(:ash_a2a, :authority_broker) do
      nil ->
        :error

      {module, broker_opts} when is_atom(module) and is_list(broker_opts) ->
        {:ok, module, broker_opts}

      module when is_atom(module) ->
        {:ok, module, []}

      _other ->
        :error
    end
  end

  # A real, visible, once-per-VM warning. `:persistent_term` rather than a
  # process dictionary or an Agent: the dispatch path runs in whichever
  # `A2A.Agent` process handled the message, so per-process state would warn
  # once per agent process instead of once per node, and a supervised
  # counter process would be one more thing to start before the library
  # could safely log.
  defp warn_once(key, message) do
    term_key = {__MODULE__, :warned, key}

    if :persistent_term.get(term_key, false) do
      :ok
    else
      :persistent_term.put(term_key, true)
      Logger.warning(message)
      :ok
    end
  end
end
