defmodule AshA2A.Semantic.Compiler do
  @moduledoc """
  Closed-loop semantic compiler: text -> admitted semantics -> ontology -> PlanningIR -> HDDL/FOND candidate.

  The `:generate_object` opt is a real 4-arity function argument (a
  dependency-injection test seam), not a call into any mocking library; it
  defaults to the real `ReqLLM.generate_object/4` in production. Tests inject
  a real anonymous function producing fixed, schema-valid output because a
  live network LLM call is not viable to run deterministically in CI. Every
  step downstream of that seam (IR construction, Admission fencing, Ontology
  projection, PlanningIR projection, ExecutionPackage fencing/fingerprinting)
  executes for real, with no further test doubles.
  """

  alias AshA2A.{LLMProfiles, Planning.SemanticSynthesis}

  alias AshA2A.Semantic.{
    Admission,
    ExecutionPackage,
    Feedback,
    IR,
    Ontology,
    PlanningIR,
    Schema,
    Source,
    Vocabulary
  }

  @default_role :semantic_reasoner

  def compile(resource_or_domain, text, opts \\ []) when is_binary(text) do
    source = Source.new(text, Keyword.get(opts, :source_opts, []))
    compile_source(resource_or_domain, source, opts)
  end

  def compile_source(resource_or_domain, %Source{} = source, opts \\ []) do
    role = Keyword.get(opts, :role, @default_role)
    generate = Keyword.get(opts, :generate_object, &ReqLLM.generate_object/4)
    model_spec = LLMProfiles.model_spec!(role)
    llm_opts = LLMProfiles.req_llm_opts!(role)
    persona_context = Keyword.get(opts, :persona_context)

    with {:ok, proposed} <-
           generate.(model_spec, prompt(source, persona_context), Schema.extraction(), llm_opts),
         {:ok, candidate_ir} <- IR.from_map(source.id, proposed),
         {:ok, admitted_ir} <- Admission.admit(source, candidate_ir),
         {:ok, ontology} <- Ontology.from_ir(admitted_ir),
         {:ok, planning_ir} <- PlanningIR.from_ir(admitted_ir, ontology),
         {:ok, plan_candidate} <- synthesize(resource_or_domain, planning_ir, role, opts),
         {:ok, package} <-
           ExecutionPackage.new(source, admitted_ir, ontology, planning_ir, plan_candidate) do
      {:ok, package}
    else
      {:error, %{code: _} = refusal} -> {:error, refusal}
      {:error, reason} -> {:error, %{code: :semantic_compilation_failed, detail: reason}}
    end
  end

  def compile_many(resource_or_domain, texts, opts \\ []) when is_list(texts) do
    concurrency = Keyword.get(opts, :max_concurrency, 50)

    texts
    |> Task.async_stream(&isolated_compile(resource_or_domain, &1, opts),
      max_concurrency: concurrency,
      ordered: true,
      timeout: :infinity
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, reason} -> {:error, %{code: :semantic_worker_exit, detail: reason}}
    end)
  end

  # `Task.async_stream/3` links each worker to the calling process, so a raised
  # exception in one text's pipeline would otherwise crash the entire batch
  # (and its caller) instead of isolating to that slot. Rescue here and return
  # a normal `{:error, ...}` value so the task itself completes without
  # crashing; the surrounding `{:exit, reason}` clause in `compile_many/3`
  # remains for genuine task exits (e.g. a `:timeout`), which this cannot
  # convert since the task never even completes in that case.
  defp isolated_compile(resource_or_domain, text, opts) do
    compile(resource_or_domain, text, opts)
  rescue
    error ->
      {:error,
       %{code: :semantic_worker_exit, detail: Exception.format(:error, error, __STACKTRACE__)}}
  end

  def replan(resource_or_domain, %ExecutionPackage{} = package, receipt, opts \\ []) do
    with {:ok, feedback} <- Feedback.from_receipt(package, receipt),
         planning_ir <- PlanningIR.with_observation(package.planning_ir, feedback.observation),
         {:ok, candidate} <-
           synthesize(
             resource_or_domain,
             planning_ir,
             Keyword.get(opts, :role, @default_role),
             opts
           ),
         {:ok, next} <-
           ExecutionPackage.new(
             package.source,
             package.semantic_ir,
             package.ontology,
             planning_ir,
             candidate,
             parent_fingerprint: package.fingerprint,
             feedback: package.feedback ++ [feedback]
           ) do
      {:ok, next, feedback}
    end
  end

  defp synthesize(resource_or_domain, planning_ir, role, opts) do
    synth_opts = [role: Keyword.get(opts, :planning_role, role)]
    synth_opts = maybe_put(synth_opts, :generate_object, Keyword.get(opts, :plan_generate_object))
    synth_opts = maybe_put(synth_opts, :persona_context, Keyword.get(opts, :persona_context))

    SemanticSynthesis.synthesize(
      resource_or_domain,
      PlanningIR.primary_goal(planning_ir),
      PlanningIR.observation(planning_ir),
      synth_opts
    )
  end

  # `persona_context`, when present, is a caller-supplied decision-making
  # LENS (e.g. `AshA2A.BoardPersona.*`'s real, cited governance framing) --
  # it never introduces new factual content the model could ground an entity
  # against: `Admission.validate_item/3`'s `source_quote` check
  # (`lib/ash_a2a/semantic/admission.ex`) verifies every extracted item
  # against `source.text` alone (the real `%Source{}` struct passed to
  # `Admission.admit/2` unchanged, never a reconstruction of this prompt),
  # so appending persona framing here cannot weaken that real grounding
  # guarantee. `nil` (the default) reproduces the exact prior prompt text
  # byte-for-byte -- every existing caller is unaffected.
  defp prompt(source, persona_context) do
    prefixes = Vocabulary.prefixes() |> Map.keys() |> Enum.sort() |> Enum.join(", ")

    """
    Extract candidate semantics from the source text. Reuse public ontology prefixes when exact semantics fit: #{prefixes}.
    Every assertion must include a verbatim source_quote from the text. Preserve uncertainty and exclusions. Do not grant execution authority; authority must be none.
    #{persona_context_block(persona_context)}
    SOURCE:
    #{source.text}
    """
  end

  defp persona_context_block(nil), do: ""

  defp persona_context_block(persona_context) when is_binary(persona_context) do
    """

    DECISION-MAKING PERSPECTIVE (a lens for interpreting the source below --
    not itself source material; do not extract entities/quotes from this
    block, only from SOURCE):
    #{persona_context}
    """
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
