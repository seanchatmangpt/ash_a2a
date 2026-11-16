# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Test.EventJournalFixture do
  @moduledoc """
  Real collaborators for the journal-backed resubscribe tests
  (`test/ash_a2a/event_journal_writer_test.exs`,
  `test/ash_a2a/event_journal_crossnode_test.exs`). Lives under `test/support/`
  so a `:peer` node can load it (see `AshA2A.Test.MultinodeEkvOwner`).
  """

  defmodule Agent do
    @moduledoc false
    use AshA2A.Protocol.Agent,
      name: "event-journal-fixture",
      description: "asks for more input until told \"done\""

    @impl AshA2A.Protocol.Agent
    def handle_message(message, _ctx) do
      if AshA2A.Protocol.Message.text(message) =~ "done",
        do: {:reply, [AshA2A.Protocol.Part.Text.new("finished")]},
        else: {:input_required, [AshA2A.Protocol.Part.Text.new("more?")]}
    end
  end

  alias AshA2A.Protocol.Task.Generation

  @doc """
  Drives one task on `agent`: a first message (input-required), then
  `followups` more, the last of which completes it when it says "done".
  Returns `{task_id, [generation after each message]}`.
  """
  def drive(agent, followups) do
    {:ok, task} = AshA2A.Protocol.call(agent, "hello")

    gens =
      Enum.reduce(followups, [Generation.generation_of(task)], fn text, gens ->
        {:ok, next} = AshA2A.Protocol.call(agent, text, task_id: task.id)
        gens ++ [Generation.generation_of(next)]
      end)

    {task.id, gens}
  end

  @doc """
  A v1.1 `tasks/resubscribe` over a real `Plug.Test` conn. Returns the decoded
  `result` of every SSE frame, in the order written.
  """
  def resubscribe(agent, task_id, last_seen, idle_ms \\ 200) do
    conn =
      Plug.Test.conn(:post, "/", "")
      |> AshA2A.Protocol.Plug.SSE.subscribe_task(agent, task_id, 7, idle_ms,
        params: %{"lastSeenGeneration" => last_seen},
        version: "1.1"
      )

    case conn.state do
      :chunked ->
        for "data: " <> json <- String.split(conn.resp_body, "\n", trim: true),
            do: Jason.decode!(json)["result"]

      _ ->
        {:not_streamed, conn.status, conn.resp_body}
    end
  end

  @doc "`{kind, generation, state | nil}` of a decoded frame."
  def summary(%{"statusUpdate" => %{"generation" => g, "status" => %{"state" => state}}}),
    do: {:status, to_int(g), state}

  def summary(%{"messageUpdate" => %{"generation" => g}}), do: {:message, to_int(g), nil}
  def summary(%{"task" => _}), do: {:task, nil, nil}
  def summary(%{"error" => %{"code" => code}}), do: {:error, nil, code}
  def summary(other), do: {:other, nil, other}

  defp to_int(g) when is_integer(g), do: g
  defp to_int(g) when is_binary(g), do: String.to_integer(g)

  @doc """
  Runs ON a peer node (via `Node.spawn/4`): joins the EKV cluster, points the
  journal at it, starts the fixture agent over the EKV task store, reports
  back and parks so the links stay alive.
  """
  def start_node_and_wait(ekv_opts, reply_to) do
    for app <- [:telemetry, :jason, :plug, :ekv], do: {:ok, _} = Application.ensure_all_started(app)
    name = Keyword.fetch!(ekv_opts, :name)

    case EKV.start_link(ekv_opts) do
      {:ok, _sup} ->
        Application.put_env(:ash_a2a, :event_journal, {AshA2A.TaskStore.EventJournalEkv, name})
        {:ok, _agent} = Agent.start_link(task_store: {AshA2A.TaskStore.Ekv, name})
        send(reply_to, {:journal_node_started, node()})

      {:error, reason} ->
        send(reply_to, {:journal_node_failed, node(), reason})
    end

    receive do
      :stop -> :ok
    end
  end
end
