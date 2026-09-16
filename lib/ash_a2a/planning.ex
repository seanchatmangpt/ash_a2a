defmodule AshA2A.Planning.Candidate do
  @moduledoc "Planner output with candidate-only standing and no DO authority."

  @enforce_keys [:planner, :plan, :capability_ids, :fingerprint]
  defstruct [
    :planner,
    :planner_ref,
    :formalism,
    :plan,
    :capability_ids,
    :fingerprint,
    standing: :candidate,
    authority: :none,
    admitted_skills: []
  ]

  @type t :: %__MODULE__{}

  @spec new(atom(), map(), [String.t()], keyword()) :: t()
  def new(planner, plan, capability_ids, opts \\ [])
      when is_atom(planner) and is_map(plan) and is_list(capability_ids) do
    capability_ids = Enum.map(capability_ids, &to_string/1)

    fingerprint =
      {planner, Keyword.get(opts, :formalism), capability_ids, plan}
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    %__MODULE__{
      planner: planner,
      planner_ref: Keyword.get(opts, :planner_ref),
      formalism: Keyword.get(opts, :formalism, :unknown),
      plan: plan,
      capability_ids: capability_ids,
      fingerprint: fingerprint
    }
  end
end

defmodule AshA2A.Planning do
  @moduledoc """
  Candidate-only planning admission over canonical AshA2A capabilities.

  Planners may propose PDDL/HDDL/FOND/HTN/temporal candidates, but every
  consequence-bearing step must project a canonical capability id that
  resolves through `AshA2A.Info`. This module has no execution function.
  Admitted candidates still require `AshA2A.CommandBus` for any later DO.
  """

  alias AshA2A.Planning.Candidate

  @spec admit(module(), Candidate.t()) :: {:ok, Candidate.t()} | {:error, map()}
  def admit(resource_or_domain, %Candidate{} = candidate) do
    with :ok <- candidate_fence(candidate),
         {:ok, skills} <- resolve_all(resource_or_domain, candidate.capability_ids) do
      {:ok, %{candidate | admitted_skills: skills}}
    end
    |> emit_admit(resource_or_domain, candidate)
  end

  # `[:ash_a2a, :planning, :admit]`: the planning admission decision, emitted
  # at this boundary (RFC-SA2A-002 §12 attempt evidence for the CHI-BRCE
  # planner falsifier). Observational only; the result passes through.
  defp emit_admit(result, resource_or_domain, %Candidate{} = candidate) do
    {outcome, code} =
      case result do
        {:ok, _admitted} -> {:admitted, nil}
        {:error, %{code: code}} -> {:refused, code}
        {:error, _other} -> {:refused, nil}
      end

    :telemetry.execute(
      [:ash_a2a, :planning, :admit],
      %{capability_count: length(candidate.capability_ids)},
      %{
        resource_or_domain: resource_or_domain,
        outcome: outcome,
        code: code,
        planner: candidate.planner,
        formalism: candidate.formalism,
        fingerprint: candidate.fingerprint,
        standing: candidate.standing,
        authority: candidate.authority
      }
    )

    result
  end

  @spec from_envelope(module(), map(), keyword()) :: {:ok, Candidate.t()} | {:error, map()}
  def from_envelope(resource_or_domain, envelope, opts \\ []) when is_map(envelope) do
    capability_ids = extract_capability_ids(envelope)

    if capability_ids == [] do
      {:error, refusal(:planner_capability_projection_missing)}
    else
      candidate =
        Candidate.new(
          Keyword.get(opts, :planner, :external),
          envelope,
          capability_ids,
          planner_ref: planner_ref(envelope),
          formalism: Keyword.get(opts, :formalism, :unknown)
        )

      admit(resource_or_domain, candidate)
    end
  end

  @spec plan_with_ferroplan(module(), String.t(), String.t(), keyword()) ::
          {:ok, Candidate.t()} | {:error, term()}
  def plan_with_ferroplan(resource_or_domain, domain, problem, opts \\ [])
      when is_binary(domain) and is_binary(problem) do
    planner = BeamPM.Ferroplan

    if Code.ensure_loaded?(planner) and function_exported?(planner, :plan_production, 4) do
      extra = Keyword.get(opts, :extra, %{})
      planner_opts = Keyword.get(opts, :planner_opts, [])

      case apply(planner, :plan_production, [domain, problem, extra, planner_opts]) do
        {:ok, envelope} when is_map(envelope) ->
          from_envelope(resource_or_domain, envelope,
            planner: :ferroplan,
            formalism: Keyword.get(opts, :formalism, :pddl)
          )

        {:error, _} = error ->
          error

        other ->
          {:error, refusal(:unexpected_planner_result, other)}
      end
    else
      {:error, refusal(:unsupported_planner, :ferroplan)}
    end
  end

  @spec extract_capability_ids(term()) :: [String.t()]
  def extract_capability_ids(term) do
    term
    |> collect([])
    |> Enum.reverse()
    |> Enum.uniq()
  end

  defp candidate_fence(%Candidate{standing: :candidate, authority: :none}), do: :ok
  defp candidate_fence(_candidate), do: {:error, refusal(:planner_authority_ceiling_violated)}

  defp resolve_all(resource_or_domain, capability_ids) do
    Enum.reduce_while(capability_ids, {:ok, []}, fn capability_id, {:ok, skills} ->
      case AshA2A.Info.skill(resource_or_domain, capability_id) do
        {:ok, skill} ->
          {:cont, {:ok, [skill | skills]}}

        {:error, :skill_not_found} ->
          {:halt, {:error, refusal(:noncanonical_capability, capability_id)}}
      end
    end)
    |> case do
      {:ok, skills} -> {:ok, Enum.reverse(skills)}
      error -> error
    end
  end

  defp collect(%{} = map, acc) do
    Enum.reduce(map, acc, fn
      {"capability_id", value}, items when is_binary(value) -> [value | items]
      {:capability_id, value}, items when is_binary(value) -> [value | items]
      {"capability_ids", values}, items when is_list(values) -> add_strings(values, items)
      {:capability_ids, values}, items when is_list(values) -> add_strings(values, items)
      {_key, value}, items -> collect(value, items)
    end)
  end

  defp collect(list, acc) when is_list(list), do: Enum.reduce(list, acc, &collect/2)
  defp collect(_value, acc), do: acc

  defp add_strings(values, acc) do
    Enum.reduce(values, acc, fn
      value, items when is_binary(value) -> [value | items]
      _value, items -> items
    end)
  end

  defp planner_ref(envelope) do
    Map.get(envelope, "request_id") || Map.get(envelope, :request_id) ||
      Map.get(envelope, "plan_id") || Map.get(envelope, :plan_id)
  end

  defp refusal(code, detail \\ nil), do: %{code: code, detail: detail}
end
