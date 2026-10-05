# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Trace.Plug do
  @moduledoc """
  Transport endpoint serving `AshA2A.Trace.export/3`:

      GET /tasks/{taskId}/trace            -> the trace document
      GET /tasks/{taskId}/trace?format=otlp -> OTLP/JSON `TracesData`

  Mount it in front of `AshA2A.A2ATransport.Plug` (same `:agent` and
  `:transport`); requests that are not a trace read pass through untouched, so
  the composition is behavior-preserving:

      forward "/a2a" do
        conn
        |> AshA2A.Trace.Plug.call(trace_opts)
        |> Plug.Conn.halt() unless served  # see call/2 -- non-trace conns
        |> AshA2A.A2ATransport.Plug.call(transport_opts)
      end

  or simply

      plug AshA2A.Trace.Plug, agent: MyAgent, transport: MyTransport
      plug AshA2A.A2ATransport.Plug, agent: MyAgent, base_url: "..."

  Owner scope matches the transport's task methods exactly
  (`AshA2A.A2ATransport.Ownership.fetch/3`): a trace of a task the verified
  caller does not own is answered exactly like a missing one (HTTP 404 with
  the A2A `-32001` task-not-found error body), so trace export leaks neither a
  foreign task's existence nor its saga. Attach `AshA2A.Protocol.Plug.Auth`
  ahead of it when the transport is authenticated.

  The read path also lazily starts `AshA2A.Trace.Recorder`, so a trace of a
  saga dispatched while the recorder was detached reports the task's wire
  events alone (a degraded but truthful document) rather than failing.
  """

  @behaviour Plug

  import Plug.Conn

  alias AshA2A.A2ATransport.Ownership
  alias AshA2A.Protocol.JSONRPC.{Error, Response}
  alias AshA2A.Trace.Recorder

  @impl Plug
  def init(opts) do
    %{
      agent: Keyword.fetch!(opts, :agent),
      transport: Keyword.fetch!(opts, :transport)
    }
  end

  @impl Plug
  def call(%{method: "GET", path_info: ["tasks", task_id, "trace"]} = conn, opts) do
    Recorder.ensure()
    principal = Ownership.caller(conn)

    case Ownership.fetch(opts.agent, task_id, principal) do
      {:ok, _task} ->
        format = format(conn.query_string)

        case AshA2A.Trace.export(opts.transport, task_id, agent: opts.agent, format: format) do
          {:ok, document} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, Jason.encode!(document))
            |> halt()

          {:error, :not_found} ->
            not_found(conn)
        end

      {:error, :not_found} ->
        not_found(conn)
    end
  end

  def call(conn, _opts), do: conn

  defp format(query_string) do
    query_string
    |> URI.decode_query()
    |> case do
      %{"format" => "otlp"} -> :otlp
      _ -> :trace
    end
  end

  # Same refusal body the transport's task methods answer (`-32001`,
  # `TASK_NOT_FOUND`), over HTTP 404: a REST read, but the same A2A error
  # semantics -- a foreign task is indistinguishable from a missing one.
  defp not_found(conn) do
    body =
      Response.error(nil, Error.task_not_found())
      |> Jason.encode!()

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, body)
    |> halt()
  end
end
