defmodule AshA2A.Planning.GoalFacts do
  @moduledoc """
  Deterministic (zero-LLM) admission fence for caller-submitted goal facts,
  and the bridge from an admitted goal-facts envelope into the real semantic
  structs (`AshA2A.Semantic.IR`/`Ontology`/`PlanningIR`) the rest of the
  candidate-only planning pipeline already consumes.

  ## Why this exists instead of `AshA2A.Semantic.Admission`

  `AshA2A.Semantic.Admission.admit/2` grounds every extracted item against a
  verbatim `source_quote` substring of free natural-language text -- there is
  no free text anywhere in this path, so there is nothing for a substring
  check to run against, and calling it would be a category error, not a
  stricter check. This module is the deterministic replacement the design
  plan calls for: three real, structural closed-set/closure checks over
  typed facts (never a string-containment check), specified below in
  `admit/2`'s own @doc, implemented exactly as specified and not embellished
  with a fourth check the plan did not ask for.

  ## Wire shape (`envelope`, `admit/2`'s second argument)

  The same map a caller would place under an A2A message's `"goal_facts"`
  data-part key (JSON on the wire, so all keys/values arrive as strings;
  internal Elixir callers may use atom keys/values interchangeably --
  `fetch/3` below accepts both):

      %{
        "request_id" => "caller-supplied-idempotency-id",           # optional
        "domain_name" => "my-domain",                               # optional
        "problem_name" => "my-problem",                             # optional
        "objects" => ["on", "off"],                                 # bare ids,
                                                                     # or %{"id" => .., "type" => ..}
        "init" => [%{"predicate" => "current_phase", "args" => ["on"]}],
        "goal" => [%{"predicate" => "current_phase", "args" => ["off"]}],
        "task_sequence" => [
          %{"capability_id" => "MyApp.Facility.advance", "args" => ["on", "off"]}
        ]
      }

  `task_sequence` entries are deliberately `{capability_id, args}` pairs, not
  bare capability-id strings -- `AshA2A.Planning.HddlRenderer`'s own
  moduledoc documents why a bare id cannot be rendered as a runnable HDDL
  task-network call (a task/action call is always `(name arg1 arg2 ...)`).
  Every fact/task-call entry may also be given as an already-normalized
  `{name, args}` 2-tuple (the shape `admit/2` itself normalizes everything
  down to) for a caller that already has one in hand.
  """

  alias AshA2A.Info
  alias AshA2A.Semantic.{IR, Ontology, PlanningIR, Source}

  @type fact :: {name :: String.t(), args :: [String.t()]}

  @doc """
  Admits a caller-submitted goal-facts envelope against `resource_or_domain`'s
  real compiled capability index. Three real, structural checks, run in this
  order (cheapest/fail-fastest first -- no solver subprocess has been spent
  yet when any of these refuse):

    1. **Closed capability-id set.** `task_sequence` must be non-empty, and
       every entry's capability id must resolve via the same canonical
       `AshA2A.Info.skill/2` that `AshA2A.Planning.resolve_all/2` uses for
       real (re-run there too, once this envelope reaches
       `AshA2A.Planning.from_envelope/3` -- same function both times, zero
       duplicated logic, zero drift risk). Refuses `:noncanonical_capability`.
    2. **Object referential closure.** Every `args` value used in `init`/
       `goal` facts must name an id present in `objects`. Refuses
       `:undeclared_object`.
    3. **Predicate closure.** Every `predicate` used in `init`/`goal` facts
       must be a member of the predicate names actually declared across the
       target's compiled `hddl_operators[].preconditions/add_effects/
       delete_effects` (the whole compiled index, not only the skills named
       in `task_sequence` -- a caller cannot introduce an unmodeled
       predicate the domain doesn't define anywhere). Refuses
       `:undeclared_predicate`.

  Also fails closed (before any of the three checks above run their real
  logic) on structurally malformed wire input: an empty/missing
  `task_sequence` (`:empty_task_sequence`), a task-call entry with no
  resolvable name (`:invalid_task_sequence_entry`), a fact entry with no
  resolvable predicate (`:invalid_fact_entry`), or an object entry with no
  resolvable id (`:invalid_object_entry`) -- input hygiene, not a fourth
  semantic admission rule.

  Returns `{:ok, admitted}` where `admitted` is a normalized, atom-keyed map
  ready for both `AshA2A.Planning.HddlRenderer.domain_text/2`+`problem_text/3`
  (via `admitted.objects`/`init`/`goal`/`task_calls`) and `to_semantic_structs/2`
  below:

      %{
        request_id: String.t() | nil,
        domain_name: String.t(),
        problem_name: String.t(),
        objects: [%{id: String.t(), type: String.t() | nil}],
        init: [fact()],
        goal: [fact()],
        task_calls: [fact()],
        capability_ids: [String.t()]
      }
  """
  @spec admit(module(), map()) :: {:ok, map()} | {:error, map()}
  def admit(resource_or_domain, envelope) when is_map(envelope) do
    objects = fetch_objects(envelope)

    with {:ok, task_calls} <- fetch_task_calls(envelope),
         {:ok, _skills} <- resolve_capability_ids(resource_or_domain, task_calls),
         {:ok, init} <- fetch_facts(envelope, "init", :init),
         {:ok, goal} <- fetch_facts(envelope, "goal", :goal),
         :ok <- validate_objects(objects),
         :ok <- referential_closure(objects, init ++ goal),
         {:ok, declared_predicates} <- declared_predicates(resource_or_domain),
         :ok <- predicate_closure(declared_predicates, init ++ goal) do
      {:ok, build_admitted(envelope, task_calls, objects, init, goal)}
    end
  end

  @doc """
  Hand-constructs the admitted semantic-struct chain
  (`AshA2A.Semantic.IR` -> `Ontology` -> `PlanningIR`) from an `admit/2`-
  admitted envelope and a `source`, deliberately bypassing
  `AshA2A.Semantic.Admission.admit/2` -- see this module's @moduledoc for why
  (no free text, so no `source_quote` fence applies). Concretely:
  `IR.from_map/2` builds the candidate IR from the same proposed-map shape
  the LLM path builds (`@fields ~w(entities relations events goals
  constraints capabilities authorities observations uncertainties exclusions
  temporal_relations causal_hypotheses unresolved)a` plus `"authority" =>
  "none"`), then a direct `%{ir | standing: :admitted}` replaces the
  `Admission.admit/2` call the LLM path makes -- this envelope was already
  admitted by real structural checks in `admit/2` above, which is a stronger
  guarantee for this path's data than a substring-quote check would be (a
  substring check couldn't even apply here). `Ontology.from_ir/1` and
  `PlanningIR.from_ir/2` run completely unchanged and for real after that.

  ## Field mapping (this module's own, explicit design choice)

  Only the IR fields with a real, direct analog among goal facts are
  populated; every other field (`relations`, `events`, `constraints`,
  `authorities`, `uncertainties`, `exclusions`, `temporal_relations`,
  `causal_hypotheses`, `unresolved`) is left `[]` -- the ordering itself is
  already fully captured, losslessly, by the rendered HDDL problem text's own
  `:ordered-subtasks` (carried in the resulting `ExecutionPackage`'s
  candidate plan), so inventing a parallel `temporal_relations` encoding of
  the same fact would duplicate, not add, information.

    * `objects`        -> `entities`     (`"kind" => "object"`)
    * `goal` facts      -> `goals`        (`"description"` = rendered fact text)
    * `task_calls`      -> `capabilities` (`"description"` = rendered call text)
    * `init` facts      -> `observations` (already-true world state, `"description"` = rendered fact text)
  """
  @spec to_semantic_structs(map(), Source.t()) ::
          {:ok, %{ir: IR.t(), ontology: Ontology.t(), planning_ir: PlanningIR.t()}}
          | {:error, map()}
  def to_semantic_structs(%{} = admitted, %Source{} = source) do
    proposed = %{
      "entities" => Enum.map(admitted.objects, &entity_item/1),
      "relations" => [],
      "events" => [],
      "goals" => admitted.goal |> Enum.with_index(1) |> Enum.map(&goal_item/1),
      "constraints" => [],
      "capabilities" => admitted.task_calls |> Enum.with_index(1) |> Enum.map(&capability_item/1),
      "authorities" => [],
      "observations" => admitted.init |> Enum.with_index(1) |> Enum.map(&observation_item/1),
      "uncertainties" => [],
      "exclusions" => [],
      "temporal_relations" => [],
      "causal_hypotheses" => [],
      "unresolved" => [],
      "authority" => "none"
    }

    with {:ok, ir} <- IR.from_map(source.id, proposed) do
      admitted_ir = %{ir | standing: :admitted}

      with {:ok, ontology} <- Ontology.from_ir(admitted_ir),
           {:ok, planning_ir} <- PlanningIR.from_ir(admitted_ir, ontology) do
        {:ok, %{ir: admitted_ir, ontology: ontology, planning_ir: planning_ir}}
      end
    end
  end

  # -- admission: task_sequence / capability-id closed set -------------------

  defp fetch_task_calls(envelope) do
    raw = envelope |> fetch("task_sequence", :task_sequence) |> List.wrap()

    if raw == [] do
      {:error,
       %{code: :empty_task_sequence, message: "task_sequence must declare at least one task call"}}
    else
      calls = Enum.map(raw, &normalize_task_call/1)

      if Enum.all?(calls, &valid_task_call?/1) do
        {:ok, calls}
      else
        {:error,
         %{
           code: :invalid_task_sequence_entry,
           message: "task_sequence contains a malformed entry"
         }}
      end
    end
  end

  defp normalize_task_call({name, args}) when is_list(args) do
    {maybe_to_string(name), Enum.map(args, &maybe_to_string/1)}
  end

  defp normalize_task_call(%{} = map) do
    capability_id = fetch(map, "capability_id", :capability_id) || fetch(map, "id", :id)
    args = map |> fetch("args", :args) |> List.wrap()
    {maybe_to_string(capability_id), Enum.map(args, &maybe_to_string/1)}
  end

  defp normalize_task_call(name) when is_binary(name) or is_atom(name),
    do: {maybe_to_string(name), []}

  defp normalize_task_call(_other), do: {nil, []}

  defp valid_task_call?({name, args}) when is_binary(name) and name != "" and is_list(args),
    do: true

  defp valid_task_call?(_other), do: false

  defp resolve_capability_ids(resource_or_domain, task_calls) do
    task_calls
    |> Enum.reduce_while({:ok, []}, fn {capability_id, _args}, {:ok, acc} ->
      case Info.skill(resource_or_domain, capability_id) do
        {:ok, skill} ->
          {:cont, {:ok, [skill | acc]}}

        {:error, :skill_not_found} ->
          {:halt, {:error, %{code: :noncanonical_capability, detail: capability_id}}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  # -- admission: facts (init/goal) + objects --------------------------------

  defp fetch_facts(envelope, string_key, atom_key) do
    facts =
      envelope
      |> fetch(string_key, atom_key)
      |> List.wrap()
      |> Enum.map(&normalize_fact/1)

    if Enum.all?(facts, &valid_fact?/1) do
      {:ok, facts}
    else
      {:error,
       %{code: :invalid_fact_entry, message: "#{string_key} contains a malformed fact entry"}}
    end
  end

  defp normalize_fact({predicate, args}) when is_list(args) do
    {maybe_to_string(predicate), Enum.map(args, &maybe_to_string/1)}
  end

  defp normalize_fact(%{} = map) do
    predicate = fetch(map, "predicate", :predicate)
    args = map |> fetch("args", :args) |> List.wrap()
    {maybe_to_string(predicate), Enum.map(args, &maybe_to_string/1)}
  end

  defp normalize_fact(_other), do: {nil, []}

  defp valid_fact?({predicate, args})
       when is_binary(predicate) and predicate != "" and is_list(args),
       do: true

  defp valid_fact?(_other), do: false

  defp fetch_objects(envelope) do
    envelope
    |> fetch("objects", :objects)
    |> List.wrap()
    |> Enum.map(&normalize_object/1)
  end

  defp normalize_object(%{} = map) do
    %{
      id: map |> fetch("id", :id) |> maybe_to_string(),
      type: map |> fetch("type", :type) |> maybe_to_string()
    }
  end

  defp normalize_object(value) when is_binary(value) or is_atom(value) do
    %{id: maybe_to_string(value), type: nil}
  end

  defp normalize_object(_other), do: %{id: nil, type: nil}

  defp validate_objects(objects) do
    if Enum.all?(objects, &(&1.id != nil)) do
      :ok
    else
      {:error, %{code: :invalid_object_entry, message: "objects contains an entry with no id"}}
    end
  end

  # -- admission: check 2 (object referential closure) -----------------------

  defp referential_closure(objects, facts) do
    object_ids = objects |> Enum.map(& &1.id) |> MapSet.new()

    facts
    |> Enum.flat_map(fn {_predicate, args} -> args end)
    |> Enum.reject(&MapSet.member?(object_ids, &1))
    |> case do
      [] -> :ok
      [undeclared | _] -> {:error, %{code: :undeclared_object, detail: undeclared}}
    end
  end

  # -- admission: check 3 (predicate closure) --------------------------------

  defp declared_predicates(resource_or_domain) do
    case Info.capability_index_result(resource_or_domain) do
      {:ok, skills} ->
        predicates =
          skills
          |> Enum.flat_map(& &1.hddl_operators)
          |> Enum.flat_map(fn op -> op.preconditions ++ op.add_effects ++ op.delete_effects end)
          |> Enum.map(fn {predicate, _args} -> to_string(predicate) end)
          |> MapSet.new()

        {:ok, predicates}

      {:error, :not_compiled} ->
        {:error,
         %{
           code: :not_compiled,
           message: "#{inspect(resource_or_domain)} has no compiled AshA2A capability index"
         }}
    end
  end

  defp predicate_closure(declared, facts) do
    facts
    |> Enum.map(fn {predicate, _args} -> predicate end)
    |> Enum.reject(&MapSet.member?(declared, &1))
    |> case do
      [] -> :ok
      [undeclared | _] -> {:error, %{code: :undeclared_predicate, detail: undeclared}}
    end
  end

  # -- admitted envelope construction -----------------------------------------

  defp build_admitted(envelope, task_calls, objects, init, goal) do
    request_id = fetch(envelope, "request_id", :request_id)

    %{
      request_id: request_id,
      domain_name:
        fetch(envelope, "domain_name", :domain_name) || default_name("domain", request_id),
      problem_name:
        fetch(envelope, "problem_name", :problem_name) || default_name("problem", request_id),
      objects: objects,
      init: init,
      goal: goal,
      task_calls: task_calls,
      capability_ids: Enum.map(task_calls, fn {capability_id, _args} -> capability_id end)
    }
  end

  defp default_name(kind, nil), do: "ash_a2a_goal_facts_#{kind}"
  defp default_name(kind, request_id), do: "ash_a2a_goal_facts_#{kind}_#{request_id}"

  # -- semantic-struct item builders ------------------------------------------

  defp entity_item(%{id: id, type: nil}), do: %{"id" => id, "kind" => "object", "label" => id}

  defp entity_item(%{id: id, type: type}),
    do: %{"id" => id, "kind" => "object", "label" => id, "type" => type}

  defp goal_item({{predicate, args}, idx}) do
    %{
      "id" => "goal-#{idx}",
      "kind" => "goal_fact",
      "description" => render_fact(predicate, args),
      "predicate" => predicate,
      "args" => args
    }
  end

  defp capability_item({{capability_id, args}, idx}) do
    %{
      "id" => "task-#{idx}",
      "kind" => "capability",
      "capability_id" => capability_id,
      "description" => render_fact(capability_id, args)
    }
  end

  defp observation_item({{predicate, args}, idx}) do
    %{
      "id" => "init-#{idx}",
      "kind" => "observation",
      "description" => render_fact(predicate, args),
      "predicate" => predicate,
      "args" => args
    }
  end

  defp render_fact(name, []), do: "(#{name})"
  defp render_fact(name, args), do: "(#{name} #{Enum.join(args, " ")})"

  # -- shared helpers ----------------------------------------------------------

  defp fetch(map, string_key, atom_key), do: Map.get(map, string_key) || Map.get(map, atom_key)

  defp maybe_to_string(nil), do: nil
  defp maybe_to_string(value), do: to_string(value)
end
