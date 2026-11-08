defmodule AshA2A.Copilot.Pipeline do
  @moduledoc """
  Dispatch pre-check chain for the Communicating Digital Twins subsystem.

  Wires three landed surfaces into one interception path:

    1. `AshA2A.Twin.Vince.evaluate_intent/2` — intent evaluation (GPM floor,
       monkey-math exact-half, round-number suspicion, optional mechanical
       prior via a loadable `AshA2A.Twin.MechanicalPrior` module).
    2. On challenge: return the challenge-as-state ledger entry (the ledger
       itself is state on the Vince struct, threaded through this pipeline —
       the pipeline is pure; callers own persistence via the returned state).
    3. On admit: `AshA2A.Twin.Tony.handle_inbound/2` strain-check of the
       coordinator (`AshA2A.Strain.Tensor.hyperplane_check/2` saturation
       gate) → shed to the senior queue or admit.
    4. On admit + capacity: `AshA2A.Attestation.Gate` on the sensor frame
       (enclave, freshness, sensor metadata).
    5. On attested: `AshA2A.Authority.PEP.assert_standing/4` — the authority
       hop (lane G4): verify the actor can act AT ALL before final admit.
       This is the LAST gate before admit; Vince/Tony/attestation order is
       unchanged.

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
  the Tony mesh and folds every verdict back into it as observations:

    * admit → `ticket_assigned` (`:active_leases` +1 for the coordinator)
    * Vince challenge → `challenge_received` with `source: :vince`
      (`:heuristic_frequency` +1)
    * refuse / escalate → `error_reported` (rolling error window)

  ## Order decision: strain-first (route/2 before Vince)

  `route/2` delegates to `Bridge.route/2` and is the cheap strain gate: it
  consults only the live tensor (no Vince interrogation, no attestation).
  Dispatch callers run `route/2` BEFORE `check/3`. Rationale: a saturated
  coordinator cannot take the ticket regardless of intent quality, so
  evaluating Vince first would burn an expensive interrogation (and mutate
  its challenge ledger) on a ticket that is shed anyway. Shedding first
  protects the human and keeps the Vince ledger clean of tickets that never
  had a coordinator. Inside `check/3` the existing per-coordinator Tony
  gate still runs after Vince (it is keyed to `intent.coordinator_id`,
  which Vince's verdict does not change); the mesh-level shed decision is
  `route/2`'s job and happens before Vince by construction.

  The pipeline is **pure**: twins are called via their module functions and
  all state (Vince challenge ledger, Tony mesh, Bridge mesh_state) is
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
      | {:escalated, %{proposal_id: reference(), card: map()}}
      | {:shed, {:senior_queue, relief_target}}

  Every branch returns a typed structured result; no strings-as-state.
  """

  alias AshA2A.Attestation.Gate
  alias AshA2A.Authority.PEP
  alias AshA2A.Strain.Bridge
  alias AshA2A.Strain.Tensor
  alias AshA2A.Twin.Tony
  alias AshA2A.Twin.Vince

  @type result ::
          {:ok, map()}
          | {:challenge, Vince.challenge_map()}
          | {:refuse, :escalate_multisig | map()}
          | {:escalated, %{proposal_id: reference(), card: map()}}
          | {:shed, {:senior_queue, :tony_relief}}

  @type state :: %{vince: Vince.t(), mesh: Tony.mesh(), bridge: Bridge.mesh_state()}

  @doc """
  Run the interception path for one intent over the given pipeline state.

  Returns `{new_state, result}`. `state` carries the Vince evaluator (its
  challenge ledger is the challenge-as-state store) and the Tony mesh.

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
    * `:attention_broker` — an `AshA2A.Attention.Broker` module (lane G5).
      When set, escalate-class refuses (Vince repeat-challenge
      `:escalate_multisig`, GPM-floor-class refuses) open a broker proposal
      and return `{:escalated, %{proposal_id, card}}` instead. When absent,
      refuses pass through unchanged.
    * `:tony_triage` — optional Tony triage payload folded into the
      escalation card by `Broker.build_card/3`.
    * `:proposal_level` — broker autonomy level for escalated proposals
      (default `:consent_by_silence`; use `:supervised` to forbid
      silence-consent execution).
    * `:coordinator_id` — fallback proposal owner when the intent carries
      no `:coordinator_id`.
  """
  @spec check(map(), state(), keyword()) :: {state(), result()}
  def check(intent, state, opts \\ [])

  def check(
        %{trade: trade, nte: nte, offer: offer, coordinator_id: coordinator_id} = intent,
        %{vince: vince, mesh: mesh} = state,
        opts
      )
      when is_number(nte) and is_number(offer) and nte != 0 do
    vince_mod = Keyword.get(opts, :vince_mod, Vince)

    {vince1, vince_verdict} =
      evaluate_vince(vince_mod, vince, %{trade: trade, nte: nte, offer: offer})

    case vince_verdict do
      {:refuse, _} = refuse ->
        {%{state | vince: vince1, bridge: record(state, intent.coordinator_id, :error_reported)},
         maybe_escalated(intent, refuse, opts)}

      {:challenge, _} = challenge ->
        {%{state | vince: vince1,
           bridge: record(state, intent.coordinator_id, {:challenge_received, :vince})},
         challenge}

      {:admit, _ticket} ->
        admit_path(intent, %{state | vince: vince1}, opts)
    end
  end

  @doc "Build initial pipeline state: `%{vince: Vince.new(opts), mesh: mesh, bridge: Bridge.new_mesh_state()}`."
  @spec init(keyword(), Tony.mesh()) :: state()
  def init(vince_opts \\ [], mesh \\ %{}) do
    %{vince: Vince.new(vince_opts), mesh: mesh, bridge: Bridge.new_mesh_state()}
  end

  @doc """
  Strain gate over the live Bridge mesh_state: delegates to
  `AshA2A.Strain.Bridge.route/2`. Cheap — consults only the tensor, never
  Vince — so callers run this BEFORE `check/3` (see moduledoc order
  decision). Returns `{:assign, coordinator_id}` or
  `{:shed, {:senior_queue, reason}}`.
  """
  @spec route(map(), Bridge.mesh_state()) :: {:assign, term()} | {:shed, {:senior_queue, term()}}
  def route(ticket, mesh_state), do: Bridge.route(ticket, mesh_state)

  # -- admit path: mechanical prior → strain → attestation -------------------

  # Vince may be injected as a module or a 2-arity fun (court instrumentation).
  defp evaluate_vince(mod, vince, claim) when is_atom(mod), do: mod.evaluate_intent(vince, claim)
  defp evaluate_vince(fun, vince, claim) when is_function(fun, 2), do: fun.(vince, claim)

  defp admit_path(intent, state, opts) do
    with {:prior, :ok} <- {:prior, mechanical_prior(intent, opts)},
         {:strain, {:admit, id}} <- {:strain, Tony.handle_inbound(state.mesh, %{coordinator_id: intent.coordinator_id})},
         {:attestation, {:ok, claims}} <-
           {:attestation, attestation_check(intent.sensor_frame, opts)},
         {:authority, :ok} <- {:authority, authority_check(intent, opts)} do
      {%{state | bridge: record(state, id, :ticket_assigned)},
       {:ok,
        %{
          trade: intent.trade,
          coordinator_id: id,
          gpm: Vince.gpm(intent.nte, intent.offer),
          attestation_claims: claims
        }}}
    else
      {:prior, {:challenge, _} = challenge} -> {state, challenge}
      {:prior, {:refuse, _} = refuse} ->
        {%{state | bridge: record(state, intent.coordinator_id, :error_reported)},
         maybe_escalated(intent, refuse, opts)}
      {:strain, {:shed, _} = shed} -> {state, shed}
      {:attestation, {:refused, _} = refused} ->
        {%{state | bridge: record(state, intent.coordinator_id, :error_reported)},
         {:refuse, %{code: :attestation, reason: refused}}}
      {:authority, {:refused, :insufficient_authority, detail}} ->
        {%{state | bridge: record(state, intent.coordinator_id, :error_reported)},
         {:refuse, %{code: :authority, reason: detail}}}
    end
  end

  # Authority hop (lane G4) — the LAST gate before final admit. Active only
  # when `:authority_source` is configured; absence is a documented skip
  # (PEP's DenyAll default would refuse every existing caller otherwise).
  defp authority_check(intent, opts) do
    case Keyword.get(opts, :authority_source) do
      nil ->
        :ok

      source ->
        actor_id = Map.get(intent, :actor_id)

        cond do
          is_nil(actor_id) ->
            {:refused, :insufficient_authority, %{reason: :missing_actor_id, action: "a2a:copilot.check"}}

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
    case Keyword.get(opts, :prior, detect_prior()) do
      nil ->
        :ok

      prior when is_atom(prior) ->
        claim = %{trade: intent.trade, nte: intent.nte, offer: intent.offer}
        telemetry = Map.get(intent, :telemetry, %{})

        case prior.prior_verdict(claim, telemetry) do
          {:admit, _} -> :ok
          {:challenge, evidence, msg} -> {:challenge, %{code: :mechanical_prior, demanded_evidence: evidence, retry_token: make_ref(), msg: msg}}
          # surface the prior's own classification code when it carries one
          # (e.g. :gpm_breach) so the escalation feed can classify the refuse;
          # the full reason payload is preserved either way.
          {:refuse, %{code: code} = reason} -> {:refuse, %{code: code, reason: reason}}
          {:refuse, reason} -> {:refuse, %{code: :mechanical_prior, reason: reason}}
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
  # module), a Vince repeat-challenge refuse (`:escalate_multisig`) or a
  # GPM-floor-class refuse is escalated: a decision card is built via the
  # broker's `build_card/3` (Vince challenge payload + optional `:tony_triage`)
  # and a proposal opened via `propose/3`, and the pipeline returns
  # `{:escalated, %{proposal_id, card}}` instead of the bare refuse.
  #
  # Unconfigured → typed refuse, unchanged, no broker call (documented skip).
  # Pure: no clock sampling (broker `:now` comes from opts, default 0);
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

      broker when is_atom(broker) ->
        coordinator_id = Map.get(intent, :coordinator_id) || Keyword.get(opts, :coordinator_id)
        triage = Keyword.get(opts, :tony_triage)

        card = broker.build_card(challenge_payload, triage, gpm_floor_breach: gpm_breach?)

        {:ok, proposal} =
          broker.propose(coordinator_id, card,
            level: Keyword.get(opts, :proposal_level, :consent_by_silence),
            now: Keyword.get(opts, :now, 0)
          )

        {:escalated,
         %{proposal_id: proposal.id, card: proposal.card, proposal: proposal}}
    end
  end

  # -- attestation gate chain -------------------------------------------------

  # Fold a pipeline verdict into the live Bridge mesh_state (Z7 seam).
  defp record(%{bridge: bridge}, coordinator_id, :ticket_assigned) do
    Bridge.record_observation(bridge, coordinator_id, %{type: :ticket_assigned})
  end

  defp record(%{bridge: bridge}, coordinator_id, {:challenge_received, :vince}) do
    Bridge.record_observation(bridge, coordinator_id, %{
      type: :challenge_received,
      source: :vince
    })
  end

  defp record(%{bridge: bridge}, coordinator_id, :error_reported) do
    Bridge.record_observation(bridge, coordinator_id, %{type: :error_reported, error: true})
  end

  defp attestation_check(sensor_frame, opts) do
    now = Keyword.get(opts, :now, System.system_time(:second))
    staleness = Map.get(sensor_frame, :max_staleness_sec, 90)

    fresh_opts = [now: now, max_staleness_sec: staleness]

    with {:ok, claims} <- Gate.verify_enclave({sensor_frame.device_token, sensor_frame.nonce}, key: sensor_frame.key),
         :ok <- Gate.verify_freshness(claims, fresh_opts),
         :ok <- Gate.verify_sensor_metadata(claims, fresh_opts) do
      {:ok, claims}
    else
      {:refused, _} = refused -> refused
      {:error, reason} -> {:refused, reason}
    end
  end
end
