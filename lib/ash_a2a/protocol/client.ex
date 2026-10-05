if Code.ensure_loaded?(Req) do
  defmodule AshA2A.Protocol.Client do
    @moduledoc """
    HTTP client for consuming remote A2A agents.

    Provides discovery, synchronous messaging, SSE streaming, and task
    management using the A2A JSON-RPC protocol over HTTP.

    ## Quick Start

        # Discover an agent
        {:ok, card} = AshA2A.Protocol.Client.discover("https://agent.example.com")

        # Create a client and send a message
        client = AshA2A.Protocol.Client.new(card)
        {:ok, task} = AshA2A.Protocol.Client.send_message(client, "Hello!")

        # Stream a response
        {:ok, stream} = AshA2A.Protocol.Client.stream_message(client, "Count to 5")
        Enum.each(stream, &IO.inspect/1)

    ## Convenience Overloads

    All functions that accept a `%AshA2A.Protocol.Client{}` also accept a URL string
    or `%AshA2A.Protocol.AgentCard{}`:

        {:ok, task} = AshA2A.Protocol.Client.send_message("https://agent.example.com", "Hello!")
        {:ok, task} = AshA2A.Protocol.Client.send_message(card, "Hello!")

    ## Options

    Functions that send messages accept these options:

    - `:task_id` — continue an existing task (multi-turn)
    - `:context_id` — set the context ID
    - `:configuration` — `MessageSendConfiguration` map
    - `:metadata` — arbitrary metadata map
    - `:headers` — additional HTTP headers
    - `:timeout` — HTTP request timeout in ms

    ## Extensions

    Pass `:extensions` to `new/2` to declare A2A protocol extensions this
    client supports. Their declared URIs are sent in the `A2A-Extensions`
    request header on every call. Use `parse_extensions_header/1` and
    `activated/2` on the resulting `Req.Response` to find out which
    extensions the server activated.

    ## Protocol version

    Pass `:version` to `new/2` to set the `A2A-Version` request header
    sent on every call. Defaults to `AshA2A.Protocol.Version.default/0` (`"1.0"`).
    Use `version/1` on a `Req.Response` to read the version the server
    echoed back.

    ## HTTP+JSON transport (`:transport` option)

    Pass `transport: :http_json` to `new/2` to speak the A2A v1.0 spec's
    native HTTP+JSON (REST) binding (§5.3 "Method Mapping Reference")
    instead of JSON-RPC 2.0:

        client = AshA2A.Protocol.Client.new(url, transport: :http_json)

    The route and status mapping (§3.3.2/§5.4) then apply to
    `send_message/3`, `get_task/3`, `cancel_task/3`, `list_tasks/2`,
    the push-notification config functions and `get_extended_card/2`:

    - `send_message/3` -> `POST /message:send` (MessageSendParams body)
    - `get_task/3` -> `GET /tasks/{id}` (`:history_length` becomes the
      `historyLength` query parameter per §11.5)
    - `cancel_task/3` -> `POST /tasks/{id}:cancel`
    - `list_tasks/2` -> `GET /tasks` (options become query parameters per §11.5;
      the page envelope decodes via `AshA2A.Protocol.JSON.decode_list_result/1`)
    - `set_push_config/3` -> `POST /tasks/{id}/pushNotificationConfig`
    - `get_push_config/4` -> `GET /tasks/{id}/pushNotificationConfig/{cid}`
    - `list_push_configs/3` -> `GET /tasks/{id}/pushNotificationConfig`
    - `delete_push_config/4` -> `DELETE /tasks/{id}/pushNotificationConfig/{cid}`
    - `get_extended_card/2` -> `POST /agent` (present credentials with the
      `:headers` option; the bearer identity is verified by the server's auth
      plug before its `:extended_card` provider runs)

    `discover/2` is binding-independent (the §8.2 well-known card) and works
    in both modes. Operations with no §5.3 REST route (`stream_message/3`,
    `resubscribe/3`) answer `{:error, {:transport_unsupported, operation}}`
    in `:http_json` mode; `list_tasks/2` and `get_extended_card/2` answer it
    in `:jsonrpc` mode.
    Error responses are mapped to typed atoms: a `google.rpc.ErrorInfo`
    detail in the body's `"details"` names the failure (`TASK_NOT_FOUND` ->
    `:task_not_found`); a `404` whose body carries no ErrorInfo also maps to
    `:task_not_found`; anything unparseable comes back as
    `{:error, {:http_error, status, body}}`.

    ## Card signature verification

    Pass `verify_card_signature: key` to `new/2` or `discover/2` to verify the
    card's `signatures` JWS entries (see `AshA2A.Protocol.CardSigning`) before
    the card is trusted. Verification is fail-closed: a wrong key, tampered
    content, or a card served without signatures answers
    `{:error, {:card_signature, detail}}` — an unverified card is never
    returned when verification was requested. Without the option, discovery
    behaves exactly as before.
    """

    require Logger

    alias AshA2A.Protocol.JSONRPC.Error

    @type transport_mode :: :jsonrpc | :http_json

    @type target :: t() | AshA2A.Protocol.AgentCard.t() | String.t()

    @type t :: %__MODULE__{
            url: String.t(),
            req: Req.Request.t(),
            transport: transport_mode(),
            verify_card_signature: binary() | nil,
            extensions: [AshA2A.Protocol.Extension.compiled()]
          }

    defstruct [:url, :req, transport: :jsonrpc, verify_card_signature: nil, extensions: []]

    @doc """
    Creates a new client struct.

    Accepts a URL string or `%AshA2A.Protocol.AgentCard{}`. Options are forwarded to
    `Req.new/1` for customizing the HTTP client (headers, timeouts, etc.).

    ## Examples

        client = AshA2A.Protocol.Client.new("https://agent.example.com")
        client = AshA2A.Protocol.Client.new(card, headers: [{"authorization", "Bearer token"}])
    """
    @spec new(AshA2A.Protocol.AgentCard.t() | String.t(), keyword()) :: t()
    def new(url_or_card, opts \\ [])

    def new(%AshA2A.Protocol.AgentCard{url: url}, opts) do
      new(url, opts)
    end

    def new(url, opts) when is_binary(url) do
      {ext_entries, opts} = Keyword.pop(opts, :extensions, [])
      {version, opts} = Keyword.pop(opts, :version, AshA2A.Protocol.Version.default())
      {transport, opts} = Keyword.pop(opts, :transport, :jsonrpc)
      {verify_key, opts} = Keyword.pop(opts, :verify_card_signature)
      compiled = AshA2A.Protocol.Extension.compile(ext_entries)
      ext_uris = AshA2A.Protocol.Extension.declared_uris(compiled)

      unless transport in [:jsonrpc, :http_json] do
        raise ArgumentError,
              "invalid :transport #{inspect(transport)}; expected :jsonrpc or :http_json"
      end

      {req_opts, _rest} =
        Keyword.split(opts, [:headers, :connect_options, :retry, :plug])

      base_headers = [
        {"content-type", "application/json"},
        {"a2a-version", version}
      ]

      base_headers =
        case ext_uris do
          [] -> base_headers
          uris -> [{"a2a-extensions", Enum.join(uris, ", ")} | base_headers]
        end

      req =
        Req.new(
          Keyword.merge(
            [base_url: url, headers: base_headers],
            req_opts
          )
        )

      %__MODULE__{
        url: url,
        req: req,
        transport: transport,
        verify_card_signature: verify_key,
        extensions: compiled
      }
    end

    @doc """
    Discovers an agent by fetching its agent card.

    Sends `GET /.well-known/agent-card.json` and decodes the response
    into an `%AshA2A.Protocol.AgentCard{}`.

    Accepts a URL string, or a client built with `new/2` (its `:base_url`
    and any `verify_card_signature: key` configured there become the
    defaults, overridable per call).

    ## Options

    - `:headers` — additional HTTP headers
    - `:timeout` — HTTP request timeout in ms
    - `:agent_card_path` — custom discovery path
      (default: `"/.well-known/agent-card.json"`)
    - `:verify_card_signature` — HMAC key (`binary()`) used to verify the
      card's `signatures` entries via `AshA2A.Protocol.CardSigning.verify/2`
      before the card is returned. Fail-closed: a wrong key, tampered
      content, or a card served without signatures answers
      `{:error, {:card_signature, detail}}`. Omit the option (or pass only
      `new/2`'s default) to keep the previous unverified behavior.

    ## Examples

        {:ok, card} = AshA2A.Protocol.Client.discover("https://agent.example.com")
        card.name #=> "my-agent"

        {:ok, card} =
          AshA2A.Protocol.Client.discover("https://agent.example.com",
            verify_card_signature: signing_key
          )
    """
    @spec discover(t() | String.t(), keyword()) ::
            {:ok, AshA2A.Protocol.AgentCard.t()} | {:error, term()}
    def discover(target, opts \\ [])

    def discover(%__MODULE__{url: url, verify_card_signature: default_key}, opts) do
      discover(url, Keyword.put_new(opts, :verify_card_signature, default_key))
    end

    def discover(base_url, opts) when is_binary(base_url) do
      {verify_key, opts} = Keyword.pop(opts, :verify_card_signature)
      path = Keyword.get(opts, :agent_card_path, "/.well-known/agent-card.json")
      req_opts = take_req_opts(opts)

      # Route options through merge_req_opts/2 rather than passing them
      # straight to Req.new/1: it translates :timeout into Req's
      # :receive_timeout (Req has no :timeout option), matching how the
      # message-send functions handle it and keeping the :timeout option
      # documented on discover/2 working consistently.
      req = merge_req_opts(Req.new(base_url: base_url), req_opts)

      case Req.get(req, url: path) do
        {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
          body |> AshA2A.Protocol.JSON.decode_agent_card() |> admit_card(verify_key)

        {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
          with {:ok, decoded} <- Jason.decode(body),
               {:ok, card} <- AshA2A.Protocol.JSON.decode_agent_card(decoded) do
            admit_card({:ok, card}, verify_key)
          end

        {:ok, %Req.Response{status: status}} ->
          {:error, {:unexpected_status, status}}

        {:error, _} = error ->
          error
      end
    end

    # Fail-closed admission gate on the discovery path: when a verification
    # key was requested, the card is returned only if EVERY `signatures`
    # entry verifies (CardSigning.verify/2 itself refuses a card with no
    # signatures, so a vacuous all-verified admission is impossible). Any
    # failure is wrapped as {:card_signature, detail} — the unverified card
    # is never surfaced. No key -> the card passes through unchanged.
    defp admit_card({:ok, card}, nil), do: {:ok, card}

    defp admit_card({:ok, card}, key) when is_binary(key) do
      case AshA2A.Protocol.CardSigning.verify(card, key) do
        :ok -> {:ok, card}
        {:error, detail} -> {:error, {:card_signature, detail}}
      end
    end

    defp admit_card({:error, _} = error, _key), do: error

    @doc """
    Sends a message to an agent via `SendMessage`.

    Returns `{:ok, task}` on success, or `{:ok, message}` when the agent
    answers out-of-band with a bare `%AshA2A.Protocol.Message{}` — `SendMessageResponse`
    is a Task/Message oneof, so match on the struct to tell them apart.
    Returns `{:error, reason}` on failure. The message can be a string, an
    `%AshA2A.Protocol.Message{}`, or a list of parts.

    ## Options

    - `:task_id` — continue an existing task
    - `:context_id` — set the context ID
    - `:configuration` — `MessageSendConfiguration` map
    - `:metadata` — arbitrary metadata map
    - `:headers` — additional HTTP headers
    - `:timeout` — HTTP request timeout in ms

    ## Examples

        {:ok, task} = AshA2A.Protocol.Client.send_message(client, "Hello!")
        {:ok, task} = AshA2A.Protocol.Client.send_message(client, "More info", task_id: task.id)
    """
    @spec send_message(target(), AshA2A.Protocol.Message.t() | String.t(), keyword()) ::
            {:ok, AshA2A.Protocol.Task.t() | AshA2A.Protocol.Message.t()} | {:error, term()}
    def send_message(target, message, opts \\ []) do
      client = ensure_client(target)

      case client.transport do
        :http_json -> http_json_send_message(client, message, opts)
        :jsonrpc ->
          {params, req_opts} = build_send_params(message, opts)
          body = jsonrpc_request("SendMessage", params)

          case post(client, body, req_opts) do
            {:ok, response} -> decode_jsonrpc_result(response, :task)
            {:error, _} = error -> error
          end
      end
    end

    @doc """
    Sends a message and returns a stream of decoded SSE events.

    Uses `SendStreamingMessage` to receive server-sent events. Returns
    `{:ok, stream}` where the stream yields decoded structs
    (`%AshA2A.Protocol.Task{}`, `%AshA2A.Protocol.Event.StatusUpdate{}`, `%AshA2A.Protocol.Event.ArtifactUpdate{}`,
    or `%AshA2A.Protocol.Message{}`).

    ## Options

    Same as `send_message/3`.

    ## Examples

        {:ok, stream} = AshA2A.Protocol.Client.stream_message(client, "Count to 5")
        Enum.each(stream, fn
          %AshA2A.Protocol.Event.StatusUpdate{final: true} -> :done
          event -> IO.inspect(event)
        end)
    """
    @spec stream_message(target(), AshA2A.Protocol.Message.t() | String.t(), keyword()) ::
            {:ok, Enumerable.t()} | {:error, term()}
    def stream_message(target, message, opts \\ []) do
      client = ensure_client(target)

      case client.transport do
        :http_json -> transport_unsupported(:stream_message)
        :jsonrpc -> jsonrpc_stream_message(client, message, opts)
      end
    end

    defp jsonrpc_stream_message(client, message, opts) do
      {params, req_opts} = build_send_params(message, opts)
      body = jsonrpc_request("SendStreamingMessage", params)

      json_body = Jason.encode!(body)
      req = merge_req_opts(client.req, req_opts)

      case Req.post(req,
             body: json_body,
             headers: [{"accept", "text/event-stream"}],
             into: :self
           ) do
        {:ok, %Req.Response{status: 200, body: async}} ->
          stream = build_sse_stream(async)
          {:ok, stream}

        {:ok, %Req.Response{status: status}} ->
          {:error, {:unexpected_status, status}}

        {:error, _} = error ->
          error
      end
    end

    @doc """
    Reattaches to a running task's event stream via `SubscribeToTask`.

    Returns `{:ok, stream}` for a task still in progress. The first element is
    the task as it stands; subsequent elements are `%AshA2A.Protocol.Event.StatusUpdate{}`
    structs, and the stream ends when the task reaches a terminal state.

    A task that does not exist answers `TaskNotFoundError` and one that has
    already finished answers `UnsupportedOperationError` — both come back as
    `{:error, %AshA2A.Protocol.JSONRPC.Error{}}` rather than an empty stream.

    Events produced before the subscription are not replayed, so a caller that
    needs the full history should pair this with `get_task/3`.

    ## Options

    - `:history_length` — number of history entries to include in the snapshot
    - `:headers` — additional HTTP headers
    - `:timeout` — HTTP request timeout in ms

    ## Examples

        {:ok, stream} = AshA2A.Protocol.Client.resubscribe(client, "tsk-abc123")
        Enum.each(stream, &IO.inspect/1)
    """
    @spec resubscribe(target(), String.t(), keyword()) ::
            {:ok, Enumerable.t()} | {:error, term()}
    def resubscribe(target, task_id, opts \\ []) do
      client = ensure_client(target)

      case client.transport do
        :http_json -> transport_unsupported(:resubscribe)
        :jsonrpc -> jsonrpc_resubscribe(client, task_id, opts)
      end
    end

    defp jsonrpc_resubscribe(client, task_id, opts) do
      params =
        %{"id" => task_id}
        |> put_opt("historyLength", opts[:history_length])

      body = jsonrpc_request("SubscribeToTask", params)
      req = merge_req_opts(client.req, take_req_opts(opts))

      case Req.post(req,
             body: Jason.encode!(body),
             headers: [{"accept", "text/event-stream"}],
             into: :self
           ) do
        {:ok, %Req.Response{status: 200} = response} ->
          # Rejections arrive as an ordinary JSON-RPC body on a 200, so the
          # content type is what separates a stream from an error. Feeding an
          # error body to the SSE decoder would surface it as a dropped frame.
          if event_stream?(response) do
            {:ok, build_sse_stream(response.body)}
          else
            decode_jsonrpc_result(%{response | body: collect_async_body(response.body)}, :task)
          end

        {:ok, %Req.Response{status: status}} ->
          {:error, {:unexpected_status, status}}

        {:error, _} = error ->
          error
      end
    end

    defp event_stream?(response) do
      response
      |> Req.Response.get_header("content-type")
      |> Enum.any?(&String.starts_with?(&1, "text/event-stream"))
    end

    defp collect_async_body(async) do
      async |> Enum.to_list() |> IO.iodata_to_binary()
    end

    @doc """
    Retrieves a task by ID via `GetTask`.

    ## Options

    - `:history_length` — number of history entries to include
    - `:headers` — additional HTTP headers
    - `:timeout` — HTTP request timeout in ms

    ## Examples

        {:ok, task} = AshA2A.Protocol.Client.get_task(client, "tsk-abc123")
    """
    @spec get_task(target(), String.t(), keyword()) ::
            {:ok, AshA2A.Protocol.Task.t()} | {:error, term()}
    def get_task(target, task_id, opts \\ []) do
      client = ensure_client(target)

      case client.transport do
        :http_json -> http_json_get_task(client, task_id, opts)
        :jsonrpc ->
          req_opts = take_req_opts(opts)

          params =
            %{"id" => task_id}
            |> put_opt("historyLength", opts[:history_length])

          body = jsonrpc_request("GetTask", params)

          case post(client, body, req_opts) do
            {:ok, response} -> decode_jsonrpc_result(response, :task)
            {:error, _} = error -> error
          end
      end
    end

    @doc """
    Parses the `A2A-Extensions` header from a `Req.Response`. Returns the
    list of extension URIs the server activated for the corresponding
    request, or `[]` if the header is absent.

    HTTP headers may appear as a single comma-separated value or as
    multiple repeated headers; both are handled.
    """
    @spec parse_extensions_header(Req.Response.t()) :: [String.t()]
    def parse_extensions_header(%Req.Response{headers: headers}) do
      headers
      |> Map.get("a2a-extensions", [])
      |> List.wrap()
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
    end

    @doc """
    Returns the negotiated A2A protocol version from the server's
    `A2A-Version` response header, or `nil` if the header is absent.
    """
    @spec version(Req.Response.t()) :: String.t() | nil
    def version(%Req.Response{headers: headers}) do
      case Map.get(headers, "a2a-version") do
        nil -> nil
        [] -> nil
        [v | _] when is_binary(v) -> v
        v when is_binary(v) -> v
      end
    end

    @doc """
    Returns the configured extension modules whose URI appears in the
    server's `A2A-Extensions` response header.
    """
    @spec activated(t(), Req.Response.t()) :: [module()]
    def activated(%__MODULE__{extensions: compiled}, response) do
      activated = MapSet.new(parse_extensions_header(response))

      for {mod, _state, %AshA2A.Protocol.AgentExtension{uri: uri}} <- compiled,
          MapSet.member?(activated, uri),
          do: mod
    end

    @doc """
    Cancels a task by ID via `CancelTask`.

    ## Options

    - `:headers` — additional HTTP headers
    - `:timeout` — HTTP request timeout in ms

    ## Examples

        {:ok, task} = AshA2A.Protocol.Client.cancel_task(client, "tsk-abc123")
    """
    @spec cancel_task(target(), String.t(), keyword()) ::
            {:ok, AshA2A.Protocol.Task.t()} | {:error, term()}
    def cancel_task(target, task_id, opts \\ []) do
      client = ensure_client(target)

      case client.transport do
        :http_json -> http_json_cancel_task(client, task_id, opts)
        :jsonrpc ->
          req_opts = take_req_opts(opts)
          params = %{"id" => task_id}
          body = jsonrpc_request("CancelTask", params)

          case post(client, body, req_opts) do
            {:ok, response} -> decode_jsonrpc_result(response, :task)
            {:error, _} = error -> error
          end
      end
    end

    @doc """
    Lists the caller's tasks via the A2A v1.0 REST binding's `GET /tasks`.

    Returns `{:ok, page}` where `page` is the decoded `tasks/list` envelope:
    `%{tasks: [%AshA2A.Protocol.Task{}], total_size: integer() | nil,
    page_size: integer() | nil, next_page_token: String.t() | nil}`.

    The listing is owner-scoped server-side: only tasks the verified caller
    owns are returned.

    ## Options (§11.5 query parameters)

    - `:page_size` — 1..100
    - `:page_token` — continuation token from a previous page's `next_page_token`
    - `:status` — wire task-state string (e.g. `"TASK_STATE_COMPLETED"`)
    - `:context_id` — only tasks in this context
    - `:status_timestamp_after` — ISO 8601 timestamp
    - `:history_length` — history entries per returned task
    - `:include_artifacts` — boolean
    - `:headers` / `:timeout` — as on the other functions

    `:jsonrpc`-mode clients answer `{:error, {:transport_unsupported, :list_tasks}}`.

    ## Examples

        {:ok, page} = AshA2A.Protocol.Client.list_tasks(client)
        {:ok, page} = AshA2A.Protocol.Client.list_tasks(client, page_size: 1)
    """
    @spec list_tasks(target(), keyword()) ::
            {:ok,
             %{
               tasks: [AshA2A.Protocol.Task.t()],
               total_size: integer() | nil,
               page_size: integer() | nil,
               next_page_token: String.t() | nil
             }}
            | {:error, term()}
    def list_tasks(target, opts \\ []) do
      client = ensure_client(target)

      case client.transport do
        :http_json -> http_json_list_tasks(client, opts)
        :jsonrpc -> transport_unsupported(:list_tasks)
      end
    end

    @doc """
    Registers a push notification config for a task.

    The config's `:task_id` names the task; `:id` is assigned by the server
    when left `nil`. Returns the stored config. The server never echoes the
    webhook credentials back (`:authentication`'s credentials are write-only).

    In `:http_json` mode this is `POST /tasks/{task_id}/pushNotificationConfig`
    with a `pushNotificationConfig` body; a missing `:task_id` is refused
    `:task_not_found` without a round trip.

    ## Options

    - `:task_id` — override the config's task (REST binding)
    - `:headers` — additional HTTP headers
    - `:timeout` — HTTP request timeout in ms

    ## Examples

        config = %AshA2A.Protocol.PushNotificationConfig{
          task_id: "tsk-abc123",
          url: "https://example.com/webhook",
          authentication: %{scheme: "Bearer", credentials: "s3cret"}
        }

        {:ok, stored} = AshA2A.Protocol.Client.set_push_config(client, config)
    """
    @spec set_push_config(target(), AshA2A.Protocol.PushNotificationConfig.t(), keyword()) ::
            {:ok, AshA2A.Protocol.PushNotificationConfig.t()} | {:error, term()}
    def set_push_config(target, %AshA2A.Protocol.PushNotificationConfig{} = config, opts \\ []) do
      client = ensure_client(target)

      case client.transport do
        :http_json -> http_json_set_push_config(client, config, opts)
        :jsonrpc -> jsonrpc_set_push_config(client, config, opts)
      end
    end

    defp jsonrpc_set_push_config(client, config, opts) do
      req_opts = take_req_opts(opts)
      {:ok, params} = AshA2A.Protocol.JSON.encode(config)
      body = jsonrpc_request("CreateTaskPushNotificationConfig", params)

      case post(client, body, req_opts) do
        {:ok, response} -> decode_jsonrpc_result(response, :push_notification_config)
        {:error, _} = error -> error
      end
    end

    @doc """
    Retrieves a push notification config by task ID and config ID.

    In `:http_json` mode this is `GET /tasks/{task_id}/pushNotificationConfig/{config_id}`.

    ## Options

    - `:headers` — additional HTTP headers
    - `:timeout` — HTTP request timeout in ms
    """
    @spec get_push_config(target(), String.t(), String.t(), keyword()) ::
            {:ok, AshA2A.Protocol.PushNotificationConfig.t()} | {:error, term()}
    def get_push_config(target, task_id, config_id, opts \\ []) do
      client = ensure_client(target)

      case client.transport do
        :http_json -> http_json_get_push_config(client, task_id, config_id, opts)
        :jsonrpc -> jsonrpc_get_push_config(client, task_id, config_id, opts)
      end
    end

    defp jsonrpc_get_push_config(client, task_id, config_id, opts) do
      req_opts = take_req_opts(opts)
      params = %{"taskId" => task_id, "id" => config_id}
      body = jsonrpc_request("GetTaskPushNotificationConfig", params)

      case post(client, body, req_opts) do
        {:ok, response} -> decode_jsonrpc_result(response, :push_notification_config)
        {:error, _} = error -> error
      end
    end

    @doc """
    Lists every push notification config registered for a task.

    In `:http_json` mode this is `GET /tasks/{task_id}/pushNotificationConfig`.

    ## Options

    - `:headers` — additional HTTP headers
    - `:timeout` — HTTP request timeout in ms
    """
    @spec list_push_configs(target(), String.t(), keyword()) ::
            {:ok, [AshA2A.Protocol.PushNotificationConfig.t()]} | {:error, term()}
    def list_push_configs(target, task_id, opts \\ []) do
      client = ensure_client(target)

      case client.transport do
        :http_json -> http_json_list_push_configs(client, task_id, opts)
        :jsonrpc -> jsonrpc_list_push_configs(client, task_id, opts)
      end
    end

    defp jsonrpc_list_push_configs(client, task_id, opts) do
      req_opts = take_req_opts(opts)
      params = %{"taskId" => task_id}
      body = jsonrpc_request("ListTaskPushNotificationConfigs", params)

      case post(client, body, req_opts) do
        {:ok, response} -> decode_jsonrpc_result(response, :push_notification_configs)
        {:error, _} = error -> error
      end
    end

    @doc """
    Deletes a push notification config. Idempotent — deleting a config that is
    not registered succeeds.

    In `:http_json` mode this is `DELETE /tasks/{task_id}/pushNotificationConfig/{config_id}`.

    ## Options

    - `:headers` — additional HTTP headers
    - `:timeout` — HTTP request timeout in ms
    """
    @spec delete_push_config(target(), String.t(), String.t(), keyword()) ::
            :ok | {:error, term()}
    def delete_push_config(target, task_id, config_id, opts \\ []) do
      client = ensure_client(target)

      case client.transport do
        :http_json -> http_json_delete_push_config(client, task_id, config_id, opts)
        :jsonrpc -> jsonrpc_delete_push_config(client, task_id, config_id, opts)
      end
    end

    defp jsonrpc_delete_push_config(client, task_id, config_id, opts) do
      req_opts = take_req_opts(opts)
      params = %{"taskId" => task_id, "id" => config_id}
      body = jsonrpc_request("DeleteTaskPushNotificationConfig", params)

      case post(client, body, req_opts) do
        {:ok, response} -> decode_jsonrpc_result(response, :push_delete_ack)
        {:error, _} = error -> error
      end
    end

    @doc """
    Fetches the authenticated extended agent card via `POST /agent`
    (the A2A v1.0 REST binding's `agent/getAuthenticatedExtendedCard`).

    Present the caller's credentials with the `:headers` option (e.g.
    `headers: [{"authorization", "Bearer <token>"}]`); the server verifies
    them before its `:extended_card` provider runs, and success is the
    provider-extended card decoded into an `%AshA2A.Protocol.AgentCard{}`.

    Failures keep the client's typed mapping: no verified identity ->
    `{:error, {:http_error, 401, body}}`; no provider or a provider error ->
    `:extended_card_not_configured` — the public card is never substituted.

    `:jsonrpc`-mode clients answer `{:error, {:transport_unsupported, :get_extended_card}}`.

    ## Options

    - `:headers` — additional HTTP headers (the caller's credentials)
    - `:timeout` — HTTP request timeout in ms

    ## Examples

        {:ok, card} =
          AshA2A.Protocol.Client.get_extended_card(client,
            headers: [{"authorization", "Bearer " <> token}]
          )
    """
    @spec get_extended_card(target(), keyword()) ::
            {:ok, AshA2A.Protocol.AgentCard.t()} | {:error, term()}
    def get_extended_card(target, opts \\ []) do
      client = ensure_client(target)

      case client.transport do
        :http_json -> http_json_get_extended_card(client, opts)
        :jsonrpc -> transport_unsupported(:get_extended_card)
      end
    end

    # -------------------------------------------------------------------
    # Private — HTTP+JSON (REST) binding, A2A v1.0 spec §5.3
    # -------------------------------------------------------------------

    defp transport_unsupported(op), do: {:error, {:transport_unsupported, op}}

    # MessageSendParams body; the REST binding answers the raw Task/Message
    # JSON with no `{"task": ...}` oneof wrapper, so the discriminator is the
    # message's `"messageId"` key vs the task's `"status"` key.
    defp http_json_send_message(client, message, opts) do
      {params, req_opts} = build_send_params(message, opts)
      req = merge_req_opts(client.req, req_opts)

      case Req.post(req, url: "/message:send", json: params) do
        {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
          decode_rest_task_or_message(body)

        {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
          with {:ok, decoded} <- Jason.decode(body) do
            decode_rest_task_or_message(decoded)
          end

        {:ok, %Req.Response{status: status, body: body}} ->
          decode_http_error(status, body)

        {:error, _} = error ->
          error
      end
    end

    # The v1.0 REST binding answers `POST /message:send` with the
    # SendMessageResponse oneof wrapper `{"task" | "message"}`; the bare
    # Task/Message shapes stay tolerated (decode-only) so older peers that
    # answer the unwrapped object still decode.
    defp decode_rest_task_or_message(%{"task" => task}) do
      AshA2A.Protocol.JSON.decode(task, :task)
    end

    defp decode_rest_task_or_message(%{"message" => message}) when is_map(message) do
      AshA2A.Protocol.JSON.decode(message, :message)
    end

    defp decode_rest_task_or_message(%{"messageId" => _} = body) do
      AshA2A.Protocol.JSON.decode(body, :message)
    end

    defp decode_rest_task_or_message(body), do: AshA2A.Protocol.JSON.decode(body, :task)

    defp http_json_get_task(client, task_id, opts) do
      req_opts = take_req_opts(opts)
      req = merge_req_opts(client.req, req_opts)

      # §11.5: request parameters arrive as query parameters on the REST binding.
      request_opts =
        case opts[:history_length] do
          nil -> []
          history when is_integer(history) -> [params: [historyLength: history]]
        end

      url = "/tasks/" <> URI.encode(task_id, &URI.char_unreserved?/1)

      case Req.get(req, [url: url] ++ request_opts) do
        {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
          AshA2A.Protocol.JSON.decode(body, :task)

        {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
          with {:ok, decoded} <- Jason.decode(body) do
            AshA2A.Protocol.JSON.decode(decoded, :task)
          end

        {:ok, %Req.Response{status: status, body: body}} ->
          decode_http_error(status, body)

        {:error, _} = error ->
          error
      end
    end

    defp http_json_cancel_task(client, task_id, opts) do
      req_opts = take_req_opts(opts)
      req = merge_req_opts(client.req, req_opts)
      url = "/tasks/" <> URI.encode(task_id, &URI.char_unreserved?/1) <> ":cancel"

      case Req.post(req, url: url, json: %{}) do
        {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
          AshA2A.Protocol.JSON.decode(body, :task)

        {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
          with {:ok, decoded} <- Jason.decode(body) do
            AshA2A.Protocol.JSON.decode(decoded, :task)
          end

        {:ok, %Req.Response{status: status, body: body}} ->
          decode_http_error(status, body)

        {:error, _} = error ->
          error
      end
    end

    # -- GET /tasks ---------------------------------------------------------------

    # §5.3 tasks/list over REST; §11.5 puts the request parameters in the query
    # string. The page envelope is the same shape as the JSON-RPC `tasks/list`
    # result, so it decodes through `AshA2A.Protocol.JSON.decode_list_result/1`.
    defp http_json_list_tasks(client, opts) do
      req = merge_req_opts(client.req, take_req_opts(opts))

      params =
        []
        |> put_query_param(:pageSize, opts[:page_size])
        |> put_query_param(:pageToken, opts[:page_token])
        |> put_query_param(:status, opts[:status])
        |> put_query_param(:contextId, opts[:context_id])
        |> put_query_param(:statusTimestampAfter, opts[:status_timestamp_after])
        |> put_query_param(:historyLength, opts[:history_length])
        |> put_query_param(:includeArtifacts, opts[:include_artifacts])

      case Req.get(req, url: "/tasks", params: params) do
        {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
          AshA2A.Protocol.JSON.decode_list_result(body)

        {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
          with {:ok, decoded} <- Jason.decode(body) do
            AshA2A.Protocol.JSON.decode_list_result(decoded)
          end

        {:ok, %Req.Response{status: status, body: body}} ->
          decode_http_error(status, body)

        {:error, _} = error ->
          error
      end
    end

    defp put_query_param(list, _key, nil), do: list
    defp put_query_param(list, key, value), do: [{key, value} | list]

    # -- push-notification-config CRUD over the REST routes ------------------------
    #
    # The v1.0 REST mapping of the `tasks/pushNotificationConfig/*` JSON-RPC
    # methods. The wire resource is the TaskPushNotificationConfig wrapper
    # `{"taskId", "pushNotificationConfig"}`; the wrapper's taskId is folded
    # into the decoded config so `get_push_config/4` returns a fully-keyed
    # struct even though the inner object does not repeat it.

    @push_item_suffix "/pushNotificationConfig"

    defp push_item_url(task_id, suffix \\ "") do
      "/tasks/" <> URI.encode(task_id, &URI.char_unreserved?/1) <> @push_item_suffix <> suffix
    end

    defp http_json_set_push_config(client, config, opts) do
      with {:ok, task_id} <- push_task_id(config.task_id || opts[:task_id]) do
        {:ok, encoded} =
          AshA2A.Protocol.JSON.encode(%{config | task_id: config.task_id || task_id})

        req = merge_req_opts(client.req, take_req_opts(opts))

        case Req.post(req, url: push_item_url(task_id), json: %{"pushNotificationConfig" => encoded}) do
          {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
            decode_push_config_resource(body)

          {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
            decode_json_body_then(body, &decode_push_config_resource/1)

          {:ok, %Req.Response{status: status, body: body}} ->
            decode_http_error(status, body)

          {:error, _} = error ->
            error
        end
      end
    end

    defp http_json_get_push_config(client, task_id, config_id, opts) do
      req = merge_req_opts(client.req, take_req_opts(opts))
      url = push_item_url(task_id, "/" <> URI.encode(config_id, &URI.char_unreserved?/1))

      case Req.get(req, url: url) do
        {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
          decode_push_config_resource(body)

        {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
          decode_json_body_then(body, &decode_push_config_resource/1)

        {:ok, %Req.Response{status: status, body: body}} ->
          decode_http_error(status, body)

        {:error, _} = error ->
          error
      end
    end

    defp http_json_list_push_configs(client, task_id, opts) do
      req = merge_req_opts(client.req, take_req_opts(opts))

      case Req.get(req, url: push_item_url(task_id)) do
        {:ok, %Req.Response{status: 200, body: body}} when is_list(body) ->
          decode_push_config_list(body)

        {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
          decode_json_body_then(body, &decode_push_config_list/1)

        {:ok, %Req.Response{status: status, body: body}} ->
          decode_http_error(status, body)

        {:error, _} = error ->
          error
      end
    end

    defp http_json_delete_push_config(client, task_id, config_id, opts) do
      req = merge_req_opts(client.req, take_req_opts(opts))
      url = push_item_url(task_id, "/" <> URI.encode(config_id, &URI.char_unreserved?/1))

      case Req.delete(req, url: url) do
        {:ok, %Req.Response{status: 200}} -> :ok
        {:ok, %Req.Response{status: status, body: body}} -> decode_http_error(status, body)
        {:error, _} = error -> error
      end
    end

    defp decode_json_body_then(body, fun) do
      case Jason.decode(body) do
        {:ok, decoded} -> fun.(decoded)
        {:error, _} = error -> error
      end
    end

    defp decode_push_config_resource(%{"pushNotificationConfig" => inner} = wrapper)
         when is_map(inner) do
      case AshA2A.Protocol.JSON.decode(inner, :push_notification_config) do
        {:ok, config} -> {:ok, %{config | task_id: config.task_id || push_wrapper_task_id(wrapper)}}
        {:error, _} = error -> error
      end
    end

    defp decode_push_config_resource(body), do: AshA2A.Protocol.JSON.decode(body, :push_notification_config)

    defp decode_push_config_list(configs) when is_list(configs) do
      decoded =
        Enum.reduce_while(configs, {:ok, []}, fn raw, {:ok, acc} ->
          case decode_push_config_resource(raw) do
            {:ok, config} -> {:cont, {:ok, [config | acc]}}
            {:error, _} = error -> {:halt, error}
          end
        end)

      case decoded do
        {:ok, configs} -> {:ok, Enum.reverse(configs)}
        {:error, _} = error -> error
      end
    end

    defp decode_push_config_list(other), do: {:error, {:unexpected_body, other}}

    defp push_wrapper_task_id(%{"taskId" => id}) when is_binary(id), do: id
    defp push_wrapper_task_id(_), do: nil

    defp push_task_id(nil), do: {:error, :task_not_found}
    defp push_task_id(task_id) when is_binary(task_id), do: {:ok, task_id}

    # -- POST /agent (authenticated extended agent card) ---------------------------

    defp http_json_get_extended_card(client, opts) do
      req = merge_req_opts(client.req, take_req_opts(opts))

      case Req.post(req, url: "/agent", json: %{}) do
        {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
          AshA2A.Protocol.JSON.decode_agent_card(body)

        {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
          decode_json_body_then(body, &AshA2A.Protocol.JSON.decode_agent_card/1)

        {:ok, %Req.Response{status: status, body: body}} ->
          decode_http_error(status, body)

        {:error, _} = error ->
          error
      end
    end

    # §3.3.2/§5.4 error mapping: a `google.rpc.ErrorInfo` detail in the body's
    # `"details"` names the failure as a typed atom; a bare 404 (no ErrorInfo)
    # is task-not-found; anything unparseable stays
    # `{:error, {:http_error, status, body}}`.
    @error_info_type "type.googleapis.com/google.rpc.ErrorInfo"

    @error_info_reasons %{
      "TASK_NOT_FOUND" => :task_not_found,
      "TASK_NOT_CANCELABLE" => :task_not_cancelable,
      "UNSUPPORTED_OPERATION" => :unsupported_operation,
      "INVALID_PARAMS" => :invalid_params,
      "INVALID_REQUEST" => :invalid_request,
      "PUSH_NOTIFICATION_NOT_SUPPORTED" => :push_notification_not_supported,
      "CONTENT_TYPE_NOT_SUPPORTED" => :content_type_not_supported,
      "INVALID_AGENT_RESPONSE" => :invalid_agent_response,
      "EXTENDED_AGENT_CARD_NOT_CONFIGURED" => :extended_card_not_configured,
      "EXTENSION_SUPPORT_REQUIRED" => :extension_support_required,
      "VERSION_NOT_SUPPORTED" => :version_not_supported
    }

    defp decode_http_error(status, body) when is_binary(body) do
      case Jason.decode(body) do
        {:ok, decoded} when is_map(decoded) -> decode_http_error(status, decoded)
        _ -> {:error, {:http_error, status, body}}
      end
    end

    # The v1.0 REST binding wraps errors in the AIP-193 envelope
    # `{"error": {...}}` (HTTP_JSON-ERR-001); the flat shapes stay tolerated
    # (decode-only) for older peers. `error.code` is the HTTP status there,
    # not the A2A code, so the ErrorInfo reason inside `details` stays the
    # discriminator.
    defp decode_http_error(status, %{"error" => inner}) when is_map(inner) do
      decode_http_error(status, Map.put(inner, "code", status))
    end

    defp decode_http_error(status, %{"details" => details} = body) when is_list(details) do
      reason =
        Enum.find_value(details, fn
          %{"@type" => @error_info_type, "reason" => reason} -> reason
          _ -> nil
        end)

      case reason && Map.fetch(@error_info_reasons, reason) do
        {:ok, atom} ->
          {:error, atom}

        nil ->
          status_fallback(status, body)

        :error ->
          # A live ErrorInfo reason with no client-side mapping stays raw so
          # the caller sees the server's actual vocabulary, not a guess.
          {:error, {:http_error, status, body}}
      end
    end

    defp decode_http_error(status, body), do: status_fallback(status, body)

    defp status_fallback(404, _body), do: {:error, :task_not_found}

    defp status_fallback(status, body), do: {:error, {:http_error, status, body}}

    defp jsonrpc_request(method, params) do
      %{
        "jsonrpc" => "2.0",
        "id" => generate_id(),
        "method" => method,
        "params" => params
      }
    end

    defp generate_id do
      System.unique_integer([:positive, :monotonic])
    end

    defp build_send_params(message, opts) do
      req_opts = take_req_opts(opts)
      msg = message |> normalize_message() |> put_message_ids(opts)
      {:ok, encoded_msg} = AshA2A.Protocol.JSON.encode(msg)

      params =
        %{"message" => encoded_msg}
        |> put_opt("id", opts[:task_id])
        |> put_opt("contextId", opts[:context_id])
        |> put_opt("configuration", encode_configuration(opts[:configuration]))
        |> put_opt("metadata", opts[:metadata])

      {params, req_opts}
    end

    # The A2A spec carries `taskId`/`contextId` on the Message. Some servers
    # (e.g. the reference JS SDK) read them only from the message and ignore the
    # top-level params, so mirror the options onto the message struct. An id set
    # explicitly on the struct takes precedence over the option.
    defp put_message_ids(%AshA2A.Protocol.Message{} = msg, opts) do
      %{
        msg
        | task_id: msg.task_id || opts[:task_id],
          context_id: msg.context_id || opts[:context_id]
      }
    end

    defp normalize_message(%AshA2A.Protocol.Message{} = msg), do: msg

    defp normalize_message(text) when is_binary(text) do
      AshA2A.Protocol.Message.new_user(text)
    end

    defp encode_configuration(nil), do: nil

    defp encode_configuration(config) when is_map(config) do
      AshA2A.Protocol.JSON.encode_known_keys(config, [
        {"acceptedOutputModes", :accepted_output_modes},
        {"blocking", :blocking},
        {"historyLength", :history_length}
      ])
    end

    defp put_opt(map, _key, nil), do: map
    defp put_opt(map, key, value), do: Map.put(map, key, value)

    # -------------------------------------------------------------------
    # Private — HTTP helpers
    # -------------------------------------------------------------------

    defp post(client, body, req_opts) do
      json_body = Jason.encode!(body)
      req = merge_req_opts(client.req, req_opts)
      Req.post(req, body: json_body)
    end

    defp merge_req_opts(req, []), do: req

    defp merge_req_opts(req, opts) do
      Enum.reduce(opts, req, fn
        {:headers, headers}, req -> Req.merge(req, headers: headers)
        {:timeout, timeout}, req -> Req.merge(req, receive_timeout: timeout)
        {:plug, plug}, req -> Req.merge(req, plug: plug)
        _, req -> req
      end)
    end

    defp take_req_opts(opts) do
      Keyword.take(opts, [:headers, :timeout, :plug])
    end

    defp ensure_client(%__MODULE__{} = client), do: client
    defp ensure_client(%AshA2A.Protocol.AgentCard{} = card), do: new(card)
    defp ensure_client(url) when is_binary(url), do: new(url)

    # -------------------------------------------------------------------
    # Private — Response decoding
    # -------------------------------------------------------------------

    defp decode_jsonrpc_result(%Req.Response{body: body}, type)
         when is_map(body) do
      decode_jsonrpc_body(body, type)
    end

    defp decode_jsonrpc_result(%Req.Response{status: status, body: body}, _type)
         when is_binary(body) and status not in 200..299 do
      # A non-2xx response is an HTTP-level refusal, not a decode problem:
      # never surface a Jason.DecodeError (Z3's mismatch matrix, case e1).
      {:error, {:http_error, status, body}}
    end

    defp decode_jsonrpc_result(%Req.Response{body: body}, type)
         when is_binary(body) do
      case Jason.decode(body) do
        {:ok, decoded} -> decode_jsonrpc_body(decoded, type)
        {:error, _} = error -> error
      end
    end

    defp decode_jsonrpc_body(%{"error" => error_map}, _type) do
      {:error,
       %Error{
         code: error_map["code"],
         message: error_map["message"],
         data: error_map["data"]
       }}
    end

    # Result oneof: {"task": Task} or {"message": Message} (v0.3 and v1.0 both
    # use these keys). v1.0 StreamResponse-wrapped event frames —
    # {"statusUpdate": ...} / {"artifactUpdate": ...}, plus the snake_case
    # spelling the v1.0 schema's patternProperties accept — are tolerated on
    # the same path so a v1.0 peer's frames decode end to end. Tolerance is
    # decode-only, mirroring the codec rule in AshA2A.Protocol.JSON: v1.0 is
    # the primary shape, v0.3 bare/kind-tagged frames still decode via the
    # :event fallback below.
    defp decode_jsonrpc_body(%{"result" => %{"task" => task}}, :task) do
      AshA2A.Protocol.JSON.decode(task, :task)
    end

    defp decode_jsonrpc_body(%{"result" => %{"message" => message}}, :task) do
      AshA2A.Protocol.JSON.decode(message, :message)
    end

    defp decode_jsonrpc_body(%{"result" => %{"statusUpdate" => event}}, :task) do
      AshA2A.Protocol.JSON.decode(event, :status_update_event)
    end

    defp decode_jsonrpc_body(%{"result" => %{"artifactUpdate" => event}}, :task) do
      AshA2A.Protocol.JSON.decode(event, :artifact_update_event)
    end

    defp decode_jsonrpc_body(%{"result" => %{"status_update" => event}}, :task) do
      AshA2A.Protocol.JSON.decode(event, :status_update_event)
    end

    defp decode_jsonrpc_body(%{"result" => %{"artifact_update" => event}}, :task) do
      AshA2A.Protocol.JSON.decode(event, :artifact_update_event)
    end

    defp decode_jsonrpc_body(%{"result" => result}, :push_notification_configs) do
      configs = Map.get(result, "configs", [])

      decoded =
        Enum.reduce_while(configs, {:ok, []}, fn raw, {:ok, acc} ->
          case AshA2A.Protocol.JSON.decode(raw, :push_notification_config) do
            {:ok, config} -> {:cont, {:ok, [config | acc]}}
            {:error, _} = error -> {:halt, error}
          end
        end)

      case decoded do
        {:ok, configs} -> {:ok, Enum.reverse(configs)}
        {:error, _} = error -> error
      end
    end

    defp decode_jsonrpc_body(%{"result" => _result}, :push_delete_ack), do: :ok

    defp decode_jsonrpc_body(%{"result" => result}, type) do
      AshA2A.Protocol.JSON.decode(result, type)
    end

    defp decode_jsonrpc_body(body, _type) do
      {:error, {:unexpected_body, body}}
    end

    # -------------------------------------------------------------------
    # Private — SSE streaming
    # -------------------------------------------------------------------

    defp build_sse_stream(async) do
      async
      |> Stream.transform(AshA2A.Protocol.Client.SSE.new(), fn chunk, sse_state ->
        {events, new_sse} = AshA2A.Protocol.Client.SSE.feed(sse_state, chunk)
        decoded = decode_sse_events(events)
        {decoded, new_sse}
      end)
    end

    # A dropped event is invisible to the caller, so it has to be loud here:
    # an encoder/decoder disagreement silently truncated every stream until
    # this logged.
    defp decode_sse_events(events) do
      Enum.flat_map(events, fn
        %{"result" => result} ->
          case AshA2A.Protocol.JSON.decode(result, :event) do
            {:ok, decoded} ->
              [decoded]

            {:error, reason} ->
              Logger.warning("AshA2A.Protocol.Client: dropped undecodable stream event: #{inspect(reason)}")
              []
          end

        # Decode-only tolerance: some v1.0 peers emit the StreamResponse
        # wrapper as the data frame itself, without a JSON-RPC envelope.
        %{"task" => _} = frame ->
          decode_bare_frame(frame)

        %{"message" => _} = frame ->
          decode_bare_frame(frame)

        %{"statusUpdate" => _} = frame ->
          decode_bare_frame(frame)

        %{"artifactUpdate" => _} = frame ->
          decode_bare_frame(frame)

        other ->
          Logger.warning("AshA2A.Protocol.Client: dropped stream frame with no result: #{inspect(other)}")
          []
      end)
    end

    defp decode_bare_frame(frame) do
      case AshA2A.Protocol.JSON.decode(frame, :event) do
        {:ok, decoded} ->
          [decoded]

        {:error, reason} ->
          Logger.warning("AshA2A.Protocol.Client: dropped undecodable stream event: #{inspect(reason)}")
          []
      end
    end
  end
end
