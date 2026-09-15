defmodule AshA2A.Planning.HddlDeterministicSynthesis do
  @moduledoc """
  Deterministic, non-LLM entry point that mirrors
  `AshA2A.Semantic.Compiler.compile_source/3`'s real public contract --
  `(resource_or_domain, payload, opts \\\\ [])`, returning
  `{:ok, AshA2A.Semantic.ExecutionPackage.t()} | {:error, map()}` -- so a
  caller of the existing semantic-compilation surface has a genuine drop-in
  alternative for the case where the "source" is already-admitted, typed
  goal facts (an ordered `task_sequence` of capability ids plus init/goal
  facts) rather than natural-language text an LLM must extract semantics
  from.

  `compile_source/3` takes a `%Source{}` because its input is free text; this
  module's payload (`goal_facts_envelope`) is already-structured data, so it
  takes a plain map instead -- the analogous adaptation of the same 3-arity
  `(subject, payload, opts)` call shape, not a different shape.

  ## Real pipeline, zero LLM calls anywhere in this path

  1. `AshA2A.Planning.GoalFacts.admit/2` -- the deterministic admission fence
     (closed-set capability ids, object referential closure, predicate
     closure; see that module's own @doc for the exact three checks).
  2. `AshA2A.Planning.HddlRenderer.domain_text/2` + `problem_text/3` -- real,
     hand-written HDDL text rendered from the compiled capability index's
     `hddl_operators` and the admitted goal facts.
  3. `AshA2A.Planning.HddlSolver.solve/3` -- a real OS subprocess invocation
     of the real `native/hddl_cli` binary over that real text. No network
     call, no LLM, no simulated result: `{:ok, decoded}` only comes back once
     the real solver has really confirmed the caller-proposed `task_sequence`
     reaches the submitted goal from the submitted initial state (this is
     real HTN plan *verification*, not open-ended plan *discovery* -- see
     the design plan's own MVP-scope note).
  4. The solved result is wrapped in an envelope carrying the already-
     admitted `capability_ids` (never re-derived from a model's own claim)
     and passed to the real, unchanged `AshA2A.Planning.from_envelope/3` --
     the exact same canonical-capability re-admission
     (`AshA2A.Planning.resolve_all/2`) the LLM path's synthesized envelope
     goes through, applied here a second time for real, not skipped because
     step 1 already checked once.
  5. `GoalFacts.to_semantic_structs/2` builds the real
     `IR`/`Ontology`/`PlanningIR` chain (deliberately bypassing
     `AshA2A.Semantic.Admission.admit/2` -- see that function's own @doc for
     why), and the real, unchanged `AshA2A.Semantic.ExecutionPackage.new/6`
     fences and fingerprints the final candidate-only package.

  The package's `source` is the real, deterministic HDDL domain+problem text
  this path itself rendered and solved (`Source.new(domain_text <> "\\n" <>
  problem_text, ...)`) -- the actual evidence this path produced, not a
  placeholder standing in for "no real source text existed here."
  """

  alias AshA2A.Planning
  alias AshA2A.Planning.{GoalFacts, HddlRenderer, HddlSolver}
  alias AshA2A.Semantic.{ExecutionPackage, Source}

  @doc """
  Synthesizes a candidate-only `AshA2A.Semantic.ExecutionPackage` from a
  goal-facts envelope, with zero LLM calls and zero network access anywhere
  in the path -- only a real local subprocess invocation of the real
  `native/hddl_cli` binary.

  `opts`:

    * `:solver_opts` -- forwarded verbatim to `HddlSolver.solve/3` (e.g.
      `:cli_path`, `:tmp_dir`). Default `[]`.

  Returns `{:error, map()}` (always carrying a `:code`) at the first failing
  real step: goal-facts admission, HDDL rendering, the real solver (including
  a genuinely unreachable goal, reported by the real binary), canonical
  capability re-admission, or `ExecutionPackage` fencing.
  """
  @spec synthesize(module(), map(), keyword()) ::
          {:ok, ExecutionPackage.t()} | {:error, map()}
  def synthesize(resource_or_domain, goal_facts_envelope, opts \\ [])
      when is_map(goal_facts_envelope) do
    solver_opts = Keyword.get(opts, :solver_opts, [])

    with {:ok, admitted} <- GoalFacts.admit(resource_or_domain, goal_facts_envelope),
         {:ok, domain_text} <- HddlRenderer.domain_text(resource_or_domain, admitted.domain_name),
         {:ok, problem_text} <-
           HddlRenderer.problem_text(resource_or_domain, admitted.problem_name,
             domain_name: admitted.domain_name,
             objects: admitted.objects,
             init: admitted.init,
             goal: admitted.goal,
             task_sequence: admitted.task_calls
           ),
         {:ok, decoded} <- HddlSolver.solve(domain_text, problem_text, solver_opts),
         hddl_text <- domain_text <> "\n" <> problem_text,
         envelope <- build_envelope(admitted, hddl_text, decoded),
         {:ok, candidate} <-
           Planning.from_envelope(resource_or_domain, envelope,
             planner: :hddl_solver,
             formalism: :hddl
           ),
         source <- Source.new(hddl_text, source_opts(admitted)),
         {:ok, structs} <- GoalFacts.to_semantic_structs(admitted, source),
         {:ok, package} <-
           ExecutionPackage.new(
             source,
             structs.ir,
             structs.ontology,
             structs.planning_ir,
             candidate
           ) do
      {:ok, package}
    end
  end

  defp build_envelope(admitted, hddl_text, decoded) do
    %{
      "request_id" => admitted.request_id,
      "capability_ids" => admitted.capability_ids,
      "authority" => "none",
      "synthesis" => %{
        "role" => "hddl_solver",
        "hddl" => hddl_text,
        "fond" => JSON.encode!(decoded),
        "rationale" =>
          "Deterministic HDDL solve: the caller-proposed task_sequence " <>
            "#{inspect(admitted.capability_ids)} was admitted against the compiled " <>
            "capability index and confirmed reachable from the submitted initial " <>
            "state by the real hddl_cli solver. No LLM call occurred."
      }
    }
  end

  defp source_opts(admitted) do
    [
      media_type: "application/hddl",
      provenance: %{request_id: admitted.request_id, planner: :hddl_solver}
    ]
  end
end
