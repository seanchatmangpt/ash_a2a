defmodule AshA2A.Chicago.Mutation do
  @moduledoc """
  RFC-SA2A-002 §11 (last paragraph), §22 and §97 anti-vacuity mutation engine.

  A falsifier that keeps passing after the guard it attacks is deleted is
  presumed vacuous (§11). This module proves the opposite for real courts by
  deleting the guard in the running VM and re-running the court:

    1. read the target module's abstract code from its BEAM `debug_info`
       chunk (`:beam_lib.chunks/2`, backend `:erlang_v1`)
    2. replace the selected clauses of one named function/arity -- public or
       private -- with a mutant body written as an Erlang expression
       (`"ok."`, `"true."`, `"{ok, nil}."`); heads and guards are kept and each
       argument is aliased as `ChicagoArg1..N` so a body can use them
    3. `:compile.forms/2` the mutated module and hot-load it with
       `:code.load_binary/3`
    4. run the designated court(s) through `AshA2A.Chicago.Runner`
    5. **always** restore the original BEAM, then judge from the durable
       evidence each run wrote to disk

  ## Restoration is exit-safe

  A guardian process (`spawn_monitor`, not linked) holds the engine lock and
  the original binary before the mutant is loaded. The owner asks it to
  restore after the stimulus returns, raises, throws or exits. If the owner
  is killed outright (`Process.exit(pid, :kill)` skips every `after` block)
  the guardian's monitor fires and it restores on its own. Restoration purges
  old code softly, then hard (killing only processes still executing the
  mutant) and verifies the loaded md5 is the on-disk md5 again.

  ## Refusals

  The engine refuses (never silently skips) a target that is: part of the
  Chicago verdict machinery itself (a mutant court judge could lie), outside
  the `:ash_a2a` application, not compiled, without object code or debug
  info, already different from its on-disk BEAM, missing the named function,
  matched by no clause, or whose mutant does not compile. Only one mutation
  may be live in the node at a time (`:global` lock held by the guardian).

  ## Telemetry (the engine's own boundary, §12)

    * `[:ash_a2a, :chicago, :mutation, :requested]` -- a mutation reached the engine
    * `[:ash_a2a, :chicago, :mutation, :refused]` -- `:code`, `:detail`
    * `[:ash_a2a, :chicago, :mutation, :applied]` -- mutant loaded (`:original_md5`, `:mutant_md5`)
    * `[:ash_a2a, :chicago, :mutation, :restored]` -- `:pristine`, `:purge`, `:mutant_calls`, `:trigger`
    * `[:ash_a2a, :chicago, :mutation, :verdict]` -- `:verdict` and the per-court judgement

  ## Verdicts (`qualify/2`)

    * `:mutant_killed` -- a killer court reports a falsifier survived or a
      positive control failed under the mutant that it did not report on the
      unmutated baseline (the court detects the guard's removal)
    * `:mutant_survived` -- every killer court still reports only corroborated
      passes with the guard removed: the court is vacuous for that guard
    * `:blocked` -- the target or every killer court is unavailable
    * `:unknown` -- the baseline was not clean, a run could not be read back
      from disk, or the original BEAM could not be restored (§130: never a pass)
  """

  alias AshA2A.Chicago
  alias AshA2A.Chicago.{Court, Runner, StandingReceipt}
  alias AshA2A.Chicago.Mutation.{Catalog, Verdict}

  @enforce_keys [:id, :module, :function, :arity, :operator]
  defstruct [
    :id,
    :module,
    :function,
    :arity,
    :operator,
    clauses: :all,
    rfc_mutation: nil,
    guard: nil,
    killers: [],
    description: nil
  ]

  @type selector ::
          :all
          | {:clause, pos_integer()}
          | {:arg_literal, pos_integer(), atom()}
          | {:arg_tag, pos_integer(), atom()}

  @type operator :: :identity | {:replace_body, String.t()} | {:collapse, String.t()}

  @type t :: %__MODULE__{
          id: String.t(),
          module: module(),
          function: atom(),
          arity: non_neg_integer(),
          operator: operator(),
          clauses: selector(),
          rfc_mutation: String.t() | nil,
          guard: String.t() | nil,
          killers: [String.t()],
          description: String.t() | nil
        }

  @type refusal :: %{code: atom(), detail: String.t()}

  @type plan :: %{
          mutation_id: String.t(),
          module: module(),
          function: atom(),
          arity: non_neg_integer(),
          target: String.t(),
          filename: charlist(),
          original_binary: binary(),
          original_md5: String.t(),
          mutant_binary: binary(),
          mutant_md5: String.t(),
          clauses_mutated: pos_integer()
        }

  @arg_prefix "ChicagoArg"
  @lock_resource {__MODULE__, :engine}
  @compile_opts [:binary, :return_errors, :return_warnings, :no_auto_import]
  @verdict_court_id "SA2A-MUTATION"

  @protected [
    AshA2A.Chicago,
    AshA2A.Chicago.Context,
    AshA2A.Chicago.Court,
    AshA2A.Chicago.FailureClass,
    AshA2A.Chicago.Falsifier,
    AshA2A.Chicago.Json,
    AshA2A.Chicago.Observer,
    AshA2A.Chicago.Profile,
    AshA2A.Chicago.Query,
    AshA2A.Chicago.Result,
    AshA2A.Chicago.Runner,
    AshA2A.Chicago.Runner.Run,
    AshA2A.Chicago.StandingReceipt,
    AshA2A.Chicago.Subject,
    AshA2A.Chicago.Courts.MutationCourt,
    __MODULE__
  ]

  @protected_prefixes ["Elixir.AshA2A.Chicago.Ocel.", "Elixir.AshA2A.Chicago.Mutation."]

  @refusal_codes %{
    mutation_target_protected: :refused_authority,
    mutation_target_foreign: :refused_authority,
    mutation_target_not_compiled: :blocked_resource,
    mutation_object_code_unavailable: :blocked_resource,
    mutation_debug_info_unavailable: :blocked_resource,
    mutation_target_not_pristine: :refused_meta_rigor,
    mutation_old_code_in_use: :blocked_resource,
    mutation_function_not_found: :blocked_resource,
    mutation_clause_not_matched: :refused_structure,
    mutation_body_invalid: :refused_structure,
    mutation_operator_invalid: :refused_structure,
    mutation_compile_failed: :refused_structure,
    mutation_load_failed: :blocked_resource,
    mutation_in_progress: :blocked_resource,
    mutation_guardian_failed: :blocked_resource,
    mutation_killer_courts_missing: :blocked_resource
  }

  @doc false
  @spec __sa2a_refusal_codes__() :: %{atom() => atom()}
  def __sa2a_refusal_codes__, do: @refusal_codes

  @doc "Telemetry events this engine emits."
  @spec events() :: [[atom()]]
  def events do
    for suffix <- [:requested, :refused, :applied, :restored, :verdict],
        do: [:ash_a2a, :chicago, :mutation, suffix]
  end

  @doc "`\"Module.function/arity\"`."
  @spec target(t()) :: String.t()
  def target(%__MODULE__{module: module, function: function, arity: arity}),
    do: "#{inspect(module)}.#{function}/#{arity}"

  @doc "True when `module` belongs to the Chicago verdict machinery and may never be mutated."
  @spec protected?(module()) :: boolean()
  def protected?(module) when is_atom(module) do
    name = Atom.to_string(module)
    module in @protected or Enum.any?(@protected_prefixes, &String.starts_with?(name, &1))
  end

  # --- preparation -----------------------------------------------------------

  @doc """
  Builds the mutant without loading it: resolves object code and debug info,
  applies the operator to the selected clauses and compiles. Pure with
  respect to the running system.
  """
  @spec prepare(t()) :: {:ok, plan()} | {:error, refusal()}
  def prepare(%__MODULE__{} = m) do
    with :ok <- check_shape(m),
         :ok <- check_protected(m.module),
         :ok <- check_loaded(m.module),
         :ok <- check_application(m.module),
         {:ok, binary, filename} <- object_code(m.module),
         :ok <- check_pristine(m.module, binary),
         {:ok, forms} <- abstract_forms(m.module, binary),
         {:ok, mutated_forms, count} <- mutate_forms(forms, m),
         {:ok, mutant} <- compile(m.module, mutated_forms) do
      {:ok,
       %{
         mutation_id: m.id,
         module: m.module,
         function: m.function,
         arity: m.arity,
         target: target(m),
         filename: filename,
         original_binary: binary,
         original_md5: binary_md5(binary),
         mutant_binary: mutant,
         mutant_md5: binary_md5(mutant),
         clauses_mutated: count
       }}
    end
  end

  defp check_shape(%__MODULE__{id: id, module: mod, function: fun, arity: arity})
       when is_binary(id) and id != "" and is_atom(mod) and is_atom(fun) and is_integer(arity) and
              arity >= 0,
       do: :ok

  defp check_shape(m), do: refuse(:mutation_operator_invalid, "malformed mutation #{inspect(m)}")

  defp check_protected(module) do
    cond do
      protected?(module) ->
        refuse(
          :mutation_target_protected,
          "#{inspect(module)} is Chicago verdict machinery; a mutant judge could manufacture its own verdict"
        )

      Code.ensure_loaded?(module) and :code.is_sticky(module) ->
        refuse(:mutation_target_protected, "#{inspect(module)} is a sticky runtime module")

      true ->
        :ok
    end
  end

  defp check_loaded(module) do
    if Code.ensure_loaded?(module),
      do: :ok,
      else:
        refuse(
          :mutation_target_not_compiled,
          "#{inspect(module)} is not compiled in this subject"
        )
  end

  defp check_application(module) do
    case :application.get_application(module) do
      {:ok, :ash_a2a} ->
        :ok

      other ->
        refuse(
          :mutation_target_foreign,
          "#{inspect(module)} belongs to #{inspect(other)}, not the :ash_a2a subject"
        )
    end
  end

  defp object_code(module) do
    case :code.get_object_code(module) do
      {^module, binary, filename} ->
        {:ok, binary, filename}

      :error ->
        refuse(
          :mutation_object_code_unavailable,
          "no BEAM on the code path for #{inspect(module)}"
        )
    end
  end

  defp check_pristine(module, binary) do
    cond do
      loaded_md5(module) != binary_md5(binary) ->
        refuse(
          :mutation_target_not_pristine,
          "loaded #{inspect(module)} differs from its on-disk BEAM (already mutated or stale)"
        )

      :erlang.check_old_code(module) and not soft_purge(module, 10) ->
        refuse(:mutation_old_code_in_use, "old code of #{inspect(module)} is still executing")

      true ->
        :ok
    end
  end

  defp abstract_forms(module, binary) do
    case :beam_lib.chunks(binary, [:debug_info]) do
      {:ok, {^module, [debug_info: {:debug_info_v1, backend, data}]}} ->
        case backend.debug_info(:erlang_v1, module, data, []) do
          {:ok, forms} -> {:ok, forms}
          {:error, reason} -> refuse(:mutation_debug_info_unavailable, inspect(reason))
        end

      other ->
        refuse(:mutation_debug_info_unavailable, inspect(other, limit: 5))
    end
  rescue
    exception -> refuse(:mutation_debug_info_unavailable, Exception.message(exception))
  end

  @doc false
  @spec mutate_forms([tuple()], t()) :: {:ok, [tuple()], pos_integer()} | {:error, refusal()}
  def mutate_forms(forms, %__MODULE__{function: fun, arity: arity} = m) do
    index =
      Enum.find_index(forms, fn
        {:function, _anno, ^fun, ^arity, _clauses} -> true
        _ -> false
      end)

    case index do
      nil ->
        refuse(:mutation_function_not_found, "#{target(m)} is not defined")

      i ->
        {:function, anno, ^fun, ^arity, clauses} = Enum.at(forms, i)

        with {:ok, new_clauses, count} <- apply_operator(m, anno, clauses) do
          {:ok, List.replace_at(forms, i, {:function, anno, fun, arity, new_clauses}), count}
        end
    end
  end

  defp apply_operator(%__MODULE__{operator: :identity, clauses: selector} = m, _anno, clauses) do
    case count_selected(clauses, selector) do
      0 ->
        refuse(
          :mutation_clause_not_matched,
          "#{inspect(selector)} matched no clause of #{target(m)}"
        )

      n ->
        {:ok, clauses, n}
    end
  end

  defp apply_operator(
         %__MODULE__{operator: {:replace_body, source}, clauses: selector} = m,
         anno,
         clauses
       )
       when is_binary(source) do
    with {:ok, body} <- parse_body(source, anno) do
      {new, count} =
        clauses
        |> Enum.with_index(1)
        |> Enum.map_reduce(0, fn {{:clause, a, heads, guards, _body} = clause, i}, n ->
          if selected?(clause, i, selector),
            do: {{:clause, a, alias_heads(heads, a), guards, body}, n + 1},
            else: {clause, n}
        end)

      if count == 0,
        do:
          refuse(
            :mutation_clause_not_matched,
            "#{inspect(selector)} matched no clause of #{target(m)}"
          ),
        else: {:ok, new, count}
    end
  end

  defp apply_operator(
         %__MODULE__{operator: {:collapse, source}, clauses: :all, arity: arity},
         anno,
         clauses
       )
       when is_binary(source) do
    with {:ok, body} <- parse_body(source, anno) do
      heads = for i <- 1..arity//1, do: {:var, anno, arg_var(i)}
      {:ok, [{:clause, anno, heads, [], body}], length(clauses)}
    end
  end

  defp apply_operator(%__MODULE__{} = m, _anno, _clauses),
    do:
      refuse(
        :mutation_operator_invalid,
        "unsupported operator/selector #{inspect({m.operator, m.clauses})}"
      )

  defp count_selected(clauses, selector) do
    clauses
    |> Enum.with_index(1)
    |> Enum.count(fn {clause, i} -> selected?(clause, i, selector) end)
  end

  defp selected?(_clause, _i, :all), do: true
  defp selected?(_clause, i, {:clause, n}), do: i == n

  defp selected?({:clause, _, heads, _, _}, _i, {:arg_literal, n, literal}),
    do: literal_pattern?(Enum.at(heads, n - 1), literal)

  defp selected?({:clause, _, heads, _, _}, _i, {:arg_tag, n, tag}),
    do: tagged_pattern?(Enum.at(heads, n - 1), tag)

  defp selected?(_clause, _i, _selector), do: false

  defp literal_pattern?({:atom, _, literal}, literal), do: true

  defp literal_pattern?({:match, _, left, right}, literal),
    do: literal_pattern?(left, literal) or literal_pattern?(right, literal)

  defp literal_pattern?(_pattern, _literal), do: false

  defp tagged_pattern?({:tuple, _, [{:atom, _, tag} | _]}, tag), do: true

  defp tagged_pattern?({:match, _, left, right}, tag),
    do: tagged_pattern?(left, tag) or tagged_pattern?(right, tag)

  defp tagged_pattern?(_pattern, _tag), do: false

  defp alias_heads(heads, anno) do
    heads
    |> Enum.with_index(1)
    |> Enum.map(fn {pattern, i} -> {:match, anno, {:var, anno, arg_var(i)}, pattern} end)
  end

  defp arg_var(i), do: String.to_atom(@arg_prefix <> Integer.to_string(i))

  defp parse_body(source, anno) do
    with {:ok, tokens, _end} <- :erl_scan.string(String.to_charlist(source), :erl_anno.line(anno)),
         {:ok, [_ | _] = exprs} <- :erl_parse.parse_exprs(tokens) do
      {:ok, exprs}
    else
      {:error, info, _location} -> refuse(:mutation_body_invalid, inspect(info))
      {:error, info} -> refuse(:mutation_body_invalid, inspect(info))
      other -> refuse(:mutation_body_invalid, inspect(other))
    end
  end

  defp compile(module, forms) do
    case :compile.forms(forms, @compile_opts) do
      {:ok, ^module, binary, _warnings} -> {:ok, binary}
      {:ok, ^module, binary} -> {:ok, binary}
      {:error, errors, _warnings} -> refuse(:mutation_compile_failed, inspect(errors, limit: 20))
      other -> refuse(:mutation_compile_failed, inspect(other, limit: 20))
    end
  rescue
    exception -> refuse(:mutation_compile_failed, Exception.message(exception))
  end

  # --- live mutation ------------------------------------------------------------

  @doc """
  Loads the mutant, runs `fun.(applied)` and always restores the original.

  Returns `{:ok, value, %{applied: map, restored: map}}`; a raise, throw or
  exit from `fun` is re-raised after restoration. `applied.guardian` is the
  pid that restores the module if the calling process dies.
  """
  @spec with_mutant(t(), (map() -> result)) ::
          {:ok, result, %{applied: map(), restored: map()}} | {:error, refusal()}
        when result: var
  def with_mutant(%__MODULE__{} = m, fun) when is_function(fun, 1) do
    emit(:requested, %{mutation_id: m.id, target: target(m), module: inspect(m.module)})

    case prepare(m) do
      {:ok, plan} -> arm_and_run(m, plan, fun)
      {:error, refusal} -> refused(m, refusal)
    end
  end

  defp arm_and_run(m, plan, fun) do
    owner = self()
    ref = make_ref()
    {guardian, gmon} = spawn_monitor(fn -> guardian_init(owner, ref, plan) end)

    receive do
      {^ref, :armed} ->
        load_and_run(m, plan, fun, guardian, gmon, ref)

      {^ref, {:refused, refusal}} ->
        Process.demonitor(gmon, [:flush])
        refused(m, refusal)

      {:DOWN, ^gmon, :process, _pid, reason} ->
        refused(m, %{code: :mutation_guardian_failed, detail: inspect(reason)})
    after
      30_000 ->
        Process.demonitor(gmon, [:flush])
        Process.exit(guardian, :kill)
        refused(m, %{code: :mutation_guardian_failed, detail: "guardian did not arm within 30s"})
    end
  end

  defp load_and_run(m, plan, fun, guardian, gmon, ref) do
    case :code.load_binary(plan.module, plan.filename, plan.mutant_binary) do
      {:module, _} ->
        counting? = enable_call_count(plan)

        applied = %{
          mutation_id: m.id,
          target: plan.target,
          module: inspect(plan.module),
          operator: operator_name(m.operator),
          clauses_mutated: plan.clauses_mutated,
          original_md5: plan.original_md5,
          mutant_md5: plan.mutant_md5,
          loaded_md5: loaded_md5(plan.module),
          call_count_enabled: counting?
        }

        emit(:applied, applied)
        applied = Map.put(applied, :guardian, guardian)

        outcome =
          try do
            {:returned, fun.(applied)}
          catch
            kind, reason -> {:raised, kind, reason, __STACKTRACE__}
          end

        restored = request_restore(plan, guardian, gmon, ref)

        case outcome do
          {:returned, value} ->
            {:ok, value, %{applied: Map.delete(applied, :guardian), restored: restored}}

          {:raised, kind, reason, stack} ->
            :erlang.raise(kind, reason, stack)
        end

      {:error, reason} ->
        send(guardian, {ref, :disarm, self()})

        receive do
          {^ref, :disarmed} -> :ok
          {:DOWN, ^gmon, :process, _, _} -> :ok
        after
          5_000 -> :ok
        end

        Process.demonitor(gmon, [:flush])
        refused(m, %{code: :mutation_load_failed, detail: inspect(reason)})
    end
  end

  defp request_restore(plan, guardian, gmon, ref) do
    send(guardian, {ref, :restore, self()})

    receive do
      {^ref, :restored, info} ->
        Process.demonitor(gmon, [:flush])
        info

      {:DOWN, ^gmon, :process, _pid, reason} ->
        restore(plan, {:guardian_down, reason})
    end
  end

  defp guardian_init(owner, ref, plan) do
    owner_mon = Process.monitor(owner)
    lock = {@lock_resource, self()}

    if :global.set_lock(lock, [node()], 0) do
      case check_pristine(plan.module, plan.original_binary) do
        :ok ->
          send(owner, {ref, :armed})
          guardian_loop(owner, owner_mon, ref, plan, lock)

        {:error, refusal} ->
          :global.del_lock(lock, [node()])
          send(owner, {ref, {:refused, refusal}})
      end
    else
      send(
        owner,
        {ref,
         {:refused,
          %{code: :mutation_in_progress, detail: "another mutation holds the engine lock"}}}
      )
    end
  end

  defp guardian_loop(owner, owner_mon, ref, plan, lock) do
    receive do
      {^ref, :restore, from} ->
        info = restore(plan, :owner)
        :global.del_lock(lock, [node()])
        send(from, {ref, :restored, info})

      {^ref, :disarm, from} ->
        :global.del_lock(lock, [node()])
        send(from, {ref, :disarmed})

      {:DOWN, ^owner_mon, :process, ^owner, reason} ->
        _ = restore(plan, {:owner_down, reason})
        :global.del_lock(lock, [node()])
    end
  end

  defp restore(plan, trigger) do
    module = plan.module
    calls = take_call_count(plan)

    {action, purge} =
      if loaded_md5(module) == plan.original_md5 do
        {:already_original, purge_old(module)}
      else
        first = purge_old(module)
        loaded = load_original(plan)
        second = purge_old(module)
        {loaded, strongest(first, second)}
      end

    restored_md5 = loaded_md5(module)
    pristine = restored_md5 == plan.original_md5 and not :erlang.check_old_code(module)

    info = %{
      mutation_id: plan.mutation_id,
      target: plan.target,
      module: inspect(module),
      pristine: pristine,
      restored_md5: restored_md5,
      original_md5: plan.original_md5,
      action: action,
      purge: purge,
      mutant_calls: calls,
      trigger: trigger_name(trigger),
      trigger_reason: trigger_reason(trigger)
    }

    emit(:restored, info)
    info
  end

  defp load_original(plan) do
    case :code.load_binary(plan.module, plan.filename, plan.original_binary) do
      {:module, _} ->
        :reloaded

      {:error, _reason} ->
        _ = :code.purge(plan.module)

        case :code.load_binary(plan.module, plan.filename, plan.original_binary) do
          {:module, _} -> :reloaded_after_hard_purge
          {:error, reason} -> {:reload_failed, reason}
        end
    end
  end

  defp purge_old(module) do
    cond do
      not :erlang.check_old_code(module) -> :none
      soft_purge(module, 40) -> :soft
      true -> if(:code.purge(module), do: :hard_killed, else: :hard)
    end
  end

  defp soft_purge(module, 0), do: :code.soft_purge(module)

  defp soft_purge(module, retries) do
    if :code.soft_purge(module) do
      true
    else
      Process.sleep(25)
      soft_purge(module, retries - 1)
    end
  end

  defp strongest(a, b) do
    rank = %{none: 0, soft: 1, hard: 2, hard_killed: 3}
    if Map.fetch!(rank, a) >= Map.fetch!(rank, b), do: a, else: b
  end

  defp trigger_name({name, _reason}), do: name
  defp trigger_name(name) when is_atom(name), do: name
  defp trigger_reason({_name, reason}), do: inspect(reason, limit: 5)
  defp trigger_reason(_name), do: nil

  defp enable_call_count(plan) do
    :erlang.trace_pattern({plan.module, plan.function, plan.arity}, true, [:call_count]) > 0
  rescue
    _ -> false
  end

  defp take_call_count(plan) do
    mfa = {plan.module, plan.function, plan.arity}

    count =
      case :erlang.trace_info(mfa, :call_count) do
        {:call_count, n} when is_integer(n) -> n
        _ -> nil
      end

    _ = :erlang.trace_pattern(mfa, false, [:call_count])
    count
  rescue
    _ -> nil
  end

  @doc "True when the loaded `module` is exactly its on-disk BEAM with no old code."
  @spec pristine?(module()) :: boolean()
  def pristine?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and
      case :code.get_object_code(module) do
        {^module, binary, _} ->
          binary_md5(binary) == loaded_md5(module) and not :erlang.check_old_code(module)

        :error ->
          false
      end
  end

  @doc """
  Forces `module` back to its on-disk BEAM (test/operator safety net).
  Returns `pristine?/1` afterwards.
  """
  @spec restore!(module()) :: boolean()
  def restore!(module) when is_atom(module) do
    if pristine?(module) do
      true
    else
      case :code.get_object_code(module) do
        {^module, binary, filename} ->
          _ = purge_old(module)
          _ = load_original(%{module: module, filename: filename, original_binary: binary})
          _ = purge_old(module)
          pristine?(module)

        :error ->
          false
      end
    end
  end

  # --- qualification -----------------------------------------------------------

  @doc """
  Resolves the courts expected to kill `mutation` by court-id family: a
  killer id `"SA2A-AUTH"` matches court `"SA2A-AUTH"` and `"SA2A-AUTH-GRANT"`.
  Candidates are `opts[:courts]`, the catalog's reference courts and every
  discoverable court; `SA2A-MUTATION` itself is never a killer.
  """
  @spec killer_courts(t(), keyword()) :: {:ok, [module()], [String.t()]} | {:error, refusal()}
  def killer_courts(%__MODULE__{killers: killers}, opts \\ []) do
    candidates =
      (Keyword.get(opts, :courts, []) ++ Catalog.reference_courts() ++ Chicago.courts())
      |> Enum.uniq()
      |> Enum.filter(&Court.court?/1)
      |> Enum.reject(&(&1.id() == @verdict_court_id))

    matched =
      Enum.filter(candidates, fn court -> Enum.any?(killers, &family?(court.id(), &1)) end)

    missing = Enum.reject(killers, fn k -> Enum.any?(matched, &family?(&1.id(), k)) end)

    case matched do
      [] ->
        {:error,
         %{
           code: :mutation_killer_courts_missing,
           detail: "no compiled court for killer ids #{Enum.join(killers, ", ")}"
         }}

      courts ->
        {:ok, Enum.sort_by(courts, & &1.id()), missing}
    end
  end

  defp family?(court_id, killer),
    do: court_id == killer or String.starts_with?(court_id, killer <> "-")

  @doc """
  Runs `courts` unmutated and reads the result back from disk. Used as the
  clean reference each mutant run is judged against.
  """
  @spec baseline([module()], Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def baseline(courts, dir, opts \\ []), do: run_courts(courts, dir, "baseline", opts)

  @doc """
  `{baseline, cache}` for `courts`, reusing a baseline already computed for the
  same court set under `root`.
  """
  @spec cached_baseline([module()], Path.t(), map(), keyword()) ::
          {{:ok, map()} | {:error, term()}, map()}
  def cached_baseline(courts, root, cache, opts \\ []) do
    key = courts |> Enum.map(& &1.id()) |> Enum.sort()

    case Map.fetch(cache, key) do
      {:ok, baseline} ->
        {baseline, cache}

      :error ->
        tag =
          :crypto.hash(:sha256, Enum.join(key, ","))
          |> Base.encode16(case: :lower)
          |> binary_part(0, 12)

        baseline = baseline(courts, Path.join(root, "baseline-" <> tag), opts)
        {baseline, Map.put(cache, key, baseline)}
    end
  end

  @doc """
  Qualifies one mutation: resolve killers, preflight the target, run (or
  reuse, `opts[:baseline]`) the unmutated baseline, run the killer courts
  under the live mutant, restore, and judge from the durable evidence.

  Options: `:courts` (extra killer candidates), `:evidence_dir`, `:baseline`,
  `:court_timeout_ms`, `:subject_opts`.
  """
  @spec qualify(t(), keyword()) :: Verdict.t()
  def qualify(%__MODULE__{} = m, opts \\ []) do
    dir =
      Keyword.get_lazy(opts, :evidence_dir, fn ->
        Path.join(
          System.tmp_dir!(),
          "ash_a2a-mutation-#{m.id}-#{System.unique_integer([:positive])}"
        )
      end)

    with {:ok, _plan} <- preflight(m),
         {:ok, courts, missing} <- preflight_killers(m, opts) do
      baseline =
        Keyword.get_lazy(opts, :baseline, fn ->
          baseline(courts, Path.join(dir, "baseline"), opts)
        end)

      mutant_dir = Path.join(dir, "mutant")

      case with_mutant(m, fn _applied -> run_courts(courts, mutant_dir, "mutant", opts) end) do
        {:ok, mutant, %{applied: applied, restored: restored}} ->
          m
          |> judge(courts, missing, baseline, mutant, applied, restored)
          |> emit_verdict()

        {:error, refusal} ->
          blocked(m, refusal)
      end
    else
      {:error, refusal} -> blocked(m, refusal)
    end
  end

  # Target first: an unresolvable target is the more specific reason.
  defp preflight(m) do
    case prepare(m) do
      {:ok, plan} ->
        {:ok, plan}

      {:error, refusal} ->
        emit(:requested, %{mutation_id: m.id, target: target(m), module: inspect(m.module)})
        refused(m, refusal)
    end
  end

  defp preflight_killers(m, opts) do
    case killer_courts(m, opts) do
      {:ok, courts, missing} ->
        {:ok, courts, missing}

      {:error, refusal} ->
        emit(:requested, %{mutation_id: m.id, target: target(m), module: inspect(m.module)})
        refused(m, refusal)
    end
  end

  defp blocked(m, refusal) do
    %Verdict{
      mutation_id: m.id,
      target: target(m),
      verdict: :blocked,
      code: refusal.code,
      detail: refusal.detail,
      killers: m.killers
    }
  end

  defp run_courts(courts, dir, phase, opts) do
    run_id = "mutation-#{phase}-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower))

    runner_opts = [
      courts: courts,
      profile: :strict,
      evidence_dir: dir,
      run_id: run_id,
      subject_opts: Keyword.get(opts, :subject_opts, artifacts: []),
      court_timeout_ms: Keyword.get(opts, :court_timeout_ms, 300_000)
    ]

    case Runner.run(runner_opts) do
      {:ok, _run} -> summarize(dir)
      {:error, reason} -> {:error, {:runner_failed, reason}}
    end
  rescue
    exception -> {:error, {:runner_raised, Exception.message(exception)}}
  end

  @doc """
  Reads a run's conformance package back from disk (fresh consumer): the
  standing receipt must re-verify its own digest before any result is used.
  """
  @spec summarize(Path.t()) :: {:ok, map()} | {:error, term()}
  def summarize(dir) do
    with {:ok, receipt} <- read_json(Path.join(dir, "standing_receipt.json")),
         :ok <- StandingReceipt.verify_digest(receipt),
         {:ok, results} when is_list(results) <- read_json(Path.join(dir, "results.json")) do
      by_court =
        results
        |> Enum.group_by(& &1["court_id"])
        |> Map.new(fn {court_id, rs} -> {court_id, classify_results(rs)} end)

      {:ok,
       %{
         dir: dir,
         standing: receipt["standing"],
         receipt_digest: receipt["receipt_digest"],
         ocel_digest: get_in(receipt, ["evidence", "ocel_digest"]),
         by_court: by_court
       }}
    else
      {:ok, other} -> {:error, {:results_not_a_list, inspect(other, limit: 3)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp classify_results(results) do
    ids = fn pred ->
      results |> Enum.filter(pred) |> Enum.map(& &1["falsifier_id"]) |> Enum.sort()
    end

    %{
      failed: ids.(&(&1["verdict"] in ["FALSIFIER_SURVIVED", "POSITIVE_CONTROL_FAILED"])),
      passed:
        ids.(
          &(&1["verdict"] in ["FALSIFIER_KILLED", "POSITIVE_CONTROL_PASSED", "MEASURED"] and
              &1["ocel_corroborated"] == true)
        ),
      unresolved:
        ids.(
          &(&1["verdict"] not in [
              "FALSIFIER_SURVIVED",
              "POSITIVE_CONTROL_FAILED",
              "UNSUPPORTED",
              "NOT_APPLICABLE"
            ] and
              not (&1["verdict"] in ["FALSIFIER_KILLED", "POSITIVE_CONTROL_PASSED", "MEASURED"] and
                     &1["ocel_corroborated"] == true))
        )
    }
  end

  defp read_json(path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, term} <- JSON.decode(bytes) do
      {:ok, term}
    else
      {:error, reason} -> {:error, {:unreadable, path, reason}}
    end
  end

  @doc false
  @spec judge(t(), [module()], [String.t()], term(), term(), map(), map()) :: Verdict.t()
  def judge(m, courts, missing, baseline, mutant, applied, restored) do
    court_ids = Enum.map(courts, & &1.id())

    court_verdicts =
      Map.new(court_ids, fn id -> {id, judge_court(id, baseline, mutant)} end)

    killed = for {id, {:killed, _}} <- court_verdicts, do: id
    survived = for {id, :survived} <- court_verdicts, do: id
    killed_by = court_verdicts |> Enum.flat_map(fn {_, v} -> killed_ids(v) end) |> Enum.sort()

    {verdict, detail} =
      cond do
        restored.pristine != true ->
          {:unknown, "original BEAM of #{target(m)} not verifiably restored; no verdict"}

        killed != [] ->
          {:mutant_killed, "killed by #{Enum.join(killed_by, ", ")}"}

        survived != [] ->
          {:mutant_survived,
           "courts #{Enum.join(survived, ", ")} report only corroborated passes with #{m.guard || target(m)} removed" <>
             call_note(restored.mutant_calls)}

        true ->
          {:unknown,
           "no court judgement: " <>
             Enum.map_join(court_verdicts, "; ", fn {id, v} -> "#{id} #{inspect(v)}" end)}
      end

    %Verdict{
      mutation_id: m.id,
      target: target(m),
      verdict: verdict,
      detail: detail,
      killers: m.killers,
      killer_courts: court_ids,
      missing_courts: missing,
      court_verdicts: Map.new(court_verdicts, fn {id, v} -> {id, verdict_name(v)} end),
      killed_by: killed_by,
      survived_courts: Enum.sort(survived),
      mutant_calls: restored.mutant_calls,
      applied: applied,
      restored: restored,
      baseline: summary_ref(baseline),
      mutant: summary_ref(mutant)
    }
  end

  defp call_note(0), do: " (mutated function was never executed by these courts)"
  defp call_note(_), do: ""

  defp judge_court(id, {:ok, baseline}, {:ok, mutant}) do
    empty = %{failed: [], passed: [], unresolved: []}
    b = Map.get(baseline.by_court, id, empty)
    mu = Map.get(mutant.by_court, id, empty)
    new_failures = mu.failed -- b.failed
    new_unresolved = mu.unresolved -- b.unresolved
    # A court carrying a recorded open defect (a baseline failure) can still
    # kill: only through a falsifier that was a CORROBORATED PASS in the
    # baseline and fails under the mutant. It can never be judged survived.
    attributable = Enum.filter(new_failures, &(&1 in b.passed))

    cond do
      b.failed != [] and attributable != [] ->
        {:killed, attributable}

      b.failed != [] ->
        {:unknown, "baseline already failing: #{Enum.join(b.failed, ", ")}"}

      b.passed == [] ->
        {:unknown, "baseline has no corroborated pass"}

      new_failures != [] ->
        {:killed, new_failures}

      new_unresolved == [] and mu.passed != [] ->
        :survived

      true ->
        {:unknown, "mutant run unresolved: #{Enum.join(new_unresolved, ", ")}"}
    end
  end

  defp judge_court(_id, {:error, reason}, _mutant),
    do: {:unknown, "baseline unreadable: #{inspect(reason)}"}

  defp judge_court(_id, _baseline, {:error, reason}),
    do: {:unknown, "mutant run unreadable: #{inspect(reason)}"}

  defp killed_ids({:killed, ids}), do: ids
  defp killed_ids(_), do: []

  defp verdict_name({:killed, _}), do: :killed
  defp verdict_name(:survived), do: :survived
  defp verdict_name({:unknown, _}), do: :unknown

  defp summary_ref({:ok, s}),
    do: %{
      dir: s.dir,
      standing: s.standing,
      receipt_digest: s.receipt_digest,
      ocel_digest: s.ocel_digest
    }

  defp summary_ref({:error, reason}), do: %{error: inspect(reason, limit: 10)}

  defp emit_verdict(%Verdict{} = v) do
    emit(:verdict, %{
      mutation_id: v.mutation_id,
      target: v.target,
      verdict: v.verdict,
      killed_by: Enum.join(v.killed_by, ","),
      killer_courts: v.killer_courts,
      survived_courts: Enum.join(v.survived_courts, ","),
      missing_courts: Enum.join(v.missing_courts, ","),
      mutant_calls: v.mutant_calls,
      baseline_standing: v.baseline[:standing],
      mutant_standing: v.mutant[:standing],
      mutant_receipt_digest: v.mutant[:receipt_digest]
    })

    v
  end

  # --- helpers -----------------------------------------------------------------

  defp refused(m, %{code: code, detail: detail} = refusal) do
    emit(:refused, %{
      mutation_id: m.id,
      target: target(m),
      module: inspect(m.module),
      code: code,
      detail: detail
    })

    {:error, refusal}
  end

  defp refuse(code, detail), do: {:error, %{code: code, detail: detail}}

  defp emit(suffix, metadata) do
    :telemetry.execute(
      [:ash_a2a, :chicago, :mutation, suffix],
      %{system_time: System.system_time()},
      metadata
    )
  end

  defp operator_name(:identity), do: "identity"
  defp operator_name({name, _}), do: Atom.to_string(name)

  defp loaded_md5(module), do: module.module_info(:md5) |> Base.encode16(case: :lower)

  defp binary_md5(binary) do
    {:ok, {_module, md5}} = :beam_lib.md5(binary)
    Base.encode16(md5, case: :lower)
  end
end
