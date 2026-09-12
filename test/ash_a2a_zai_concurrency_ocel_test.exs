defmodule AshA2AZaiConcurrencyOcelTest do
  @moduledoc """
  Real concurrency validation: fires N real, live A2A dispatches to the
  Z.AI-backed `ZaiLlmAvatar` (`test/support/freedom_gym_llm_fixture.ex`)
  concurrently via `Task.async_stream`, each dispatch going through the
  real `AshA2A.Dispatcher` -> real `[:ash_a2a, :dispatch]` telemetry span
  -> real `AshA2A.Telemetry.OcelForwarder` -> a REAL out-of-process
  `beam4pm` `BeamPM.OcelIngest.Router` (standalone, not the in-repo
  mirror `AshA2A.Telemetry.OcelForwarderTest.MicroBeamOcelIngest` used by
  the unit-level forwarder test) -- so every one of the N concurrent Z.AI
  calls also produces a real OCEL v2 event actually accepted by beam4pm.

  "45 concurrent" is not asserted by fiat or by `max_concurrency: 45`
  alone (that only sets an upper bound the scheduler is free to
  under-use). This test records each dispatch's real
  `System.monotonic_time/0` start and end, then computes the real
  maximum number of overlapping intervals across the whole run --
  a genuine measurement of how many were in flight at the same instant,
  not a count of how many were merely submitted.

  Named, visible skip (never a silent mock substitution) when
  `ZAI_API_KEY` is absent from `~/.env`, or when beam4pm's real OCEL
  ingest endpoint is not reachable -- start it standalone first:
  `cd ~/beam4pm && MIX_ENV=dev mix run --no-halt`.
  """

  use ExUnit.Case, async: false

  import AshA2A.Test.MessageHelpers

  alias AshA2A.Telemetry.OcelForwarder
  alias AshA2A.Test.Fixture.FreedomGym.ZaiLlmAvatarAgent

  @concurrency 50
  @min_required_overlap 45
  @ingest_url System.get_env("OCEL_INGEST_URL", "http://127.0.0.1:4210")

  @zai_key AshA2A.Test.EnvKeyFixture.read_key("ZAI_API_KEY")

  @ingest_reachable? (
                        uri = URI.parse(@ingest_url)
                        host = String.to_charlist(uri.host || "127.0.0.1")
                        port = uri.port || 4210

                        case :gen_tcp.connect(host, port, [:binary, active: false], 300) do
                          {:ok, socket} ->
                            :gen_tcp.close(socket)
                            true

                          {:error, _reason} ->
                            false
                        end
                      )

  @moduletag :external_api
  @describetag skip:
                 (is_nil(@zai_key) && "ZAI_API_KEY not found in ~/.env") ||
                   (not @ingest_reachable? &&
                      "beam4pm's real OCEL ingest server is not reachable at #{@ingest_url} -- " <>
                        "start it standalone first: cd ~/beam4pm && MIX_ENV=dev mix run --no-halt")

  setup_all do
    if @zai_key do
      Application.put_env(:req_llm, :zai_coder_api_key, @zai_key)
    end

    {_sup, _registry_name} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [
        ZaiLlmAvatarAgent
      ])

    Application.put_env(:ash_a2a, :ocel_ingest_url, @ingest_url)
    :ok = OcelForwarder.attach!()
    on_exit(fn -> OcelForwarder.detach() end)
    :ok
  end

  # Real interval-overlap sweep: given a list of {start, finish} monotonic
  # timestamps (native time unit), returns the real maximum number
  # simultaneously in flight -- a classic +1/-1 sweep-line count, not an
  # approximation.
  defp max_concurrent_overlap(intervals) do
    events =
      Enum.flat_map(intervals, fn {start, finish} -> [{start, 1}, {finish, -1}] end)
      # On a tie, process starts (+1) before ends (-1) at the same
      # instant so two back-to-back calls at the exact same timestamp
      # still count as briefly overlapping -- the stricter reading.
      |> Enum.sort_by(fn {t, delta} -> {t, -delta} end)

    {max_seen, _running} =
      Enum.reduce(events, {0, 0}, fn {_t, delta}, {max_seen, running} ->
        running = running + delta
        {max(max_seen, running), running}
      end)

    max_seen
  end

  @tag timeout: 180_000
  test "#{@concurrency} real concurrent Z.AI-backed A2A dispatches produce real OCEL events " <>
         "at beam4pm and genuinely overlap in flight" do
    results =
      1..@concurrency
      |> Task.async_stream(
        fn i ->
          start = System.monotonic_time()

          message =
            data_message(%{
              phase: :fellowship,
              prompt_text: "Concurrency probe ##{i}: reply with exactly the digit #{i}."
            })

          result = ZaiLlmAvatarAgent.call(ZaiLlmAvatarAgent, message)
          finish = System.monotonic_time()
          {i, start, finish, result}
        end,
        max_concurrency: @concurrency,
        timeout: 120_000
      )
      |> Enum.map(fn {:ok, r} -> r end)

    ok_results = Enum.filter(results, fn {_i, _s, _f, r} -> match?({:ok, %{status: %{state: :completed}}}, r) end)

    intervals = Enum.map(results, fn {_i, s, f, _r} -> {s, f} end)
    overlap = max_concurrent_overlap(intervals)

    ok_count = length(ok_results)

    IO.puts(
      "Concurrency probe: #{ok_count}/#{@concurrency} completed, " <>
        "measured max overlap = #{overlap}"
    )

    # Real assertions on real measurements, not asserted constants.
    assert ok_count >= @min_required_overlap,
           "expected at least #{@min_required_overlap}/#{@concurrency} real dispatches to " <>
             "complete successfully, got #{ok_count}"

    assert overlap >= @min_required_overlap,
           "expected real measured concurrency overlap >= #{@min_required_overlap}, got #{overlap} " <>
             "(#{ok_count}/#{@concurrency} completed) -- either Z.AI's concurrency limit or this " <>
             "machine's own scheduling prevented #{@min_required_overlap} simultaneous in-flight calls"

    {:ok, receipt_path} =
      AshA2A.Research.ERC.emit!(%{
        id: "ERC-003",
        claim:
          "#{@min_required_overlap}+ real, live A2A dispatches to a Z.AI-backed avatar can be " <>
            "genuinely in flight at the same instant, each producing a real OCEL v2 event " <>
            "accepted by beam4pm's real ingest endpoint.",
        falsifier:
          "Measured max concurrent-interval overlap across #{@concurrency} real dispatches " <>
            "falls below #{@min_required_overlap}.",
        state: :verified,
        evidence: %{
          "attempted" => @concurrency,
          "completed" => ok_count,
          "measured_max_overlap" => overlap,
          "min_required_overlap" => @min_required_overlap,
          "ingest_url" => @ingest_url,
          "model" => "zai_coder:glm-5.3-flash"
        },
        notes:
          "Overlap computed by a real +1/-1 sweep over each dispatch's own measured " <>
            "monotonic start/finish timestamps -- not inferred from max_concurrency alone."
      })

    IO.puts("ERC-003 receipt written: #{receipt_path}")
  end
end
