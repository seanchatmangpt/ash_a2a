defmodule AshA2A.Chicago.Courts.MutationCourt do
  @moduledoc """
  `SA2A-MUTATION`: anti-vacuity mutation qualification (RFC-SA2A-002 §11,
  §22, §97, §129).

  One `:negative` falsifier per `AshA2A.Chicago.Mutation.Catalog` entry
  (`SA2A-MUTATION-001..`): the invariant under attack is *the killer courts
  are not vacuous for this guard*. The stimulus hot-loads the §97 mutant into
  the real subject, runs the killer courts through `AshA2A.Chicago.Runner`
  and restores the original BEAM; the forbidden outcome is
  `mutant_survived`. An entry whose target or killer courts are not compiled
  in this subject is reported `BLOCKED`, never passed.

  Harness controls (the harness itself must discriminate, §100):

    * `SA2A-MUTATION-101` positive control -- an equivalent (identity)
      recompilation of `CommandBus.admit/2` must be judged `mutant_survived`;
      a harness that calls every reload a kill is vacuous.
    * `SA2A-MUTATION-102` -- the process owning a live mutant is killed with
      `:kill` (no `after` block runs); the module must still end pristine.
    * `SA2A-MUTATION-103` -- a mutation of the Chicago verdict machinery
      (`AshA2A.Chicago.Runner.run/1`) must be refused, never loaded.

  Extra killer candidates can be supplied through the runner option
  `:mutation_courts` (carried in `Context.opts`).
  """

  use AshA2A.Chicago.Court

  alias AshA2A.Chicago.{Context, Falsifier, Mutation, Result}
  alias AshA2A.Chicago.Mutation.{Catalog, Verdict}
  alias AshA2A.Chicago.Ocel.Mapping

  @id "SA2A-MUTATION"
  @guard_killers ["CHI-MUTGUARD"]

  @impl true
  def id, do: @id
  @impl true
  def title, do: "Anti-vacuity mutation qualification"
  @impl true
  def gate, do: nil
  @impl true
  def profile, do: :strict
  @impl true
  def rfc_sections, do: ["§11", "§22", "§97", "§100", "§129", "§130"]

  @impl true
  def refusal_codes, do: Mutation.__sa2a_refusal_codes__()

  @impl true
  def ocel_mappings do
    for {suffix, activity} <- [
          requested: "chicago.mutation.requested",
          refused: "chicago.mutation.refused",
          applied: "chicago.mutation.applied",
          restored: "chicago.mutation.restored",
          verdict: "chicago.mutation.verdict"
        ] do
      Mapping.new!(
        event: [:ash_a2a, :chicago, :mutation, suffix],
        activity: activity,
        source: __MODULE__,
        objects: fn _m, meta ->
          [
            {"mutation", meta[:mutation_id], "mutation"},
            {"mutation_target", meta[:target], "target"},
            {"beam_module", meta[:module], "target_module"}
          ] ++ Enum.map(List.wrap(meta[:killer_courts]), &{"chicago_court", &1, "killer_court"})
        end,
        attributes: fn _m, meta ->
          Map.take(meta, [
            :mutation_id,
            :target,
            :code,
            :detail,
            :operator,
            :clauses_mutated,
            :original_md5,
            :mutant_md5,
            :restored_md5,
            :pristine,
            :purge,
            :action,
            :trigger,
            :mutant_calls,
            :verdict,
            :killed_by,
            :survived_courts,
            :missing_courts,
            :baseline_standing,
            :mutant_standing,
            :mutant_receipt_digest
          ])
        end
      )
    end
  end

  # --- declarations ------------------------------------------------------------

  @impl true
  def falsifiers do
    catalog =
      for {fid, m} <- Catalog.numbered() do
        Falsifier.new!(
          id: fid,
          court_id: @id,
          kind: :negative,
          invariant:
            "courts #{Enum.join(m.killers, ", ")} are not vacuous for #{m.guard}: " <>
              "#{m.rfc_mutation} must make a court fail (§11, §22, §97)",
          stimulus:
            "hot-load mutant of #{Mutation.target(m)} (#{operator_text(m)}), run the killer courts via Runner, restore the original BEAM",
          boundary: "AshA2A.Chicago.Mutation over #{Mutation.target(m)} + the killer courts",
          forbidden_outcome:
            "mutant_survived: every resolved killer court reports only corroborated passes while the guard is removed",
          attempt_evidence:
            "chicago.mutation.applied then chicago.mutation.restored (pristine) for mutation #{m.id}",
          survival_evidence:
            "chicago.mutation.verdict verdict=mutant_survived, judged from each run's digest-verified standing_receipt.json and results.json",
          guard: "§22 anti-vacuity of the falsifiers covering #{m.guard}",
          failure_class: :meta_admission_failure,
          attempt_predicate: applied_and_restored(m.id),
          outcome_predicate:
            {:observed, "chicago.mutation.verdict",
             %{"mutation_id" => m.id, "verdict" => "mutant_survived"}},
          rfc_sections: ["§11", "§22", "§97"],
          tags: [:mutation]
        )
      end

    catalog ++
      [
        Falsifier.new!(
          id: "#{@id}-101",
          court_id: @id,
          kind: :positive_control,
          invariant:
            "the harness discriminates: an equivalent (identity) recompilation is not reported as a kill",
          stimulus:
            "hot-load an identity recompilation of AshA2A.CommandBus.admit/2 and run CHI-MUTGUARD",
          boundary: "AshA2A.Chicago.Mutation judgement",
          attempt_evidence:
            "chicago.mutation.applied then restored (pristine) for equivalent_command_bus_admit",
          survival_evidence: "chicago.mutation.verdict verdict=mutant_survived",
          attempt_predicate: applied_and_restored(equivalent().id),
          outcome_predicate:
            {:observed, "chicago.mutation.verdict",
             %{"mutation_id" => equivalent().id, "verdict" => "mutant_survived"}},
          rfc_sections: ["§22", "§100"]
        ),
        Falsifier.new!(
          id: "#{@id}-102",
          court_id: @id,
          kind: :negative,
          invariant: "a live mutant never outlives the process that loaded it",
          stimulus:
            "load the authority_check_true mutant in an owner process, then Process.exit(owner, :kill)",
          boundary: "AshA2A.Chicago.Mutation guardian",
          forbidden_outcome:
            "AshA2A.CommandBus left mutated (loaded md5 != on-disk md5, or old mutant code)",
          attempt_evidence: "chicago.mutation.applied for exit_safety_command_bus_admit",
          survival_evidence:
            "no chicago.mutation.restored pristine=true trigger=owner_down; Mutation.pristine?(AshA2A.CommandBus) false",
          guard: "Mutation guardian monitor restore on owner DOWN",
          failure_class: :build_broken,
          attempt_predicate:
            {:observed, "chicago.mutation.applied", %{"mutation_id" => exit_safety().id}},
          outcome_predicate:
            {:not_observed, "chicago.mutation.restored",
             %{"mutation_id" => exit_safety().id, "pristine" => "true", "trigger" => "owner_down"}},
          rfc_sections: ["§22", "§130"]
        ),
        Falsifier.new!(
          id: "#{@id}-103",
          court_id: @id,
          kind: :negative,
          invariant: "the harness never mutates the Chicago verdict machinery that judges it",
          stimulus: "Mutation.with_mutant/2 of AshA2A.Chicago.Runner.run/1",
          boundary: "AshA2A.Chicago.Mutation.prepare/1 protection check",
          forbidden_outcome: "a Runner mutant is loaded or its stimulus executes",
          attempt_evidence: "chicago.mutation.requested for protected_chicago_runner",
          survival_evidence:
            "chicago.mutation.applied for protected_chicago_runner; Runner md5 changed",
          guard: "Mutation.check_protected/1",
          failure_class: :meta_admission_failure,
          attempt_predicate:
            {:observed, "chicago.mutation.requested", %{"mutation_id" => protected().id}},
          outcome_predicate:
            {:observed, "chicago.mutation.applied", %{"mutation_id" => protected().id}},
          rfc_sections: ["§8", "§22"]
        )
      ]
  end

  defp applied_and_restored(mutation_id) do
    {:all,
     [
       {:observed, "chicago.mutation.applied", %{"mutation_id" => mutation_id}},
       {:observed, "chicago.mutation.restored",
        %{"mutation_id" => mutation_id, "pristine" => "true"}},
       {:precedes, "chicago.mutation.applied", "chicago.mutation.restored", "mutation"}
     ]}
  end

  defp operator_text(%Mutation{operator: :identity}), do: "identity"

  defp operator_text(%Mutation{operator: {name, body}, clauses: clauses}),
    do: "#{name} #{inspect(clauses)} -> #{body |> String.split() |> Enum.join(" ")}"

  @doc false
  def equivalent do
    %Mutation{
      id: "equivalent_command_bus_admit",
      rfc_mutation: "equivalent mutant (identity recompilation)",
      module: AshA2A.CommandBus,
      function: :admit,
      arity: 2,
      operator: :identity,
      guard: "none -- semantics unchanged",
      killers: @guard_killers
    }
  end

  @doc false
  def exit_safety do
    %{Catalog.fetch!("authority_check_true") | id: "exit_safety_command_bus_admit"}
  end

  @doc false
  def protected do
    %Mutation{
      id: "protected_chicago_runner",
      rfc_mutation: "mutate the court's own judge",
      module: AshA2A.Chicago.Runner,
      function: :run,
      arity: 1,
      operator: {:replace_body, "{error, mutated_judge}."},
      guard: "Chicago verdict machinery protection",
      killers: []
    }
  end

  # --- execution -----------------------------------------------------------------

  @impl true
  def run(%Context{} = ctx) do
    root = Path.join(ctx.evidence_dir, "mutations")
    extra = Keyword.get(ctx.opts, :mutation_courts, [])
    by_id = Map.new(falsifiers(), &{&1.id, &1})

    {catalog, cache} =
      Enum.map_reduce(Catalog.numbered(), %{}, fn {fid, m}, cache ->
        qualify(ctx, Map.fetch!(by_id, fid), m, extra, root, cache)
      end)

    {equivalent, _cache} =
      qualify(ctx, Map.fetch!(by_id, "#{@id}-101"), equivalent(), extra, root, cache)

    catalog ++
      [
        equivalent,
        exit_safety_result(ctx, Map.fetch!(by_id, "#{@id}-102")),
        protected_result(ctx, Map.fetch!(by_id, "#{@id}-103"))
      ]
  end

  defp qualify(ctx, f, m, extra, root, cache) do
    {baseline_opts, cache} =
      with {:ok, courts, _missing} <- Mutation.killer_courts(m, courts: extra),
           {:ok, _plan} <- Mutation.prepare(m) do
        {baseline, cache} = Mutation.cached_baseline(courts, root, cache)
        {[baseline: baseline], cache}
      else
        _ -> {[], cache}
      end

    opts = [courts: extra, evidence_dir: Path.join(root, m.id)] ++ baseline_opts
    verdict = Context.stimulus(ctx, f, fn -> Mutation.qualify(m, opts) end)
    {to_result(ctx, f, m, verdict), cache}
  end

  defp to_result(ctx, %Falsifier{} = f, m, %Verdict{} = v) do
    evidence = Verdict.to_map(v)

    result =
      case {v.verdict, f.kind} do
        {:blocked, _} ->
          Result.blocked(f, "#{v.code}: #{v.detail}")

        {:unknown, _} ->
          Result.unknown(f, v.detail)

        {verdict, :negative} ->
          Result.negative(f,
            attempt_observed?: applied_and_restored?(ctx, f, m.id),
            forbidden_outcome_observed?: verdict == :mutant_survived,
            detail: v.detail
          )

        {verdict, :positive_control} ->
          Result.positive(f,
            attempt_observed?: applied_and_restored?(ctx, f, m.id),
            expected_outcome_observed?: verdict == :mutant_survived,
            detail: v.detail
          )
      end

    %{result | evidence: evidence}
  end

  defp applied_and_restored?(ctx, f, mutation_id) do
    records = Context.observed(ctx, f)
    applied = find_record(records, "chicago.mutation.applied", mutation_id, %{})

    restored =
      find_record(records, "chicago.mutation.restored", mutation_id, %{"pristine" => true})

    applied != nil and restored != nil and applied.seq < restored.seq
  end

  defp find_record(records, activity, mutation_id, attrs) do
    Enum.find(records, fn r ->
      r.activity == activity and r.attributes["mutation_id"] == mutation_id and
        Enum.all?(attrs, fn {k, v} -> r.attributes[k] == v end)
    end)
  end

  defp exit_safety_result(ctx, f) do
    m = exit_safety()
    parent = self()

    outcome =
      Context.stimulus(ctx, f, fn ->
        {owner, owner_ref} =
          spawn_monitor(fn ->
            Mutation.with_mutant(m, fn applied ->
              send(parent, {:chicago_mutant_live, self(), applied.guardian})
              Process.sleep(:infinity)
            end)
          end)

        receive do
          {:chicago_mutant_live, ^owner, guardian} ->
            guardian_ref = Process.monitor(guardian)
            Process.exit(owner, :kill)

            receive do
              {:DOWN, ^owner_ref, :process, _, _} -> :ok
            end

            receive do
              {:DOWN, ^guardian_ref, :process, _, _} -> :guardian_finished
            after
              15_000 -> :guardian_timeout
            end

          {:DOWN, ^owner_ref, :process, _, reason} ->
            {:owner_exited_before_mutant, reason}
        after
          30_000 -> :mutant_never_applied
        end
      end)

    pristine = Mutation.pristine?(m.module)
    records = Context.observed(ctx, f)

    restored =
      find_record(records, "chicago.mutation.restored", m.id, %{
        "pristine" => true,
        "trigger" => "owner_down"
      })

    %{
      Result.negative(f,
        attempt_observed?: find_record(records, "chicago.mutation.applied", m.id, %{}) != nil,
        forbidden_outcome_observed?: not pristine or restored == nil
      )
      | evidence: %{"outcome" => inspect(outcome), "pristine_after" => pristine}
    }
  end

  defp protected_result(ctx, f) do
    m = protected()
    md5_before = m.module.module_info(:md5)
    parent = self()

    reply =
      Context.stimulus(ctx, f, fn ->
        Mutation.with_mutant(m, fn _applied ->
          send(parent, :chicago_protected_mutant_ran)
          :ran
        end)
      end)

    ran? =
      receive do
        :chicago_protected_mutant_ran -> true
      after
        0 -> false
      end

    records = Context.observed(ctx, f)

    %{
      Result.negative(f,
        attempt_observed?: find_record(records, "chicago.mutation.requested", m.id, %{}) != nil,
        forbidden_outcome_observed?:
          ran? or m.module.module_info(:md5) != md5_before or
            find_record(records, "chicago.mutation.applied", m.id, %{}) != nil
      )
      | evidence: %{"reply" => inspect(reply, limit: 5)}
    }
  end
end
