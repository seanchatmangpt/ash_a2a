defmodule AshA2A.Planning.SemanticSynthesis do
  @moduledoc """
  Semantic plan synthesis for UNKNOWN boundaries.

  A configured LLM role may propose HDDL/FOND artifacts and canonical A2A
  capability ids, but the result is only a `AshA2A.Planning.Candidate`.
  The model cannot grant authority or execute anything: every capability is
  re-resolved through `AshA2A.Info`, and any later consequence-bearing action
  must still be constructed as a command and enter through `AshA2A.CommandBus`.
  """

  alias AshA2A.{Info, LLMProfiles, Planning}

  @default_role :surface_planner

  @type result :: {:ok, Planning.Candidate.t()} | {:error, map() | term()}

  @doc """
  Synthesizes a candidate HDDL/FOND plan from a semantic goal and observation.

  `:surface_planner` is the default LLM role. Provider identity remains runtime
  configuration owned by `AshA2A.LLMProfiles`; callers never name Z.AI (or any
  other provider) in the domain model.

  `:generate_object` is an injectable four-arity function used only as a test
  seam around `ReqLLM.generate_object/4`. It does not bypass candidate
  admission or the authority fence. Tests inject a real anonymous function
  with fixed output because a live network LLM call isn't viable in CI;
  capability admission (via `AshA2A.Planning.from_envelope`) and the authority
  fence still run for real against whatever the injected function returns.
  """
  @spec synthesize(module(), String.t(), map(), keyword()) :: result()
  def synthesize(resource_or_domain, goal, observation, opts \\ [])
      when is_binary(goal) and is_map(observation) do
    role = Keyword.get(opts, :role, @default_role)
    capability_ids = capability_ids(resource_or_domain)

    if capability_ids == [] do
      {:error, refusal(:no_canonical_capabilities)}
    else
      model_spec = LLMProfiles.model_spec!(role)

      llm_opts =
        role
        |> LLMProfiles.req_llm_opts!()
        |> Keyword.merge(Keyword.get(opts, :req_llm_opts, []))

      generate_object = Keyword.get(opts, :generate_object, &ReqLLM.generate_object/4)
      schema = output_schema(capability_ids)
      prompt = build_prompt(goal, observation, capability_ids)

      with {:ok, proposed} <- generate_object.(model_spec, prompt, schema, llm_opts),
           {:ok, envelope} <- normalize_proposal(proposed, role),
           {:ok, candidate} <-
             Planning.from_envelope(resource_or_domain, envelope,
               planner: :semantic_synthesis,
               formalism: :hddl_fond
             ) do
        {:ok, candidate}
      else
        {:error, %{code: _} = refusal} -> {:error, refusal}
        {:error, reason} -> {:error, refusal(:semantic_synthesis_failed, reason)}
      end
    end
  end

  @doc "Returns the canonical capability ids eligible for semantic synthesis."
  @spec capability_ids(module()) :: [String.t()]
  def capability_ids(resource_or_domain) do
    resource_or_domain
    |> Info.capability_index()
    |> List.wrap()
    |> Enum.map(& &1.id)
    |> Enum.map(&to_string/1)
    |> Enum.sort()
  end

  defp normalize_proposal(proposed, role) when is_map(proposed) do
    authority = field(proposed, "authority")

    if authority in ["none", :none] do
      capability_ids = field(proposed, "capability_ids")
      request_id = field(proposed, "request_id")

      if is_list(capability_ids) and capability_ids != [] and
           Enum.all?(capability_ids, &is_binary/1) and is_binary(request_id) do
        {:ok,
         %{
           "request_id" => request_id,
           "capability_ids" => capability_ids,
           "authority" => "none",
           "synthesis" => %{
             "role" => to_string(role),
             "hddl" => field(proposed, "hddl"),
             "fond" => field(proposed, "fond"),
             "rationale" => field(proposed, "rationale")
           }
         }}
      else
        {:error, refusal(:invalid_semantic_plan_shape)}
      end
    else
      {:error, refusal(:planner_authority_ceiling_violated, authority)}
    end
  end

  defp normalize_proposal(other, _role),
    do: {:error, refusal(:invalid_semantic_plan_shape, other)}

  defp build_prompt(goal, observation, capability_ids) do
    """
    Manufacture a candidate web-surface plan from admitted semantic state.

    Goal:
    #{goal}

    Observation JSON:
    #{Jason.encode!(observation)}

    Canonical capability ids (choose only from this closed set):
    #{Enum.join(capability_ids, "\n")}

    Return a structured candidate only. `authority` MUST be `none`.
    Produce an HDDL task-network candidate and a FOND policy candidate that
    describe how the goal could be achieved under nondeterministic surface
    observations. Do not execute, actuate, click, submit, mutate, or claim that
    any step ran. The returned capability ids are proposals and will be
    independently admitted against the canonical AshA2A capability index.
    """
  end

  defp output_schema(capability_ids) do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "request_id" => %{"type" => "string"},
        "authority" => %{"type" => "string", "enum" => ["none"]},
        "capability_ids" => %{
          "type" => "array",
          "items" => %{"type" => "string", "enum" => capability_ids},
          "uniqueItems" => true
        },
        "hddl" => %{"type" => "string"},
        "fond" => %{"type" => "string"},
        "rationale" => %{"type" => "string"}
      },
      "required" => ["request_id", "authority", "capability_ids", "hddl", "fond"]
    }
  end

  defp field(map, key), do: Map.get(map, key) || Map.get(map, String.to_atom(key))

  defp refusal(code, detail \\ nil), do: %{code: code, detail: detail}
end
