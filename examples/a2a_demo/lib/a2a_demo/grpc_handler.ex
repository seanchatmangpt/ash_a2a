defmodule A2aDemo.GrpcHandler do
  @moduledoc """
  The `AshA2A.Protocol.JSONRPC` behaviour implementation the demo's gRPC
  mount (`AshA2A.Transport.GRPC.Server`) dispatches through — the same
  dispatcher (and therefore the same protocol logic, error table and task
  store) as the HTTP mounts, minus the HTTP-specific ownership context.

  Modeled on `AshA2A.Transport.Plug`'s own JSONRPC callbacks, with the
  conn-dependent pieces (connection metadata, verified principal) replaced
  by the demo's gRPC reality: no credential transport, so every gRPC caller
  is the anonymous principal (`:anonymous`).
  """

  @behaviour AshA2A.Protocol.JSONRPC

  alias AshA2A.Protocol.JSONRPC.Error
  alias AshA2A.Transport.Runtime

  @impl AshA2A.Protocol.JSONRPC
  def handle_send(message, params, ctx) do
    case AshA2A.Protocol.call(ctx.agent, message, call_opts(params, message)) do
      {:ok, task} ->
        {:ok, Runtime.wire_task(task)}

      {:error, reason} ->
        {:error, wire_error(reason)}
    end
  end

  @impl AshA2A.Protocol.JSONRPC
  def handle_get(task_id, _params, ctx) do
    case get_task(ctx, task_id) do
      {:ok, task} -> {:ok, Runtime.wire_task(task)}
      {:error, _} -> {:error, Error.task_not_found()}
    end
  end

  @impl AshA2A.Protocol.JSONRPC
  def handle_cancel(task_id, _cancel_params, ctx) do
    with {:ok, _task} <- get_task(ctx, task_id),
         :ok <- GenServer.call(ctx.agent, {:cancel, task_id}),
         {:ok, task} <- get_task(ctx, task_id) do
      {:ok, Runtime.wire_task(task)}
    else
      {:error, :not_found} -> {:error, Error.task_not_found()}
      {:error, :not_cancelable} -> {:error, Error.task_not_cancelable()}
      {:error, reason} -> {:error, wire_error(reason)}
    end
  end

  @impl AshA2A.Protocol.JSONRPC
  def handle_list(params, ctx) do
    case GenServer.call(ctx.agent, {:ash_a2a_list_tasks, principal(ctx), params}) do
      {:ok, %{tasks: tasks} = result} ->
        {:ok, %{result | tasks: Enum.map(tasks, &Runtime.wire_task/1)}}

      {:error, :invalid_page_token} ->
        {:error, Error.invalid_params("\"pageToken\" is invalid")}

      {:error, reason} ->
        {:error, wire_error(reason)}
    end
  end

  # gRPC carries no credential transport, so every gRPC caller is the same
  # anonymous principal -- the SAME key the agent's runtime derives for
  # unauthenticated sends (`Principal.from_metadata(%{}) == :anonymous`),
  # which is what makes tasks created over gRPC visible to gRPC gets.
  defp principal(ctx), do: Map.get(ctx, :principal, :anonymous)

  defp get_task(ctx, task_id) do
    GenServer.call(ctx.agent, {:ash_a2a_get_task, principal(ctx), task_id})
  end

  defp call_opts(params, message) do
    metadata =
      case params["metadata"] do
        %{} = m -> Map.drop(m, ["a2a.auth", Runtime.owner_key()])
        _ -> %{}
      end

    []
    |> put_opt(:task_id, params["id"] || message.task_id)
    |> put_opt(:context_id, params["contextId"] || message.context_id)
    |> put_opt(:metadata, if(metadata == %{}, do: nil, else: metadata))
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp wire_error(reason) do
    AshA2A.Transport.Plug.wire_error(reason)
  end
end
