defmodule AshA2A.Chicago.Bench.B1Admission do
  @moduledoc """
  RFC-SA2A-002 §85 benchmark `SA2A-B1` -- admission latency and throughput.

  Drives every case of `AshA2A.Chicago.Fixtures.BenchHarness.AdmissionCorpus`
  (one lawful candidate, five invalid ones refused at parse / ShEx / SHACL /
  falsifier / provenance) through the real
  `AshA2A.Semantic.AdmissionPipeline.admit/2` and the real `praxis-graphlaw`
  wasm on every iteration. Invalid candidates are never skipped from cost
  reporting (§85): they share the overall latency distribution and throughput
  with the lawful case and have their own per-case distribution.

  ## Per-stage latency

  Split from the real `[:ash_a2a, :semantic, :admission, :start | :stage |
  :stop]` telemetry: each stage's latency is the gap from the previous
  pipeline event to that stage's event. The pipeline issues one GraphLaw
  batch (parse witness, graph hash, full law validation, version) before its
  first stage event, so the `parse` stage latency includes that engine
  transport; later stages interpret the already-returned engine report.
  `finalize` is last stage -> stop (admission digest), `total_admission` is
  start -> stop.

  | §85 measure                | phase(s)                         |
  |----------------------------|----------------------------------|
  | candidate parse latency    | `parse` (includes engine batch)  |
  | canonicalization latency   | `identity`                       |
  | ShEx latency               | `shex`                           |
  | SHACL latency              | `shacl`                          |
  | closure latency            | `rule_closure`                   |
  | falsifier latency          | `sparql_falsifiers`              |
  | provenance/profile latency | `provenance`, `profile_checks`   |
  | total admission latency    | `total_admission`                |

  ## Invariants (§84), checked on every sample

  A lawful case must reach `:admitted` with `authority: :none` and every
  required stage passed; an invalid case must be refused at exactly its
  expected stage; the telemetry must show exactly one start and one stop whose
  outcome agrees with the returned value. Any violation is an invariant
  failure in the raw result.
  """

  alias AshA2A.Chicago.Bench
  alias AshA2A.Chicago.Bench.Timeline
  alias AshA2A.Chicago.Fixtures.BenchHarness.AdmissionCorpus
  alias AshA2A.GraphLaw.Wasm
  alias AshA2A.Semantic.AdmissionPipeline

  @id "SA2A-B1"

  @start [:ash_a2a, :semantic, :admission, :start]
  @stage [:ash_a2a, :semantic, :admission, :stage]
  @stop [:ash_a2a, :semantic, :admission, :stop]

  @rfc_measures [
    {"candidate_parse", ["parse"]},
    {"canonicalization", ["identity"]},
    {"shex", ["shex"]},
    {"shacl", ["shacl"]},
    {"closure", ["rule_closure"]},
    {"falsifier", ["sparql_falsifiers"]},
    {"provenance_profile", ["provenance", "profile_checks"]},
    {"total_admission", ["total_admission"]}
  ]

  @spec id() :: String.t()
  def id, do: @id

  @doc "Telemetry events the benchmark times."
  @spec events() :: [[atom()]]
  def events, do: [@start, @stage, @stop]

  @doc """
  Runs the benchmark. Returns `{:ok, body}` or `{:blocked, detail}` when the
  real GraphLaw engine is not runnable on this host (never a fake engine).

  Options: `:iterations`, `:warmup`, `:graphlaw_opts` (passed to the
  pipeline), `:cases` (corpus override; its digest is recorded).
  """
  @spec run(keyword()) :: {:ok, map()} | {:blocked, String.t()}
  def run(opts \\ []) do
    # `AdmissionCorpus.law_opts/0` pins the corpus's own law (RFC-SA2A-001
    # S20/S21) with standing under a fresh Root Manifest; an explicit
    # `:root_manifest` in `:graphlaw_opts` still wins (`Keyword.merge/2`
    # keeps the second list's value on a key collision).
    engine_opts =
      Keyword.merge(AdmissionCorpus.law_opts(), Keyword.get(opts, :graphlaw_opts, []))

    case Wasm.availability(engine_opts) do
      :ok -> {:ok, measure(Keyword.get(opts, :cases, AdmissionCorpus.cases()), engine_opts, opts)}
      {:error, detail} -> {:blocked, "real GraphLaw engine unavailable: #{inspect(detail)}"}
    end
  end

  defp measure(cases, engine_opts, opts) do
    engine_version =
      case Wasm.version(engine_opts) do
        {:ok, version} -> version
        {:error, detail} -> "unavailable: " <> inspect(detail)
      end

    ref = Timeline.attach(events())

    try do
      handlers = length(:telemetry.list_handlers(@stop))

      measured =
        Bench.measure(fn _phase, _i -> Enum.map(cases, &sample(&1, ref, engine_opts)) end, opts)

      admitted = count_outcome(measured, "admitted")
      refused = count_outcome(measured, "refused")
      wall_us = measured["throughput"]["wall_us"]

      stage_latency =
        measured["samples"]
        |> Enum.flat_map(&Enum.to_list(&1["phases_us"]))
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
        |> Map.new(fn {phase, values} -> {phase, Bench.distribution(values)} end)

      rfc_measures =
        Map.new(@rfc_measures, fn {name, phases} ->
          values =
            measured["samples"]
            |> Enum.map(fn s ->
              phases |> Enum.map(&s["phases_us"][&1]) |> Enum.reject(&is_nil/1)
            end)
            |> Enum.reject(&(&1 == []))
            |> Enum.map(&Enum.sum/1)

          {name, Bench.distribution(values)}
        end)

      Map.merge(measured, %{
        "benchmark" => "B1 admission latency and throughput",
        "rfc_sections" => ["§84", "§85"],
        "sut" => %{
          "boundary" => "AshA2A.Semantic.AdmissionPipeline.admit/2",
          "engine" => engine_version,
          "required_stages" => Enum.map(AdmissionPipeline.required_stages(), &Atom.to_string/1)
        },
        "fixture" => %{
          "corpus" => inspect(AdmissionCorpus),
          "corpus_digest" => AdmissionCorpus.digest(cases),
          "valid_cases" => Enum.count(cases, & &1.valid?),
          "invalid_cases" => Enum.count(cases, &(not &1.valid?)),
          "cases" =>
            Enum.map(cases, fn c ->
              %{
                "id" => c.id,
                "valid" => c.valid?,
                "expect" => AdmissionCorpus.expectation_to_string(c.expect)
              }
            end)
        },
        "stage_latency_us" => stage_latency,
        "rfc_measures_us" => rfc_measures,
        "rfc_measure_map" =>
          Map.new(@rfc_measures, fn {name, phases} -> {name, Enum.join(phases, "+")} end),
        "throughput" =>
          Map.merge(measured["throughput"], %{
            "admissions_per_second" => Bench.per_second(admitted, wall_us),
            "refusals_per_second" => Bench.per_second(refused, wall_us),
            "candidates_per_second" => Bench.per_second(admitted + refused, wall_us),
            "admitted" => admitted,
            "refused" => refused
          }),
        "evidence_handlers_attached" => handlers,
        "notes" => [
          "parse stage latency includes the single GraphLaw batch issued before the first stage event",
          "invalid candidates are included in every latency and throughput figure"
        ],
        "highlights" => %{
          "total_admission_p50_us" => rfc_measures["total_admission"]["p50"],
          "total_admission_p99_us" => rfc_measures["total_admission"]["p99"],
          "admissions_per_second" => Bench.per_second(admitted, wall_us),
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
  @spec sample(AdmissionCorpus.case_spec(), reference(), keyword()) :: Bench.sample()
  def sample(case_spec, ref, engine_opts) do
    _ = Timeline.drain(ref)
    started = System.monotonic_time(:microsecond)
    result = AdmissionPipeline.admit(case_spec.candidate, engine_opts)
    duration = System.monotonic_time(:microsecond) - started
    timeline = Timeline.drain(ref)

    %{
      case: case_spec.id,
      duration_us: duration,
      outcome: outcome(result),
      phases: phases(timeline),
      invariant: invariant(case_spec, result, timeline)
    }
  end

  defp outcome({:ok, _}), do: "admitted"
  defp outcome({:error, _}), do: "refused"

  defp phases(timeline) do
    start = Timeline.first(timeline, @start)
    stop = Timeline.first(timeline, @stop)
    stages = Timeline.all(timeline, @stage)

    {stage_phases, last} =
      Enum.reduce(stages, {%{}, start}, fn entry, {acc, previous} ->
        {Map.put(acc, to_string(entry.metadata[:stage]), Timeline.gap(previous, entry)), entry}
      end)

    stage_phases
    |> Map.put("finalize", if(stages != [], do: Timeline.gap(last, stop)))
    |> Map.put("total_admission", Timeline.gap(start, stop))
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp invariant(case_spec, result, timeline) do
    starts = length(Timeline.all(timeline, @start))
    stops = Timeline.all(timeline, @stop)
    stop_outcome = with [entry] <- stops, do: entry.metadata[:outcome]

    cond do
      starts != 1 or length(stops) != 1 ->
        {:error, "expected one admission start and stop, observed #{starts} and #{length(stops)}"}

      to_string(stop_outcome) != outcome(result) ->
        {:error,
         "admission.stop outcome #{inspect(stop_outcome)} disagrees with #{outcome(result)}"}

      true ->
        expectation(case_spec.expect, result, timeline)
    end
  end

  defp expectation(:admitted, {:ok, result}, _timeline) do
    cond do
      result.standing != :admitted ->
        {:error, "lawful candidate reached #{inspect(result.standing)}, not :admitted"}

      result.authority != :none ->
        {:error, "admission conferred authority #{inspect(result.authority)} (must be :none)"}

      result.stages != AdmissionPipeline.required_stages() ->
        {:error, "admitted without every required stage: #{inspect(result.stages)}"}

      true ->
        :ok
    end
  end

  defp expectation(:admitted, {:error, refusal}, _timeline),
    do:
      {:error, "lawful candidate refused at #{inspect(refusal.stage)} (#{inspect(refusal.code)})"}

  defp expectation({:refused, stage}, {:ok, _result}, _timeline),
    do: {:error, "invalid candidate (expected refusal at #{stage}) was ADMITTED"}

  defp expectation({:refused, stage}, {:error, refusal}, timeline) do
    refused_stage_event? =
      timeline
      |> Timeline.all(@stage)
      |> Enum.any?(&(&1.metadata[:stage] == stage and &1.metadata[:outcome] == :refused))

    cond do
      refusal.stage != stage ->
        {:error,
         "invalid candidate refused at #{inspect(refusal.stage)} (#{inspect(refusal.code)}), expected #{stage}"}

      not refused_stage_event? ->
        {:error, "no admission.stage refused event for #{stage}"}

      true ->
        :ok
    end
  end
end
