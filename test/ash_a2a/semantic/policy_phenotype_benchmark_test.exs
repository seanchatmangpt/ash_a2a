defmodule AshA2A.Semantic.PolicyPhenotypeBenchmarkTest do
  @moduledoc """
  Real wall-clock benchmark + regression bound for
  `AshA2A.Semantic.PolicyPhenotype` (ash_a2a#41).

  Measures, with `:timer.tc/1` over a real warm-up and a real sample list
  (nearest-rank percentiles, same method as `bench/ash_a2a_bench.exs`):

    * `new/1` on the full nine-axis default vocabulary with reaction norms
      (the admission fence: option/duplicate/normalized-authority checks);
    * `condition/2` on the same phenotype (re-validation + reaction step);
    * `new/1` refusing a disguised authority axis (the refusal path).

  Each sample is a batch of `@batch` calls so per-call cost is above timer
  resolution. The numbers are printed and written to
  `receipts/v26.9.26/policy_phenotype_bench.json` when
  `POLICY_PHENOTYPE_BENCH_RECEIPT=1` (with `POLICY_PHENOTYPE_BENCH_PARENT` set to
  the commit the measured tree is committed on). The receipt carries the git
  blob id of the measured module; a non-benchmark test refuses a stale receipt.

  Regression bound: the median (p50) per-call cost must stay under
  `@p50_bound_us`. p50 is used, not p99, because this host is shared with
  other concurrent builds and its tails are dominated by scheduler noise
  (observed p99 swinging 250us-3100us run to run with an unchanged subject).
  The bound is set to catch the one regression actually observed while
  hardening: normalizing axis names through runtime-compiled Unicode regexes
  on every call measured p50 new/1 = 261-286us, condition/2 = 136-147us,
  refusal = 139-149us; the ASCII fast path measured p50 new/1 = 45-93us,
  condition/2 = 29-42us, refusal = 20-22us on the same loaded host. The
  committed receipt records the admitted run.

  Tagged `:benchmark` (excluded by default in `test/test_helper.exs`):

      mix test test/ash_a2a/semantic/policy_phenotype_benchmark_test.exs --include benchmark
  """
  use ExUnit.Case, async: false

  alias AshA2A.Semantic.PolicyPhenotype

  @moduletag :benchmark

  @warmup 200
  @samples 400
  @batch 50
  @p50_bound_us %{new: 200.0, condition: 120.0, refuse: 100.0}

  defp full_opts do
    axes = PolicyPhenotype.default_axes()

    [
      capability_iri: "urn:sa2a:capability:Example.Search.read",
      policy_family: "planner:MCTS",
      conditionable_axes: Map.new(axes, &{&1, %{min: 0.0, max: 1.0}}),
      condition: Map.new(axes, &{&1, 0.5}),
      reaction_norms:
        axes
        |> Enum.with_index()
        |> Map.new(fn {a, i} -> {a, %{slope: (i - 4) / 10, reference_cue: 0.5}} end),
      evidence_refs: ["urn:evidence:temperament-engineering"]
    ]
  end

  defp measure(fun) do
    for _ <- 1..@warmup, do: fun.()

    samples =
      for _ <- 1..@samples do
        {us, _} = :timer.tc(fn -> for _ <- 1..@batch, do: fun.() end)
        us / @batch
      end
      |> Enum.sort()

    n = length(samples)
    pct = fn p -> Enum.at(samples, max(ceil(p * n) - 1, 0)) end

    %{
      p50_us: Float.round(pct.(0.50), 3),
      p95_us: Float.round(pct.(0.95), 3),
      p99_us: Float.round(pct.(0.99), 3),
      max_us: Float.round(List.last(samples), 3),
      samples: n,
      batch: @batch
    }
  end

  test "policy phenotype admission/conditioning stays within the regression bound" do
    opts = full_opts()
    {:ok, phenotype} = PolicyPhenotype.new(opts)

    refuse_opts =
      Keyword.update!(
        opts,
        :conditionable_axes,
        &Map.put(&1, "Execution-Grant", %{min: 0.0, max: 1.0})
      )

    assert {:error, %{code: :temperament_cannot_encode_authority}} =
             PolicyPhenotype.new(refuse_opts)

    results = %{
      new: measure(fn -> {:ok, _} = PolicyPhenotype.new(opts) end),
      condition: measure(fn -> {:ok, _} = PolicyPhenotype.condition(phenotype, 0.8) end),
      refuse: measure(fn -> {:error, _} = PolicyPhenotype.new(refuse_opts) end)
    }

    IO.puts("\n[policy_phenotype_bench] " <> inspect(results))

    if System.get_env("POLICY_PHENOTYPE_BENCH_RECEIPT") == "1" do
      subject_path = "lib/ash_a2a/semantic/policy_phenotype.ex"
      content = File.read!(subject_path)

      # git blob id of the measured module, so the receipt names its exact
      # subject; a commit cannot contain its own SHA, so the commit identity is
      # the parent the measured tree is committed on (POLICY_PHENOTYPE_BENCH_PARENT).
      blob_sha1 =
        :crypto.hash(:sha, ["blob ", Integer.to_string(byte_size(content)), 0, content])
        |> Base.encode16(case: :lower)

      receipt = %{
        subject: "ash_a2a AshA2A.Semantic.PolicyPhenotype",
        subject_path: subject_path,
        subject_blob_sha1: blob_sha1,
        measured_on_parent: System.fetch_env!("POLICY_PHENOTYPE_BENCH_PARENT"),
        otp_release: to_string(:erlang.system_info(:otp_release)),
        elixir: System.version(),
        system_architecture: to_string(:erlang.system_info(:system_architecture)),
        method: "timer.tc, nearest-rank percentiles, per-call = batch time / batch",
        warmup: @warmup,
        bound_p50_us: @p50_bound_us,
        results: results
      }

      path = Path.join([File.cwd!(), "receipts", "v26.9.26", "policy_phenotype_bench.json"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, :json.format(receipt) |> IO.iodata_to_binary())
    end

    for {name, bound} <- @p50_bound_us do
      p50 = results[name].p50_us
      assert p50 < bound, "#{name} p50 #{p50}us exceeded regression bound #{bound}us"
    end
  end
end
