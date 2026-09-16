defmodule AshA2A.Chicago.FailureClass do
  @moduledoc """
  RFC-SA2A-002 §117 failure classes (by failed transition) and §23 standing
  vocabulary.

  Failures are classified by the transition that failed, never summarized as
  "tests failed".
  """

  @type t ::
          :identity_failure
          | :admission_failure
          | :validator_failure
          | :meta_admission_failure
          | :planning_failure
          | :bound_failure
          | :authority_failure
          | :receipt_failure
          | :actuation_failure
          | :postcondition_failure
          | :replay_failure
          | :fresh_consumer_failure
          | :ocel_validation_failure
          | :ocel_evidence_incomplete
          | :cross_runtime_divergence
          | :resource_blocked
          | :build_broken
          | :unsupported

  @classes [
    :identity_failure,
    :admission_failure,
    :validator_failure,
    :meta_admission_failure,
    :planning_failure,
    :bound_failure,
    :authority_failure,
    :receipt_failure,
    :actuation_failure,
    :postcondition_failure,
    :replay_failure,
    :fresh_consumer_failure,
    :ocel_validation_failure,
    :ocel_evidence_incomplete,
    :cross_runtime_divergence,
    :resource_blocked,
    :build_broken,
    :unsupported
  ]

  @standings [
    :unknown,
    :partial_alive,
    :alive,
    :blocked,
    :build_broken,
    :unsupported,
    :refused,
    :falsifier_killed,
    :falsifier_survived,
    :conformant,
    :nonconformant,
    :requalifying
  ]

  @spec classes() :: [t()]
  def classes, do: @classes

  @spec class?(term()) :: boolean()
  def class?(value), do: value in @classes

  @doc "§23 standing vocabulary (kept distinct; never collapsed)."
  @spec standings() :: [atom()]
  def standings, do: @standings

  @spec standing?(term()) :: boolean()
  def standing?(value), do: value in @standings

  @doc "Wire form: `:ocel_evidence_incomplete` -> `\"OCEL_EVIDENCE_INCOMPLETE\"`."
  @spec wire(atom()) :: String.t()
  def wire(atom) when is_atom(atom), do: atom |> Atom.to_string() |> String.upcase()
end
