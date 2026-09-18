defmodule AshA2A.Test.Fixture.BrokerScaleItemAgent do
  @moduledoc """
  Real `A2A.Agent` GenServer built with `use AshA2A.Agent` over the existing
  real `AshA2A.Test.Fixture.Item`/`AshA2A.Test.Fixture.ItemDomain` fixture
  (`test/support/fixture.ex`, real `:create`/`:update`/`:destroy`/`:ping`
  skills already used by `test/ash_a2a_command_bus_concurrency_test.exs`,
  `test/ash_a2a/chicago/stress/sustained_throughput_test.exs`, and
  `test/ash_a2a_agent_command_bus_test.exs`) -- no new resource is invented
  here.

  Named distinctly from `AshA2A.Test.Fixture.ItemAgent`
  (`test/ash_a2a_agent_command_bus_test.exs`, a private fixture over the SAME
  real `Item` resource) so both files compile together in a full suite run
  without a duplicate-module-definition conflict -- `test/support/**` is
  always compiled (`mix.exs` `elixirc_paths(:test)`), but a plain `test/
  *_test.exs` file is only compiled when Mix is asked to run it, so this
  file's own fixture module must not collide with one another test file
  privately defines the same way.
  """

  use AshA2A.Agent,
    resource_or_domain: AshA2A.Test.Fixture.Item,
    name: "broker_scale_item_agent"
end

defmodule AshA2A.Chicago.Stress.AgentDispatchBrokerScaleTest do
  @moduledoc """
  RFC-SA2A-002 stress/soak coverage, secondary confirmatory measurement:
  real, sustained dispatch through the REAL Agent-level path that actually
  consults `AshA2A.Authority.Broker` -- `AshA2A.Agent.build_command/4` ->
  `AshA2A.Authority.Grant.authorize/3` -> `broker.granted?/3` -- comparing
  `AshA2A.Authority.Broker.InMemory` (a single real `GenServer`, one
  mailbox, every concurrent grant lookup funneled through
  `GenServer.call/2`) against `AshA2A.Authority.Broker.Ekv` (backed by the
  real `:ekv` dependency, per-key CAS via `EKV.get`/`EKV.put(if_vsn: ...)`,
  no shared mailbox) under real concurrent load.

  ## Why this is a different layer than the sibling stress test

  `test/ash_a2a/chicago/stress/sustained_throughput_test.exs` deliberately
  calls `AshA2A.CommandBus.run/4` directly with a hand-built
  `AshA2A.Authority` struct already attached to the command -- that layer's
  own `admit/2` reads `command.authority` directly and never consults the
  configured `AshA2A.Authority.Broker` (its own moduledoc says so
  explicitly). The real broker consultation happens one layer up, in
  `AshA2A.Agent.build_command/4` (`lib/ash_a2a/agent.ex`): it resolves the
  dispatched skill's canonical capability id via `AshA2A.Info.skill/2`, then
  calls `AshA2A.Authority.Grant.authorize(auth_identity, capability_id)`,
  which -- under the default `:broker` policy -- asks the configured broker
  `granted?/3` whether THIS principal holds a standing grant for THIS
  capability, on every single dispatch. A real caller going through the full
  A2A dispatch path (a real `AshA2A.Agent`-based resource, a real inbound
  `A2A.Message`) pays that broker-lookup cost per dispatch; a caller that
  only exercises `CommandBus.run/4` directly never does. This file drives
  THAT full path -- `BrokerScaleItemAgent.call/3` (`A2A.Agent.call/3` ->
  `AshA2A.Agent.__dispatch__/3` -> `build_command/4` -> `Authority.Grant.
  authorize/3` -> broker -> `AshA2A.CommandBus.run/4` -> real `Ash.create`
  -> `Receipt`), against the same real `AshA2A.Test.Fixture.Item`/
  `ItemDomain` fixture the sibling test uses (a real `Ash.DataLayer.Ets`-
  backed resource), not a bare `CommandBus.run/4` call.

  ## Real collaborators, no mocking (this workspace's Chicago-style
  discipline)

  Both broker phases below run against a REAL broker process for the
  duration of that phase: `AshA2A.Authority.Broker.InMemory` is a real
  `GenServer`, `AshA2A.Authority.Broker.Ekv` runs against a real, on-disk
  `EKV` instance started via `start_supervised!/1` with a real temp
  `data_dir` under `System.tmp_dir!/0` and `cluster_size: 1` -- the exact
  same real-local-EKV pattern `test/ash_a2a/authority_broker_ekv_test.exs`
  and `test/ash_a2a/receipt_store_ekv_test.exs` already use. Every grant is
  issued through the real `AshA2A.Authority.Grant.grant/3` seam (the same
  one `AshA2A.Test.AuthorityGrantCase.grant!/1` wraps for other tests), and
  every dispatch is a real `BrokerScaleItemAgent.call/3` round trip through
  a real supervised `A2A.Agent` process -- never a bare function call into
  `AshA2A.Dispatcher` or a hand-built receipt. No Mock/mox/patch/monkeypatch
  anywhere in this file.

  Swapping `config :ash_a2a, :authority_broker` at runtime via
  `Application.put_env/3` between the two phases is the same pattern
  `test/ash_a2a_authority_capability_grant_test.exs` already uses and
  `test/test_helper.exs`'s own comment names as the sanctioned exception to
  the run-wide shared broker: "A test that specifically needs isolated
  grant/revocation state ... starts its own uniquely-named broker and is
  `async: false`." This module is `async: false` for exactly that reason,
  and restores the prior `:authority_policy`/`:authority_broker` application
  environment in `on_exit/1` regardless of pass/fail.

  ## Measurement, reused from the real Chicago bench harness

  Latency distribution (`min`/`p50`/`p90`/`p95`/`p99`/`max`/`mean`/`stddev`)
  and throughput are computed with the SAME real
  `AshA2A.Chicago.Bench.distribution/1` and `AshA2A.Chicago.Bench.
  per_second/2` the sibling stress test and the B1/B5/B9 benchmarks use --
  not a second, parallel stats implementation.

  ## Running this file

  Excluded from the default suite (`@moduletag :benchmark`, matching every
  other real-duration stress/benchmark file in this repo) because it
  deliberately runs for a real bounded wall-clock window. Run it explicitly:

      mix test test/ash_a2a/chicago/stress/agent_dispatch_broker_scale_test.exs --include benchmark

  Override the per-phase real run duration with
  `ASH_A2A_BROKER_SCALE_DURATION_MS` (default `#{6_000}`ms -- two phases,
  so `#{2 * 6_000}`ms of real timed load total, deliberately kept under the
  sibling `sustained_throughput_test.exs`'s real `3 x 12_000`ms = 36s
  budget, since this is a secondary confirmatory measurement of a different
  layer, not the primary sustained-throughput characterization); override
  worker concurrency with `ASH_A2A_BROKER_SCALE_WORKERS` (default
  `System.schedulers_online()`).
  """

  use ExUnit.Case, async: false

  import AshA2A.Test.MessageHelpers

  alias AshA2A.Authority
  alias AshA2A.Authority.Broker.{Ekv, InMemory}
  alias AshA2A.Chicago.{Bench, Json}
  alias AshA2A.Identity
  alias AshA2A.Test.Fixture.{BrokerScaleItemAgent, Item, ItemDomain}

  @moduletag :benchmark
  @moduletag timeout: :infinity

  @capability_selector "create_item"
  @default_duration_ms 6_000
  @min_expected_samples 20

  setup do
    {_sup, _registry} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [
        BrokerScaleItemAgent
      ])

    # This test mutates `config :ash_a2a, :authority_broker`/`:authority_policy`
    # at runtime (the sanctioned exception `test/test_helper.exs`'s own comment
    # names, safe only because this module is `async: false`) -- restored here
    # regardless of pass/fail, the same pattern
    # `test/ash_a2a_authority_capability_grant_test.exs` already uses.
    prior_policy = Application.get_env(:ash_a2a, :authority_policy)
    prior_broker = Application.get_env(:ash_a2a, :authority_broker)

    on_exit(fn ->
      restore(:authority_policy, prior_policy)
      restore(:authority_broker, prior_broker)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:ash_a2a, key)
  defp restore(key, value), do: Application.put_env(:ash_a2a, key, value)

  # `A2A.Plug` populates `context.metadata["a2a.auth"]` only after real
  # credential verification; `A2A.Agent.call/3`'s own `opts` become exactly
  # `context.metadata` -- the same real shape
  # `test/ash_a2a_agent_command_bus_test.exs`'s `authenticated_call_opts/1`
  # already establishes, duplicated here (test-file-local, by this repo's own
  # convention of not cross-requiring other test files).
  defp authenticated_call_opts(identity) do
    [metadata: %{"a2a.auth" => %{identity: identity}}]
  end

  # SA2A-AUTH-017 (RFC-SA2A-002 S66): `AshA2A.Agent.build_command/4` resolves
  # the CANONICAL, resource-qualified capability id via `AshA2A.Info.skill/2`
  # before calling `Authority.Grant.authorize/3` -- a grant issued under the
  # bare wire selector `"create_item"` would not match what the real dispatch
  # path looks up, so grants below are issued under this same canonical id.
  defp capability_id! do
    {:ok, skill} = AshA2A.Info.skill(Item, @capability_selector)
    skill.id
  end

  test "InMemory vs Ekv AshA2A.Authority.Broker under sustained real Agent-dispatch load" do
    capability_id = capability_id!()
    run_id = System.unique_integer([:positive])
    duration_ms = duration_ms()
    workers = worker_count()

    in_memory_report = run_phase(:in_memory, capability_id, run_id, duration_ms, workers)
    ekv_report = run_phase(:ekv, capability_id, run_id, duration_ms, workers)

    comparison = %{
      "run_id" => run_id,
      "capability_id" => capability_id,
      "in_memory" => in_memory_report,
      "ekv" => ekv_report,
      "p50_ratio_ekv_over_in_memory" =>
        ratio(
          get_in(ekv_report, ["latency_us", "p50"]),
          get_in(in_memory_report, ["latency_us", "p50"])
        ),
      "p90_ratio_ekv_over_in_memory" =>
        ratio(
          get_in(ekv_report, ["latency_us", "p90"]),
          get_in(in_memory_report, ["latency_us", "p90"])
        ),
      "p99_ratio_ekv_over_in_memory" =>
        ratio(
          get_in(ekv_report, ["latency_us", "p99"]),
          get_in(in_memory_report, ["latency_us", "p99"])
        ),
      "throughput_ratio_ekv_over_in_memory" =>
        ratio(ekv_report["throughput_per_second"], in_memory_report["throughput_per_second"])
    }

    IO.puts("\n[SA2A-STRESS-BROKER-SCALE] " <> Json.canonical(comparison))

    # --- real, state-based invariants, per phase ----------------------------
    for {label, report} <- [{"in_memory", in_memory_report}, {"ekv", ekv_report}] do
      # Enough real load was actually generated to call this a real
      # sustained-dispatch measurement, not a handful of samples (floor kept
      # low enough to hold on a slow/loaded CI host and given the heavier
      # per-dispatch cost of the full Agent path vs. bare `CommandBus.run/4`
      # -- the real observed number is what gets reported, this only guards
      # against a run that silently did ~nothing).
      assert report["sample_count"] >= @min_expected_samples,
             "#{label}: expected at least #{@min_expected_samples} real Agent dispatches in " <>
               "#{duration_ms}ms, got #{report["sample_count"]} -- real sustained load did not " <>
               "materialize"

      # Zero errors is the real expected invariant: every worker holds a real
      # standing grant for the exact canonical capability it dispatches, and
      # every command carries a globally unique label and a fresh (random)
      # `message_id`, so no legitimate refusal exists to trigger. A real
      # error surfacing here is a real defect to be named, not papered over.
      assert report["error_count"] == 0,
             "#{label}: expected zero errors under sustained load, got " <>
               "#{report["error_count"]}: #{inspect(report["errors"])}"

      assert report["unique_ids"] == report["ok_count"],
             "#{label}: expected every real completed dispatch to have produced a genuinely " <>
               "distinct created Item id"

      # Real data-layer proof, independent of the task replies: exactly
      # `ok_count` real `Item` rows carry this phase's unique label prefix,
      # plus one for the real warm-up dispatch below (the same
      # real-row-count pattern `sustained_throughput_test.exs` uses, since
      # the ETS table is not reset between test files in the suite).
      assert report["real_row_count"] == report["ok_count"] + 1,
             "#{label}: real Item row count (#{report["real_row_count"]}) did not match the " <>
               "real completed sample count (#{report["ok_count"]}) + 1 real warm-up row"
    end
  end

  defp run_phase(:in_memory, capability_id, run_id, duration_ms, workers) do
    broker_name = :"#{__MODULE__}.InMemoryBroker#{run_id}"
    start_supervised!(Supervisor.child_spec({InMemory, name: broker_name}, id: broker_name))

    configure_broker!({InMemory, name: broker_name})

    drive(:in_memory, capability_id, run_id, duration_ms, workers)
  end

  defp run_phase(:ekv, capability_id, run_id, duration_ms, workers) do
    ekv_name = :"#{__MODULE__}.EkvBroker#{run_id}"

    data_dir =
      Path.join(System.tmp_dir!(), "ash_a2a_broker_scale_test_#{run_id}")

    on_exit(fn -> File.rm_rf!(data_dir) end)

    start_supervised!({EKV, name: ekv_name, data_dir: data_dir, cluster_size: 1})

    configure_broker!({Ekv, name: ekv_name})

    drive(:ekv, capability_id, run_id, duration_ms, workers)
  end

  defp configure_broker!(broker) do
    Application.put_env(:ash_a2a, :authority_policy, :broker)
    Application.put_env(:ash_a2a, :authority_broker, broker)
  end

  defp drive(phase, capability_id, run_id, duration_ms, workers) do
    label_prefix = "broker-scale-#{phase}-#{run_id}-"

    # One real, standing grant per worker principal, issued up front through
    # the real broker `configure_broker!/1` just pointed `:authority_broker`
    # at -- issuance cost is deliberately OUTSIDE the timed window below, the
    # same warm-up-before-timing discipline `sustained_throughput_test.exs`
    # uses for its own one-time ETS table-init warm-up.
    principals =
      for worker_idx <- 1..workers, into: %{} do
        principal_id = "#{label_prefix}worker-#{worker_idx}"
        subject = Identity.principal(principal_id)
        {:ok, _authority} = Authority.Grant.grant(subject, capability_id)
        true = Authority.Grant.granted?(subject, capability_id)
        {worker_idx, principal_id}
      end

    warmup_identity = Map.fetch!(principals, 1)

    warmup_message =
      data_message(%{"label" => "#{label_prefix}warmup"}, %{
        metadata: %{skill: @capability_selector}
      })

    assert {:ok, warmup_task} =
             BrokerScaleItemAgent.call(
               BrokerScaleItemAgent,
               warmup_message,
               authenticated_call_opts(warmup_identity)
             )

    assert warmup_task.status.state == :completed,
           "#{phase}: real warm-up dispatch did not complete: #{inspect(warmup_task.status)}"

    run_started_ms = System.monotonic_time(:millisecond)
    deadline_ms = run_started_ms + duration_ms

    results =
      1..workers
      |> Task.async_stream(
        fn worker_idx ->
          drive_worker(worker_idx, Map.fetch!(principals, worker_idx), label_prefix, deadline_ms)
        end,
        max_concurrency: workers,
        timeout: :infinity
      )
      |> Enum.flat_map(fn {:ok, samples} -> samples end)

    wall_ms = System.monotonic_time(:millisecond) - run_started_ms

    {ok_samples, error_samples} = Enum.split_with(results, &(&1.outcome == :ok))
    sample_count = length(results)

    latency = Bench.distribution(Enum.map(ok_samples, & &1.duration_us))
    throughput = Bench.per_second(sample_count, max(wall_ms * 1_000, 1))
    ids = Enum.map(ok_samples, & &1.item_id)

    assert {:ok, all_items} = Ash.read(Item, domain: ItemDomain)
    real_row_count = Enum.count(all_items, &String.starts_with?(&1.label, label_prefix))

    %{
      "phase" => Atom.to_string(phase),
      "broker" =>
        case phase do
          :in_memory -> "AshA2A.Authority.Broker.InMemory"
          :ekv -> "AshA2A.Authority.Broker.Ekv"
        end,
      "workers" => workers,
      "requested_duration_ms" => duration_ms,
      "actual_wall_ms" => wall_ms,
      "sample_count" => sample_count,
      "ok_count" => length(ok_samples),
      "error_count" => length(error_samples),
      "errors" => Enum.take(Enum.map(error_samples, & &1.reason), 5),
      "throughput_per_second" => throughput,
      "latency_us" => latency,
      "unique_ids" => length(Enum.uniq(ids)),
      "real_row_count" => real_row_count
    }
  end

  defp drive_worker(worker_idx, principal_id, label_prefix, deadline_ms) do
    drive_worker_loop(worker_idx, principal_id, label_prefix, deadline_ms, [])
  end

  defp drive_worker_loop(worker_idx, principal_id, label_prefix, deadline_ms, acc) do
    if System.monotonic_time(:millisecond) >= deadline_ms do
      Enum.reverse(acc)
    else
      seq = System.unique_integer([:positive, :monotonic])
      label = "#{label_prefix}#{worker_idx}-#{seq}"

      message =
        data_message(%{"label" => label}, %{metadata: %{skill: @capability_selector}})

      started_us = System.monotonic_time(:microsecond)

      reply =
        BrokerScaleItemAgent.call(
          BrokerScaleItemAgent,
          message,
          authenticated_call_opts(principal_id)
        )

      duration_us = System.monotonic_time(:microsecond) - started_us
      sample = to_sample(reply, duration_us)

      drive_worker_loop(worker_idx, principal_id, label_prefix, deadline_ms, [sample | acc])
    end
  end

  defp to_sample(
         {:ok,
          %{
            status: %{state: :completed},
            artifacts: [%A2A.Artifact{parts: [%A2A.Part.Data{data: created}]}]
          }},
         duration_us
       ) do
    %{outcome: :ok, duration_us: duration_us, item_id: created.id}
  end

  defp to_sample({:ok, %{status: status}}, duration_us) do
    %{outcome: :error, duration_us: duration_us, reason: {:task_not_completed, status}}
  end

  defp to_sample({:error, reason}, duration_us) do
    %{outcome: :error, duration_us: duration_us, reason: reason}
  end

  defp ratio(_late, nil), do: nil
  defp ratio(nil, _early), do: nil
  defp ratio(_late, 0), do: nil

  defp ratio(late, early) when is_number(late) and is_number(early),
    do: Float.round(late / early, 3)

  defp duration_ms do
    case System.get_env("ASH_A2A_BROKER_SCALE_DURATION_MS") do
      nil -> @default_duration_ms
      raw -> String.to_integer(raw)
    end
  end

  defp worker_count do
    case System.get_env("ASH_A2A_BROKER_SCALE_WORKERS") do
      nil -> max(System.schedulers_online(), 2)
      raw -> String.to_integer(raw)
    end
  end
end
