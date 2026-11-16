defmodule AshA2A.LaneW202.SSEJournalResubscribeTest do
  # UNVERIFIED: authored without an Elixir toolchain; not yet run.
  @moduledoc """
  `tasks/resubscribe` replays missed events through the configured
  `AshA2A.Protocol.EventJournal` and, for a non-terminal task with no local
  live producer, closes with a `PRODUCER_UNAVAILABLE` StreamError instead of
  hanging. Real agent, real Plug.Test conn, hand-written journal module.
  """
  use ExUnit.Case, async: false
  import Plug.Test

  defmodule AskAgent do
    use AshA2A.Protocol.Agent,
      name: "w202-ask",
      description: "leaves tasks input-required"

    @impl AshA2A.Protocol.Agent
    def handle_message(_message, _ctx),
      do: {:input_required, [AshA2A.Protocol.Part.Text.new("more?")]}
  end

  # Hand-written implementation of the real behaviour, backed by app env.
  defmodule Journal do
    def append(_task_id, _generation, _event), do: :ok
    def trim(_task_id, _keep_last), do: :ok

    def replay_after(task_id, generation) do
      events = Application.get_env(:ash_a2a, :w202_journal_events, [])

      {:ok,
       Enum.filter(events, fn e ->
         get_in(e, ["statusUpdate", "taskId"]) == task_id and
           get_in(e, ["statusUpdate", "generation"]) > generation
       end)}
    end
  end

  setup do
    start_supervised!({AskAgent, []})

    old = Application.get_all_env(:ash_a2a)
    Application.put_env(:ash_a2a, :event_journal, Journal)
    Application.put_env(:ash_a2a, :resubscribe_orphan_grace_ms, 50)

    on_exit(fn ->
      for k <- [:event_journal, :resubscribe_orphan_grace_ms, :w202_journal_events] do
        case Keyword.fetch(old, k) do
          {:ok, v} -> Application.put_env(:ash_a2a, k, v)
          :error -> Application.delete_env(:ash_a2a, k)
        end
      end
    end)

    {:ok, task} = AshA2A.Protocol.call(AskAgent, "hello")
    %{task: task, gen: AshA2A.Protocol.Task.Generation.generation_of(task)}
  end

  defp status_event(task_id, gen, state) do
    %{
      "statusUpdate" => %{
        "taskId" => task_id,
        "status" => %{"state" => state},
        "generation" => gen
      }
    }
  end

  defp resubscribe(task_id, last_seen) do
    conn(:post, "/", "")
    |> AshA2A.Protocol.Plug.SSE.subscribe_task(AskAgent, task_id, 9, 1_000,
      params: %{"lastSeenGeneration" => last_seen},
      version: "1.1"
    )
  end

  defp frames(conn) do
    for "data: " <> json <- String.split(conn.resp_body, "\n", trim: true),
        do: Jason.decode!(json)["result"]
  end

  test "replays journal events then closes with PRODUCER_UNAVAILABLE", %{task: task, gen: gen} do
    Application.put_env(:ash_a2a, :w202_journal_events, [
      status_event(task.id, gen + 1, "TASK_STATE_WORKING")
    ])

    started = System.monotonic_time(:millisecond)
    conn = resubscribe(task.id, gen)
    elapsed = System.monotonic_time(:millisecond) - started

    assert conn.state == :chunked
    assert [replayed, error] = frames(conn)
    assert replayed["statusUpdate"]["generation"] in [gen + 1, Integer.to_string(gen + 1)]
    assert Jason.encode!(error) =~ "PRODUCER_UNAVAILABLE"
    # closed by the orphan grace, not the 1s idle timeout
    assert elapsed < 900
  end

  test "a replayed terminal event closes without the producer error", %{task: task, gen: gen} do
    Application.put_env(:ash_a2a, :w202_journal_events, [
      status_event(task.id, gen + 1, "TASK_STATE_COMPLETED")
    ])

    conn = resubscribe(task.id, gen)

    assert [%{"statusUpdate" => _}] = frames(conn)
    refute conn.resp_body =~ "PRODUCER_UNAVAILABLE"
  end

  test "an unloadable journal module falls back without crashing", %{task: task, gen: gen} do
    Application.put_env(:ash_a2a, :event_journal, AshA2A.LaneW202.NoSuchJournal)

    conn = resubscribe(task.id, gen)

    assert conn.state == :chunked
    refute conn.resp_body =~ "PRODUCER_UNAVAILABLE"
  end
end
