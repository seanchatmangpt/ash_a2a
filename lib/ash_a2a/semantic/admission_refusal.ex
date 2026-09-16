defmodule AshA2A.Semantic.AdmissionRefusal do
  @moduledoc """
  A typed refusal from the RFC S13 semantic admission pipeline.

  Every refusal names the exact **stage** that refused, a machine `:code`, the
  standing actually held when the refusal was raised, and the real engine
  evidence behind it. A refusal is a positive, replayable determination -- it is
  never a fallback for "nothing happened".

  ## Refusal is the answer to "could not determine" too (RFC S43)

  `determinacy: :undetermined` marks a refusal raised because the pipeline could
  not establish whether the predicate holds -- an engine error, an absent
  dialect, missing shapes, a host failure. Those are refusals, exactly like
  `determinacy: :violated`. The distinction is recorded for diagnosis, never so
  that a caller can choose to pass an undetermined predicate: both values reach
  the caller as the same `{:error, %Refusal{}}`.
  """

  @enforce_keys [:stage, :code, :determinacy, :standing]
  defstruct [:stage, :code, :determinacy, :standing, :detail, evidence: %{}]

  @type determinacy :: :violated | :undetermined

  @type t :: %__MODULE__{
          stage: atom(),
          code: atom(),
          determinacy: determinacy(),
          standing: AshA2A.Semantic.AdmissionStanding.t(),
          detail: term(),
          evidence: map()
        }

  @doc """
  Builds a refusal for a predicate the engine positively determined to be
  violated (e.g. a real SHACL report with violations).
  """
  @spec violated(atom(), atom(), AshA2A.Semantic.AdmissionStanding.t(), keyword()) :: t()
  def violated(stage, code, standing, opts \\ []),
    do: build(stage, code, :violated, standing, opts)

  @doc """
  Builds a refusal for a predicate the pipeline could not determine (RFC S43).

  "Could not check" is never "checked and passed": this constructor exists so
  the undetermined path is as explicit in the code as it is in the RFC.
  """
  @spec undetermined(atom(), atom(), AshA2A.Semantic.AdmissionStanding.t(), keyword()) :: t()
  def undetermined(stage, code, standing, opts \\ []),
    do: build(stage, code, :undetermined, standing, opts)

  defp build(stage, code, determinacy, standing, opts)
       when is_atom(stage) and is_atom(code) and is_atom(determinacy) do
    %__MODULE__{
      stage: stage,
      code: code,
      determinacy: determinacy,
      standing: standing,
      detail: Keyword.get(opts, :detail),
      evidence: Keyword.get(opts, :evidence, %{})
    }
  end

  @doc "Stable one-line rendering of a refusal, for logs and receipts."
  @spec describe(t()) :: String.t()
  def describe(%__MODULE__{} = refusal) do
    "REFUSED stage=#{refusal.stage} code=#{refusal.code} " <>
      "determinacy=#{refusal.determinacy} standing=#{refusal.standing}"
  end
end
