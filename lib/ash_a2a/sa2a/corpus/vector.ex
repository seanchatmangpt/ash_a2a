defmodule AshA2A.SA2A.Corpus.Vector do
  @moduledoc """
  One conformance vector: a real Turtle graph plus the typed expectations from
  its `.expected.json` sidecar.

  The two expectation families are deliberately kept apart:

    * `expected_admission` / `expected_refusal` / `graph_digest` /
      `law_graph_digest` -- what RFC-SA2A-001 requires of ANY conformant
      runtime. Law.
    * `measured` -- what the pinned GraphLaw wasm actually did when the corpus
      was built. Evidence.

  `conformance` records whether the two agree today:

    * `:holds` -- the pinned engine satisfies the requirement.
    * `:failing_on_pinned_engine` -- the requirement is NOT satisfied; `failure`
      names the measured divergence. The vector is kept at the RFC's value, not
      weakened to the engine's, so it stays a live falsifier.
    * `:host_gate_required` -- the engine cannot decide this vector at all and
      the host must own the gate ahead of the engine boundary.

  Every expected value here is a digest or a typed refusal code. None is a
  serialized RDF string: comparing pretty-printed RDF across two runtimes would
  measure their serializers rather than their semantics.
  """

  @enforce_keys [:name, :file, :class, :graph, :expected_admission, :conformance]
  defstruct [
    :name,
    :file,
    :class,
    :description,
    :graph,
    :expected_admission,
    :expected_refusal,
    :graph_digest,
    :law_graph_digest,
    :digest_must_equal_vector,
    :digest_must_differ_from_vector,
    :conformance,
    :failure,
    rfc_sections: [],
    measured: %{}
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          file: String.t(),
          class: String.t(),
          description: String.t() | nil,
          graph: String.t(),
          expected_admission: :admitted | :refused,
          expected_refusal:
            %{code: atom(), dialect: String.t() | nil, severity: String.t() | nil} | nil,
          graph_digest: String.t() | nil,
          law_graph_digest: String.t() | nil,
          digest_must_equal_vector: String.t() | nil,
          digest_must_differ_from_vector: String.t() | nil,
          conformance: :holds | :failing_on_pinned_engine | :host_gate_required,
          failure: String.t() | nil,
          rfc_sections: [String.t()],
          measured: map()
        }

  @doc """
  The SHACL dialect status the pinned engine produced for this vector under each
  of the three severity-partitioned shape graphs, as
  `%{full: ..., violations_only: ..., warnings_only: ...}`.

  This is the measurement RFC S15 is decided from on the pinned artifact, whose
  wasm build does not expose per-result `sh:severity` at all.
  """
  @spec shacl_partition(t()) :: map()
  def shacl_partition(%__MODULE__{measured: m}),
    do: Map.get(m, "shacl_by_severity_partition", %{})

  @doc """
  Derives SA2A admission from the SHACL status of the **violations-only** shape
  graph, per RFC S15 ("a sh:Warning MUST NOT override a failing sh:Violation").

  The violations-only status alone decides admission, and that is the content of
  S15: no result at any lesser severity may change the answer, so there is
  nothing for the full-shapes status to contribute here. It contributes to
  `severity_class/2` instead, which distinguishes a clean graph from a
  warning-only one -- a real distinction, but not an admission-changing one.

      "REFUSED"  -> :refused   (at least one sh:Violation)
      "ADMITTED" -> :admitted  (no sh:Violation, whatever else was reported)

  Takes the status as a real string from an engine run, so the same function
  decides a live run and a recorded measurement identically.
  """
  @spec admission_from_severity(String.t()) :: :admitted | :refused
  def admission_from_severity("REFUSED"), do: :refused
  def admission_from_severity("ADMITTED"), do: :admitted

  @doc """
  Classifies a severity partition as `:violation`, `:warning_only`, or `:clean`
  from the violations-only and full-shapes SHACL statuses.

  Unlike `admission_from_severity/1` this is diagnostic, not decisional: a
  `:warning_only` graph is ADMITTED exactly like a `:clean` one.
  """
  @spec severity_class(String.t(), String.t()) :: :violation | :warning_only | :clean
  def severity_class("REFUSED", _full), do: :violation
  def severity_class("ADMITTED", "REFUSED"), do: :warning_only
  def severity_class("ADMITTED", "ADMITTED"), do: :clean
end
