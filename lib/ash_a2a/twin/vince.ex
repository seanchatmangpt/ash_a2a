defmodule AshA2A.Twin.Vince do
  @moduledoc """
  Vince — the adversarial twin: intent evaluator for the Communicating
  Digital Twins subsystem.

  Vince sits opposite the partner twin and evaluates every offer/claim
  against mechanical detectors ("Monkey Math") before any trust is extended:

    * exact-half split detector — the offer is exactly NTE/2 within a
      rounding tolerance (the lazy 50/50 anchor)
    * round-number detector — offer is a multiple of 100 while the NTE is
      not, i.e. the offer was chosen for its shape, not its contents.
      Calibration: round numbers on BOTH sides are normal (a whole-dollar
      NTE quoted as a whole-dollar offer is not suspicious); only the
      mismatch pattern flags.
    * GPM-floor detector — gross profit margin `(nte - offer) / nte` below
      the 22% floor, vocabulary per the `financial-margin-envelope` pack
      (`fme:floor` default 0.22, law `(NTE - quote)/NTE >= floor`).

  Evaluation returns the A2ATwin verdict shape:

      {:admit, ticket}
      {:challenge, %{code: ..., demanded_evidence: [...], retry_token: ref}}
      {:refuse, msg}

  Challenges are STATE: a repeat challenge on the same trade escalates to
  `{:refuse, :escalate_multisig}`; the ledger counts every challenge and
  escalation per trade (counter bounded) and the ledger itself is bounded by
  `:max_ledger` (default 10_000) — when full, a NEW challenge-worthy trade is
  refused with `%{code: :ledger_full}` rather than evicting (eviction would
  reset escalation).

  Malformed intents (non-map, missing keys, non-number or non-positive
  `nte`, non-number or negative `offer`) get a typed
  `{:refuse, %{code: :invalid_intent, reason: reason}}` and leave the ledger
  untouched. The mechanical-prior interrogation hook
  (`check_claim/3`) consults a pluggable `AshA2A.Twin.MechanicalPrior`
  behaviour — the default `RefuseAll` stub is documented as the injection
  point for trade reticle packs.
  """

  alias AshA2A.Twin.Vince

  @enforce_keys [:prior, :challenges]
  defstruct prior: AshA2A.Twin.MechanicalPrior.RefuseAll,
            challenges: %{},
            gpm_floor: 0.22,
            tolerance: 0.0,
            max_ledger: 10_000

  @max_count 1_000

  @type trade_ref :: term()
  @type t :: %Vince{
          prior: module(),
          challenges: %{trade_ref() => pos_integer()},
          gpm_floor: float(),
          tolerance: number(),
          max_ledger: pos_integer()
        }

  @type intent :: %{
          required(:trade) => trade_ref(),
          required(:nte) => number(),
          required(:offer) => number()
        }

  @type challenge_map :: %{
          required(:code) =>
            :monkey_math | :round_number_suspicious | :gpm_floor | :mechanical_prior,
          optional(:msg) => String.t(),
          required(:demanded_evidence) => [String.t()],
          required(:retry_token) => reference()
        }

  @type verdict ::
          {:admit, map()}
          | {:challenge, challenge_map()}
          | {:refuse, :escalate_multisig | map()}

  @doc "New Vince evaluator. `:prior` is an `AshA2A.Twin.MechanicalPrior` module."
  @spec new(keyword()) :: Vince.t()
  def new(opts \\ []) do
    %Vince{
      prior: Keyword.get(opts, :prior, AshA2A.Twin.MechanicalPrior.RefuseAll),
      challenges: %{},
      gpm_floor: Keyword.get(opts, :gpm_floor, 0.22),
      tolerance: Keyword.get(opts, :tolerance, 0.0),
      max_ledger: Keyword.get(opts, :max_ledger, 10_000)
    }
  end

  @doc """
  Evaluate an intent: `%{trade: ref, nte: number, offer: number}`.

  Detector order: GPM floor first (hard economic law), then exact-half,
  then round-number suspicion, then the mechanical prior verdict is folded
  in through `check_claim/3`. First firing detector wins. A repeat
  challenge on the same trade escalates to `{:refuse, :escalate_multisig}`.

  Returns `{new_state, verdict}` — the challenge ledger is state on Vince.
  """
  @spec evaluate_intent(Vince.t(), intent()) :: {Vince.t(), verdict()}
  def evaluate_intent(%Vince{} = v, %{trade: trade, nte: nte, offer: offer})
      when is_number(nte) and is_number(offer) and nte > 0 and offer >= 0 do
    cond do
      Map.has_key?(v.challenges, trade_key(trade)) ->
        escalate(v, trade)

      gpm_breach?(nte, offer, v.gpm_floor) ->
        challenge(v, trade, :gpm_floor, ["itemized_cost_breakdown", "subcontractor_quote_doc"])

      exact_half?(nte, offer, v.tolerance) ->
        challenge(v, trade, :monkey_math, ["trade_scope_statement", "labor_hours_breakdown"])

      round_suspicious?(nte, offer) ->
        challenge(v, trade, :round_number_suspicious, ["cost_basis_worksheet"])

      true ->
        ticket = %{trade: trade, gpm: gpm(nte, offer)}
        {v, {:admit, ticket}}
    end
  end

  def evaluate_intent(%Vince{} = v, intent), do: {v, invalid_intent(intent)}

  @doc """
  Mechanical-prior interrogation hook: `check_claim(vince, claim, telemetry)`.

  `claim` and `telemetry` are opaque domain terms (e.g. a blown-motor claim
  with ambient-temp telemetry). Delegates to the configured prior module's
  `c:prior_verdict/2`. On a prior challenge/refusal, counter-punch messages
  are demanded mechanically (e.g. blown motor + high ambient temperature ->
  winding-resistance readings).

  A prior that is not a loaded module exporting `prior_verdict/2`, or that
  returns an unexpected shape, yields a typed
  `{:refuse, %{code: :mechanical_prior, reason: {:invalid_prior, _} |
  {:invalid_prior_verdict, term}}}`.
  """
  @spec check_claim(Vince.t(), term(), term()) :: {Vince.t(), verdict()}
  def check_claim(%Vince{prior: prior} = v, claim, telemetry) do
    if is_atom(prior) and Code.ensure_loaded?(prior) and
         function_exported?(prior, :prior_verdict, 2) do
      v |> check_prior(prior.prior_verdict(claim, telemetry))
    else
      {v, {:refuse, %{code: :mechanical_prior, reason: {:invalid_prior, prior}}}}
    end
  end

  defp check_prior(v, verdict) do
    case verdict do
      {:admit, ticket} ->
        {v, {:admit, ticket}}

      {:challenge, evidence, msg} ->
        {v,
         {:challenge,
          %{
            code: :mechanical_prior,
            demanded_evidence: evidence,
            retry_token: make_ref(),
            msg: msg
          }}}

      {:refuse, reason} ->
        {v, {:refuse, %{code: :mechanical_prior, reason: reason}}}

      other ->
        {v, {:refuse, %{code: :mechanical_prior, reason: {:invalid_prior_verdict, other}}}}
    end
  end

  # -- Monkey Math detectors (pure) ----------------------------------------

  @doc """
  Exact-half split: `offer == nte/2` within `tolerance` (absolute, on the
  difference). `tolerance` defaults to 0 (exact equality) at `new/1`; a
  small positive tolerance absorbs cent-level rounding.
  """
  @spec exact_half?(number(), number(), number()) :: boolean()
  def exact_half?(nte, offer, tolerance \\ 0.0) do
    abs(offer - nte / 2) <= tolerance
  end

  @doc """
  Round-number suspicion: the offer is a multiple of 100 while the NTE is
  NOT. Round numbers on both sides are the normal quoting pattern and do
  not flag; only the shape mismatch is suspicious.
  """
  @spec round_suspicious?(number(), number()) :: boolean()
  def round_suspicious?(nte, offer) do
    rem100(offer) == 0 and rem100(nte) != 0
  end

  @doc "GPM = (nte - offer) / nte."
  @spec gpm(number(), number()) :: float()
  def gpm(nte, offer) when nte != 0, do: (nte - offer) / nte

  @doc "GPM-floor breach: `gpm(nte, offer) < floor` (floor itself admits)."
  @spec gpm_breach?(number(), number(), number()) :: boolean()
  def gpm_breach?(nte, offer, floor), do: gpm(nte, offer) < floor

  # -- Internals ------------------------------------------------------------

  defp rem100(n) when is_integer(n), do: Integer.mod(n, 100)
  defp rem100(n) when is_float(n), do: :erlang.trunc(n) |> Integer.mod(100)

  defp challenge(%Vince{} = v, trade, code, evidence) do
    if map_size(v.challenges) >= v.max_ledger do
      {v, {:refuse, %{code: :ledger_full, reason: :challenge_ledger_at_capacity}}}
    else
      key = trade_key(trade)

      count =
        case Map.fetch(v.challenges, key) do
          {:ok, n} -> bump(n)
          :error -> 1
        end

      {%{v | challenges: Map.put(v.challenges, key, count)},
       {:challenge, %{code: code, demanded_evidence: evidence, retry_token: make_ref()}}}
    end
  end

  defp escalate(%Vince{} = v, trade) do
    {%{v | challenges: Map.update!(v.challenges, trade_key(trade), &bump/1)},
     {:refuse, :escalate_multisig}}
  end

  defp bump(n), do: min(n + 1, @max_count)

  defp invalid_intent(intent) do
    reason =
      case intent do
        %{trade: _, nte: nte, offer: offer} ->
          cond do
            not is_number(nte) -> :nte_not_a_number
            nte <= 0 -> :nte_not_positive
            not is_number(offer) -> :offer_not_a_number
            true -> :offer_negative
          end

        _ ->
          :malformed_intent
      end

    {:refuse, %{code: :invalid_intent, reason: reason}}
  end

  # Ledger-identity normalization (lane F8): string trades are trimmed and
  # case-folded before ledger keying so "HVAC.Drain" / "hvac.drain" /
  # " hvac.drain " / "HVAC.Drain " collapse to one ledger identity — a
  # respelling after a challenge can no longer reset the escalate ledger.
  # Atoms and other terms pass through unchanged (atom-keyed courts keep
  # their exact keys).
  defp trade_key(trade) when is_binary(trade) do
    trade |> String.trim() |> String.downcase()
  end

  defp trade_key(trade), do: trade
end

defmodule AshA2A.Twin.MechanicalPrior do
  @moduledoc """
  Behaviour for mechanical priors consulted by `AshA2A.Twin.Vince.check_claim/3`.

  A prior maps `{claim, telemetry}` to a typed verdict. The default
  `AshA2A.Twin.MechanicalPrior.RefuseAll` stub refuses every claim; trade
  reticle packs (first one owned by lane X5) implement this behaviour to
  inject domain-specific interrogation tables.
  """

  @callback prior_verdict(claim :: term(), telemetry :: term()) ::
              {:admit, map()}
              | {:challenge, evidence :: [String.t()], msg :: String.t()}
              | {:refuse, reason :: term()}
end

defmodule AshA2A.Twin.MechanicalPrior.RefuseAll do
  @moduledoc """
  Default mechanical prior: refuse every claim.

  Injection point, not a policy: any real trade domain replaces this via
  `AshA2A.Twin.Vince.new(prior: MyReticle)`.
  """

  @behaviour AshA2A.Twin.MechanicalPrior

  @impl true
  def prior_verdict(_claim, _telemetry), do: {:refuse, :refuse_all_default_prior}
end
