defmodule AshA2A.Semantic.AdmissionStanding do
  @moduledoc """
  Ordered semantic standing for a candidate graph moving through the RFC S13
  admission pipeline.

  Standing is **evidence of what has been determined**, never permission to act.
  Reaching `:admitted` says every required predicate was checked by a real
  engine and held; it grants no authority whatsoever (RFC S4.2/S28). Authority
  in this codebase lives only behind `AshA2A.Authority` and the
  `AshA2A.CommandBus` consequence boundary, and nothing in this module can
  produce it.

  ## Integration point

  This is the minimal real transition contract `AshA2A.Semantic.AdmissionPipeline`
  needs, defined here because no `AshA2A.Semantic.AdmissionStanding` existed on `main`
  at branch point `54e16c0`. If a richer sibling implementation lands, the
  contract to preserve is exactly: an ordered stage list (`stages/0`), a
  monotonic single-step `advance/2`, and `reached?/2`. `AshA2A.Semantic.IR`'s
  own `:standing` field (`:candidate` | `:admitted`) is a coarser two-valued
  view of the same axis and is deliberately left untouched -- `:candidate` here
  maps onto `IR`'s `:candidate`, and only this module's `:admitted` maps onto
  `IR`'s `:admitted`.

  ## Monotonicity

  `advance/2` only ever moves forward by exactly one stage. There is no
  function in this module that lowers standing or skips a stage, so a caller
  cannot reach `:admitted` without having passed through every intermediate
  stage in order -- that structural property is what makes RFC S19's
  "admitted set is the intersection of all required predicates" enforceable
  rather than advisory.
  """

  @stages [
    :candidate,
    :parsed,
    :identified,
    :shex_conformant,
    :shacl_conformant,
    :closed,
    :falsifiers_clear,
    :provenance_grounded,
    :profile_conformant,
    :admitted
  ]

  @type t ::
          :candidate
          | :parsed
          | :identified
          | :shex_conformant
          | :shacl_conformant
          | :closed
          | :falsifiers_clear
          | :provenance_grounded
          | :profile_conformant
          | :admitted

  @doc "The ordered standing ladder, lowest first."
  @spec stages() :: [t()]
  def stages, do: @stages

  @doc "The standing every candidate graph starts at."
  @spec initial() :: t()
  def initial, do: :candidate

  @doc "The terminal standing, reachable only by passing every stage in order."
  @spec terminal() :: t()
  def terminal, do: :admitted

  @doc "Zero-based position of `standing` on the ladder, or `:error`."
  @spec rank(t()) :: {:ok, non_neg_integer()} | :error
  def rank(standing) do
    case Enum.find_index(@stages, &(&1 == standing)) do
      nil -> :error
      index -> {:ok, index}
    end
  end

  @doc """
  Advances `standing` to `next` iff `next` is the immediately following stage.

  Returns `{:ok, next}`, or `{:error, %{code: :standing_transition_invalid}}`
  for any skip, any repeat, and any regression. This refuses rather than
  clamping: a pipeline that tried to jump a stage is a bug, not something to
  silently normalise.
  """
  @spec advance(t(), t()) :: {:ok, t()} | {:error, map()}
  def advance(standing, next) do
    with {:ok, from} <- rank(standing),
         {:ok, to} <- rank(next),
         true <- to == from + 1 do
      {:ok, next}
    else
      _ ->
        {:error, %{code: :standing_transition_invalid, from: standing, to: next}}
    end
  end

  @doc "True iff `standing` is at or beyond `target` on the ladder."
  @spec reached?(t(), t()) :: boolean()
  def reached?(standing, target) do
    case {rank(standing), rank(target)} do
      {{:ok, a}, {:ok, b}} -> a >= b
      _ -> false
    end
  end

  @doc "True iff `standing` is the terminal `:admitted` standing."
  @spec admitted?(t()) :: boolean()
  def admitted?(standing), do: standing == :admitted
end
