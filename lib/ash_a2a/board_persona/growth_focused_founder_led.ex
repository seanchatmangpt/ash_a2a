defmodule AshA2A.BoardPersona.GrowthFocusedFounderLed do
  @moduledoc """
  A generic, synthetic, composite board archetype -- **not modeled on any real,
  named company or individual**. Encodes a growth-focused, founder-led
  decision posture drawn from well-established, real, publicly cited
  governance literature on founder control and growth orientation: Noam
  Wasserman's *The Founder's Dilemmas: Anticipating and Avoiding the Pitfalls
  That Can Sink a Startup* (Princeton University Press, 2012), which
  documents founders' real, empirically observed preference for growth and
  control retention (the "rich vs. king" tradeoff) over conservative,
  risk-minimizing governance.

  The archetype's growth-oriented posture is encoded as real, structural
  capability shape, not prompt flavor alone: there is deliberately **no
  `:reject` action** on this resource. A caller (real or the semantic
  planning pipeline) genuinely cannot synthesize a plan admitting a flat
  refusal capability for this persona, because no such capability exists in
  its real compiled `AshA2A.Info.capability_index/1` -- a founder-led growth
  board defers (`:request_more_data`) or conditions (`:approve_with_conditions`)
  rather than flatly refusing, the same fail-closed, capability-truth-over-
  prompt-wish discipline `AshA2A.BoardPersona.RiskAverseFiduciary` (see its
  own moduledoc) uses for its own, opposite-shaped omission.

  See `AshA2A.BoardPersona.Deliberation` for how this resource is used
  alongside the other real persona archetypes to fan out one scenario across
  multiple distinct, real, closed decision spaces.
  """

  use Ash.Resource,
    domain: AshA2A.BoardPersona.GrowthFocusedFounderLedDomain,
    data_layer: Ash.DataLayer.Simple,
    extensions: [AshA2A]

  actions do
    action :approve, :map do
      argument(:rationale, :string, allow_nil?: false)

      run(fn input, _context ->
        {:ok, %{decision: :approve, rationale: input.arguments.rationale}}
      end)
    end

    action :approve_with_conditions, :map do
      argument(:rationale, :string, allow_nil?: false)
      argument(:conditions, {:array, :string}, allow_nil?: false)

      run(fn input, _context ->
        {:ok,
         %{
           decision: :approve_with_conditions,
           rationale: input.arguments.rationale,
           conditions: input.arguments.conditions
         }}
      end)
    end

    action :request_more_data, :map do
      argument(:rationale, :string, allow_nil?: false)

      run(fn input, _context ->
        {:ok, %{decision: :request_more_data, rationale: input.arguments.rationale}}
      end)
    end
  end

  a2a do
    skill(:approve, :approve, consequence: :change)
    skill(:approve_with_conditions, :approve_with_conditions, consequence: :change)
    skill(:request_more_data, :request_more_data, consequence: :change)
  end
end

defmodule AshA2A.BoardPersona.GrowthFocusedFounderLedDomain do
  @moduledoc "Real domain for `AshA2A.BoardPersona.GrowthFocusedFounderLed`."

  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(AshA2A.BoardPersona.GrowthFocusedFounderLed)
  end
end
