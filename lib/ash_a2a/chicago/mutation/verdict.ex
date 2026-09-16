defmodule AshA2A.Chicago.Mutation.Verdict do
  @moduledoc """
  Outcome of `AshA2A.Chicago.Mutation.qualify/2` for one mutation (§22, §97).

    * `:verdict` -- `:mutant_killed | :mutant_survived | :blocked | :unknown`
    * `:court_verdicts` -- `%{court_id => :killed | :survived | :unknown}`: a
      court that survives while another kills is still vacuous for the guard
    * `:killed_by` -- falsifier ids that newly failed under the mutant
    * `:mutant_calls` -- how many times the mutated function actually ran
      (`:erlang.trace_pattern/3` `call_count`), `nil` when not measurable
    * `:baseline` / `:mutant` -- where the durable evidence of each run lives
      and the digests the verdict was read from
  """

  defstruct [
    :mutation_id,
    :target,
    :verdict,
    :code,
    :detail,
    :mutant_calls,
    :applied,
    :restored,
    :baseline,
    :mutant,
    killers: [],
    killer_courts: [],
    missing_courts: [],
    court_verdicts: %{},
    killed_by: [],
    survived_courts: []
  ]

  @type verdict :: :mutant_killed | :mutant_survived | :blocked | :unknown

  @type t :: %__MODULE__{
          mutation_id: String.t(),
          target: String.t(),
          verdict: verdict(),
          code: atom() | nil,
          detail: String.t() | nil,
          mutant_calls: non_neg_integer() | nil,
          applied: map() | nil,
          restored: map() | nil,
          baseline: map() | nil,
          mutant: map() | nil,
          killers: [String.t()],
          killer_courts: [String.t()],
          missing_courts: [String.t()],
          court_verdicts: %{String.t() => :killed | :survived | :unknown},
          killed_by: [String.t()],
          survived_courts: [String.t()]
        }

  @doc "JSON-safe form."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = v) do
    AshA2A.Chicago.Json.safe(%{
      "mutation_id" => v.mutation_id,
      "target" => v.target,
      "verdict" => v.verdict,
      "code" => v.code,
      "detail" => v.detail,
      "killers" => v.killers,
      "killer_courts" => v.killer_courts,
      "missing_courts" => v.missing_courts,
      "court_verdicts" => v.court_verdicts,
      "killed_by" => v.killed_by,
      "survived_courts" => v.survived_courts,
      "mutant_calls" => v.mutant_calls,
      "applied" => v.applied,
      "restored" => v.restored,
      "baseline" => v.baseline,
      "mutant" => v.mutant
    })
  end
end
