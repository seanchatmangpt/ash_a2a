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

  ## Input bound (SEC-09)

  Every compile is a paid LLM call, so the source text is bounded BEFORE any
  hashing, telemetry or model invocation: text larger than
  `max_text_bytes/1` (`opts[:max_text_bytes]`, else
  `config :ash_a2a, :semantic_max_text_bytes`, default 16_384 bytes) is
  refused with `{:error, %{code: :semantic_text_too_large, ...}}` and the
  model is never called. `compile_many/3` bounds its batch size the same way
  (`:semantic_max_batch`, default 100 -> `:semantic_batch_too_large`).
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

  @default_max_text_bytes 16_384
  @default_max_batch 100

  @doc false
  # S42 refusal totality.
  def __sa2a_refusal_codes__ do
    %{semantic_text_too_large: :refused_bounds, semantic_batch_too_large: :refused_bounds}
  end

  @doc "The effective per-compile source-text byte ceiling."
  @spec max_text_bytes(keyword()) :: pos_integer()
  def max_text_bytes(opts \\ []) do
    (Keyword.get(opts, :max_text_bytes) ||
       Application.get_env(:ash_a2a, :semantic_max_text_bytes))
    |> bound_or_default(@default_max_text_bytes)
  end

  # Fail closed on a malformed bound: a non-integer (e.g. an unparsed
  # `System.get_env/1` string) would otherwise compare as larger than every
  # integer under Erlang term order and silently disable the cap.
  defp bound_or_default(value, _default) when is_integer(value) and value > 0, do: value
  defp bound_or_default(_value, default), do: default

  def compile(resource_or_domain, text, opts \\ []) when is_binary(text) do
    with :ok <- check_text_size(text, opts) do
      source = Source.new(text, Keyword.get(opts, :source_opts, []))
      compile_source(resource_or_domain, source, opts)
    end
  end

  def compile_source(resource_or_domain, %Source{} = source, opts \\ []) do
    case check_text_size(source.text || "", opts) do
      :ok -> do_compile_source(resource_or_domain, source, opts)
      refusal -> refusal
    end
  end

  defp check_text_size(text, opts) do
    limit = max_text_bytes(opts)
    size = byte_size(text)

    if size > limit do
      {:error,
       %{
         code: :semantic_text_too_large,
         detail: %{bytes: size, max_text_bytes: limit}
       }}
    else
      :ok
    end
  end

  defp do_compile_source(resource_or_domain, %Source{} = source, opts) do
    role = Keyword.get(opts, :role, @default_role)
    generate = Keyword.get(opts, :generate_object, &ReqLLM.generate_object/4)

    # `[:ash_a2a, :llm, :invoke]`: this path allocates exploratory model
    # inference. Emitted on entry, before role resolution, so a misconfigured
    # role or a raising model call still counts as an allocation attempt
    # (RFC-SA2A-002 §43 Allocation_LLM measurement). Observational only.
    :telemetry.execute([:ash_a2a, :llm, :invoke], %{count: 1}, %{
      site: :semantic_compiler,
      role: role,
      source_id: source.id,
      resource_or_domain: resource_or_domain
    })

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
    max_batch =
      (Keyword.get(opts, :max_batch) || Application.get_env(:ash_a2a, :semantic_max_batch))
      |> bound_or_default(@default_max_batch)

    if length(texts) > max_batch do
      {:error,
       %{code: :semantic_batch_too_large, detail: %{count: length(texts), max_batch: max_batch}}}
    else
      do_compile_many(resource_or_domain, texts, opts)
    end
  end

  defp do_compile_many(resource_or_domain, texts, opts) do
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
