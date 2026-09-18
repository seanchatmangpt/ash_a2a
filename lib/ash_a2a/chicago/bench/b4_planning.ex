defmodule AshA2A.Chicago.Bench.B4Planning do
  @moduledoc """
  RFC-SA2A-002 §88 benchmark `SA2A-B4` -- planning latency.

  Drives the real FOND/HDDL planning path -- `AshA2A.Planning.HddlSolver.solve/3`,
  a real OS subprocess over the real, already-built `native/hddl_cli`
  (ferroplan) binary -- over three real, pre-existing, disclosed HDDL
  fixtures under `test/support/hddl/`. No fixture is invented for this
  benchmark: all three are already independently verified via the real
  binary by other tests in this repo, cited below, never hand-constructed
  for this module.

    * `freedom_gym_meeting` (18-line domain) -- solvable HTN. Verified
      `solved: true` by `AshA2AHddlSolverQualificationTest` and consumed by
      `test/support/freedom_gym_meeting_plan.ex`.
    * `unsolvable_qualification` (15-line domain) -- a genuine logical
      impossibility (`has-permission` can never become true). Verified to
      report `{"error":"planner error: NoPlan"}` by
      `AshA2AHddlSolverQualificationTest`.
    * `sa2a_v26_9_17_dogfood` (1113-line domain, 135-line problem) -- the
      real cross-repo self-improvement HDDL model
      (`test/support/hddl/sa2a_v26_9_17_dogfood/SOURCE.md`). Its real,
      reconciled result is also `NoPlan` --
      `SA2AV26917FondQualificationTest`'s own moduledoc calls this "the
      real, honest result ... not a failure to fix." Kept here because its
      ~60x larger domain text gives a real domain-size-vs-latency data
      point the two small fixtures alone cannot.

  ## §88 measures reported

  | §88 measure             | how measured here                                                    |
  |--------------------------|-----------------------------------------------------------------------|
  | planner invocation time  | `planner_invocation` phase -- real subprocess wall time inside `HddlSolver.solve/3` |
  | planning projection time | `fixture_load` phase -- real `File.read!/1` of the static fixture text. This is disclosed as fixture I/O, not ontology projection: this benchmark reads pre-existing committed fixture files, it does not project HDDL text from a live ontology per iteration |
  | plan size                | `plan_structure.<case>.plan_size` -- real `length(decoded["policy"])`, solved cases only |
  | fan-out/depth bounds     | `plan_structure.<case>.max_outcomes_per_state` (fan-out) and `.depth` -- real BFS shortest-path length over the real solved policy graph, solved cases only |
  | resource envelope        | `memory`/`cpu` -- identical `AshA2A.Chicago.Bench.measure/2` machinery as B1/B5/B9 (BEAM-side envelope of the invoking process; the `hddl_cli` subprocess's own OS rusage is not captured, disclosed rather than fabricated) |
  | plan-admission time       | NOT measured -- `HddlSolver.solve/3` is the planner boundary only; no admission pipeline sits downstream of it in this repo today. Left absent rather than invented |

  Planner computation is the only thing this benchmark measures end to end:
  `HddlSolver.solve/3` never touches `AshA2A.Semantic.AdmissionPipeline`,
  `AshA2A.Authority`, or `AshA2A.CommandBus`, so every microsecond reported
  here is real planner latency and zero authority/DO latency -- satisfying
  §88's "MUST distinguish planner computation from authority and DO
  latency" by construction, not by subtraction.

  ## Invariants (§84), checked on every sample

  Exactly one real `[:ash_a2a, :planner, :invoke]` telemetry event per call,
  whose `:outcome`/`:code` metadata agrees with the real returned value; a
  `:solved` case must return `{:ok, decoded}` with `decoded["solved"] ==
  true` and a non-empty real policy; a `:refused` case must return
  `{:error, %{code: expected_code}}` with the exact expected refusal code
  (`:hddl_solve_error` for both unsolvable fixtures here, per the real
  binary output verified during development -- see moduledoc citations
  above).
  """

  alias AshA2A.Chicago.Bench
  alias AshA2A.Chicago.Bench.Timeline
  alias AshA2A.Planning.HddlSolver

  @id "SA2A-B4"

  @invoke [:ash_a2a, :planner, :invoke]

  @fixtures_dir Path.expand("../../../../test/support/hddl", __DIR__)

  @cases [
    %{
      id: "freedom_gym_meeting",
      domain_path: Path.join([@fixtures_dir, "freedom_gym_meeting", "domain.hddl"]),
      problem_path: Path.join([@fixtures_dir, "freedom_gym_meeting", "problem.hddl"]),
      expect: :solved,
      expect_code: nil
    },
    %{
      id: "unsolvable_qualification",
      domain_path: Path.join([@fixtures_dir, "unsolvable_qualification", "domain.hddl"]),
      problem_path: Path.join([@fixtures_dir, "unsolvable_qualification", "problem.hddl"]),
      expect: :refused,
      expect_code: :hddl_solve_error
    },
    %{
      id: "sa2a_v26_9_17_dogfood",
      domain_path: Path.join([@fixtures_dir, "sa2a_v26_9_17_dogfood", "domain.hddl"]),
      problem_path: Path.join([@fixtures_dir, "sa2a_v26_9_17_dogfood", "problem.hddl"]),
      expect: :refused,
      expect_code: :hddl_solve_error
    }
  ]

  @type case_spec :: %{
          id: String.t(),
          domain_path: String.t(),
          problem_path: String.t(),
          expect: :solved | :refused,
          expect_code: atom() | nil
        }

  @spec id() :: String.t()
  def id, do: @id

  @doc "Telemetry events the benchmark times."
  @spec events() :: [[atom()]]
  def events, do: [@invoke]

  @doc "The real fixture corpus this benchmark drives (`[case_spec()]`)."
  @spec cases() :: [case_spec()]
  def cases, do: @cases

  @doc """
  Runs the benchmark. Returns `{:ok, body}` or `{:blocked, detail}` when the
  real `native/hddl_cli` binary is not built on this host (never a fake
  solver).

  Options: `:iterations`, `:warmup`, `:cli_path`/`:tmp_dir` (passed through
  to the real `HddlSolver.solve/3`), `:cases` (corpus override; its digest
  is recorded).
  """
  @spec run(keyword()) :: {:ok, map()} | {:blocked, String.t()}
  def run(opts \\ []) do
    solver_opts = Keyword.take(opts, [:cli_path, :tmp_dir])
    path = HddlSolver.cli_path(solver_opts)

    if File.exists?(path) do
      {:ok, measure(Keyword.get(opts, :cases, @cases), path, solver_opts, opts)}
    else
      {:blocked,
       "real hddl_cli binary not built at #{path} -- run: cd native/hddl_cli && cargo build --release"}
    end
  end

  defp measure(cases, cli_path, solver_opts, opts) do
    ref = Timeline.attach(events())

    try do
      handlers = length(:telemetry.list_handlers(@invoke))

      measured =
        Bench.measure(
          fn _phase, _i -> Enum.map(cases, &sample(&1, ref, solver_opts)) end,
          opts
        )

      solved = count_outcome(measured, "solved")
      refused = count_outcome(measured, "refused")
      wall_us = measured["throughput"]["wall_us"]

      plan_structure =
        Map.new(cases, fn case_spec ->
          {case_spec.id, plan_structure(case_spec, solver_opts)}
        end)

      Map.merge(measured, %{
        "benchmark" => "B4 planning latency",
        "rfc_sections" => ["§84", "§88"],
        "sut" => %{
          "boundary" => "AshA2A.Planning.HddlSolver.solve/3",
          "solver_binary" => cli_path,
          "solver_binary_sha256" => Bench.sha256(File.read!(cli_path)),
          "authority_or_do_latency_included" => false
        },
        "fixture" => %{
          "corpus" =>
            "test/support/hddl (freedom_gym_meeting, unsolvable_qualification, sa2a_v26_9_17_dogfood)",
          "corpus_digest" => corpus_digest(cases),
          "solved_cases" => Enum.count(cases, &(&1.expect == :solved)),
          "refused_cases" => Enum.count(cases, &(&1.expect == :refused)),
          "cases" =>
            Enum.map(cases, fn c ->
              %{
                "id" => c.id,
                "expect" => Atom.to_string(c.expect),
                "domain_path" => c.domain_path,
                "domain_bytes" => file_size(c.domain_path),
                "problem_bytes" => file_size(c.problem_path)
              }
            end)
        },
        "plan_structure" => plan_structure,
        "throughput" =>
          Map.merge(measured["throughput"], %{
            "solves_per_second" => Bench.per_second(solved, wall_us),
            "refusals_per_second" => Bench.per_second(refused, wall_us),
            "invocations_per_second" => Bench.per_second(solved + refused, wall_us),
            "solved" => solved,
            "refused" => refused
          }),
        "evidence_handlers_attached" => handlers,
        "notes" => [
          "planner_invocation is the real HddlSolver.solve/3 subprocess wall time; fixture_load is the real File.read!/1 time for the static fixture text, not ontology projection",
          "sa2a_v26_9_17_dogfood is a real, disclosed NoPlan (unsolved) result, not a benchmark defect -- see its own SOURCE.md and SA2AV26917FondQualificationTest",
          "plan-admission time is not measured: no admission pipeline sits downstream of HddlSolver.solve/3 in this repo",
          "resource envelope is the BEAM-side envelope of the invoking process (identical machinery to B1/B5/B9); the hddl_cli subprocess's own OS rusage is not captured",
          "plan_structure is derived from one additional real solve/3 call per case, run after the measured distribution -- disclosed extra real work, not part of the timed samples"
        ],
        "highlights" => %{
          "freedom_gym_meeting_planner_invocation_p50_us" =>
            get_in(measured, [
              "by_case",
              "freedom_gym_meeting",
              "phases_us",
              "planner_invocation",
              "p50"
            ]),
          "freedom_gym_meeting_planner_invocation_p99_us" =>
            get_in(measured, [
              "by_case",
              "freedom_gym_meeting",
              "phases_us",
              "planner_invocation",
              "p99"
            ]),
          "sa2a_v26_9_17_dogfood_planner_invocation_p50_us" =>
            get_in(measured, [
              "by_case",
              "sa2a_v26_9_17_dogfood",
              "phases_us",
              "planner_invocation",
              "p50"
            ]),
          "solves_per_second" => Bench.per_second(solved, wall_us),
          "refusals_per_second" => Bench.per_second(refused, wall_us)
        }
      })
    after
      Timeline.detach(ref)
    end
  end

  defp count_outcome(measured, outcome),
    do: Enum.count(measured["samples"], &(&1["outcome"] == outcome))

  @doc false
  @spec sample(case_spec(), reference(), keyword()) :: Bench.sample()
  def sample(case_spec, ref, solver_opts) do
    _ = Timeline.drain(ref)

    load_started = System.monotonic_time(:microsecond)
    domain_text = File.read!(case_spec.domain_path)
    problem_text = File.read!(case_spec.problem_path)
    load_us = System.monotonic_time(:microsecond) - load_started

    solve_started = System.monotonic_time(:microsecond)
    result = HddlSolver.solve(domain_text, problem_text, solver_opts)
    solve_us = System.monotonic_time(:microsecond) - solve_started

    timeline = Timeline.drain(ref)

    %{
      case: case_spec.id,
      duration_us: load_us + solve_us,
      outcome: outcome(result),
      phases: %{"fixture_load" => load_us, "planner_invocation" => solve_us},
      invariant: invariant(case_spec, result, timeline)
    }
  end

  defp outcome({:ok, _}), do: "solved"
  defp outcome({:error, _}), do: "refused"

  defp invariant(case_spec, result, timeline) do
    invokes = Timeline.all(timeline, @invoke)

    cond do
      length(invokes) != 1 ->
        {:error, "expected exactly one planner.invoke event, observed #{length(invokes)}"}

      to_string(hd(invokes).metadata[:outcome]) != outcome(result) ->
        {:error,
         "planner.invoke outcome #{inspect(hd(invokes).metadata[:outcome])} disagrees with #{outcome(result)}"}

      true ->
        expectation(case_spec, result)
    end
  end

  defp expectation(%{expect: :solved}, {:ok, decoded}) do
    cond do
      decoded["solved"] != true ->
        {:error, "expected solved case reported solved: #{inspect(decoded["solved"])}"}

      not is_list(decoded["policy"]) or decoded["policy"] == [] ->
        {:error, "expected solved case produced an empty or missing real policy"}

      true ->
        :ok
    end
  end

  defp expectation(%{expect: :solved, id: id}, {:error, refusal}),
    do: {:error, "expected #{id} to solve, real solver refused: #{inspect(refusal)}"}

  defp expectation(%{expect: :refused, id: id}, {:ok, _decoded}),
    do: {:error, "expected #{id} to be refused (NoPlan), real solver SOLVED it"}

  defp expectation(%{expect: :refused, expect_code: expect_code, id: id}, {:error, refusal}) do
    if refusal[:code] == expect_code do
      :ok
    else
      {:error,
       "#{id} refused with code #{inspect(refusal[:code])}, expected #{inspect(expect_code)}"}
    end
  end

  defp plan_structure(case_spec, solver_opts) do
    domain_text = File.read!(case_spec.domain_path)
    problem_text = File.read!(case_spec.problem_path)

    case HddlSolver.solve(domain_text, problem_text, solver_opts) do
      {:ok, decoded} ->
        policy = decoded["policy"] || []
        outcome_counts = Enum.map(policy, &length(&1["outcomes"] || []))

        %{
          "solved" => true,
          "plan_size" => length(policy),
          "max_outcomes_per_state" => if(policy == [], do: 0, else: Enum.max(outcome_counts)),
          "mean_outcomes_per_state" =>
            if(policy == [],
              do: 0,
              else: Float.round(Enum.sum(outcome_counts) / length(policy), 2)
            ),
          "unique_states" => policy |> Enum.map(& &1["state"]) |> Enum.uniq() |> length(),
          "depth" => depth(policy)
        }

      {:error, refusal} ->
        %{"solved" => false, "refusal_code" => Map.get(refusal, :code)}
    end
  end

  # Real BFS shortest-path depth from the policy's first state, following the
  # real `outcomes[].state` edges the solved policy actually contains.
  # Strong-cyclic FOND policies can revisit states via `oneof` outcomes, so
  # this is a shortest-path DEPTH bound (§88's "depth"), not a step count --
  # `plan_size` above is the real step count.
  defp depth([]), do: 0

  defp depth([%{"state" => start} | _] = policy) do
    edges =
      Map.new(policy, fn entry ->
        {entry["state"], Enum.map(entry["outcomes"] || [], & &1["state"])}
      end)

    bfs([{start, 0}], MapSet.new([start]), edges, 0)
  end

  defp bfs([], _visited, _edges, best), do: best

  defp bfs([{state, dist} | rest], visited, edges, best) do
    next_states =
      edges
      |> Map.get(state, [])
      |> Enum.reject(&MapSet.member?(visited, &1))

    visited = Enum.reduce(next_states, visited, &MapSet.put(&2, &1))
    frontier = rest ++ Enum.map(next_states, &{&1, dist + 1})
    bfs(frontier, visited, edges, max(best, dist))
  end

  defp corpus_digest(cases) do
    cases
    |> Enum.map(fn c -> File.read!(c.domain_path) <> File.read!(c.problem_path) end)
    |> Enum.join()
    |> Bench.sha256()
  end

  defp file_size(path), do: File.stat!(path).size
end
