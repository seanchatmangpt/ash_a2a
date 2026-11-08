defmodule AshA2A.Attention.Broker do
  @moduledoc """
  Article-14 attention broker (human oversight) — skeleton.

  Pure decision core over an in-memory ledger. Time is always injected
  (`now`), never sampled — no `Process.sleep` anywhere; courts advance the
  clock to exercise window expiry.

  Autonomy levels (Article-14 semantics):

    * `:autonomous` — may execute on silence after the window expires.
    * `:consent_by_silence` — may execute on silence after the window expires.
    * `:supervised` — NEVER auto-executes; silence yields
      `{:awaiting, :supervisor}` regardless of elapsed window.

  Decision cards are pre-validated option sets. GPM-floor cards (gross
  margin below the declared floor — the monkey-math family from
  `AshA2A.Twin.Vince`) ALWAYS carry `requires_signature: true`; this is
  asserted as an invariant, not a convention.
  """

  require Logger

  @typedoc "Autonomy level of a proposal."
  @type level :: :autonomous | :consent_by_silence | :supervised

  @typedoc "A pre-validated option on a decision card."
  @type option :: %{
          required(:option_id) => term(),
          required(:summary) => String.t(),
          required(:consequence) => String.t(),
          required(:requires_signature) => true
        }

  @typedoc "Decision card: pre-validated options presented for oversight."
  @type decision_card :: %{
          required(:options) => [option()],
          optional(:source) => :vince_challenge | :tony_triage | :gpm_floor | term(),
          optional(:gpm_floor_breach) => boolean()
        }

  @typedoc "A proposal open for attention."
  @type proposal :: %{
          required(:id) => reference(),
          required(:coordinator_id) => term(),
          required(:card) => any(),
          required(:level) => level(),
          required(:at_least_one_signed) => boolean(),
          required(:proposed_at) => integer()
        }

  @typedoc "Recorded human decision."
  @type override_decision :: :approve | :reject

  @typedoc "In-memory ledger: proposal id => override entries."
  @type ledger :: %{optional(reference()) => [map()]}

  @typedoc "Window outcomes."
  @type window_outcome ::
          {:executed, :silence_consent}
          | {:awaiting, :window_open}
          | {:awaiting, :supervisor}
          | {:refused, :already_decided}

  @typedoc "Escalation outcome."
  @type escalation :: {:page, :founder} | :no_escalation

  @doc "Levels that may auto-execute on silence after window expiry."
  @spec silence_eligible_levels() :: [level()]
  def silence_eligible_levels, do: [:autonomous, :consent_by_silence]

  @doc """
  Opens a proposal for attention: `propose/3` with
  `{coordinator_id, decision_card, opts}`. Opts: `:level` (default
  `:consent_by_silence`), `:now` (default 0).

  Cards built by `build_card/3` carry the GPM-floor invariant; raw cards
  are re-checked here via `enforce_gpm_floor_invariant/1` so neither
  constructor path can produce a GPM-floor card without a signature
  option.
  """
  @spec propose(term(), decision_card(), keyword()) :: {:ok, proposal()}
  def propose(coordinator_id, card, opts \\ []) when is_map(card) do
    level = Keyword.get(opts, :level, :consent_by_silence)
    now = Keyword.get(opts, :now, 0)

    {:ok,
     %{
       id: make_ref(),
       coordinator_id: coordinator_id,
       card: enforce_gpm_floor_invariant(card),
       level: level,
       proposed_at: now
     }}
  end

  @doc """
  Sliding-window consent by silence. `{proposal, window_ms, now, ledger}`.

  Returns:

    * `{:awaiting, :supervisor}` — level `:supervised`, before anything
      else is considered (supervised NEVER auto-executes).
    * `{:refused, :already_decided}` — a human override exists in the
      ledger; silence never displaces a recorded human decision.
    * `{:executed, :silence_consent}` — window expired and level allows.
    * `{:awaiting, :window_open}` — window not yet expired.
  """
  @spec consent_by_silence(proposal(), non_neg_integer(), integer(), ledger()) ::
          window_outcome()
  def consent_by_silence(proposal, window_ms, now, ledger \\ %{}) do
    cond do
      proposal.level == :supervised ->
        {:awaiting, :supervisor}

      Map.has_key?(ledger, proposal.id) ->
        {:refused, :already_decided}

      now - proposal.proposed_at >= window_ms and proposal.level in silence_eligible_levels() ->
        {:executed, :silence_consent}

      true ->
        {:awaiting, :window_open}
    end
  end

  @doc """
  Records a human decision against the proposal id in the in-memory
  ledger: `override/4` with `{proposal, actor_signature, decision,
  ledger}`. `decision` is `:approve` | `:reject`. Once recorded, silence
  is short-circuited for that proposal (`consent_by_silence/4` refuses).
  """
  @spec override(proposal(), term(), override_decision(), ledger()) ::
          {:ok, ledger(), map()}
  def override(proposal, actor_signature, decision, ledger \\ %{})
      when decision in [:approve, :reject] do
    entry = %{
      proposal_id: proposal.id,
      actor_signature: actor_signature,
      decision: decision,
      recorded_at: System.monotonic_time()
    }

    {:ok, Map.update(ledger, proposal.id, [entry], &[entry | &1]), entry}
  end

  @doc """
  Escalation path: when the ledger shows `N` or more proposals with no
  human decision (`opts[:unresolved_threshold]`, default 3), pages the
  founder. Typed, with a log line. `{ledger, opts}`.
  """
  @spec escalation_path(ledger(), keyword()) :: escalation()
  def escalation_path(ledger, opts \\ []) do
    threshold = Keyword.get(opts, :unresolved_threshold, 3)

    unresolved =
      ledger
      |> Enum.reject(fn {_id, entries} -> Enum.any?(entries, &(&1.decision != nil)) end)
      |> Map.new()

    if map_size(unresolved) >= threshold do
      Logger.warning("attention_broker: escalation — #{map_size(unresolved)} unresolved proposals; paging founder")

      {:page, :founder}
    else
      :no_escalation
    end
  end

  @doc """
  Pure card constructor integrating the landed stack:
  `build_card/3` with `{vince_challenge_or_nil, tony_triage_or_nil,
  opts}`. Builds options from the challenge state (demanded evidence /
  retry token) and triage output (routine vs escalation edges).

  GPM-floor law: a card sourced from a GPM-floor breach, or a Tony
  triage escalation edge, ALWAYS sets `requires_signature: true` on
  every option — asserted by `enforce_gpm_floor_invariant/1` and by the
  court.
  """
  @spec build_card(term() | nil, term() | nil, keyword()) :: decision_card()
  def build_card(challenge, triage, opts \\ []) do
    gpm_breach? =
      Keyword.get(opts, :gpm_floor_breach, false) or gpm_floor_challenge?(challenge) or
        triage_escalation?(triage)

    options =
      build_options(
        [
          {:accept, "accept the challenged claim as evidenced"},
          {:reject, "refuse the claim and re-scope the trade"},
          {:escalate, "route to a human supervisor"}
        ],
        "attention required: vince challenge and/or tony triage escalation edge",
        requires_signature: gpm_breach?
      )

    %{
      options: options,
      source: source(challenge, triage),
      gpm_floor_breach: gpm_breach?
    }
  end

  @doc """
  Invariant enforcement: if a card is flagged `gpm_floor_breach`, every
  option must (and will be forced to) carry `requires_signature: true`.
  Returns the corrected card. A court asserts the flag-then-force path.
  """
  @spec enforce_gpm_floor_invariant(decision_card()) :: decision_card()
  def enforce_gpm_floor_invariant(%{gpm_floor_breach: true} = card) do
    %{
      card
      | options:
          Enum.map(card.options, fn opt -> Map.put(opt, :requires_signature, true) end)
    }
  end

  def enforce_gpm_floor_invariant(card), do: card

  # -- Internals ------------------------------------------------------------

  defp gpm_floor_challenge?(%{code: code}) when code in [:gpm_floor, :gpm_breach, :monkey_math],
    do: true

  defp gpm_floor_challenge?(_), do: false

  defp triage_escalation?(nil), do: false
  defp triage_escalation?({[], []}), do: false
  defp triage_escalation?({_routine, [_ | _] = edges}), do: true
  defp triage_escalation?(_), do: false

  defp build_options(summaries, consequence, opts)
       when is_list(summaries) and is_binary(consequence) do
    Enum.map(summaries, fn {id, summary} ->
      %{
        option_id: id,
        summary: summary,
        consequence: consequence,
        requires_signature: Keyword.get(opts, :requires_signature, false)
      }
    end)
  end

  defp source(nil, triage), do: if(triage, do: :tony_triage, else: :manual)
  defp source(challenge, _triage), do: if(challenge, do: :vince_challenge, else: :manual)
end
