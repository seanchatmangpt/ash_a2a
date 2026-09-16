defmodule AshA2A.Semantic.Selection do
  @moduledoc """
  The result of a `AshA2A.Semantic.Select.select/3` -- evidence that a
  choice among lawful possibilities was made, and of what was considered.

  Standing `:candidate`, authority `:none`. Selecting does not confer the
  authority to execute the selected plan (RFC-SA2A-001 S25).
  """

  @enforce_keys [:chosen, :chosen_digest, :considered_digests, :selection_digest]
  defstruct [
    :chosen,
    :chosen_digest,
    :considered_digests,
    :selection_digest,
    :selector_identity,
    rejected_digests: [],
    standing: :candidate,
    authority: :none
  ]

  @type t :: %__MODULE__{
          chosen: AshA2A.Semantic.PlanPackage.t(),
          chosen_digest: String.t(),
          considered_digests: [String.t()],
          rejected_digests: [String.t()],
          selection_digest: String.t(),
          selector_identity: String.t() | nil,
          standing: :candidate,
          authority: :none
        }
end

defmodule AshA2A.Semantic.Select do
  @moduledoc """
  SELECT (RFC-SA2A-001 S25): choose among lawful possibilities.

  > SELECT chooses among lawful possibilities and MUST NOT perform
  > consequential external mutation.

  ## How the "no consequential external mutation" rule is actually enforced

  Not by a promise in this docstring. Three real properties:

    1. **This module calls nothing consequential.** It has no reference to
       `AshA2A.CommandBus`, `AshA2A.ReceiptStore`, `AshA2A.ReceiptOutbox`,
       `Ash`, or `Ecto`. That is checkable without running anything, and
       `test/ash_a2a/semantic/select_test.exs` checks it for real against
       the compiled BEAM's own import table (`:beam_lib.chunks(beam,
       [:imports])`) rather than against a grep of the source.
    2. **Every candidate must be admissible before it can be ranked.**
       `select/3` runs `PlanPackage.verify/1` on each candidate and refuses
       the whole selection if any candidate fails, rather than silently
       ranking a tampered package (S27's edited-projection case, arriving
       one layer up).
    3. **The scorer is confined to a comparison role.** It receives a
       package and must return a real `number()`; a non-numeric return is a
       typed refusal (`:selection_scorer_invalid`), not a crash and not a
       coerced ranking. A scorer is a pure comparison function -- if a
       caller's scorer performs a side effect, that side effect is the
       *caller's* consequence and requires the caller's own authority; this
       module contributes none.

  Selection is total-order-deterministic: candidates are ranked by
  `{score, plan_digest}` ascending with the **lowest** score winning (a
  score is a cost, not a fitness), so two runs over the same candidate set
  with the same scorer always select the same package even when scores tie.
  Tie-breaking on `plan_digest` -- a value-level digest -- means the
  tie-break does not depend on the order the caller happened to pass the
  candidates in.
  """

  alias AshA2A.Semantic.{CanonicalTermDigest, PlanPackage, Selection}

  @type refusal :: {:error, %{code: atom(), detail: term()}}
  @type scorer :: (PlanPackage.t() -> number())

  @doc """
  Selects one package from `candidates`.

  `scorer` returns a **cost**; the lowest-cost candidate wins, ties broken
  by `plan_digest` ascending.

  `opts`:

    * `:selector_identity` -- recorded on the `%Selection{}` as evidence of
      who chose; never used as authority
    * `:profile` -- when given, every candidate must additionally pass
      `PlanPackage.enforce_profile/1` under that profile before being
      ranked. This is how a strict receiver refuses to select among
      permissively-built plans.

  Refusals:

    * `:selection_no_candidates` -- empty candidate list
    * `:selection_candidate_unverifiable` -- some candidate's recorded
      `plan_digest` disagrees with its content; detail names the index and
      the underlying refusal
    * `:selection_candidate_profile_violation` -- some candidate fails the
      requested `:profile`
    * `:selection_scorer_invalid` -- the scorer returned a non-number
  """
  @spec select([PlanPackage.t()], scorer(), keyword()) :: {:ok, Selection.t()} | refusal()
  def select(candidates, scorer, opts \\ [])
      when is_list(candidates) and is_function(scorer, 1) and is_list(opts) do
    with :ok <- nonempty(candidates),
         :ok <- verify_all(candidates),
         :ok <- profile_all(candidates, Keyword.get(opts, :profile)),
         {:ok, scored} <- score_all(candidates, scorer) do
      ranked = Enum.sort_by(scored, fn {score, package} -> {score, package.plan_digest} end)
      [{_score, chosen} | rest] = ranked

      considered = Enum.map(ranked, fn {_score, package} -> package.plan_digest end)
      rejected = Enum.map(rest, fn {_score, package} -> package.plan_digest end)

      selection = %Selection{
        chosen: chosen,
        chosen_digest: chosen.plan_digest,
        considered_digests: considered,
        rejected_digests: rejected,
        selector_identity: Keyword.get(opts, :selector_identity),
        selection_digest: "pending"
      }

      {:ok, %{selection | selection_digest: selection_digest(selection)}}
    end
    |> emit_decision(length(candidates))
  end

  # `[:ash_a2a, :semantic, :select]`: the SELECT decision (RFC-SA2A-002 §35
  # SELECTED-standing evidence). Observational only; the result passes through.
  defp emit_decision(result, candidate_count) do
    meta =
      case result do
        {:ok, %Selection{} = s} ->
          %{
            outcome: :selected,
            chosen_digest: s.chosen_digest,
            selection_digest: s.selection_digest,
            selector_identity: s.selector_identity,
            standing: s.standing,
            authority: s.authority
          }

        {:error, %{code: code}} ->
          %{outcome: :refused, code: code}
      end

    :telemetry.execute(
      [:ash_a2a, :semantic, :select],
      %{system_time: System.system_time(), candidates: candidate_count},
      meta
    )

    result
  end

  @doc """
  The selection's own content digest: chosen + everything considered +
  selector identity. Two selections that chose the same package out of
  *different* candidate sets are distinguishable.
  """
  @spec selection_digest(Selection.t()) :: String.t()
  def selection_digest(%Selection{} = selection) do
    CanonicalTermDigest.digest(%{
      chosen_digest: selection.chosen_digest,
      considered_digests: selection.considered_digests,
      rejected_digests: selection.rejected_digests,
      selector_identity: selection.selector_identity
    })
  end

  defp nonempty([]), do: error(:selection_no_candidates)
  defp nonempty([_ | _]), do: :ok

  defp verify_all(candidates) do
    candidates
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {package, index}, :ok ->
      case PlanPackage.verify(package) do
        {:ok, _package} ->
          {:cont, :ok}

        {:error, detail} ->
          {:halt, error(:selection_candidate_unverifiable, %{index: index, refusal: detail})}
      end
    end)
  end

  defp profile_all(_candidates, nil), do: :ok

  defp profile_all(candidates, profile) do
    candidates
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {package, index}, :ok ->
      case PlanPackage.enforce_profile(%{package | profile: profile}) do
        :ok ->
          {:cont, :ok}

        {:error, detail} ->
          {:halt,
           error(:selection_candidate_profile_violation, %{
             index: index,
             profile: profile,
             refusal: detail
           })}
      end
    end)
  end

  defp score_all(candidates, scorer) do
    Enum.reduce_while(candidates, {:ok, []}, fn package, {:ok, acc} ->
      case scorer.(package) do
        score when is_number(score) ->
          {:cont, {:ok, [{score, package} | acc]}}

        other ->
          {:halt,
           error(:selection_scorer_invalid, %{plan_digest: package.plan_digest, returned: other})}
      end
    end)
    |> case do
      {:ok, scored} -> {:ok, Enum.reverse(scored)}
      {:error, _} = refusal -> refusal
    end
  end

  defp error(code, detail \\ nil), do: {:error, %{code: code, detail: detail}}
end
