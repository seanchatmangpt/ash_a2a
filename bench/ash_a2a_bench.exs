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

# `Item` mirrors `test/support/fixture.ex`'s `AshA2A.Test.Fixture.Item`
# exactly (real `:create`/`:update`/`:destroy` actions restricted to a
# required `:label`, plus one real generic `:action` (`:ping`) with an
# explicit `consequence: :observe` override) -- inlined here for the same
# reason `Echo`/`Domain` above are inlined: `test/support/fixture.ex` is not
# on `elixirc_paths` outside `Mix.env() == :test`, so `mix run` cannot see
# it. This gives the three new benchmarks below (a real `:change`-consequence
# `CommandBus.run/4`, and a real multi-action `Compiler.compile/3`) a real
# resource with several distinct action types instead of `Echo`'s single
# `:read`.
defmodule AshA2A.Bench.Fixture.Item do
  @moduledoc false

  use Ash.Resource,
    domain: AshA2A.Bench.Fixture.ItemDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
    attribute(:label, :string, public?: true, allow_nil?: false)
  end

  actions do
    defaults([:read, :destroy, create: [:label], update: [:label]])

    action :ping, :string do
      run(fn _input, _context -> {:ok, "pong"} end)
    end
  end

  a2a do
    skill(:create_item, :create)
    skill(:update_item, :update)
    skill(:destroy_item, :destroy)
    skill(:ping, :ping, consequence: :observe)
  end
end

defmodule AshA2A.Bench.Fixture.ItemDomain do
  @moduledoc false

  # Same real, documented `validate_config_inclusion?: false` opt-out as
  # `AshA2A.Bench.Fixture.Domain` above, for the same reason: this domain
  # exists only for the lifetime of this script.
  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.Bench.Fixture.Item)
  end
end

defmodule AshA2A.Bench do
  @moduledoc false

  alias AshA2A.{Authority, Command, CommandBus, Identity, Info, Receipt}
  alias AshA2A.Semantic.{Compiler, IR}
  alias AshA2A.Bench.Fixture.{Echo, Item}

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

    # -- CommandBus.run/4, :observe consequence -----------------------------
    #
    # Real end-to-end admit -> claim -> dispatch -> receipt -> commit path
    # for a real `:observe`-consequence skill (`Echo`'s `:read`, same
    # fixture/capability id as the `Info.capability_index/1` bench above).
    # `admit/2` short-circuits authority for `:observe`, but every other real
    # mechanic still runs: `AshA2A.Info.skill/2` lookup, the real
    # `store.claim/2` GenServer round trip, real `AshA2A.Dispatcher.dispatch/5`
    # against the real ETS data layer, `Receipt.from_reply/4`, and the real
    # `store.commit/2` round trip. A dedicated, freshly-started
    # `AshA2A.ReceiptStore.Memory` backs this one benchmark's full run (warm-up
    # + timed iterations); each timed call builds a brand-new `Command` (fresh
    # `command_id` via `Command.new/2`'s own default `Ash.UUIDv7.generate()`)
    # so every call is a real first-time `:execute` claim, never a `:replay`
    # short-circuit or a `:command_conflict` refusal.
    observe_store_name = AshA2A.Bench.ObserveReceiptStore
    {:ok, _pid} = AshA2A.ReceiptStore.Memory.start_link(name: observe_store_name)

    bench("AshA2A.CommandBus.run/4 (:observe consequence, real dispatch)", fn ->
      command =
        Command.new(@capability_id,
          agent_id: "bench-agent",
          principal_id: "bench-principal-observe",
          input: %{}
        )

      message = A2A.Message.new_user([A2A.Part.Data.new(%{})])

      case CommandBus.run(command, message, Echo, store_opts: [name: observe_store_name]) do
        {:ok, %Receipt{status: :completed, consequence: :observe}} ->
          :ok

        other ->
          raise "unexpected CommandBus.run/4 (:observe) result in bench loop: #{inspect(other)}"
      end
    end)

    # -- CommandBus.run/4, :change consequence, real synthesized Authority --
    #
    # Same real end-to-end path as above, but against `Item`'s real
    # `:create` action (`consequence: :change`, Ash's own default for
    # `:create`/`:update`/`:destroy` -- see `AshA2A.CapabilityIndex.Compiler`'s
    # `default_consequence/1`), with a real `AshA2A.Authority` struct
    # synthesized via `Authority.new/3` (mirroring
    # `test/ash_a2a/command_bus_test.exs`'s "matching authority admits a real
    # create and commits its receipt" case) so `admit/2`'s
    # `Authority.admits?/2` branch actually passes and the command reaches
    # real `Ash.Changeset.for_create/3` / `Ash.create/2` -- not just the
    # authority-refusal branch the `:observe` benchmark above never even
    # exercises. `item_principal`/`item_authority` are built once, outside
    # the timed loop (matching this script's existing convention of building
    # fixed fixtures once, e.g. `command = build_command()` for
    # `Command.fingerprint/1` above) since `Authority.admits?/2` only checks
    # `subject`/`capability_id`/expiry, never the per-call `command_id` --
    # reusing one authority across iterations changes nothing about which
    # real code path runs. Its own dedicated `ReceiptStore.Memory` (again,
    # one store per benchmark run, fresh `command_id` per timed call) keeps
    # this benchmark's real repeated creates collision-free exactly like the
    # `:observe` one above.
    item_capability_id = AshA2A.CapabilityIndex.Compiler.capability_id(Item, :create)
    item_principal = Identity.principal("bench-principal-item")

    item_authority =
      Authority.new(item_principal, item_capability_id, token_id: "bench-authority-item-1")

    change_store_name = AshA2A.Bench.ChangeReceiptStore
    {:ok, _pid} = AshA2A.ReceiptStore.Memory.start_link(name: change_store_name)

    bench("AshA2A.CommandBus.run/4 (:change consequence, real Ash.create)", fn ->
      command =
        Command.new(item_capability_id,
          agent_id: "bench-agent",
          principal_id: item_principal,
          authority: item_authority,
          input: %{label: "widget"}
        )

      message = A2A.Message.new_user([A2A.Part.Data.new(%{"label" => "widget"})])

      case CommandBus.run(command, message, Item, store_opts: [name: change_store_name]) do
        {:ok, %Receipt{status: :completed, consequence: :change}} ->
          :ok

        other ->
          raise "unexpected CommandBus.run/4 (:change) result in bench loop: #{inspect(other)}"
      end
    end)

    # -- AshA2A.CapabilityIndex.Compiler.compile/3 classification cost ------
    #
    # Real consequence-classification cost (`AshA2A.CapabilityIndex.Compiler`'s
    # `default_consequence/1` plus its one explicit `Skill` override) for
    # `Item`, which (unlike `Echo`'s single `:read`) has several real action
    # types: `:read` (default `:observe`), `:create`/`:update`/`:destroy`
    # (default `:change`), and one generic `:action` (`:ping`) with an
    # explicit `consequence: :observe` DSL override -- the one
    # `default_consequence/1` branch (`:unknown`) the other two operations
    # above never reach. `item_kind`/`item_overrides` are the exact same real
    # persisted terms `AshA2A.Info.capability_index_result/1` itself reads
    # via `Spark.Dsl.Extension.get_persisted/3` before calling `compile/3` --
    # fetched once, outside the timed loop, so the timed closure measures
    # `compile/3` alone, not the persisted-term lookup already covered by the
    # `Info.capability_index/1` benchmark above.
    item_kind = Spark.Dsl.Extension.get_persisted(Item, :ash_a2a_subject_kind, :resource)
    item_overrides = Spark.Dsl.Extension.get_persisted(Item, :ash_a2a_skill_overrides, [])
    item_action_count = Item |> Ash.Resource.Info.public_actions() |> length()

    bench(
      "AshA2A.CapabilityIndex.Compiler.compile/3 (Item, #{item_action_count} actions)",
      fn ->
        skills = AshA2A.CapabilityIndex.Compiler.compile(Item, item_kind, item_overrides)

        unless length(skills) == item_action_count and Enum.all?(skills, & &1.consequence) do
          raise "unexpected compile/3 result in bench loop: #{inspect(skills)}"
        end
      end
    )
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
