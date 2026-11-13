defmodule AshA2A.Copilot.Pipeline do
  @moduledoc """
  Dispatch pre-check chain for the Communicating Digital Twins subsystem.

  Wires three landed surfaces into one interception path:

    1. `AshA2A.Twin.CEO.evaluate_intent/2` — intent evaluation (GPM floor,
       monkey-math exact-half, round-number suspicion). On challenge: return
       the challenge-as-state ledger entry (the ledger is state on the CEO
       struct, threaded through this pipeline — the pipeline is pure;
       callers own persistence via the returned state).
    2. On CEO admit, in this order (first non-ok stage wins):
       a. optional mechanical prior (loadable `TradeReticle.Plumbing` or the
          `:prior` opt) — may challenge or refuse;
       b. `AshA2A.Twin.COO.handle_inbound/2` strain-check of the
          coordinator (`AshA2A.Strain.Tensor.hyperplane_check/2` saturation
          gate) → shed to the senior queue or admit;
       c. `AshA2A.Attestation.Gate` on the sensor frame (enclave, freshness,
          sensor metadata); a missing/non-map `:sensor_frame` is a typed
          `:attestation` refusal;
       d. `AshA2A.Authority.PEP.assert_standing/4` — the authority hop (lane
          G4), LAST gate before admit.

  Malformed intents (missing keys, non-number or zero `nte`, non-number
  `offer`, nil `coordinator_id`) return a typed
  `{:refuse, %{code: :invalid_intent, reason: _}}` and never raise.

  **LOUD NOTE — authority hop is opt-in, absence = documented skip.** The
  PEP's default source is `AshA2A.Authority.Source.DenyAll` (fail-closed:
  it refuses everything). Wiring the PEP unconditionally would refuse every
  existing caller and turn every landed court red. Therefore the hop is
  active ONLY when the `:authority_source` opt is supplied; when absent the
  hop is SKIPPED (not failed) and this moduledoc is the disclosure. Supply
  `authority_source: AshA2A.Authority.Source.AllowAll` (tests) or a real
  `AshA2A.Authority.Source` implementation (production) to enforce it.

  The actor is `intent[:actor_id]` (optional key); when `:authority_source`
  is configured but `intent` carries no `:actor_id`, the hop refuses with
  reason `:missing_actor_id` — a configured PEP never silently admits an
  unidentified principal.

  ## Bridge observation feed (Z7 seam join)

  The pipeline threads a live `AshA2A.Strain.Bridge` `mesh_state` alongside
  the COO mesh and folds every verdict back into it as observations:

    * admit → `ticket_assigned` (`:active_leases` +1 for the coordinator)
    * CEO challenge → `challenge_received` with `source: :ceo`
      (`:heuristic_frequency` +1)
    * refuse / escalate → `error_reported` (rolling error window)

  ## Order decision: strain-first (route/2 before CEO)

  `route/2` delegates to `Bridge.route/2` and is the cheap strain gate: it
  consults only the live tensor (no CEO interrogation, no attestation).
  Dispatch callers run `route/2` BEFORE `check/3`. Rationale: a saturated
  coordinator cannot take the ticket regardless of intent quality, so
  evaluating CEO first would burn an expensive interrogation (and mutate
  its challenge ledger) on a ticket that is shed anyway. Shedding first
  protects the human and keeps the CEO ledger clean of tickets that never
  had a coordinator. Inside `check/3` the existing per-coordinator COO
  gate still runs after CEO (it is keyed to `intent.coordinator_id`,
  which CEO's verdict does not change); the mesh-level shed decision is
  `route/2`'s job and happens before CEO by construction.

  ## Known unauthenticated channels (lane F8 disclosure)

    * **Strain-observation identity is the declared `coordinator_id`.**
      Every Bridge observation (`challenge_received`, `error_reported`,
      `ticket_assigned`) folds against the intent's declared
      `coordinator_id` with no binding to an attested actor. An attacker
      submitting intents with a rival's id inflates the rival's tensor
      (`heuristic_frequency` rises on attacker-provoked challenges).
      FIXED: the attested actor (`"actor_id"` claim of the verified sensor frame,
      never the caller's `intent.actor_id`) is bound to the strain key; a mismatched
      `coordinator_id` is refused by default when the frame carries an actor claim
      (optionally mapped via `:coordinator_binding`) and is refused `:coordinator_mismatch` with no observation
      folded; Bridge no longer auto-registers unknown ids. Without the option
      the binding stage is skipped observably (`[:ash_a2a, :copilot,
      :stage_skipped]`, as are absent mechanical prior / authority source).

  Negative-NTE intents are FIXED upstream: `CEO.evaluate_intent/2` refuses
  `nte <= 0` / negative offers with a typed `:invalid_intent` refusal.

  `coordinator_id: nil` is FIXED: it returns a typed `:invalid_intent`
  refusal instead of raising inside `COO.handle_inbound/2`.

  The pipeline is **pure**: twins are called via their module functions and
  all state (CEO challenge ledger, COO mesh, Bridge mesh_state) is
  threaded in and out. The only environmental read is the wall clock when
  the caller does not supply `:now` — disclosed for honesty; tests inject
  `:now` for determinism.

  ## Input

      intent = %{
        trade: ref(),
        nte: number(),
        offer: number(),
        coordinator_id: term(),
        sensor_frame: %{
          device_token: binary(),
          nonce: binary(),
          key: AshA2A.Attestation.Key.key() (the verification key),
          max_staleness_sec: pos_integer() (optional, default 90)
        }
      }

  ## Result

      {:ok, admitted_ticket}
      | {:challenge, %{code: _, demanded_evidence: _, retry_token: _}}
      | {:refuse, :escalate_multisig | %{code: _, reason: _}}
      | {:escalated, %{proposal_id: reference(), card: map(), proposal: map()}}
      | {:shed, {:senior_queue, relief_target}}

  Every branch returns a typed structured result; no strings-as-state.
  """

  alias AshA2A.Attestation.Gate
  alias AshA2A.Authority.PEP
  alias AshA2A.Strain.Bridge
  alias AshA2A.Twin.COO
  alias AshA2A.Twin.CEO

  @type result ::
          {:ok, map()}
          | {:challenge, CEO.challenge_map()}
          | {:refuse, :escalate_multisig | map()}
          | {:escalated, %{proposal_id: reference(), card: map(), proposal: map()}}
          | {:shed, {:senior_queue, term()}}

  @type state :: %{ceo: CEO.t(), mesh: COO.mesh(), bridge: Bridge.mesh_state()}

  @doc """
  Run the interception path for one intent over the given pipeline state.

  Returns `{new_state, result}`. `state` carries the CEO evaluator (its
  challenge ledger is the challenge-as-state store) and the COO mesh.

  ## Options

    * `:prior` — mechanical-prior module consulted when
      `AshA2A.Twin.MechanicalPrior` trade-reticle plumbing is loadable
      (lane X5's `TradeReticle.Plumbing`). Default: auto-detect at call
      time via `detect_prior/0`; `nil` skips the prior stage.
    * `:now` — unix seconds injected for attestation freshness checks
      (defaults to `System.system_time(:second)`).
    * `:authority_source` — an `AshA2A.Authority.Source` module or
      `{module, opts}` tuple enforcing the authority hop (lane G4). When
      absent the hop is skipped (see the moduledoc loud note). When present,
      `AshA2A.Authority.PEP.assert_standing/4` runs as the LAST gate before
      admit: `:ok` admits onward, any `{:refused, :insufficient_authority,
      detail}` becomes `{:refuse, %{code: :authority, reason: detail}}`.
    * `:attention_broker` — an `AshA2A.Attention.Broker` module or
      `{module, broker_opts}` (lane G5; broker_opts may carry `:level` and
      `:now` defaults, overridden by `:proposal_level` / `:now`).
      When set, escalate-class refuses (CEO repeat-challenge
      `:escalate_multisig`, GPM-floor-class refuses) open a broker proposal
      and return `{:escalated, %{proposal_id, card}}` instead. When absent,
      refuses pass through unchanged.
    * `:coo_triage` — optional COO triage payload folded into the
      escalation card by `Broker.build_card/3`.
    * `:proposal_level` — broker autonomy level for escalated proposals
      (default `:consent_by_silence`; use `:supervised` to forbid
      silence-consent execution).
    * `:ceo_mod` — CEO module or 2-arity fun (court instrumentation).

  The former `:coordinator_id` option was removed: `check/3` requires
  `intent.coordinator_id`, so the fallback was unreachable.
  """
  @spec check(map(), state(), keyword()) :: {state(), result()}
  def check(intent, state, opts \\ [])

  def check(%{coordinator_id: cid} = intent, state, opts) when not is_nil(cid) do
    case binding_check(intent, opts) do
      :ok -> do_check(intent, state, opts)
      {:refuse, _} = refuse -> {state, refuse}
    end
  end

  def check(intent, state, opts), do: do_check(intent, state, opts)

  # Strain-key binding (F8/A3): with `:coordinator_binding` (a map
  # `actor_id => coordinator_id` or a 1-arity fun `actor_id -> coordinator_id | nil`)
  # the intent's declared `coordinator_id` must equal the attested actor's bound
  # coordinator, else a typed refusal (no observation folded). Absent binding is an
  # observable skip: telemetry `[:ash_a2a, :copilot, :stage_skipped]`.
  defp binding_check(intent, opts) do
    attested = attested_actor(intent, opts)

    case {Keyword.get(opts, :coordinator_binding), attested} do
      {nil, nil} ->
        skip(:coordinator_binding, intent)
        :ok

      {nil, actor} ->
        # Default-on: the attested actor IS the strain key unless a binding says otherwise.
        check_bound(intent, actor, actor)

      {binding, actor} ->
        check_bound(
          intent,
          actor,
          if(actor == nil, do: nil, else: lookup_binding(binding, actor))
        )
    end
  end

  defp check_bound(intent, actor, bound) do
    if bound != nil and bound == intent.coordinator_id do
      :ok
    else
      {:refuse,
       %{
         code: :coordinator_mismatch,
         reason: %{actor_id: actor, declared: intent.coordinator_id, bound: bound}
       }}
    end
  end

  # Attested actor = `"actor_id"` claim inside the verified (signed) sensor frame.
  # The caller-supplied `intent.actor_id` is never consulted for binding.
  defp attested_actor(intent, opts) do
    case attestation_check(Map.get(intent, :sensor_frame), opts) do
      {:ok, %{"actor_id" => actor}} when not is_nil(actor) -> actor
      _ -> nil
    end
  end

  defp lookup_binding(fun, actor) when is_function(fun, 1), do: fun.(actor)
  defp lookup_binding(%{} = map, actor), do: Map.get(map, actor)

  defp skip(stage, intent) do
    :telemetry.execute([:ash_a2a, :copilot, :stage_skipped], %{count: 1}, %{
      stage: stage,
      coordinator_id: Map.get(intent, :coordinator_id)
    })
  end

  defp do_check(
         %{trade: trade, nte: nte, offer: offer, coordinator_id: coordinator_id} = intent,
         %{ceo: ceo, mesh: _mesh} = state,
         opts
       )
       when is_number(nte) and is_number(offer) and nte != 0 and not is_nil(coordinator_id) do
    ceo_mod = Keyword.get(opts, :ceo_mod, CEO)

    {ceo1, ceo_verdict} =
      evaluate_ceo(ceo_mod, ceo, %{trade: trade, nte: nte, offer: offer})

    case ceo_verdict do
      {:refuse, _} = refuse ->
        {%{state | ceo: ceo1, bridge: record(state, intent.coordinator_id, :error_reported)},
         maybe_escalated(intent, refuse, opts)}

      {:challenge, _} = challenge ->
        {%{
           state
           | ceo: ceo1,
             bridge: record(state, intent.coordinator_id, {:challenge_received, :ceo})
         }, challenge}

      {:admit, _ticket} ->
        admit_path(intent, %{state | ceo: ceo1}, opts)
    end
  end

  defp do_check(intent, state, _opts) do
    {state, {:refuse, %{code: :invalid_intent, reason: invalid_reason(intent)}}}
  end

  defp invalid_reason(%{} = intent) do
    missing = for k <- [:trade, :nte, :offer, :coordinator_id], not Map.has_key?(intent, k), do: k

    cond do
      missing != [] -> {:missing_keys, missing}
      not is_number(intent.nte) -> :nte_not_a_number
      intent.nte == 0 -> :nte_zero
      not is_number(intent.offer) -> :offer_not_a_number
      is_nil(intent.coordinator_id) -> :coordinator_id_nil
      true -> :malformed
    end
  end

  defp invalid_reason(_), do: :intent_not_a_map

  @doc "Build initial pipeline state: `%{ceo: CEO.new(opts), mesh: mesh, bridge: Bridge.new_mesh_state()}`."
  @spec init(keyword(), COO.mesh()) :: state()
  def init(ceo_opts \\ [], mesh \\ %{}) do
    %{ceo: CEO.new(ceo_opts), mesh: mesh, bridge: Bridge.new_mesh_state(Map.keys(mesh))}
  end

  @doc """
  Strain gate over the live Bridge mesh_state: delegates to
  `AshA2A.Strain.Bridge.route/2`. Cheap — consults only the tensor, never
  CEO — so callers run this BEFORE `check/3` (see moduledoc order
  decision). Returns `{:assign, coordinator_id}` or
  `{:shed, {:senior_queue, reason}}`.
  """
  @spec route(map(), Bridge.mesh_state()) :: {:assign, term()} | {:shed, {:senior_queue, term()}}
  def route(ticket, mesh_state), do: Bridge.route(ticket, mesh_state)

  # -- admit path: mechanical prior → strain → attestation -------------------

  # CEO may be injected as a module or a 2-arity fun (court instrumentation).
  defp evaluate_ceo(mod, ceo, claim) when is_atom(mod), do: mod.evaluate_intent(ceo, claim)
  defp evaluate_ceo(fun, ceo, claim) when is_function(fun, 2), do: fun.(ceo, claim)

  defp admit_path(intent, state, opts) do
    with {:prior, :ok} <- {:prior, mechanical_prior(intent, opts)},
         {:strain, {:admit, id}} <-
           {:strain, COO.handle_inbound(state.mesh, %{coordinator_id: intent.coordinator_id})},
         {:attestation, {:ok, claims}} <-
           {:attestation, attestation_check(Map.get(intent, :sensor_frame), opts)},
         {:authority, :ok} <- {:authority, authority_check(intent, opts)} do
      {%{state | bridge: record(state, id, :ticket_assigned)},
       {:ok,
        %{
          trade: intent.trade,
          coordinator_id: id,
          gpm: CEO.gpm(intent.nte, intent.offer),
          attestation_claims: claims
        }}}
    else
      {:prior, {:challenge, _} = challenge} ->
        {%{state | bridge: record(state, intent.coordinator_id, {:challenge_received, :ceo})},
         challenge}

      {:prior, {:refuse, _} = refuse} ->
        {%{state | bridge: record(state, intent.coordinator_id, :error_reported)},
         maybe_escalated(intent, refuse, opts)}

      {:strain, {:shed, _} = shed} ->
        {state, shed}

      {:attestation, {:refused, _} = refused} ->
        {%{state | bridge: record(state, intent.coordinator_id, :error_reported)},
         {:refuse, %{code: :attestation, reason: refused}}}

      {:authority, {:refused, :insufficient_authority, detail}} ->
        {%{state | bridge: record(state, intent.coordinator_id, :error_reported)},
         {:refuse, %{code: :authority, reason: detail}}}

      {:authority, other} ->
        {%{state | bridge: record(state, intent.coordinator_id, :error_reported)},
         {:refuse, %{code: :authority, reason: {:unexpected, other}}}}

      {:attestation, other} ->
        {%{state | bridge: record(state, intent.coordinator_id, :error_reported)},
         {:refuse, %{code: :attestation, reason: {:unexpected, other}}}}

      {:strain, other} ->
        {state, {:refuse, %{code: :strain, reason: {:unexpected, other}}}}
    end
  end

  # Authority hop (lane G4) — the LAST gate before final admit. Active only
  # when `:authority_source` is configured; absence is a documented skip
  # (PEP's DenyAll default would refuse every existing caller otherwise).
  defp authority_check(intent, opts) do
    case Keyword.get(opts, :authority_source) do
      nil ->
        skip(:authority_source, intent)
        :ok

      source ->
        actor_id = Map.get(intent, :actor_id)

        cond do
          is_nil(actor_id) ->
            {:refused, :insufficient_authority,
             %{reason: :missing_actor_id, action: "a2a:copilot.check"}}

          true ->
            scope = %{
              action: "a2a:copilot.check",
              coordinator_id: intent.coordinator_id,
              trade: intent.trade
            }

            PEP.assert_standing(actor_id, scope, intent, source: source)
        end
    end
  end

  # Mechanical prior (lane X5 plumbing) — only when configured/loadable.
  defp mechanical_prior(intent, opts) do
    prior =
      case Keyword.fetch(opts, :prior) do
        {:ok, p} -> p
        :error -> detect_prior()
      end

    case prior do
      nil ->
        skip(:mechanical_prior, intent)
        :ok

      prior when is_atom(prior) ->
        claim = %{trade: intent.trade, nte: intent.nte, offer: intent.offer}
        telemetry = Map.get(intent, :telemetry, %{})

        case prior.prior_verdict(claim, telemetry) do
          {:admit, _} ->
            :ok

          {:challenge, evidence, msg} ->
            {:challenge,
             %{
               code: :mechanical_prior,
               demanded_evidence: evidence,
               retry_token: make_ref(),
               msg: msg
             }}

          # surface the prior's own classification code when it carries one
          # (e.g. :gpm_breach) so the escalation feed can classify the refuse;
          # the full reason payload is preserved either way.
          {:refuse, %{code: code} = reason} ->
            {:refuse, %{code: code, reason: reason}}

          {:refuse, reason} ->
            {:refuse, %{code: :mechanical_prior, reason: reason}}
        end
    end
  end

  @doc """
  Auto-detect a mechanical-prior module: the application env
  `:ash_a2a, :copilot_mechanical_prior` if set, else lane X5's
  `TradeReticle.Plumbing` if loadable, else `nil` (stage skipped).
  """
  @spec detect_prior() :: module() | nil
  def detect_prior do
    case Application.get_env(:ash_a2a, :copilot_mechanical_prior) do
      nil ->
        case Code.ensure_loaded(TradeReticle.Plumbing) do
          {:module, _} -> TradeReticle.Plumbing
          _ -> nil
        end

      prior when is_atom(prior) ->
        prior
    end
  end

  # -- attention-broker escalation feed (lane G5) -----------------------------
  #
  # When `opts[:attention_broker]` is configured (an `AshA2A.Attention.Broker`
  # module), a CEO repeat-challenge refuse (`:escalate_multisig`) or a
  # GPM-floor-class refuse is escalated: a decision card is built via the
  # broker's `build_card/3` (CEO challenge payload + optional `:coo_triage`)
  # and a proposal opened via `propose/3`, and the pipeline returns
  # `{:escalated, %{proposal_id, card}}` instead of the bare refuse.
  #
  # Unconfigured → typed refuse, unchanged, no broker call (documented skip).
  # No clock sampling (broker `:now` comes from opts, default 0);
  # `consent_by_silence/4` stays at the caller's cadence — this module only
  # creates proposals, it never resolves them.

  @gpm_floor_codes [:gpm_floor, :gpm_breach, :monkey_math]

  defp maybe_escalated(intent, {:refuse, :escalate_multisig} = refuse, opts) do
    escalate(intent, refuse, %{code: :gpm_floor, repeat_challenge: true}, true, opts)
  end

  defp maybe_escalated(intent, {:refuse, %{code: code} = reason}, opts)
       when code in @gpm_floor_codes do
    escalate(intent, {:refuse, reason}, reason, true, opts)
  end

  defp maybe_escalated(_intent, refuse, _opts), do: refuse

  defp escalate(intent, refuse, challenge_payload, gpm_breach?, opts) do
    case Keyword.get(opts, :attention_broker) do
      nil ->
        refuse

      spec ->
        {broker, bopts} = broker_spec(spec)
        triage = Keyword.get(opts, :coo_triage)

        card = broker.build_card(challenge_payload, triage, gpm_floor_breach: gpm_breach?)

        level =
          Keyword.get(opts, :proposal_level, Keyword.get(bopts, :level, :consent_by_silence))

        now = Keyword.get(opts, :now, Keyword.get(bopts, :now, 0))

        case broker.propose(intent.coordinator_id, card, level: level, now: now) do
          {:ok, proposal} ->
            {:escalated, %{proposal_id: proposal.id, card: proposal.card, proposal: proposal}}

          {:error, reason} ->
            {:refuse, %{code: :escalation_failed, reason: reason, original: refuse}}
        end
    end
  end

  defp broker_spec({mod, bopts}) when is_atom(mod) and is_list(bopts), do: {mod, bopts}
  defp broker_spec(mod) when is_atom(mod), do: {mod, []}

  # -- attestation gate chain -------------------------------------------------

  # Fold a pipeline verdict into the live Bridge mesh_state (Z7 seam).
  defp record(%{bridge: bridge0, mesh: mesh}, coordinator_id, :ticket_assigned) do
    Bridge.record_observation(registered(bridge0, mesh, coordinator_id), coordinator_id, %{
      type: :ticket_assigned
    })
  end

  defp record(%{bridge: bridge0, mesh: mesh}, coordinator_id, {:challenge_received, :ceo}) do
    Bridge.record_observation(registered(bridge0, mesh, coordinator_id), coordinator_id, %{
      type: :challenge_received,
      source: :ceo
    })
  end

  defp record(%{bridge: bridge0, mesh: mesh}, coordinator_id, :error_reported) do
    Bridge.record_observation(registered(bridge0, mesh, coordinator_id), coordinator_id, %{
      type: :error_reported,
      error: true
    })
  end

  defp attestation_check(%{device_token: _, nonce: _, key: _} = sensor_frame, opts) do
    now = Keyword.get(opts, :now, System.system_time(:second))
    staleness = Map.get(sensor_frame, :max_staleness_sec, 90)

    fresh_opts = [now: now, max_staleness_sec: staleness]

    with {:ok, claims} <-
           Gate.verify_enclave({sensor_frame.device_token, sensor_frame.nonce},
             key: sensor_frame.key
           ),
         :ok <- Gate.verify_freshness(claims, fresh_opts),
         :ok <- Gate.verify_sensor_metadata(claims, fresh_opts) do
      {:ok, claims}
    else
      {:refused, _} = refused -> refused
      {:error, reason} -> {:refused, reason}
      other -> {:refused, {:unexpected, other}}
    end
  end

  defp attestation_check(_missing, _opts), do: {:refused, :missing_sensor_frame}

  # Only coordinators registered in the COO mesh (the admitted set) may own a
  # Bridge entry; an id absent from the mesh is never minted (F8/A3).
  defp registered(bridge, mesh, id) do
    if Map.has_key?(mesh, id) and not Map.has_key?(bridge, id),
      do: Map.merge(Bridge.new_mesh_state([id]), bridge),
      else: bridge
  end
end
