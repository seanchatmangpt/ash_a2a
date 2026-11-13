if Code.ensure_loaded?(Req) do
  defmodule AshA2A.Protocol.Client.Live do
    @moduledoc """
    Client for A2A v1.1 `SendLiveMessage` (spec 3.1.12) over the HTTP+JSON binding.

    On HTTP the invoking call's response is the **downlink** and stays open; later
    input goes through **additional short-lived `POST /message:live` calls** that
    return only an acknowledgement (the current `Task`) and never replay events.

        {:ok, %{events: events, session: session}} =
          Live.open(client, %{"subscribe" => %{"id" => task_id}})

        {:ok, ack_task} = Live.send_message(session, "more input")
        :ok = Live.close(session)

    ## Session correlation

    The server's session id is read from the downlink response header
    `a2a-live-session-id` (override with `Live.open(..., session_id: id)`). Uplink
    calls carry it as the `a2a-live-session-id` header and the `live_session_id`
    query parameter. With no id the server routes an uplink by the request's
    `taskId` (spec: a session of the same principal bound to that task).

    ## Events

    `events` is a lazy stream of decoded `StreamResponse` payloads: `%Task{}`,
    `%Event.StatusUpdate{}`, `%Event.ArtifactUpdate{}`, `%Event.MessageUpdate{}`,
    `%Message{}`, and `{:stream_error, %StreamError{}}` for non-fatal rejections
    (the stream continues). Unknown payload kinds are skipped. Option
    `track_generation: true` wraps elements via
    `AshA2A.Protocol.Client.Generation.annotate/2`.

    The async response is owned by the process that consumes `events`; call
    `close/1` from that process. The stream also cancels the response when it
    ends or halts early.
    """

    alias AshA2A.Protocol.Client
    alias AshA2A.Protocol.JSON
    alias AshA2A.Protocol.StreamError

    @session_header "a2a-live-session-id"

    defmodule Session do
      @moduledoc false
      defstruct [:client, :session_id, :response]
    end

    @type session :: %Session{}

    @doc """
    Opens a live session. `first_request` is a `StreamRequest` map
    (`%{"subscribe" => %{"id" => ..., "lastSeenGeneration" => n}}` or
    `%{"sendMessage" => %{"message" => ...}}`).

    Returns `{:ok, %{events: Enumerable.t(), session: session()}}` or
    `{:error, reason}` (typed like `Client` errors). `:jsonrpc` clients answer
    `{:error, {:transport_unsupported, :live}}`.

    Options: `:session_id`, `:track_generation`, `:headers`, `:timeout`.
    """
    @spec open(Client.target(), map(), keyword()) ::
            {:ok, %{events: Enumerable.t(), session: session()}} | {:error, term()}
    def open(target, first_request, opts \\ []) when is_map(first_request) do
      client = ensure_client(target)

      cond do
        client.transport != :http_json ->
          {:error, {:transport_unsupported, :live}}

        Client.__streaming_declared__(client) == false ->
          {:error, :streaming_not_supported}

        true ->
          do_open(client, first_request, opts)
      end
    end

    defp do_open(client, first_request, opts) do
      req = merge_opts(client.req, opts)

      result =
        Req.post(req,
          url: "/message:live",
          json: first_request,
          headers: [{"accept", "text/event-stream"}],
          into: :self,
          retry: false
        )

      case result do
        {:ok, %Req.Response{status: 200} = response} ->
          if Client.__event_stream__?(response) do
            events =
              response
              |> Client.__response_stream__()
              |> Stream.map(&surface_error/1)
              |> maybe_track(opts)

            session = %Session{
              client: client,
              session_id: opts[:session_id] || session_id_header(response),
              response: response
            }

            {:ok, %{events: events, session: session}}
          else
            Client.__stream_error__(client, response)
          end

        {:ok, %Req.Response{} = response} ->
          Client.__stream_error__(client, response)

        {:error, _} = error ->
          error
      end
    end

    @doc """
    Sends one more request on the session (a short-lived `POST /message:live`) and
    returns the acknowledgement. `message_or_map` is a text, a
    `%AshA2A.Protocol.Message{}`, a ready `StreamRequest` map (has a
    `"sendMessage"`/`"subscribe"` key) or an encoded message map.

    Options: `:if_generation_match`, `:configuration` (wire map), `:headers`,
    `:timeout`. Answers `{:ok, %Task{} | %Message{} | nil}` or `{:error, reason}`
    (a `StreamError` rejection of a session-less call is `{:error, %StreamError{}}`).
    """
    @spec send_message(session(), term(), keyword()) :: {:ok, term()} | {:error, term()}
    def send_message(%Session{} = session, message_or_map, opts \\ []) do
      uplink(session, build_request(message_or_map, opts), opts)
    end

    @doc false
    @spec uplink(session(), map(), keyword()) :: {:ok, term()} | {:error, term()}
    def uplink(%Session{client: client, session_id: sid}, request, opts \\ []) do
      req = merge_opts(client.req, opts)

      {headers, params} =
        case sid do
          nil -> {[], []}
          id -> {[{@session_header, id}], [live_session_id: id]}
        end

      case Req.post(req, url: "/message:live", json: request, headers: headers, params: params, retry: false) do
        {:ok, %Req.Response{status: 200, body: body}} -> decode_ack(body)
        {:ok, %Req.Response{status: status, body: body}} -> Client.__decode_http_error__(status, body)
        {:error, _} = error -> error
      end
    end

    @doc """
    Closes the session by cancelling the downlink response. Call from the process
    that consumes `events`. Always `:ok`.
    """
    @spec close(session()) :: :ok
    def close(%Session{response: response}) do
      Req.cancel_async_response(response)
      :ok
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    # -- helpers ----------------------------------------------------------------

    defp build_request(%{} = map, _opts) when is_map_key(map, "sendMessage") or is_map_key(map, "subscribe"),
      do: map

    defp build_request(%AshA2A.Protocol.Message{} = message, opts) do
      {:ok, encoded} = JSON.encode(message)
      build_request(encoded, opts)
    end

    defp build_request(text, opts) when is_binary(text),
      do: build_request(AshA2A.Protocol.Message.new_user(text), opts)

    defp build_request(%{} = message_map, opts) do
      configuration =
        (opts[:configuration] || %{})
        |> put_if("ifGenerationMatch", opts[:if_generation_match])

      send_message_body =
        %{"message" => message_map}
        |> put_if("configuration", if(configuration == %{}, do: nil, else: configuration))

      %{"sendMessage" => send_message_body}
    end

    defp put_if(map, _key, nil), do: map
    defp put_if(map, key, value), do: Map.put(map, key, value)

    defp surface_error(%StreamError{} = error), do: {:stream_error, error}
    defp surface_error(other), do: other

    defp maybe_track(stream, opts) do
      if opts[:track_generation] do
        AshA2A.Protocol.Client.Generation.annotate(stream, last_seen: opts[:last_seen_generation])
      else
        stream
      end
    end

    defp session_id_header(response) do
      case Req.Response.get_header(response, @session_header) do
        [id | _] -> id
        [] -> nil
      end
    end

    # The ack is the current Task (wrapped `{"task": ..}` or bare), or a Message.
    defp decode_ack(body) when is_binary(body) do
      case Jason.decode(body) do
        {:ok, decoded} -> decode_ack(decoded)
        {:error, _} = error -> error
      end
    end

    defp decode_ack(%{"task" => task}) when is_map(task), do: JSON.decode(task, :task)
    defp decode_ack(%{"message" => message}) when is_map(message), do: JSON.decode(message, :message)
    defp decode_ack(%{"error" => %{} = inner}) do
      case JSON.decode(inner, :stream_error) do
        {:ok, error} -> {:error, error}
        other -> other
      end
    end

    defp decode_ack(%{"id" => _, "status" => _} = body), do: JSON.decode(body, :task)
    defp decode_ack(%{} = body) when map_size(body) == 0, do: {:ok, nil}
    defp decode_ack(other), do: {:error, {:unexpected_body, other}}

    defp merge_opts(req, opts) do
      Enum.reduce(opts, req, fn
        {:headers, headers}, req -> Req.merge(req, headers: headers)
        {:timeout, timeout}, req -> Req.merge(req, receive_timeout: timeout)
        _, req -> req
      end)
    end

    defp ensure_client(%Client{} = client), do: client
    defp ensure_client(other), do: Client.new(other, transport: :http_json)
  end
end
