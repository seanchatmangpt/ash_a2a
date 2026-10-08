# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConferenceSim.WorkshopCourt.Agent do
  @moduledoc false
  # A real, stateless protocol agent: the workshop instructor. All state
  # lives in the task's own history — no second source of truth.
  #
  #   * First turn: parks the task `:input_required` with the workshop prompt
  #     (a Data part carrying topic + deadline), the workshop materials (a
  #     real File part attached BEFORE parking), and a check-in instruction.
  #   * Continuation turn: reads the park from history. If the attendee's
  #     answer arrives after the embedded deadline -> `{:error,
  #     {:workshop_closed, topic}}` (typed refusal, terminal `:failed`).
  #     Otherwise -> `{:reply, [certificate text]}` (completed + artifact).
  use AshA2A.Protocol.Agent, name: "workshop-instructor", description: "runs a check-in workshop"

  alias AshA2A.Protocol.{FileContent, Part}

  @impl AshA2A.Protocol.Agent
  def handle_message(_message, context) do
    agent_turns = Enum.filter(context.history, &(&1.role == :agent))

    case agent_turns do
      [] -> park(context)
      _parked -> resume(context)
    end
  end

  defp park(context) do
    topic =
      context.history
      |> Enum.filter(&(&1.role == :user))
      |> flat_texts()
      |> List.first()
      |> topic_from("general")

    deadline =
      DateTime.add(
        DateTime.utc_now(),
        if(topic == "timeboxed", do: 150, else: 60_000),
        :millisecond
      )

    materials =
      Part.File.new(
        FileContent.from_bytes("# Workshop: #{topic}\nAttendees check in by name.\n",
          name: "materials-#{topic}.md",
          mime_type: "text/markdown"
        )
      )

    prompt =
      Part.Data.new(%{
        "workshop" => %{
          "topic" => topic,
          "deadline" => DateTime.to_iso8601(deadline)
        }
      })

    {:input_required, [prompt, materials, Part.Text.new("Reply with your attendee name to check in")]}
  end

  defp resume(context) do
    park = find_park(context.history)
    name = context.history |> Enum.filter(&(&1.role == :user)) |> flat_texts() |> List.last()
    topic = park["topic"]

    if DateTime.compare(DateTime.utc_now(), parse_deadline(park)) == :gt do
      {:error, {:workshop_closed, topic}}
    else
      {:reply, [Part.Text.new("certificate: #{name} completed the #{topic} workshop")]}
    end
  end

  defp find_park(history) do
    history
    |> Enum.filter(&(&1.role == :agent))
    |> Enum.flat_map(& &1.parts)
    |> Enum.find_value(fn
      %Part.Data{data: %{"workshop" => w}} -> w
      _ -> nil
    end)
  end

  defp flat_texts(history) do
    Enum.flat_map(history, fn msg ->
      if msg.role == :user do
        for %Part.Text{text: t} <- msg.parts, do: t
      else
        []
      end
    end)
  end

  defp topic_from("enroll: " <> topic, _default), do: String.trim(topic)
  defp topic_from(_, default), do: default

  defp parse_deadline(%{"deadline" => iso}), do: elem(DateTime.from_iso8601(iso), 1)
end

defmodule AshA2A.ConferenceSim.WorkshopCourt do
  @moduledoc """
  Conference-sim EV15: workshops as long-running interactive tasks.

  The `input-required` lifecycle (STREAM-SUB-002's pass condition) as the
  star scenario, over the real wire: a real protocol agent behind a real
  Bandit HTTP listener, SSE frames parsed from real wire bytes. No mocks.

  Courts:

    * the workshop parks `input-required` and the stream STAYS OPEN (G3's
      law — input-required keeps streams alive, keepalives flowing, no
      terminal frame, no close);
    * the attendee's `message/send` with the same `taskId` resumes the task,
      which completes with real output — on BOTH the resuming stream and the
      still-open original stream;
    * an attendee who never submits finds the venue honest: the task is
      still parked `input-required` after the idle window (no phantom
      timeout, no phantom completion), stream still alive;
    * a late submission (past the deadline embedded at park time) gets a
      typed refusal: terminal `:failed` with `{:workshop_closed, topic}`;
    * two attendees in one workshop: interleaved enroll/submit, each task
      gets its own certificate, no cross-wiring;
    * workshop materials: the File part attached before parking is fetched
      by the attendee via `tasks/get`; the completed task exposes the
      certificate as a real Artifact.
  """

  use ExUnit.Case, async: true

  alias AshA2A.ConferenceSim.WorkshopCourt.Agent
  alias AshA2A.Test.EphemeralHttp

  setup do
    uniq = System.unique_integer([:positive])
    agent = :"workshop_agent_#{uniq}"
    transport = :"workshop_transport_#{uniq}"

    start_supervised!({Agent, name: agent})
    start_supervised!({AshA2A.A2ATransport, name: transport})

    http =
      EphemeralHttp.start!(
        {AshA2A.A2ATransport.Plug,
         agent: agent,
         base_url: "http://x/a2a",
         transport: transport,
         heartbeat_ms: 100,
         agent_card_opts: [capabilities: %{streaming: true}]}
      )

    %{url: http.base_url, agent: agent}
  end

  alias AshA2A.Protocol.{JSON, Message, Part}

  # -- wire helpers ----------------------------------------------------------

  defp envelope(method, params),
    do: %{"jsonrpc" => "2.0", "id" => System.unique_integer([:positive]), "method" => method, "params" => params}

  defp wire_message(text, task_id \\ nil) do
    {:ok, encoded} = JSON.encode(%{Message.new_user(text) | task_id: task_id})
    encoded
  end

  # Opens a streaming request in a separate process; raw chunks forwarded to
  # the test process (a chunk boundary can split a frame — buffer first).
  defp open_stream(url, method, params) do
    parent = self()

    spawn(fn ->
      Req.post!(url,
        json: envelope(method, params),
        retry: false,
        receive_timeout: 10_000,
        into: fn {:data, data}, acc ->
          send(parent, {:chunk, self(), data})
          {:cont, acc}
        end
      )

      send(parent, {:stream_closed, self()})
    end)
  end

  defp drain(pid, acc \\ "") do
    receive do
      {:chunk, ^pid, data} -> drain(pid, acc <> data)
      {:stream_closed, ^pid} -> full_frames(acc)
    after
      10_000 -> flunk("stream did not close")
    end
  end

  # Collects chunks until an ABSOLUTE deadline (not per-message relative) so a
  # steady keepalive flow cannot starve the timeout; returns {frames, raw, closed?}.
  defp collect_for(pid, ms, acc \\ "") do
    deadline = System.monotonic_time(:millisecond) + ms

    do_collect(pid, deadline, acc)
  end

  defp do_collect(pid, deadline, acc) do
    now = System.monotonic_time(:millisecond)

    receive do
      {:chunk, ^pid, data} -> do_collect(pid, deadline, acc <> data)
      {:stream_closed, ^pid} -> {full_frames(acc), acc, :closed}
    after
      max(0, deadline - now) -> {full_frames(acc), acc, :open}
    end
  end

  defp send_message(url, text, task_id \\ nil) do
    %{"result" => result} =
      Req.post!(url,
        json: envelope("message/send", %{"message" => wire_message(text, task_id)}),
        retry: false
      ).body

    result["task"] || raise("message/send returned no task: #{inspect(result)}")
  end

  defp get_task(url, task_id) do
    %{"result" => result} =
      Req.post!(url, json: envelope("tasks/get", %{"id" => task_id}), retry: false).body

    result["task"] || result
  end

  defp state(task), do: task["status"]["state"] |> String.downcase() |> String.replace_prefix("task_state_", "")

  defp status_message(task), do: task["status"]["message"]

  defp history_texts(task) do
    for %{"role" => "ROLE_AGENT", "parts" => parts} <- task["history"] || [],
        %{"text" => t} <- parts,
        do: t
  end

  defp history_files(task) do
    for %{"role" => "ROLE_AGENT", "parts" => parts} <- task["history"] || [],
        %{"filename" => _} = file <- parts,
        do: file
  end

  defp artifact_texts(task) do
    for %{"parts" => parts} <- task["artifacts"] || [],
        %{"text" => t} <- parts,
        do: t
  end

  defp unwrap(%{"task" => %{"id" => _} = task}), do: {:snapshot, task}
  defp unwrap(%{"statusUpdate" => event}), do: {:status, event}
  defp unwrap(%{"artifactUpdate" => event}), do: {:artifact, event}

  defp full_frames(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.flat_map(fn frame ->
      id_line = frame |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "id: "))
      data_line = frame |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "data: "))

      case {id_line, data_line} do
        {"id: " <> seq, "data: " <> json} -> [{seq, Jason.decode!(json)["result"]}]
        _ -> []
      end
    end)
  end

  defp keepalives(body), do: Regex.scan(~r/^: keepalive$/m, body) |> length()

  @terminal_states ["TASK_STATE_COMPLETED", "TASK_STATE_FAILED", "TASK_STATE_CANCELED",
                    "TASK_STATE_REJECTED", "TASK_STATE_AUTH_REQUIRED"]

  defp terminal_frame?(frames) do
    Enum.any?(frames, fn {_seq, result} ->
      case unwrap(result) do
        {:status, %{"status" => %{"state" => s}}} -> s in @terminal_states
        _ -> false
      end
    end)
  end

  defp last_state(frames) do
    {_, result} = List.last(frames)

    case unwrap(result) do
      {:status, %{"status" => %{"state" => s}}} ->
        s |> String.downcase() |> String.replace_prefix("task_state_", "")

      {:snapshot, %{"status" => %{"state" => s}}} ->
        s |> String.downcase() |> String.replace_prefix("task_state_", "")

      other ->
        flunk("last frame is not a status event: #{inspect(other)}")
    end
  end

  # -- courts ----------------------------------------------------------------

  @tag :conference_sim
  test "G3 / full interactive lifecycle: enroll parks input-required, the resubscribe stream STAYS OPEN, and the attendee's submit resumes and completes", %{url: url} do
    # Attendee enrolls over message/send; the task parks input-required.
    task = send_message(url, "enroll: taming")
    assert state(task) == "input_required"
    task_id = task["id"]

    # A subscriber attaches while the task is parked. The venue keeps the
    # stream OPEN through the park (G3: input-required keeps streams alive).
    watcher = open_stream(url, "tasks/resubscribe", %{"id" => task_id})
    {frames, raw, closed} = collect_for(watcher, 500)

    assert closed == :open, "the stream closed while the task was input-required (G3 violation)"

    # First frame: the parked Task snapshot.
    assert [{_seq, first} | _] = frames

    assert {:snapshot, %{"id" => ^task_id, "status" => %{"state" => "TASK_STATE_INPUT_REQUIRED"}}} =
             unwrap(first)

    assert terminal_frame?(frames) == false

    # The venue's keepalives flowed while nobody spoke.
    assert keepalives(raw) >= 2

    # The attendee submits input via message/send with the same taskId; the
    # task resumes and completes with real output.
    done = send_message(url, "Ada", task_id)
    assert state(done) == "completed"

    # The stream that stayed open through the park received the same terminal
    # event, then closed at the terminal state (STREAM-SUB-002).
    w_frames = drain(watcher)
    assert last_state(w_frames) == "completed"
    assert terminal_frame?(w_frames)

    # And the certificate is real, on the task surface.
    assert "certificate: Ada completed the taming workshop" in artifact_texts(get_task(url, task_id))
  end

  @tag :conference_sim
  test "attendee never submits: the venue idles honestly — still input-required after the window, stream alive, no phantom terminal", %{url: url} do
    task = send_message(url, "enroll: idle")
    assert state(task) == "input_required"
    task_id = task["id"]

    # Open a resubscriber to watch the parked task.
    watcher = open_stream(url, "tasks/resubscribe", %{"id" => task_id})
    {frames, raw, closed} = collect_for(watcher, 500)

    assert closed == :open
    assert terminal_frame?(frames) == false
    assert keepalives(raw) >= 2

    # The venue's actual idle policy: the task stays parked — no phantom
    # timeout, no phantom completion.
    assert state(get_task(url, task_id)) == "input_required"

    # Cleanup by protocol, not by kill: a late (still in-window) check-in
    # completes the task, so the watcher stream terminates at the terminal
    # state instead of being torn down mid-flight.
    assert state(send_message(url, "Patient Pat", task_id)) == "completed"
    assert last_state(drain(watcher)) == "completed"
  end

  @tag :conference_sim
  test "late submission after the deadline: typed refusal — terminal failed with workshop_closed", %{url: url} do
    task = send_message(url, "enroll: timeboxed")
    task_id = task["id"]
    assert state(task) == "input_required"

    # Outlive the 150 ms venue window, then submit anyway.
    Process.sleep(300)

    late = send_message(url, "Late Larry", task_id)
    assert state(late) == "failed"

    assert %{"text" => reason} = status_message(late)["parts"] |> List.first()
    assert reason =~ "workshop_closed"
    assert reason =~ "timeboxed"
  end

  @tag :conference_sim
  test "two attendees, one workshop: interleaved enroll/submit, each gets their own output, no cross-wiring", %{url: url} do
    ada = send_message(url, "enroll: concurrency")
    grace = send_message(url, "enroll: concurrency")

    assert ada["id"] != grace["id"]
    assert state(ada) == "input_required" and state(grace) == "input_required"

    # Interleave: submit in the opposite order of enrollment.
    a2 = send_message(url, "Ada", ada["id"])
    g2 = send_message(url, "Grace", grace["id"])

    assert state(a2) == "completed" and state(g2) == "completed"

    assert "certificate: Ada completed the concurrency workshop" in artifact_texts(a2)
    assert "certificate: Grace completed the concurrency workshop" in artifact_texts(g2)
    refute "Grace" in artifact_texts(a2)
    refute "Ada" in artifact_texts(g2)
  end

  @tag :conference_sim
  test "workshop materials: File part attached before parking is fetchable via tasks/get; the completed task exposes the certificate artifact", %{url: url} do
    task = send_message(url, "enroll: materials")
    task_id = task["id"]

    # Materials were attached BEFORE the park: visible in the parked task's
    # history as a real File part.
    files = history_files(task)
    assert [%{"filename" => "materials-materials.md", "mediaType" => "text/markdown", "raw" => bytes}] =
             files

    assert bytes == Base.encode64("# Workshop: materials\nAttendees check in by name.\n")

    # And the park prompt itself is in the history too.
    assert Enum.any?(history_texts(task), &(&1 == "Reply with your attendee name to check in"))

    # The attendee submits; the completed task carries the certificate as a
    # real Artifact.
    done = send_message(url, "Marie", task_id)
    assert state(done) == "completed"
    assert artifact_texts(done) == ["certificate: Marie completed the materials workshop"]
  end
end
