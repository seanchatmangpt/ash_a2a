defmodule AshA2A.Chicago.Result do
  @moduledoc """
  The outcome of executing one `AshA2A.Chicago.Falsifier`.

  The constructors encode the RFC-SA2A-002 Chicago rule (§12) so a court
  cannot record a pass without positive attempt evidence:

      PASS = AttemptObserved ∧ ViolationDidNotAcquireStanding

  never `PASS = ¬ObservedViolation`.

    * `negative/2`: `attempt_observed?: true` and `forbidden_outcome_observed?:
      false` -> `:falsifier_killed`; forbidden observed -> `:falsifier_survived`;
      anything undetermined (attempt not positively observed, or forbidden
      outcome `:unknown`) -> `:unknown` (§130).
    * `positive/2`: attempt observed and expected outcome observed ->
      `:positive_control_passed`; attempt observed, expected absent ->
      `:positive_control_failed`; otherwise `:unknown`.
    * `measured/2`: attempt observed -> `:measured`; otherwise `:unknown`.
    * `not_applicable/2`, `unsupported/2`, `blocked/3`, `build_broken/2`,
      `unknown/3` record the remaining lawful outcomes.

  `:ocel_corroborated?` starts `nil` and is set by `AshA2A.Chicago.Runner`
  after the independent consumer evaluates the falsifier's predicates against
  the durable OCEL artifact. A result is only counted as passed for standing
  when it is corroborated (`counts_as_pass?/1`).
  """

  alias AshA2A.Chicago.{FailureClass, Falsifier}

  @verdicts [
    :falsifier_killed,
    :falsifier_survived,
    :positive_control_passed,
    :positive_control_failed,
    :measured,
    :unknown,
    :blocked,
    :build_broken,
    :unsupported,
    :not_applicable
  ]

  @passing [:falsifier_killed, :positive_control_passed, :measured]

  @enforce_keys [:falsifier_id, :court_id, :kind, :verdict]
  defstruct [
    :falsifier_id,
    :court_id,
    :gate,
    :kind,
    :verdict,
    :attempt_observed?,
    :outcome_observed?,
    :failure_class,
    :detail,
    :duration_us,
    ocel_corroborated?: nil,
    ocel_detail: nil,
    evidence: %{},
    measurements: %{}
  ]

  @type verdict ::
          :falsifier_killed
          | :falsifier_survived
          | :positive_control_passed
          | :positive_control_failed
          | :measured
          | :unknown
          | :blocked
          | :build_broken
          | :unsupported
          | :not_applicable

  @type t :: %__MODULE__{
          falsifier_id: String.t(),
          court_id: String.t(),
          gate: 1..12 | nil,
          kind: Falsifier.kind(),
          verdict: verdict(),
          attempt_observed?: boolean() | :unknown | nil,
          outcome_observed?: boolean() | :unknown | nil,
          failure_class: FailureClass.t() | nil,
          detail: String.t() | nil,
          duration_us: non_neg_integer() | nil,
          ocel_corroborated?: boolean() | nil,
          ocel_detail: String.t() | nil,
          evidence: map(),
          measurements: map()
        }

  @spec verdicts() :: [verdict()]
  def verdicts, do: @verdicts

  @doc """
  Result of a `:negative` falsifier.

  Required: `:attempt_observed?` (must be literally `true` to count) and
  `:forbidden_outcome_observed?` (`true | false | :unknown`). Optional:
  `:evidence` (JSON-safe map), `:detail`, `:failure_class` (defaults to the
  falsifier's declared class when it survives).
  """
  @spec negative(Falsifier.t(), keyword()) :: t()
  def negative(%Falsifier{kind: :negative} = f, opts) do
    attempt = Keyword.fetch!(opts, :attempt_observed?)
    forbidden = Keyword.fetch!(opts, :forbidden_outcome_observed?)

    {verdict, class} =
      cond do
        attempt != true ->
          {:unknown, :ocel_evidence_incomplete}

        forbidden == true ->
          {:falsifier_survived, Keyword.get(opts, :failure_class, f.failure_class)}

        forbidden == false ->
          {:falsifier_killed, nil}

        true ->
          {:unknown, Keyword.get(opts, :failure_class, :ocel_evidence_incomplete)}
      end

    build(f, verdict, class, attempt, forbidden, opts)
  end

  @doc "Result of a `:positive_control` or `:unsupported_control` falsifier."
  @spec positive(Falsifier.t(), keyword()) :: t()
  def positive(%Falsifier{kind: kind} = f, opts)
      when kind in [:positive_control, :unsupported_control] do
    attempt = Keyword.fetch!(opts, :attempt_observed?)
    expected = Keyword.fetch!(opts, :expected_outcome_observed?)

    {verdict, class} =
      cond do
        attempt != true ->
          {:unknown, :ocel_evidence_incomplete}

        expected == true ->
          {:positive_control_passed, nil}

        expected == false ->
          {:positive_control_failed, Keyword.get(opts, :failure_class, f.failure_class)}

        true ->
          {:unknown, Keyword.get(opts, :failure_class, :ocel_evidence_incomplete)}
      end

    build(f, verdict, class, attempt, expected, opts)
  end

  @doc "Result of a `:measurement` falsifier (benchmark). `:measurements` is a JSON-safe map."
  @spec measured(Falsifier.t(), keyword()) :: t()
  def measured(%Falsifier{kind: :measurement} = f, opts) do
    attempt = Keyword.fetch!(opts, :attempt_observed?)
    measurements = Keyword.get(opts, :measurements, %{})

    {verdict, class} =
      if attempt == true and map_size(measurements) > 0,
        do: {:measured, nil},
        else: {:unknown, :ocel_evidence_incomplete}

    %{build(f, verdict, class, attempt, nil, opts) | measurements: measurements}
  end

  @spec unknown(Falsifier.t(), String.t(), FailureClass.t() | nil) :: t()
  def unknown(%Falsifier{} = f, detail, class \\ nil),
    do: build(f, :unknown, class, :unknown, :unknown, detail: detail)

  @spec blocked(Falsifier.t(), String.t(), FailureClass.t()) :: t()
  def blocked(%Falsifier{} = f, detail, class \\ :resource_blocked),
    do: build(f, :blocked, class, nil, nil, detail: detail)

  @spec build_broken(Falsifier.t(), String.t()) :: t()
  def build_broken(%Falsifier{} = f, detail),
    do: build(f, :build_broken, :build_broken, nil, nil, detail: detail)

  @doc "The implementation structurally lacks the capability under test (§101)."
  @spec unsupported(Falsifier.t(), String.t()) :: t()
  def unsupported(%Falsifier{} = f, detail),
    do: build(f, :unsupported, :unsupported, nil, nil, detail: detail)

  @spec not_applicable(Falsifier.t(), String.t()) :: t()
  def not_applicable(%Falsifier{} = f, detail),
    do: build(f, :not_applicable, nil, nil, nil, detail: detail)

  @doc "True for a verdict that can contribute to a pass (before corroboration)."
  @spec passing_verdict?(t()) :: boolean()
  def passing_verdict?(%__MODULE__{verdict: verdict}), do: verdict in @passing

  @doc "Passed AND corroborated by the independent OCEL consumer."
  @spec counts_as_pass?(t()) :: boolean()
  def counts_as_pass?(%__MODULE__{} = r), do: passing_verdict?(r) and r.ocel_corroborated? == true

  @spec failed?(t()) :: boolean()
  def failed?(%__MODULE__{verdict: verdict}),
    do: verdict in [:falsifier_survived, :positive_control_failed]

  @doc "JSON-safe form."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = r) do
    %{
      "falsifier_id" => r.falsifier_id,
      "court_id" => r.court_id,
      "gate" => r.gate,
      "kind" => Atom.to_string(r.kind),
      "verdict" => FailureClass.wire(r.verdict),
      "attempt_observed" => json_tri(r.attempt_observed?),
      "outcome_observed" => json_tri(r.outcome_observed?),
      "failure_class" => r.failure_class && FailureClass.wire(r.failure_class),
      "detail" => r.detail,
      "duration_us" => r.duration_us,
      "ocel_corroborated" => r.ocel_corroborated?,
      "ocel_detail" => r.ocel_detail,
      "evidence" => AshA2A.Chicago.Json.safe(r.evidence),
      "measurements" => AshA2A.Chicago.Json.safe(r.measurements)
    }
  end

  defp build(%Falsifier{} = f, verdict, class, attempt, outcome, opts) do
    %__MODULE__{
      falsifier_id: f.id,
      court_id: f.court_id,
      kind: f.kind,
      verdict: verdict,
      attempt_observed?: attempt,
      outcome_observed?: outcome,
      failure_class: class,
      detail: Keyword.get(opts, :detail),
      evidence: Keyword.get(opts, :evidence, %{}),
      duration_us: Keyword.get(opts, :duration_us)
    }
  end

  defp json_tri(value) when is_boolean(value) or is_nil(value), do: value
  defp json_tri(value), do: to_string(value)
end
