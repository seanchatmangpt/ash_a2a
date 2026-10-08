# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.A2ATransport.Ownership do
  @moduledoc """
  Task ownership and credential hygiene for `AshA2A.A2ATransport.Plug`.

  The vendored `AshA2A.Protocol.Plug` stores the caller's verified identity in the call
  metadata as `"a2a.auth"`, and `AshA2A.Protocol.Agent` copies call metadata verbatim into
  `task.metadata`. Two consequences this module closes for the methods the
  transport implements itself:

    * **Owner scope.** `tasks/resubscribe`, `tasks/pushNotificationConfig/*`
      and continuation (`message/*` naming an existing task) only act on a
      task owned by the verified caller. Ownership is
      `AshA2A.Transport.Runtime.owner/1` (the recorded `"ash_a2a.owner"` key,
      else the principal of the atom-keyed `"a2a.auth"` identity -- the shape
      a JSON caller cannot forge), compared with
      `AshA2A.Transport.Principal.key/1` of the conn's verified identity. A
      foreign task is reported exactly like a missing one (`-32001`), so its
      existence is not revealed.
    * **No credential echo.** Every payload the transport publishes (SSE
      frames to any subscriber, webhook bodies to third-party receivers) is
      stripped of `"a2a.auth"`, the owner key and the raw stream reference.
  """

  alias AshA2A.Transport.{Principal, Runtime}

  @internal_keys ["a2a.auth", "ash_a2a.owner", :stream]

  @doc "Principal key of the verified caller on `conn` (`:anonymous` when none)."
  @spec caller(Plug.Conn.t()) :: Principal.key()
  def caller(conn) do
    case AshA2A.Protocol.Plug.Auth.get_identity(conn) do
      %{identity: identity} -> Principal.key(identity)
      _ -> :anonymous
    end
  end

  @doc """
  Fetches `task_id` from `agent` when `principal` owns it. A foreign task is
  `{:error, :not_found}`, indistinguishable from a missing one.
  """
  @spec fetch(GenServer.server(), term(), Principal.key()) ::
          {:ok, AshA2A.Protocol.Task.t()} | {:error, :not_found}
  def fetch(agent, task_id, principal) when is_binary(task_id) do
    with {:ok, task} <- GenServer.call(agent, {:get_task, task_id}),
         true <- Runtime.owned_by?(task, principal) do
      {:ok, task}
    else
      _ -> {:error, :not_found}
    end
  end

  def fetch(_agent, _task_id, _principal), do: {:error, :not_found}

  @doc """
  Removes verified auth, owner key and stream ref from a task's metadata --
  and from every history message's metadata (EV10-F1: caller-supplied
  `message.metadata` rides into the stored history and must not be echoed).
  """
  @spec strip_task(AshA2A.Protocol.Task.t()) :: AshA2A.Protocol.Task.t()
  def strip_task(%AshA2A.Protocol.Task{} = task) do
    task
    |> drop_from()
    |> drop_from_history()
  end

  def strip_task(task), do: task

  @doc "Removes the same keys from an already-encoded (wire) task map."
  @spec strip_wire(map()) :: map()
  def strip_wire(%{} = wire) do
    wire
    |> drop_wire_metadata()
    |> drop_wire_history()
  end

  def strip_wire(wire), do: wire

  defp drop_from(%{metadata: metadata} = task) when is_map(metadata),
    do: %{task | metadata: Map.drop(metadata, @internal_keys)}

  defp drop_from(task), do: task

  defp drop_from_history(%{history: history} = task) when is_list(history),
    do: %{task | history: Enum.map(history, &strip_message/1)}

  defp drop_from_history(task), do: task

  defp drop_wire_metadata(%{"metadata" => %{} = metadata} = wire),
    do: %{wire | "metadata" => Map.drop(metadata, @internal_keys)}

  defp drop_wire_metadata(wire), do: wire

  defp drop_wire_history(%{"history" => history} = wire) when is_list(history),
    do: %{wire | "history" => Enum.map(history, &strip_message/1)}

  defp drop_wire_history(wire), do: wire

  defp strip_message(%{metadata: metadata} = message) when is_map(metadata),
    do: %{message | metadata: Map.drop(metadata, @internal_keys)}

  defp strip_message(%{"metadata" => %{} = metadata} = message),
    do: %{message | "metadata" => Map.drop(metadata, @internal_keys)}

  defp strip_message(message), do: message

  @doc """
  Drops the caller-forgeable internal keys from a JSON-RPC `params.metadata`
  so a caller can neither overwrite the verified `"a2a.auth"` nor claim an
  owner.
  """
  @spec sanitize_params(map()) :: map()
  def sanitize_params(%{"metadata" => %{} = metadata} = params),
    do: %{params | "metadata" => Map.drop(metadata, @internal_keys)}

  def sanitize_params(params), do: params
end
