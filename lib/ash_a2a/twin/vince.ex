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
  `{:refuse, :escalate_multisig}`. The mechanical-prior interrogation hook
  (`check_claim/3`) consults a pluggable `AshA2A.Twin.MechanicalPrior`
  behaviour — the default `RefuseAll` stub is documented as the injection
  point for trade reticle packs.
  """

  alias AshA2A.Twin.Vince

  @enforce_keys [:prior, :challenges]
  defstruct prior: AshA2A.Twin.MechanicalPrior.RefuseAll,
            challenges: %{},
            gpm_floor: 0.22,
            tolerance: 0.0

  @type trade_ref :: term()
  @type t :: %Vince{
          prior: module(),
          challenges: %{trade_ref() => pos_integer()},
          gpm_floor: float(),
          tolerance: number()
        }

  @type intent :: %{
          required(:trade) => trade_ref(),
          required(:nte) => number(),
          required(:offer) => number()
        }

  @type challenge_map :: %{
          code: :monkey_math | :round_number_suspicious | :gpm_floor | :mechanical_prior,
          demanded_evidence: [String.t()],
          retry_token: reference()
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
      tolerance: Keyword.get(opts, :tolerance, 0.0)
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
      when is_number(nte) and is_number(offer) and nte != 0 do
    cond do
      Map.has_key?(v.challenges, trade) ->
        {v, {:refuse, :escalate_multisig}}

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

  @doc """
  Mechanical-prior interrogation hook: `check_claim(vince, claim, telemetry)`.

  `claim` and `telemetry` are opaque domain terms (e.g. a blown-motor claim
  with ambient-temp telemetry). Delegates to the configured prior module's
  `c:prior_verdict/2`. On a prior challenge/refusal, counter-punch messages
  are demanded mechanically (e.g. blown motor + high ambient temperature ->
  winding-resistance readings).
  """
  @spec check_claim(Vince.t(), term(), term()) ::
          {:admit, map()} | {:challenge, challenge_map()} | {:refuse, map()}
  def check_claim(%Vince{prior: prior} = v, claim, telemetry) do
    case prior.prior_verdict(claim, telemetry) do
      {:admit, ticket} ->
        {v, {:admit, ticket}}

      {:challenge, evidence, msg} ->
        {v, {:challenge, %{code: :mechanical_prior, demanded_evidence: evidence,
                           retry_token: make_ref(), msg: msg}}}

      {:refuse, reason} ->
        {v, {:refuse, %{code: :mechanical_prior, reason: reason}}}
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
    {%{v | challenges: Map.put(v.challenges, trade, 1)},
     {:challenge, %{code: code, demanded_evidence: evidence, retry_token: make_ref()}}}
  end
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
