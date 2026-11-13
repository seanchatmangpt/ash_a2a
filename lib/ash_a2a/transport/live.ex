# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Transport.Live do
  @moduledoc """
  Transport-independent core of A2A v1.1 `SendLiveMessage` (spec 3.1.12).

  A live exchange has an **uplink** (`StreamRequest` maps from the client) and a
  **downlink** (`StreamResponse` events from the agent). gRPC bidi and HTTP
  `POST /message:live` bind to the API below; this module never touches a
  connection.

  ## Supervision

  Add `AshA2A.Transport.Live.Supervisor` to the application tree. It owns the
  session registry and a `DynamicSupervisor`. Without it `open/3` still works
  (unsupervised, self-cleaning sessions) but `uplink_call/4` cannot route by
  session id or task id.

  ## API

      open(agent, ctx, downlink) :: {:ok, session_pid} | {:error, reason}
      session_id(session_pid) :: String.t()
      uplink(session_pid, stream_request_map) :: :ok | {:error, reason}
      uplink_call(agent, ctx, stream_request_map, opts \\\\ []) ::
        {:ack, Task.t() | Message.t() | nil} | {:error, reason | StreamError.t()}
      close(session_pid) :: :ok
      encode(event) :: map()          # StreamResponse wrapper map (camelCase JSON shape)
      capability?(card, :streaming | :user_artifacts) :: boolean()

  `agent` is the agent GenServer (name or pid). `ctx` is a map; recognised keys:
  `:metadata` (call metadata, e.g. `"a2a.auth"`), `:principal` (owner key, default
  derived from metadata), `:card` (agent card override, default `:get_agent_card`),
  `:timeout` (agent call timeout, default 60_000), `:live_session_id` (for
  `uplink_call/4`).

  `downlink` is a pid or a 1-arity function. It receives, in task order:

    * `{:a2a_live, session_id, event}` where `event` is one of
      `AshA2A.Protocol.Task` (snapshot), `Event.StatusUpdate`, `Event.ArtifactUpdate`,
      `Event.MessageUpdate` (all carrying `generation`), `AshA2A.Protocol.Message`
      (message-only reply) or `AshA2A.Protocol.StreamError` (non-fatal rejection);
    * `{:a2a_live_closed, session_id, reason}` exactly once, with `reason` `:terminal`,
      `:message` (message-only answer), or `:closed`. A function downlink receives the
      same tuples. A pid downlink that dies ends the session.

  ## `open/3`

  Fails with `{:error, :unsupported_operation}` unless the agent card declares
  `capabilities.streaming`, and `{:error, :unavailable}` if the card is unreachable.

  ## `uplink/2` (native duplex / downlink-call mode)

  The first accepted request binds the stream to one task:

    * `"subscribe"` attaches to an existing task. `lastSeenGeneration` unset: a Task
      snapshot, then follow. Set: no snapshot, only events after that generation
      (reconstructed from the task timeline/artifacts), falling back to a snapshot when
      replay is impossible. Unknown or foreign task: `{:error, :not_found}`.
    * `"sendMessage"` creates (no `taskId`) or continues (`taskId`) a task. The
      agent call runs off the session process; the downlink opens with a Task snapshot
      reflecting the message. `configuration.acceptedOutputModes` and
      `ifGenerationMatch` are forwarded to the agent call, `returnImmediately` is ignored;
      `artifactUpdates` require `capabilities.user_artifacts`.

  Later requests apply to the bound task. Rejections are `StreamError` events on the
  downlink (stream stays open) and `uplink/2` still returns `:ok`:

  | condition | code |
  |---|---|
  | `subscribe` after the first request | `FAILED_PRECONDITION` |
  | request names a different task | `INVALID_ARGUMENT` |
  | unknown payload kind | `UNIMPLEMENTED` |
  | malformed request | `INVALID_ARGUMENT` (`reference_id` = messageId / artifactId) |
  | agent busy / refusing input (`task_in_progress`, `server_busy`, `rate_limited`, a send already in flight) | `UNAVAILABLE` |
  | `artifactUpdates` without capability | `UNSUPPORTED_OPERATION` |
  | `ifGenerationMatch` mismatch | `ABORTED` |
  | task vanished | `NOT_FOUND` |
  | agent returned another error | `INTERNAL` (opaque) |

  A terminal task ends the stream (after the final events); `input_required` /
  `auth_required` keep it open. A first `sendMessage` that fails leaves the stream
  unbound so the client may retry.

  ## `uplink_call/4` (HTTP short-lived call mode)

  Used for an uplink call that is NOT the downlink. It only ever returns
  `{:ack, task}` and never replays events. Routing:

    1. `ctx[:live_session_id]` / `opts[:live_session_id]` selects a session
       (`{:error, :unknown_session}` if absent or owned by another principal);
    2. else a session of the same principal bound to the request's `taskId` on the same
       agent is used;
    3. else there is no downlink: a `sendMessage` runs directly against the agent and
       returns `{:ack, task_or_message}`; rejections return `{:error, %StreamError{}}`
       (`{:error, :not_found}` for an unknown task).

  With a session, every event goes to the downlink only, rejections are emitted there as
  `StreamError`, and the call returns `{:ack, current_task}` (for a request that creates
  the task the ack waits for the agent call, since the task id is unknown before that).
  Streaming must be declared (`{:error, :unsupported_operation}` otherwise).
  """

  alias AshA2A.Protocol.{StreamError, StreamRequest}
  alias AshA2A.Protocol.Task, as: T
  alias AshA2A.Transport.Live.Session
  alias AshA2A.Transport.{Principal, Runtime}

  @registry AshA2A.Transport.Live.Registry
  @session_sup AshA2A.Transport.Live.SessionSup

  @doc false
  def registry, do: @registry

  @doc "Opens a live session. See the moduledoc."
  @spec open(GenServer.server(), map(), pid() | (term() -> any())) ::
          {:ok, pid()} | {:error, term()}
  def open(agent, ctx, downlink) when is_pid(downlink) or is_function(downlink, 1) do
    ctx = normalize(ctx)

    with {:ok, card} <- card(agent, ctx),
         true <- capability?(card, :streaming) || {:error, :unsupported_operation} do
      id = "live-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      args = {id, agent, ctx, downlink, card}

      if Process.whereis(@session_sup) do
        DynamicSupervisor.start_child(@session_sup, {Session, args})
      else
        GenServer.start(Session, args)
      end
    end
  end

  @doc "Server-issued session id (the `live_session_id` correlation value)."
  @spec session_id(pid()) :: String.t()
  def session_id(session), do: GenServer.call(session, :id)

  @doc "Applies one `StreamRequest` map to the session. See the moduledoc."
  @spec uplink(pid(), map()) :: :ok | {:error, term()}
  def uplink(session, request) do
    GenServer.call(session, {:uplink, request}, 120_000)
  catch
    :exit, _ -> {:error, :closed}
  end

  @doc "Stops the session (emits `{:a2a_live_closed, id, :closed}`)."
  @spec close(pid()) :: :ok
  def close(session) do
    GenServer.cast(session, :close)
  end

  @doc "HTTP-style uplink call that returns only an acknowledgement."
  @spec uplink_call(GenServer.server(), map(), map(), keyword()) ::
          {:ack, term()} | {:error, term()}
  def uplink_call(agent, ctx, request, opts \\ []) do
    ctx = normalize(ctx)

    with {:ok, card} <- card(agent, ctx),
         true <- capability?(card, :streaming) || {:error, :unsupported_operation} do
      principal = principal(ctx)
      sid = Map.get(ctx, :live_session_id) || Keyword.get(opts, :live_session_id)

      case find_session(agent, principal, sid, request) do
        {:ok, pid} ->
          try do
            case GenServer.call(pid, {:uplink_call, request, principal}, 120_000) do
              {:error, _} = error -> error
              {:ack, _} = ack -> ack
            end
          catch
            :exit, _ -> {:error, :unknown_session}
          end

        {:error, _} = error ->
          error

        :none ->
          Session.direct(agent, Map.put(ctx, :card, card), request)
      end
    end
  end

  @doc "Encodes a downlink event as its v1.1 `StreamResponse` wrapper map."
  @spec encode(struct()) :: map()
  def encode(event) do
    {:ok, wrapped} = AshA2A.Protocol.JSON.encode_stream_response(event)
    wrapped
  end

  @doc "Whether the card declares the capability (`:streaming` or `:user_artifacts`)."
  @spec capability?(map() | nil, :streaming | :user_artifacts) :: boolean()
  def capability?(nil, _), do: false

  def capability?(card, :user_artifacts), do: AshA2A.Protocol.ClientArtifacts.user_artifacts?(card)

  def capability?(card, :streaming) do
    case fetch(card, :capabilities) do
      nil -> false
      caps -> fetch(caps, :streaming) == true
    end
  end

  @doc false
  def register(key, value) do
    if Process.whereis(@registry), do: Registry.register(@registry, key, value)
    :ok
  end

  @doc false
  def principal(ctx) do
    case Map.get(ctx, :principal) do
      nil -> Principal.from_metadata(Map.get(ctx, :metadata, %{}))
      key -> key
    end
  end

  # -- internals ----------------------------------------------------------------

  defp normalize(ctx) when is_map(ctx), do: Map.put_new(ctx, :metadata, %{})
  defp normalize(_), do: %{metadata: %{}}

  defp card(agent, ctx) do
    case Map.get(ctx, :card) do
      %{} = card ->
        {:ok, card}

      _ ->
        try do
          case GenServer.call(agent, :get_agent_card, 5_000) do
            %{} = card -> {:ok, card}
            _ -> {:error, :unavailable}
          end
        catch
          :exit, _ -> {:error, :unavailable}
        end
    end
  end

  defp find_session(agent, principal, sid, request) do
    cond do
      is_nil(Process.whereis(@registry)) ->
        if sid, do: {:error, :unknown_session}, else: :none

      is_binary(sid) ->
        case Registry.lookup(@registry, {:session, sid}) do
          [{pid, _} | _] -> {:ok, pid}
          [] -> {:error, :unknown_session}
        end

      true ->
        with {:ok, %StreamRequest{kind: :send_message, payload: %{task_id: id}}} when is_binary(id) <-
               StreamRequest.decode(request),
             [_ | _] = entries <- Registry.lookup(@registry, {:task, agent, id}),
             {pid, _} <- Enum.find(entries, fn {_pid, owner} -> owner == principal end) do
          {:ok, pid}
        else
          _ -> :none
        end
    end
  end

  defp fetch(%{} = map, key) do
    case Map.fetch(map, key) do
      {:ok, v} -> v
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp fetch(_, _), do: nil

  @doc false
  def wire(%T{} = task), do: task |> Runtime.wire_task() |> T.strip_stream_metadata()

  @doc false
  def stream_error(code, message, task_id, ref) do
    %StreamError{code: code, message: message, task_id: task_id, reference_id: ref}
  end
end

defmodule AshA2A.Transport.Live.Supervisor do
  @moduledoc """
  Supervision tree for live sessions: the session/task `Registry` plus a
  `DynamicSupervisor` (`AshA2A.Transport.Live.SessionSup`). Add it to the
  application's children.
  """

  use Supervisor

  def start_link(opts \\ []),
    do: Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :duplicate, name: AshA2A.Transport.Live.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: AshA2A.Transport.Live.SessionSup}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
