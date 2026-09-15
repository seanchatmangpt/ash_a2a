defmodule AshA2A.BoardPersona.ActivistPressured do
  @moduledoc """
  A generic, synthetic, composite board archetype -- **not modeled on any real,
  named company or individual**. Encodes a decision posture under real,
  publicly cited activist-investor pressure dynamics: Brav, Jiang, Partnoy &
  Thomas, "Hedge Fund Activism, Corporate Governance, and Firm Performance,"
  _The Journal of Finance_, 63(4), 2008 -- a real, well-known empirical study
  of how activist campaigns push boards toward decisive binary outcomes and,
  when a board and an activist cannot converge, toward putting the matter
  directly to shareholders.

  The archetype's posture is encoded as real, structural capability shape,
  not prompt flavor alone: unlike `AshA2A.BoardPersona.RiskAverseFiduciary`
  (no unconditional `:approve`) and `AshA2A.BoardPersona.GrowthFocusedFounderLed`
  (no `:reject`), this resource carries **both** `:approve` and `:reject` --
  an activist-pressured board is pushed toward decisive binary outcomes -- plus
  a third, distinct `:escalate_to_shareholder_vote` action with no equivalent
  on either other persona, modeling the real activist tactic of forcing an
  unresolved board disagreement to a shareholder vote rather than settling it
  internally. A caller (real or the semantic planning pipeline) can only
  synthesize a plan admitting one of these three real, closed capabilities,
  never a `:defer_decision` or `:request_more_data`-shaped capability this
  persona's compiled `AshA2A.Info.capability_index/1` simply does not carry.

  See `AshA2A.BoardPersona.Deliberation` for how this resource is used
  alongside the other real persona archetypes to fan out one scenario across
  multiple distinct, real, closed decision spaces.
  """

  use Ash.Resource,
    domain: AshA2A.BoardPersona.ActivistPressuredDomain,
    data_layer: Ash.DataLayer.Simple,
    extensions: [AshA2A]

  actions do
    action :approve, :map do
      argument(:rationale, :string, allow_nil?: false)

      run(fn input, _context ->
        {:ok, %{decision: :approve, rationale: input.arguments.rationale}}
      end)
    end

    action :reject, :map do
      argument(:rationale, :string, allow_nil?: false)

      run(fn input, _context ->
        {:ok, %{decision: :reject, rationale: input.arguments.rationale}}
      end)
    end

    action :escalate_to_shareholder_vote, :map do
      argument(:rationale, :string, allow_nil?: false)
      argument(:proposal, :string, allow_nil?: false)

      run(fn input, _context ->
        {:ok,
         %{
           decision: :escalate_to_shareholder_vote,
           rationale: input.arguments.rationale,
           proposal: input.arguments.proposal
         }}
      end)
    end
  end

  a2a do
    skill(:approve, :approve, consequence: :change)
    skill(:reject, :reject, consequence: :change)
    skill(:escalate_to_shareholder_vote, :escalate_to_shareholder_vote, consequence: :change)
  end
end

defmodule AshA2A.BoardPersona.ActivistPressuredDomain do
  @moduledoc "Real domain for `AshA2A.BoardPersona.ActivistPressured`."

  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(AshA2A.BoardPersona.ActivistPressured)
  end
end
