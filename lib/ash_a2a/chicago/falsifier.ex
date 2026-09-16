defmodule AshA2A.Chicago.Falsifier do
  @moduledoc """
  RFC-SA2A-002 §11 falsifier declaration.

  Every mandatory falsification test declares, before it runs:

    * the invariant under attack (`:invariant`)
    * the stimulus / mutation (`:stimulus`)
    * the boundary expected to decide (`:boundary`)
    * the forbidden standing or consequence (`:forbidden_outcome`)
    * the positive evidence that the attack was attempted (`:attempt_evidence`)
    * the evidence used to determine survival (`:survival_evidence`)
    * the guard whose removal must make it survive (`:guard`, §11 last paragraph, §22)

  The exact subject is bound by the run (`AshA2A.Chicago.Subject`), not per
  falsifier.

  ## Kinds

    * `:negative` -- an attack; passes only as `:falsifier_killed` (§12).
    * `:positive_control` -- a lawful case that must succeed, proving the
      boundary discriminates rather than refusing everything (§100, §73).
    * `:unsupported_control` -- a feature declared unsupported must surface as
      UNSUPPORTED, not REFUSED (§101).
    * `:measurement` -- a benchmark run (§84-§94); passes as `:measured` only
      when the measured path positively executed.

  ## OCEL predicates

  `:attempt_predicate` and `:outcome_predicate` are `AshA2A.Chicago.Query`
  predicates evaluated by the independent consumer over the durable OCEL
  artifact, scoped to the events attributed to this falsifier's stimulus.
  For `:negative` the outcome predicate describes the FORBIDDEN outcome; for
  `:positive_control` / `:unsupported_control` it describes the EXPECTED one.
  A result whose attempt the OCEL cannot corroborate never counts as passed
  (§104, §106).
  """

  alias AshA2A.Chicago.{FailureClass, Query}

  @kinds [:negative, :positive_control, :unsupported_control, :measurement]

  @enforce_keys [:id, :court_id, :kind, :invariant, :stimulus, :boundary]
  defstruct [
    :id,
    :court_id,
    :kind,
    :invariant,
    :stimulus,
    :boundary,
    :forbidden_outcome,
    :attempt_evidence,
    :survival_evidence,
    :guard,
    :attempt_predicate,
    :outcome_predicate,
    failure_class: nil,
    rfc_sections: [],
    tags: []
  ]

  @type kind :: :negative | :positive_control | :unsupported_control | :measurement

  @type t :: %__MODULE__{
          id: String.t(),
          court_id: String.t(),
          kind: kind(),
          invariant: String.t(),
          stimulus: String.t(),
          boundary: String.t(),
          forbidden_outcome: String.t() | nil,
          attempt_evidence: String.t() | nil,
          survival_evidence: String.t() | nil,
          guard: String.t() | nil,
          attempt_predicate: Query.predicate() | nil,
          outcome_predicate: Query.predicate() | nil,
          failure_class: FailureClass.t() | nil,
          rfc_sections: [String.t()],
          tags: [atom()]
        }

  @id_format ~r/^(CHI|SA2A)-[A-Z0-9]+(-[A-Z0-9]+)*-\d{3}$/

  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc """
  Builds a falsifier, raising `ArgumentError` on an incomplete §11 declaration.

  `:negative` falsifiers must name `:forbidden_outcome`, `:attempt_evidence`,
  `:survival_evidence` and `:guard`; every kind must name the invariant,
  stimulus and boundary. Predicates, when given, are validated structurally.
  """
  @spec new!(keyword() | map()) :: t()
  def new!(fields) do
    falsifier = struct!(__MODULE__, Map.new(fields))

    unless is_binary(falsifier.id) and Regex.match?(@id_format, falsifier.id) do
      raise ArgumentError,
            "falsifier id must match #{inspect(@id_format.source)} (e.g. \"CHI-BRCE-001\"), got: #{inspect(falsifier.id)}"
    end

    unless falsifier.kind in @kinds do
      raise ArgumentError, "falsifier #{falsifier.id}: kind must be one of #{inspect(@kinds)}"
    end

    required =
      [:court_id, :invariant, :stimulus, :boundary] ++
        if(falsifier.kind == :negative,
          do: [:forbidden_outcome, :attempt_evidence, :survival_evidence, :guard],
          else: [:attempt_evidence]
        )

    for key <- required, not non_empty_string?(Map.fetch!(falsifier, key)) do
      raise ArgumentError, "falsifier #{falsifier.id}: #{key} must be a non-empty string"
    end

    if falsifier.failure_class && not FailureClass.class?(falsifier.failure_class) do
      raise ArgumentError,
            "falsifier #{falsifier.id}: failure_class #{inspect(falsifier.failure_class)} is not an RFC-SA2A-002 §117 class"
    end

    for {key, predicate} <- [
          attempt_predicate: falsifier.attempt_predicate,
          outcome_predicate: falsifier.outcome_predicate
        ],
        predicate != nil do
      case Query.validate_predicate(predicate) do
        :ok -> :ok
        {:error, reason} -> raise ArgumentError, "falsifier #{falsifier.id}: #{key} #{reason}"
      end
    end

    falsifier
  end

  @doc "JSON-safe declaration, used for the falsifier corpus digest (§137)."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = f) do
    %{
      "id" => f.id,
      "court_id" => f.court_id,
      "kind" => Atom.to_string(f.kind),
      "invariant" => f.invariant,
      "stimulus" => f.stimulus,
      "boundary" => f.boundary,
      "forbidden_outcome" => f.forbidden_outcome,
      "attempt_evidence" => f.attempt_evidence,
      "survival_evidence" => f.survival_evidence,
      "guard" => f.guard,
      "attempt_predicate" => f.attempt_predicate && Query.predicate_to_json(f.attempt_predicate),
      "outcome_predicate" => f.outcome_predicate && Query.predicate_to_json(f.outcome_predicate),
      "failure_class" => f.failure_class && Atom.to_string(f.failure_class),
      "rfc_sections" => f.rfc_sections,
      "tags" => Enum.map(f.tags, &Atom.to_string/1)
    }
  end

  defp non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""
end
