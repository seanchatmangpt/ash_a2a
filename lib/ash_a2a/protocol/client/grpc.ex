if Code.ensure_loaded?(Req) do
  defmodule AshA2A.Protocol.Client.GRPC do
    @moduledoc """
    gRPC binding of the A2A client (`lf.a2a.v1.A2AService`).

    Normally reached through `AshA2A.Protocol.Client` built with
    `transport: :grpc`; every function here takes the `%AshA2A.Protocol.Client{}`
    and answers the same terms as the HTTP bindings:

        client = AshA2A.Protocol.Client.new("localhost:50051", transport: :grpc)
        {:ok, task} = AshA2A.Protocol.Client.send_message(client, "hi")

    ## Wire bridge

    Requests are shaped as the codec's proto-JSON maps and decoded into the
    generated `Lf.A2a.V1` messages with `Protobuf.JSON`; replies take the
    reverse path into `AshA2A.Protocol.JSON`. The result structs are therefore
    identical to the HTTP clients'.

    ## Channels

    `connect/1` opens a `GRPC.Channel` stored in the client (`:channel`); pass
    `channel:` to `Client.new/2` to reuse one you own. With no channel each
    call connects and disconnects (streams disconnect when they end or halt).
    `:grpc_opts` on `Client.new/2` are merged into `GRPC.Stub.connect/2`
    options (default adapter `GRPC.Client.Adapters.Mint`).

    ## Metadata

    `A2A-Version` (the client's `:version`) and `A2A-Extensions` ride as gRPC
    metadata, together with the client's `:headers` and the per-call `:headers`
    option (a list of `{name, value}`). `:timeout` is the call deadline in ms.

    ## Errors

    `GRPC.RPCError` is mapped by `map_error/1`: the packed `google.rpc.ErrorInfo`
    reason gives the same atoms as the REST client (`:task_not_found`, ...);
    `ABORTED` + `TASK_GENERATION_MISMATCH` gives
    `{:task_generation_mismatch, %{metadata: m, message: msg}}`; with no
    ErrorInfo `NOT_FOUND` is `:task_not_found`, `UNAUTHENTICATED`
    `{:unauthorized, []}`, `PERMISSION_DENIED` `{:forbidden, message}`, anything
    else `{:grpc_error, status, message}`. A failure after a stream opened is
    emitted as a final `{:error, reason}` element.

    ## Live sessions (`SendLiveMessage`, bidirectional)

        {:ok, %{events: events, session: session}} =
          GRPC.open_live(client, %{"subscribe" => %{"id" => task_id}})

        :ok = GRPC.live_send(session, "more input")
        :ok = GRPC.live_close(session)

    `events` carries decoded `StreamResponse` payloads (`%Task{}`,
    `%Event.StatusUpdate{}`, ...) and `{:stream_error, %StreamError{}}` for
    non-fatal rejections. Uplink calls return `:ok`; their results arrive as
    events. Consume `events` from the process that opened the session.
    """

    require Logger

    alias AshA2A.Protocol.Client
    alias AshA2A.Protocol.JSON
    alias Lf.A2a.V1, as: Pb
    alias Lf.A2a.V1.A2AService.Stub

    @default_timeout 15_000
    @long_poll_margin 5_000
    @stream_timeout 3_600_000

    defmodule Session do
      @moduledoc false
      defstruct [:client, :channel, :owned?, :stream]
    end

    @type session :: %Session{}

    # -- channel management ----------------------------------------------------

    @doc "Opens a channel and stores it in the client. Idempotent."
    @spec connect(Client.t()) :: {:ok, Client.t()} | {:error, term()}
    def connect(%Client{channel: nil} = client) do
      with {:ok, channel} <- open_channel(client), do: {:ok, %{client | channel: channel}}
    end

    def connect(%Client{} = client), do: {:ok, client}

    @doc "Closes the client's channel (if any) and returns the client without one."
    @spec disconnect(Client.t()) :: Client.t()
    def disconnect(%Client{channel: nil} = client), do: client

    def disconnect(%Client{channel: channel} = client) do
      release(channel, true)
      %{client | channel: nil}
    end

    defp open_channel(%Client{url: url, grpc_opts: grpc_opts}) do
      {target, cred} = parse_target(url)

      opts =
        [adapter: GRPC.Client.Adapters.Mint]
        |> Keyword.merge(cred)
        |> Keyword.merge(grpc_opts || [])

      case GRPC.Stub.connect(target, opts) do
        {:ok, channel} -> {:ok, channel}
        {:error, reason} -> {:error, {:grpc_connect_failed, reason}}
      end
    rescue
      e -> {:error, {:grpc_connect_failed, Exception.message(e)}}
    end

    defp parse_target("https://" <> rest),
      do: {String.trim_trailing(rest, "/"), [cred: GRPC.Credential.new(ssl: [])]}

    defp parse_target("http://" <> rest), do: {String.trim_trailing(rest, "/"), []}
    defp parse_target(target), do: {target, []}

    defp acquire(%Client{channel: nil} = client) do
      with {:ok, channel} <- open_channel(client), do: {:ok, channel, true}
    end

    defp acquire(%Client{channel: channel}), do: {:ok, channel, false}

    defp release(_channel, false), do: :ok

    defp release(channel, true) do
      GRPC.Stub.disconnect(channel)
      :ok
    catch
      _, _ -> :ok
    end

    defp with_channel(client, fun) do
      with {:ok, channel, owned?} <- acquire(client) do
        try do
          fun.(channel)
        after
          release(channel, owned?)
        end
      end
    end

    # -- unary RPCs --------------------------------------------------------------

    @doc "`SendMessage`. Result is a `%Task{}` or `%Message{}`."
    def send_message(%Client{} = client, message, opts \\ []) do
      {params, _req_opts} = Client.__build_send_params__(message, opts)

      map =
        params
        |> Map.take(["message", "configuration", "metadata", "artifactUpdates"])
        |> put_tenant(client)

      unary(client, :send_message, Pb.SendMessageRequest, map, opts, &decode_event/1)
    end

    @doc "`GetTask` (`:history_length`, `:timeline_length`, `:current_generation`)."
    def get_task(%Client{} = client, task_id, opts \\ []) do
      map =
        %{"id" => task_id}
        |> put("historyLength", opts[:history_length])
        |> put("timelineLength", opts[:timeline_length])
        |> put("currentGeneration", opts[:current_generation])
        |> put_tenant(client)

      unary(client, :get_task, Pb.GetTaskRequest, map, opts, &JSON.decode(&1, :task))
    end

    @doc "`CancelTask`."
    def cancel_task(%Client{} = client, task_id, opts \\ []) do
      map =
        %{"id" => task_id}
        |> put("metadata", opts[:metadata])
        |> put_tenant(client)

      unary(client, :cancel_task, Pb.CancelTaskRequest, map, opts, &JSON.decode(&1, :task))
    end

    @doc "`ListTasks`; options as `AshA2A.Protocol.Client.list_tasks/2`."
    def list_tasks(%Client{} = client, opts \\ []) do
      map =
        %{}
        |> put("pageSize", opts[:page_size])
        |> put("pageToken", opts[:page_token])
        |> put("status", state_name(opts[:status]))
        |> put("contextId", opts[:context_id])
        |> put("statusTimestampAfter", timestamp(opts[:status_timestamp_after]))
        |> put("historyLength", opts[:history_length])
        |> put("includeArtifacts", opts[:include_artifacts])
        |> put("timelineLength", opts[:timeline_length])
        |> put_tenant(client)

      unary(client, :list_tasks, Pb.ListTasksRequest, map, opts, fn result ->
        JSON.decode_list_result(Map.put_new(result, "tasks", []))
      end)
    end

    @doc "`CreateTaskPushNotificationConfig`."
    def set_push_config(
          %Client{} = client,
          %AshA2A.Protocol.PushNotificationConfig{} = config,
          opts \\ []
        ) do
      case config.task_id || opts[:task_id] do
        nil ->
          {:error, :task_not_found}

        task_id ->
          {:ok, encoded} = JSON.encode(%{config | task_id: task_id})

          unary(
            client,
            :create_task_push_notification_config,
            Pb.TaskPushNotificationConfig,
            put_tenant(encoded, client),
            opts,
            &JSON.decode(&1, :push_notification_config)
          )
      end
    end

    @doc "`GetTaskPushNotificationConfig`."
    def get_push_config(%Client{} = client, task_id, config_id, opts \\ []) do
      map = put_tenant(%{"taskId" => task_id, "id" => config_id}, client)

      unary(
        client,
        :get_task_push_notification_config,
        Pb.GetTaskPushNotificationConfigRequest,
        map,
        opts,
        &JSON.decode(&1, :push_notification_config)
      )
    end

    @doc "`ListTaskPushNotificationConfigs`."
    def list_push_configs(%Client{} = client, task_id, opts \\ []) do
      map =
        %{"taskId" => task_id}
        |> put("pageSize", opts[:page_size])
        |> put("pageToken", opts[:page_token])
        |> put_tenant(client)

      unary(
        client,
        :list_task_push_notification_configs,
        Pb.ListTaskPushNotificationConfigsRequest,
        map,
        opts,
        fn result ->
          result
          |> Map.get("configs", [])
          |> Enum.reduce_while({:ok, []}, fn raw, {:ok, acc} ->
            case JSON.decode(raw, :push_notification_config) do
              {:ok, config} -> {:cont, {:ok, [config | acc]}}
              {:error, _} = error -> {:halt, error}
            end
          end)
          |> case do
            {:ok, configs} -> {:ok, Enum.reverse(configs)}
            error -> error
          end
        end
      )
    end

    @doc "`DeleteTaskPushNotificationConfig` (idempotent)."
    def delete_push_config(%Client{} = client, task_id, config_id, opts \\ []) do
      map = put_tenant(%{"taskId" => task_id, "id" => config_id}, client)

      case unary(
             client,
             :delete_task_push_notification_config,
             Pb.DeleteTaskPushNotificationConfigRequest,
             map,
             opts,
             fn _ -> {:ok, :deleted} end
           ) do
        {:ok, :deleted} -> :ok
        {:error, _} = error -> error
      end
    end

    @doc "`GetExtendedAgentCard`; present credentials with `headers:` (metadata)."
    def get_extended_card(%Client{} = client, opts \\ []) do
      unary(
        client,
        :get_extended_agent_card,
        Pb.GetExtendedAgentCardRequest,
        put_tenant(%{}, client),
        opts,
        &JSON.decode_agent_card/1
      )
    end

    defp unary(client, rpc, request_mod, map, opts, decode) do
      with {:ok, request} <- to_pb(map, request_mod),
           {:ok, reply} <- call_unary(client, rpc, request, opts) do
        decode.(to_map(reply))
      end
    end

    # Static dispatch (no apply/3): the closure court needs every edge visible.
    defp stub_unary(:send_message, ch, req, o), do: Stub.send_message(ch, req, o)
    defp stub_unary(:get_task, ch, req, o), do: Stub.get_task(ch, req, o)
    defp stub_unary(:cancel_task, ch, req, o), do: Stub.cancel_task(ch, req, o)
    defp stub_unary(:list_tasks, ch, req, o), do: Stub.list_tasks(ch, req, o)

    defp stub_unary(:create_task_push_notification_config, ch, req, o),
      do: Stub.create_task_push_notification_config(ch, req, o)

    defp stub_unary(:get_task_push_notification_config, ch, req, o),
      do: Stub.get_task_push_notification_config(ch, req, o)

    defp stub_unary(:list_task_push_notification_configs, ch, req, o),
      do: Stub.list_task_push_notification_configs(ch, req, o)

    defp stub_unary(:delete_task_push_notification_config, ch, req, o),
      do: Stub.delete_task_push_notification_config(ch, req, o)

    defp stub_unary(:get_extended_agent_card, ch, req, o),
      do: Stub.get_extended_agent_card(ch, req, o)

    defp stub_stream(:send_streaming_message, ch, req, o),
      do: Stub.send_streaming_message(ch, req, o)

    defp stub_stream(:subscribe_to_task, ch, req, o), do: Stub.subscribe_to_task(ch, req, o)

    defp call_unary(client, rpc, request, opts) do
      result =
        with_channel(client, fn channel ->
          stub_unary(rpc, channel, request, call_opts(client, opts, @default_timeout))
        end)

      case result do
        {:ok, reply} -> {:ok, reply}
        {:error, error} -> {:error, map_error(error)}
      end
    end

    # -- server streaming ----------------------------------------------------------

    @doc "`SendStreamingMessage`: `{:ok, stream}` of decoded events."
    def stream_message(%Client{} = client, message, opts \\ []) do
      {params, _req_opts} = Client.__build_send_params__(message, opts)

      map =
        params
        |> Map.take(["message", "configuration", "metadata", "artifactUpdates"])
        |> put_tenant(client)

      server_stream(client, :send_streaming_message, Pb.SendMessageRequest, map, opts)
    end

    @doc "`SubscribeToTask` (`:last_seen_generation`)."
    def resubscribe(%Client{} = client, task_id, opts \\ []) do
      map =
        %{"id" => task_id}
        |> put("lastSeenGeneration", opts[:last_seen_generation])
        |> put_tenant(client)

      server_stream(client, :subscribe_to_task, Pb.SubscribeToTaskRequest, map, opts)
    end

    defp server_stream(client, rpc, request_mod, map, opts) do
      with {:ok, request} <- to_pb(map, request_mod),
           {:ok, channel, owned?} <- acquire(client) do
        case stub_stream(rpc, channel, request, call_opts(client, opts, @stream_timeout)) do
          {:ok, replies} ->
            {:ok, wrap_stream(replies, fn -> release(channel, owned?) end, :events)}

          {:error, error} ->
            release(channel, owned?)
            {:error, map_error(error)}
        end
      end
    end

    defp wrap_stream(replies, release_fun, mode) do
      Stream.transform(
        replies,
        fn -> :ok end,
        fn item, acc -> {frames(item, mode), acc} end,
        fn acc -> {[], acc} end,
        fn _acc -> release_fun.() end
      )
    end

    defp frames({:ok, %Pb.StreamResponse{} = frame}, mode), do: decode_frame(frame, mode)
    defp frames({:error, error}, _mode), do: [{:error, map_error(error)}]
    defp frames(_other, _mode), do: []

    defp decode_frame(frame, mode) do
      case JSON.decode(to_map(frame), :event) do
        {:ok, %AshA2A.Protocol.StreamError{} = error} when mode == :live ->
          [{:stream_error, error}]

        {:ok, event} ->
          [event]

        {:skip, _reason} ->
          []

        {:error, reason} ->
          Logger.warning(
            "AshA2A.Protocol.Client.GRPC: dropped undecodable stream frame: #{inspect(reason)}"
          )

          []
      end
    end

    # -- live (bidirectional) ------------------------------------------------------

    @doc """
    Opens a `SendLiveMessage` session. `first_request` is a `StreamRequest`
    proto-JSON map (`%{"subscribe" => %{"id" => ..}}` /
    `%{"sendMessage" => %{"message" => ..}}`) or a `%Lf.A2a.V1.StreamRequest{}`.
    Options: `:track_generation`, `:last_seen_generation`, `:headers`, `:timeout`.
    """
    @spec open_live(Client.target(), map() | struct(), keyword()) ::
            {:ok, %{events: Enumerable.t(), session: session()}} | {:error, term()}
    def open_live(target, first_request, opts \\ []) do
      client = ensure_client(target)

      cond do
        client.transport != :grpc -> {:error, {:transport_unsupported, :grpc_live}}
        Client.__streaming_declared__(client) == false -> {:error, :streaming_not_supported}
        true -> do_open_live(client, first_request, opts)
      end
    end

    defp do_open_live(client, first_request, opts) do
      first =
        case first_request do
          %Pb.StreamRequest{} = request -> {:ok, request}
          %{} = map -> to_pb(put_tenant(map, client), Pb.StreamRequest)
        end

      with {:ok, request} <- first,
           {:ok, channel, owned?} <- acquire(client) do
        timeout = opts[:timeout] || @stream_timeout

        result =
          try do
            stream = Stub.send_live_message(channel, call_opts(client, opts, @stream_timeout))
            stream = GRPC.Stub.send_request(stream, request)

            case GRPC.Stub.recv(stream, timeout: timeout) do
              {:ok, replies} -> {:ok, stream, replies}
              {:error, error} -> {:error, map_error(error)}
            end
          catch
            :exit, reason -> {:error, {:grpc_exit, reason}}
          end

        case result do
          {:ok, stream, replies} ->
            events =
              replies
              |> wrap_stream(fn -> release(channel, owned?) end, :live)
              |> maybe_track(opts)

            {:ok,
             %{
               events: events,
               session: %Session{client: client, channel: channel, owned?: owned?, stream: stream}
             }}

          {:error, _} = error ->
            release(channel, owned?)
            error
        end
      end
    end

    @doc """
    Sends one more `StreamRequest` on the session. `message_or_map` is a text, a
    `%Message{}`, a ready `StreamRequest` map or an encoded message map.
    Options: `:if_generation_match`, `:configuration` (wire map). Returns `:ok`;
    the outcome arrives on the event stream.
    """
    @spec live_send(session(), term(), keyword()) :: :ok | {:error, term()}
    def live_send(%Session{client: client} = session, message_or_map, opts \\ []) do
      with {:ok, request} <-
             to_pb(put_tenant(build_live_request(message_or_map, opts), client), Pb.StreamRequest) do
        push(session, request)
      end
    end

    @doc "Sends a `subscribe` request on the session (`:last_seen_generation`)."
    @spec live_subscribe(session(), String.t(), keyword()) :: :ok | {:error, term()}
    def live_subscribe(%Session{client: client} = session, task_id, opts \\ []) do
      subscribe = put(%{"id" => task_id}, "lastSeenGeneration", opts[:last_seen_generation])

      with {:ok, request} <-
             to_pb(put_tenant(%{"subscribe" => subscribe}, client), Pb.StreamRequest) do
        push(session, request)
      end
    end

    @doc "Half-closes the uplink and releases the channel when the session owns it. Always `:ok`."
    @spec live_close(session()) :: :ok
    def live_close(%Session{stream: stream, channel: channel, owned?: owned?}) do
      try do
        GRPC.Stub.end_stream(stream)
      catch
        _, _ -> :ok
      end

      release(channel, owned?)
    end

    defp push(%Session{stream: stream}, request) do
      _ = GRPC.Stub.send_request(stream, request)
      :ok
    rescue
      e -> {:error, {:live_send_failed, Exception.message(e)}}
    catch
      :exit, reason -> {:error, {:live_closed, reason}}
    end

    defp build_live_request(%{} = map, _opts)
         when is_map_key(map, "sendMessage") or is_map_key(map, "subscribe"),
         do: map

    defp build_live_request(%AshA2A.Protocol.Message{} = message, opts) do
      {:ok, encoded} = JSON.encode(message)
      build_live_request(encoded, opts)
    end

    defp build_live_request(text, opts) when is_binary(text),
      do: build_live_request(AshA2A.Protocol.Message.new_user(text), opts)

    defp build_live_request(%{} = message_map, opts) do
      configuration =
        (opts[:configuration] || %{})
        |> put("ifGenerationMatch", opts[:if_generation_match])

      body =
        %{"message" => message_map}
        |> put("configuration", if(configuration == %{}, do: nil, else: configuration))

      %{"sendMessage" => body}
    end

    defp maybe_track(stream, opts) do
      if opts[:track_generation] do
        AshA2A.Protocol.Client.Generation.annotate(stream, last_seen: opts[:last_seen_generation])
      else
        stream
      end
    end

    defp ensure_client(%Client{} = client), do: client
    defp ensure_client(other), do: Client.new(other, transport: :grpc)

    # -- error mapping -------------------------------------------------------------

    @doc """
    Maps a `GRPC.RPCError` to the client's error vocabulary (see moduledoc).
    Non-RPC errors pass through unchanged.
    """
    @spec map_error(term()) :: term()
    def map_error(%GRPC.RPCError{status: status, message: message, details: details}) do
      info =
        details
        |> List.wrap()
        |> Enum.find_value(fn
          %Google.Protobuf.Any{value: value} -> decode_error_info(value)
          _ -> nil
        end)

      case info do
        %{reason: "TASK_GENERATION_MISMATCH"} = info ->
          {:task_generation_mismatch, %{metadata: info.metadata || %{}, message: message}}

        %{reason: reason} ->
          case Map.fetch(Client.__error_info_reasons__(), reason) do
            {:ok, atom} -> atom
            :error -> {:grpc_error, status, message}
          end

        nil ->
          case status do
            5 -> :task_not_found
            16 -> {:unauthorized, []}
            7 -> {:forbidden, message}
            _ -> {:grpc_error, status, message}
          end
      end
    end

    def map_error(other), do: other

    defp decode_error_info(value) do
      case Google.Rpc.ErrorInfo.decode(value) do
        %Google.Rpc.ErrorInfo{reason: reason} = info when reason not in [nil, ""] -> info
        _ -> nil
      end
    rescue
      _ -> nil
    end

    # -- helpers ---------------------------------------------------------------------

    defp decode_event(map) do
      case JSON.decode(map, :event) do
        {:ok, decoded} -> {:ok, decoded}
        {:skip, _} -> {:error, {:unexpected_body, map}}
        {:error, _} = error -> error
      end
    end

    defp to_pb(%{__struct__: _} = struct, _mod), do: {:ok, struct}

    defp to_pb(map, mod) do
      {:ok, map |> Jason.encode!() |> Protobuf.JSON.decode!(mod)}
    rescue
      e -> {:error, {:invalid_request, Exception.message(e)}}
    end

    defp to_map(pb), do: pb |> Protobuf.JSON.encode!() |> Jason.decode!()

    defp put(map, _key, nil), do: map
    defp put(map, key, value), do: Map.put(map, key, value)

    defp put_tenant(map, %Client{tenant: tenant}) when is_binary(tenant) and tenant != "",
      do: Map.put_new(map, "tenant", tenant)

    defp put_tenant(map, _client), do: map

    defp state_name(nil), do: nil
    defp state_name(name) when is_binary(name), do: name

    defp state_name(atom) when is_atom(atom),
      do: "TASK_STATE_" <> String.upcase(Atom.to_string(atom))

    defp timestamp(nil), do: nil
    defp timestamp(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
    defp timestamp(other), do: other

    defp call_opts(%Client{} = client, opts, default_timeout) do
      timeout =
        cond do
          opts[:timeout] -> opts[:timeout]
          default_timeout == @default_timeout -> unary_timeout(client, opts)
          true -> default_timeout
        end

      [metadata: metadata(client, opts), timeout: timeout]
    end

    # Long-poll: the deadline must outlast the server's hold.
    defp unary_timeout(client, opts) do
      base = Map.get(client.req.options, :receive_timeout) || @default_timeout

      if opts[:current_generation] != nil, do: base + @long_poll_margin, else: base
    end

    defp metadata(%Client{req: req, version: version}, opts) do
      base =
        for {name, values} <- req.headers,
            name not in ["content-type", "accept"],
            into: %{},
            do:
              {String.downcase(to_string(name)),
               values |> List.wrap() |> List.first() |> to_string()}

      extra =
        for {name, value} <- List.wrap(opts[:headers]),
            into: %{},
            do: {String.downcase(to_string(name)), to_string(value)}

      base
      |> Map.merge(extra)
      |> Map.put_new("a2a-version", version || "1.1")
    end
  end
end
