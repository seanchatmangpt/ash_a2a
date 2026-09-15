defmodule AshA2A.BoardPersona.RiskAverseFiduciary do
  @moduledoc """
  A generic, synthetic, composite board archetype -- **not modeled on any real,
  named company or individual**. Encodes a risk-averse, fiduciary-duty-first
  decision posture drawn from well-established, real, publicly cited corporate
  governance literature: agency theory (Jensen & Meckling, 1976, "Theory of the
  Firm: Managerial Behavior, Agency Costs and Ownership Structure," _Journal of
  Financial Economics_) and enterprise risk-appetite framing (the COSO
  Enterprise Risk Management framework's real, well-known distinction between
  risk appetite and risk tolerance).

  The archetype's risk posture is encoded as real, structural capability
  shape, not prompt flavor alone: there is deliberately **no unconditional
  `:approve` action** on this resource. A caller (real or the semantic
  planning pipeline) genuinely cannot synthesize a plan admitting an
  unconditional approval capability for this persona, because no such
  capability exists in its real compiled `AshA2A.Info.capability_index/1` --
  the same fail-closed, capability-truth-over-prompt-wish discipline every
  other real gate in this project uses.

  See `AshA2A.BoardPersona.Deliberation` for how this resource is used
  alongside the other real persona archetypes to fan out one scenario across
  multiple distinct, real, closed decision spaces.
  """

  use Ash.Resource,
    domain: AshA2A.BoardPersona.RiskAverseFiduciaryDomain,
    data_layer: Ash.DataLayer.Simple,
    extensions: [AshA2A]

  actions do
    action :request_more_data, :map do
      argument(:rationale, :string, allow_nil?: false)

      run(fn input, _context ->
        {:ok, %{decision: :request_more_data, rationale: input.arguments.rationale}}
      end)
    end

    action :defer_decision, :map do
      argument(:rationale, :string, allow_nil?: false)
      argument(:defer_until, :string, default: "next scheduled review")

      run(fn input, _context ->
        {:ok,
         %{
           decision: :defer_decision,
           rationale: input.arguments.rationale,
           defer_until: input.arguments.defer_until
         }}
      end)
    end

    action :reject, :map do
      argument(:rationale, :string, allow_nil?: false)

      run(fn input, _context ->
        {:ok, %{decision: :reject, rationale: input.arguments.rationale}}
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
  end

  a2a do
    skill(:request_more_data, :request_more_data, consequence: :change)
    skill(:defer_decision, :defer_decision, consequence: :change)
    skill(:reject, :reject, consequence: :change)
    skill(:approve_with_conditions, :approve_with_conditions, consequence: :change)
  end
end

defmodule AshA2A.BoardPersona.RiskAverseFiduciaryDomain do
  @moduledoc "Real domain for `AshA2A.BoardPersona.RiskAverseFiduciary`."

  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(AshA2A.BoardPersona.RiskAverseFiduciary)
  end
end
