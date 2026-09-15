defmodule AshA2A.Planning.HddlRenderer do
  @moduledoc """
  Deterministic (hand-written, no LLM, no template engine) HDDL domain/problem
  text renderer for the non-LLM planning path.

  `domain_text/2` renders one HDDL `:action` per declared
  `AshA2A.HddlOperator` on the target's compiled capability index
  (`AshA2A.Info.capability_index/1` -- real, live data built by
  `AshA2A.CapabilityIndex.Compiler.project/3`, not a second source of truth).
  `problem_text/3` renders an HDDL problem from caller-submitted, already-
  admitted goal facts (objects/init/goal/task calls) -- this module performs
  no closed-set/referential-closure admission of its own; that fence belongs
  to a caller (`AshA2A.Planning.GoalFacts.admit/2`, a later task) that must
  run *before* text generation.

  ## Fact/task-call convention

  Every predicate/task-call surface in this module shares one 2-tuple shape,
  reusing `AshA2A.HddlOperator.fact()`'s own STRIPS convention rather than
  inventing a second one:

      {name :: atom() | String.t(), args :: [atom() | String.t()]}

  A domain-level operator fact's `args` name *parameter variables* (rendered
  `?arg`); a problem-level init/goal fact or task call's `args` name *ground
  objects* (rendered bare, no `?`). Same shape, different rendering context --
  `render_domain_fact/1` vs. `render_ground_call/1` below.

  ## Grammar verified against the real `native/hddl_cli` binary this session

  Two claims below are real, run-checked facts, not carried over unverified
  from the design plan that preceded this module (per this session's own
  DMEDI Measure discipline -- "do not assume the grammar sketch is correct
  without running it through the real binary"):

    1. `:types` and typed parameters are optional. Confirmed by
       `ferroplan_hddl::grounder::ground`'s own doctest
       (`crates/ferroplan-hddl/src/grounder.rs`, real crate source, real
       `cargo test --doc` surface) using an untyped `(:action open-door
       :parameters (?d) ...)` domain with no `:types` section at all, and by
       this session's own two hand-authored domain/problem pairs run through
       the real `hddl_cli` binary (`{"solved":true,...}` both times).

    2. **No synthetic top-level `:task`/`:method` wrapper is needed.** The
       original design plan assumed `problem_text/3` would need to render a
       synthetic compound `:task` + `:method` (methods being a domain-only
       construct per `ferroplan_hddl::parser::parse_domain`'s section match
       arm -- `:method` is not a recognized `parse_problem` section keyword
       at all) whose `:ordered-subtasks` enumerated the caller's task
       sequence. That assumption is corrected here: the SAME doctest above
       grounds a problem whose `:htn :ordered-subtasks (open-door d1)` calls
       a **primitive action name directly**, with zero domain-side
       `:task`/`:method` declared -- `ferroplan_hddl::grounder`'s own
       `ground_root_network` resolves a root task-network subtask against
       either a domain action or a domain task by name uniformly. This
       session confirmed the same thing twice more by hand: a one-action and
       a two-action-in-sequence domain/problem pair, both solved for real via
       `hddl_cli`, both using a bare `:htn :ordered-subtasks (and (t1 (op
       args...)) (t2 (op2 args...)))` referencing declared `:action` names
       with no intervening `:task`/`:method`. `problem_text/3` therefore
       renders this simpler, empirically-sufficient shape -- a real
       correction to the design plan's assumption, not a deviation from
       anything actually verified.

  ## Deliberate deviation from the design plan's `task_sequence` shape

  The design plan's sketch had `task_sequence: [capability_id]` -- bare
  capability-id strings, no call arguments. That shape cannot actually be
  rendered as a runnable HDDL task-network subtask: an HDDL task/action call
  is always `(name arg1 arg2 ...)` -- a bare name with no way to supply the
  concrete object arguments most operators need (see `advance(?from, ?to)`
  in every existing fixture in `test/support/hddl/`). `problem_text/3`
  therefore takes `task_sequence` as a list of the same
  `{name, args}` 2-tuples described above (name = a capability id or
  already-safe-named action, args = ground object ids in call order), the
  only shape HDDL itself can actually execute. A future `GoalFacts.admit/2`
  (a later task) is responsible for building this shape from the wire
  envelope's JSON, not this module.

  ## Untyped MVP scope

  `:types` is never emitted; `objects: [%{id: ...}]` entries' optional
  `type:`/`"type"` key (if present) is accepted for forward-compatibility but
  intentionally ignored -- matches this repo's own stated MVP decision
  (typed parameters are a strict superset addable later without breaking
  this untyped shape).
  """

  alias AshA2A.HddlOperator
  alias AshA2A.Info

  @type fact :: {name :: atom() | String.t(), args :: [atom() | String.t()]}

  @doc """
  Converts any atom/string/term into a valid HDDL name token: ASCII
  alphanumeric plus `-`/`_` only, guaranteed to start with a letter (the
  real lexer's own `is_name_start`/`is_name_cont` rules --
  `crates/ferroplan/src/lexer.rs` in the real `ferroplan` dependency source,
  read this session -- accept `[A-Za-z][A-Za-z0-9_:-]*`; this function never
  emits a leading `:` to avoid any ambiguity with a keyword token). Every
  non-conforming byte (most importantly `.`, which appears in every default
  `AshA2A.CapabilityIndex.Compiler.capability_id/2` value, e.g.
  `"MyApp.Resource.advance"`, and which the real lexer does NOT accept inside
  a name -- only inside a numeric literal) becomes `_`.

  Exposed (not private) because `problem_text/3`'s caller must apply this
  exact same transform to any capability id it renders as a task-call name,
  so the resulting call matches the action name `domain_text/2` already
  emitted for that same skill.
  """
  @spec safe_name(atom() | String.t()) :: String.t()
  def safe_name(value) do
    value
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_-]/, "_")
    |> ensure_leading_letter()
  end

  defp ensure_leading_letter(<<c, _rest::binary>> = s) when c in ?a..?z or c in ?A..?Z, do: s
  defp ensure_leading_letter(s), do: "n_" <> s

  @doc """
  Renders one HDDL domain definition from `resource_or_domain`'s compiled
  capability index: one `:predicates` declaration (derived from the union of
  every declared operator's precondition/add-effect/delete-effect facts) and
  one `:action` per declared `AshA2A.HddlOperator`.

  Skills with `hddl_operators == []` are silently excluded -- not a planning-
  relevant capability for this path, never an error. Returns
  `{:error, %{code: :no_hddl_operators, ...}}` if none remain (a domain with
  zero actions cannot solve anything, so this fails closed rather than
  emitting a degenerate always-unsolvable domain silently).
  """
  @spec domain_text(module(), String.t()) :: {:ok, String.t()} | {:error, map()}
  def domain_text(resource_or_domain, domain_name) when is_binary(domain_name) do
    with {:ok, index} <- fetch_index(resource_or_domain),
         skills <- Enum.filter(index, &(&1.hddl_operators != [])),
         :ok <- ensure_nonempty(skills, :no_hddl_operators, "no skill declares an hddl_operator"),
         {:ok, arities} <- predicate_arities(skills) do
      predicates_block =
        arities
        |> Enum.sort()
        |> Enum.map(fn {name, arity} -> "    (#{name}#{placeholder_params(arity)})" end)
        |> Enum.join("\n")

      action_blocks =
        skills
        |> Enum.flat_map(fn skill ->
          count = length(skill.hddl_operators)

          skill.hddl_operators
          |> Enum.with_index()
          |> Enum.map(fn {op, idx} -> render_action(action_name(skill, idx, count), op) end)
        end)
        |> Enum.join("\n")

      text = """
      (define (domain #{safe_name(domain_name)})
        (:predicates
      #{predicates_block})
      #{action_blocks})
      """

      {:ok, text}
    end
  end

  @doc """
  Renders one HDDL problem from caller-submitted, already-admitted goal
  facts.

  `opts`:

    * `:domain_name` (required) -- must be the exact same string passed to
      `domain_text/2` for this plan (both go through `safe_name/1`
      identically, so any string round-trips consistently, but they must be
      the *same* string).
    * `:objects` -- list of object ids, each either a bare atom/string or a
      `%{id: id}` / `%{"id" => id}` map (an optional `type:`/`"type"` key is
      accepted and ignored -- see moduledoc's "Untyped MVP scope"). Default
      `[]`.
    * `:init` -- list of ground `fact()` 2-tuples. Default `[]`.
    * `:goal` -- list of ground `fact()` 2-tuples, rendered as a conjunction.
      Default `[]` (an always-satisfied empty goal).
    * `:task_sequence` (required, non-empty) -- ordered list of `fact()`-
      shaped `{name, args}` task calls (see moduledoc's "Deliberate
      deviation" section for why this is call tuples, not bare capability-id
      strings).

  Returns `{:error, %{code: :missing_opt, ...}}` if `:domain_name` or
  `:task_sequence` is absent, or `{:error, %{code: :empty_task_sequence,
  ...}}` if `:task_sequence` is present but empty.
  """
  @spec problem_text(module(), String.t(), keyword()) :: {:ok, String.t()} | {:error, map()}
  def problem_text(_resource_or_domain, problem_name, opts) when is_binary(problem_name) do
    with {:ok, domain_name} <- fetch_required(opts, :domain_name),
         {:ok, task_calls} <- fetch_required(opts, :task_sequence),
         :ok <-
           ensure_nonempty(
             task_calls,
             :empty_task_sequence,
             "task_sequence must declare at least one task call"
           ) do
      objects = Keyword.get(opts, :objects, [])
      init = Keyword.get(opts, :init, [])
      goal = Keyword.get(opts, :goal, [])

      objects_line =
        objects
        |> Enum.map(&(&1 |> object_id() |> safe_name()))
        |> Enum.join(" ")

      init_block =
        init
        |> Enum.map(&render_ground_call/1)
        |> Enum.join(" ")

      goal_block =
        case goal do
          [] -> "()"
          facts -> "(and #{Enum.map_join(facts, " ", &render_ground_call/1)})"
        end

      subtasks_block =
        task_calls
        |> Enum.with_index(1)
        |> Enum.map(fn {call, i} -> "      (t#{i} #{render_ground_call(call)})" end)
        |> Enum.join("\n")

      text = """
      (define (problem #{safe_name(problem_name)})
        (:domain #{safe_name(domain_name)})
        (:objects #{objects_line})
        (:init #{init_block})
        (:goal #{goal_block})
        (:htn
          :ordered-subtasks (and
      #{subtasks_block})))
      """

      {:ok, text}
    end
  end

  # -- domain rendering -----------------------------------------------------

  defp render_action(name, %HddlOperator{} = op) do
    params =
      op.parameters
      |> Enum.map(&"?#{safe_name(&1)}")
      |> Enum.join(" ")

    precondition = render_domain_conjunction(op.preconditions)
    effect = render_domain_effect(op.add_effects, op.delete_effects)

    """
      (:action #{name}
        :parameters (#{params})
        :precondition #{precondition}
        :effect #{effect})
    """
    |> String.trim_trailing("\n")
  end

  defp render_domain_conjunction([]), do: "()"

  defp render_domain_conjunction(facts) do
    "(and #{Enum.map_join(facts, " ", &render_domain_fact/1)})"
  end

  defp render_domain_effect([], []), do: "()"

  defp render_domain_effect(add_effects, delete_effects) do
    add_strs = Enum.map(add_effects, &render_domain_fact/1)
    delete_strs = Enum.map(delete_effects, &"(not #{render_domain_fact(&1)})")
    "(and #{Enum.join(add_strs ++ delete_strs, " ")})"
  end

  defp render_domain_fact({predicate, args}) do
    case Enum.map(args, &"?#{safe_name(&1)}") do
      [] -> "(#{safe_name(predicate)})"
      arg_strs -> "(#{safe_name(predicate)} #{Enum.join(arg_strs, " ")})"
    end
  end

  defp action_name(skill, _idx, 1), do: safe_name(skill.id)
  defp action_name(skill, idx, _count), do: "#{safe_name(skill.id)}-#{idx}"

  defp placeholder_params(0), do: ""

  defp placeholder_params(arity) do
    " " <> (1..arity |> Enum.map_join(" ", &"?a#{&1}"))
  end

  defp predicate_arities(skills) do
    skills
    |> Enum.flat_map(fn skill -> Enum.flat_map(skill.hddl_operators, &operator_facts/1) end)
    |> Enum.reduce_while({:ok, %{}}, fn {predicate, args}, {:ok, acc} ->
      name = safe_name(predicate)
      arity = length(args)

      case Map.fetch(acc, name) do
        {:ok, ^arity} ->
          {:cont, {:ok, acc}}

        {:ok, other_arity} ->
          {:halt,
           {:error,
            %{
              code: :inconsistent_predicate_arity,
              predicate: name,
              arities: [other_arity, arity]
            }}}

        :error ->
          {:cont, {:ok, Map.put(acc, name, arity)}}
      end
    end)
  end

  defp operator_facts(%HddlOperator{} = op) do
    op.preconditions ++ op.add_effects ++ op.delete_effects
  end

  # -- problem rendering ------------------------------------------------------

  defp render_ground_call({name, args}) do
    case Enum.map(args, &safe_name/1) do
      [] -> "(#{safe_name(name)})"
      arg_strs -> "(#{safe_name(name)} #{Enum.join(arg_strs, " ")})"
    end
  end

  defp object_id(%{id: id}), do: id
  defp object_id(%{"id" => id}), do: id
  defp object_id(id) when is_atom(id) or is_binary(id), do: id

  # -- shared helpers -----------------------------------------------------

  defp fetch_index(resource_or_domain) do
    case Info.capability_index_result(resource_or_domain) do
      {:ok, index} ->
        {:ok, index}

      {:error, :not_compiled} ->
        {:error,
         %{
           code: :not_compiled,
           message: "#{inspect(resource_or_domain)} has no compiled AshA2A capability index"
         }}
    end
  end

  defp fetch_required(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, %{code: :missing_opt, opt: key}}
    end
  end

  defp ensure_nonempty([], code, message), do: {:error, %{code: code, message: message}}
  defp ensure_nonempty(_list, _code, _message), do: :ok
end
