# bench/ash_a2a_bench.exs
#
# Lightweight, dependency-free wall-clock latency benchmark for ash_a2a.
#
# Run with:
#
#     mix run bench/ash_a2a_bench.exs
#
# Timing uses only `:timer.tc/1` from the stdlib -- no Benchee, no new
# mix.exs dependency. Percentiles (p50/p95/p99) are computed by hand from a
# real sorted sample list (nearest-rank method) after a real warm-up loop;
# nothing here is simulated.
#
# `mix run` compiles and boots the app under `Mix.env() == :dev` by default,
# and this project's `elixirc_paths/1` (mix.exs) only adds `test/support`
# under `Mix.env() == :test` -- so `test/support/fixture.ex`'s
# `AshA2A.Test.Fixture.Echo` is NOT compiled/available when this script runs.
# A tiny, real `Ash.Resource` + `Ash.Domain` with the `AshA2A` extension is
# therefore declared inline below, mirroring that fixture's shape exactly
# (same `data_layer: Ash.DataLayer.Ets`, same single `skill(:echo, :read)`)
# so this script is genuinely standalone-runnable.

defmodule AshA2A.Bench.Fixture.Echo do
  @moduledoc false

  use Ash.Resource,
    domain: AshA2A.Bench.Fixture.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
    attribute(:message, :string, public?: true)
  end

  actions do
    defaults([:read])
  end

  a2a do
    skill(:echo, :read)
  end
end

defmodule AshA2A.Bench.Fixture.Domain do
  @moduledoc false

  # `validate_config_inclusion?: false` is a real, documented Ash.Domain
  # option (not a mock/stub) opting this bench-only domain out of the
  # `config :ash_a2a, ash_domains: [...]` app-wide inclusion check -- this
  # domain exists only for the lifetime of this script and has no business
  # being listed in the real app's production domain config.
  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.Bench.Fixture.Echo)
  end
end

defmodule AshA2A.Bench do
  @moduledoc false

  alias AshA2A.{Command, Identity, Info, Receipt}
  alias AshA2A.Semantic.{Compiler, IR}
  alias AshA2A.Bench.Fixture.Echo

  @iterations 100
  @warmup 10
  @compile_many_size 50
  @capability_id AshA2A.CapabilityIndex.Compiler.capability_id(Echo, :read)

  def run do
    configure_llm_profile!()

    IO.puts(
      "ash_a2a bench -- #{@iterations} timed iterations per operation " <>
        "(#{@warmup} warm-up calls discarded first), compile_many batch size " <>
        "#{@compile_many_size}"
    )

    IO.puts(String.duplicate("=", 78))

    bench("AshA2A.Info.capability_index/1", fn -> Info.capability_index(Echo) end)

    plan_fn = plan_generate_object()
    single_text = "The goal is to lead the people."
    single_extract_fn = generate_object_for(single_text)

    bench("AshA2A.Semantic.Compiler.compile/3 (1 text)", fn ->
      case Compiler.compile(Echo, single_text,
             generate_object: single_extract_fn,
             plan_generate_object: plan_fn
           ) do
        {:ok, _package} -> :ok
        other -> raise "unexpected compile/3 result in bench loop: #{inspect(other)}"
      end
    end)

    many_texts =
      for i <- 1..@compile_many_size,
          do: "The goal is to lead the people, batch item number #{i}."

    many_extract_fn = generate_object_for_many(many_texts)

    bench("AshA2A.Semantic.Compiler.compile_many/3 (#{@compile_many_size} texts)", fn ->
      results =
        Compiler.compile_many(Echo, many_texts,
          generate_object: many_extract_fn,
          plan_generate_object: plan_fn
        )

      unless length(results) == @compile_many_size and Enum.all?(results, &match?({:ok, _}, &1)) do
        raise "unexpected compile_many/3 result in bench loop: #{inspect(results)}"
      end
    end)

    command = build_command()

    bench("AshA2A.Command.fingerprint/1", fn -> Command.fingerprint(command) end)

    reply = {:reply, %{"message" => "hello"}}
    execution_id = Identity.execution("bench-execution-1")

    bench("AshA2A.Receipt.from_reply/4", fn ->
      Receipt.from_reply(command, execution_id, :read, reply)
    end)
  end

  # Real (if benchmark-only) LLM profile config -- `AshA2A.LLMProfiles`
  # fail-closed raises `ArgumentError` when `:semantic_reasoner` is
  # unconfigured, and `mix run` (unlike `mix test`) never loads
  # `config/test.exs`'s profile. This is the same real
  # `Application.put_env/3` + `Application.get_env/3` config-lookup
  # extension point `AshA2A.LLMProfiles` documents for switching providers --
  # not a mock of the module. The `:generate_object`/`:plan_generate_object`
  # closures below never actually read the model spec string this produces.
  defp configure_llm_profile! do
    Application.put_env(:ash_a2a, :llm_profiles,
      semantic_reasoner: [provider: :bench, model: "bench-deterministic", max_tokens: 4096]
    )
  end

  defp plan_generate_object do
    fn _model_spec, _prompt, _schema, _opts ->
      {:ok,
       %{
         "request_id" => "bench-plan-1",
         "authority" => "none",
         "capability_ids" => [@capability_id],
         "hddl" => "(:task lead)",
         "fond" => "(:policy observe-or-replan)"
       }}
    end
  end

  defp generate_object_for(text) do
    fn _model_spec, _prompt, _schema, _opts -> {:ok, extraction(text)} end
  end

  # `Compiler.compile_many/3` runs one worker per text and formats each
  # worker's own text into its own prompt (see `AshA2A.Semantic.Compiler`'s
  # private `prompt/1`, which interpolates `source.text` verbatim) -- so the
  # injected closure recovers which of the 50 real texts it was called for by
  # matching the real prompt string, exactly like
  # `test/ash_a2a/semantic_compiler_test.exs`'s multi-text closures do.
  defp generate_object_for_many(texts) do
    lookup = Map.new(texts, &{&1, extraction(&1)})

    fn _model_spec, prompt, _schema, _opts ->
      case Enum.find(texts, &String.contains?(prompt, &1)) do
        nil -> {:error, %{code: :bench_prompt_not_found}}
        text -> {:ok, Map.fetch!(lookup, text)}
      end
    end
  end

  defp extraction(text) do
    IR.fields()
    |> Map.new(&{Atom.to_string(&1), []})
    |> Map.put("authority", "none")
    |> Map.put("goals", [
      %{
        "id" => "lead",
        "kind" => "goal",
        "description" => "lead the people",
        "source_quote" => text
      }
    ])
  end

  defp build_command do
    Command.new(@capability_id,
      agent_id: "bench-agent",
      principal_id: "bench-principal",
      input: %{"query" => "hello"}
    )
  end

  defp bench(label, fun) do
    # Warm-up: real calls, discarded, so first-call effects (Spark DSL
    # persisted-term lookups, ETS table warm access, module code loading)
    # are not counted in the timed sample.
    for _ <- 1..@warmup, do: fun.()

    samples =
      for _ <- 1..@iterations do
        {micros, _result} = :timer.tc(fun)
        micros
      end
      |> Enum.sort()

    report(label, samples)
  end

  defp report(label, samples) do
    n = length(samples)
    mean = Enum.sum(samples) / n

    IO.puts("")
    IO.puts(label)
    IO.puts("  n    = #{n}")
    IO.puts("  mean = " <> format_us(mean))
    IO.puts("  p50  = " <> format_us(percentile(samples, 50)))
    IO.puts("  p95  = " <> format_us(percentile(samples, 95)))
    IO.puts("  p99  = " <> format_us(percentile(samples, 99)))
    IO.puts("  min  = " <> format_us(List.first(samples)))
    IO.puts("  max  = " <> format_us(List.last(samples)))
  end

  # Nearest-rank percentile over an already-sorted, real sample list --
  # `ceil(p / 100 * n)`, 1-indexed and clamped to `[1, n]`.
  defp percentile(sorted_samples, p) when is_list(sorted_samples) do
    n = length(sorted_samples)
    rank = p / 100 * n
    index = rank |> Float.ceil() |> trunc() |> max(1) |> min(n)
    Enum.at(sorted_samples, index - 1)
  end

  defp format_us(value) when is_float(value), do: format_us(round(value))

  defp format_us(value) when is_integer(value) do
    "#{value} us (#{Float.round(value / 1000, 3)} ms)"
  end
end

AshA2A.Bench.run()
