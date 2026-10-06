# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Transport.Plug do
  @moduledoc """
  Owner-scoped A2A HTTP transport for `AshA2A.Agent` processes.

  A drop-in replacement for `AshA2A.Protocol.Plug` (same `:agent`, `:base_url`,
  `:agent_card_path`, `:json_rpc_path`, `:agent_card_opts`, `:metadata`
  options) that closes the gaps the vendored plug cannot:

    * **Task ownership (SEC-01).** `tasks/get`, `tasks/cancel` and
      `tasks/list` are answered only for tasks the verified caller owns
      (`AshA2A.Transport.Principal` of `conn.private[:a2a][:auth][:identity]`).
      A task owned by someone else is `-32001 task not found`, never `403`,
      so its existence is not revealed. Continuation (`message/send` with a
      `taskId`) is enforced inside the agent itself
      (`AshA2A.Transport.Runtime`), so it holds for every transport.
    * **Unforgeable auth.** The verified `"a2a.auth"` is put into the call
      metadata *after* the caller's `params.metadata` merge, so a caller can
      never overwrite it (the vendored plug merges caller metadata last).
    * **No credential echo.** Task results are stripped of `"a2a.auth"` and
      the owner key before encoding; the vendored plug echoes the verified
      identity map (tokens included) back in `task.metadata`.
    * **Typed transport errors.** Admission refusals map to JSON-RPC codes
      (`server_busy`/`rate_limited` -> `-32000`, unknown/foreign task ->
      `-32001`); anything else is an `internal_error` with an opaque `ref`,
      never `inspect/1` of an internal reason (SEC-08).
    * **`message/stream` for every skill (TQ-05).** A streaming skill's parts
      are sent as v1.0 `{"artifactUpdate": ...}` SSE frames; a non-streaming reply (an ordinary
      read/generic action) is sent as a task snapshot, one `ArtifactUpdate`
      per artifact, and a final `StatusUpdate` carrying the task's real
      state -- instead of the vendored plug's `{:not_streaming, task}` JSON
      error.
    * **Truthful AgentCard (CONF-06, CONF-09).** `capabilities.streaming` is
      `true`, `pushNotifications` reflects the `:push_notifications` option
      (default `false`), and the SA2A profile is advertised at the
      spec-mandated `capabilities.extensions` site whenever the card's
      `supportedInterfaces` already carry it (`AshA2A.Semantic.Extension.
      advertise/1`), or when passed explicitly via `:extensions`.

  Mount it after `AshA2A.Protocol.Plug.Auth`:

      plug AshA2A.Protocol.Plug.Auth, verify: &MyApp.verify/3
      plug AshA2A.Transport.Plug, agent: MyAgent, base_url: "https://x/a2a"

  `:max_body_bytes` (default 1_000_000) bounds the JSON-RPC body read.

  Passing `serve_schemas: true` (with the `:schema_index` capability-index
  source) also mounts the machine-readable schema endpoints
  (`AshA2A.Transport.SchemaEndpoints`): `GET /.well-known/agent-card.schema.json`
  and `GET /.well-known/skills.schema.json`. Default off -- both paths then
  answer `404` like any other unserved path.

  A mount with `force_ssl: [rewrite_on: [:x_forwarded_proto]]` (the prod
  posture `config/prod.exs` states for the transport) refuses plaintext
  requests behind a proxy that sets `x-forwarded-proto: http` with
  `400 Bad Request` and serves `strict-transport-security` on every response.
  The default (`nil`) does not enforce.
  """

  @behaviour Plug
  @behaviour AshA2A.Protocol.JSONRPC

  import Plug.Conn

  alias AshA2A.Protocol.JSONRPC.{Error, Response}
  alias AshA2A.Transport.{Principal, Runtime, SafeError}

  @doc "Typed transport refusal codes, classified for S42 totality."
  @spec __sa2a_refusal_codes__() :: %{atom() => atom()}
  def __sa2a_refusal_codes__ do
    %{
      body_too_large: :refused_bounds,
      parse_error: :refused_structure,
      invalid_page_token: :refused_structure
    }
  end

  @impl Plug
  @spec init(keyword()) :: map()
  def init(opts) do
    %{
      agent: Keyword.fetch!(opts, :agent),
      base_url: Keyword.get(opts, :base_url),
      agent_card_path: Keyword.get(opts, :agent_card_path, [".well-known", "agent-card.json"]),
      json_rpc_path: Keyword.get(opts, :json_rpc_path, []),
      agent_card_opts: Keyword.get(opts, :agent_card_opts, []),
      metadata: Keyword.get(opts, :metadata, %{}),
      max_body_bytes: Keyword.get(opts, :max_body_bytes, 1_000_000),
      push_notifications: Keyword.get(opts, :push_notifications, false),
      extensions: Keyword.get(opts, :extensions, []),
      force_ssl: Keyword.get(opts, :force_ssl, nil)
    }
    |> Map.merge(AshA2A.Transport.SchemaEndpoints.init(opts))
  end

  @impl Plug
  @spec call(Plug.Conn.t(), map()) :: Plug.Conn.t()
  # Prod hardening (sobelow Config.HTTPS): a mount that passes `:force_ssl`
  # refuses plaintext behind a proxy (`x-forwarded-proto: http`) and serves
  # HSTS. Correctness of the check precedes routing, so it runs before the
  # agent-card / JSON-RPC / schema dispatch clauses below.
  def call(conn, %{force_ssl: force_ssl} = opts) when force_ssl != nil do
    conn =
      put_resp_header(conn, "strict-transport-security", hsts_header(force_ssl))

    case get_req_header(conn, "x-forwarded-proto") do
      ["http" | _] ->
        conn
        |> put_resp_header("content-type", "text/plain; charset=utf-8")
        |> send_resp(400, "HTTPS required")
        |> halt()

      _ ->
        call(conn, Map.delete(opts, :force_ssl))
    end
  end

  def call(%{method: "GET", path_info: path} = conn, %{agent_card_path: path} = opts) do
    serve_agent_card(conn, opts)
  end

  def call(%{method: "POST", path_info: path} = conn, %{json_rpc_path: path} = opts) do
    handle_json_rpc(conn, opts)
  end

  def call(%{path_info: path} = conn, %{agent_card_path: path}) do
    conn |> put_resp_header("allow", "GET") |> send_resp(405, "Method Not Allowed")
  end

  # Machine-readable schema endpoints (mounted only when `serve_schemas: true`;
  # disabled the helper answers :next and these paths fall through to 404).
  # Membership is tested in the body, not a guard: `SchemaEndpoints.paths/0`
  # is a runtime list, and a guard's `in` right operand must be compile-time.
  def call(%{path_info: path} = conn, opts) do
    if Enum.member?(AshA2A.Transport.SchemaEndpoints.paths(), path) do
      case AshA2A.Transport.SchemaEndpoints.serve(conn, opts) do
        %Plug.Conn{} = conn -> conn
        :next -> send_resp(conn, 404, "Not Found")
      end
    else
      send_resp(conn, 404, "Not Found")
    end
  end

  def call(conn, _opts), do: send_resp(conn, 404, "Not Found")

  # -- agent card ------------------------------------------------------------

  @doc """
  The wire AgentCard JSON map this plug serves: the vendored encoder's output
  with truthful `capabilities` and `capabilities.extensions` added.
  """
  @spec agent_card_json(map(), map(), String.t()) :: map()
  def agent_card_json(card, opts, base_url) do
    card_opts = [url: base_url, capabilities: capabilities(opts)] ++ opts.agent_card_opts
    json = AshA2A.Protocol.JSON.encode_agent_card(card, card_opts)

    case extensions(opts, json) do
      [] -> json
      extensions -> put_in(json, ["capabilities", "extensions"], extensions)
    end
  end

  defp capabilities(opts) do
    %{
      streaming: true,
      push_notifications: opts.push_notifications == true,
      state_transition_history: false,
      extended_agent_card: false
    }
  end

  defp extensions(opts, json) do
    profile = AshA2A.Semantic.Extension.profile_id()

    advertised? =
      json
      |> Map.get("supportedInterfaces", [])
      |> Enum.any?(&(Map.get(&1, "protocolBinding") == profile))

    auto = if advertised?, do: [AshA2A.Semantic.Extension.capability_declaration()], else: []

    (auto ++ List.wrap(opts.extensions))
    |> Enum.uniq_by(&(Map.get(&1, :uri) || Map.get(&1, "uri")))
    |> Enum.map(&stringify/1)
  end

  # An AgentExtension struct stringifies like its plain-map wire shape, but a
  # struct is not Enumerable — unwrap via the codec's canonical encoder
  # before the generic map clause below, which would otherwise crash trying
  # to iterate it.
  defp stringify(%AshA2A.Protocol.AgentExtension{} = ext),
    do: AshA2A.Protocol.JSON.encode_agent_extension(ext)

  defp stringify(%{} = map), do: Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)
  defp stringify(other), do: other

  # Phoenix force_ssl-compatible HSTS: enabled whenever `:force_ssl` is set
  # (its `:hsts` option defaulting to `true`; `:hsts_include_subdomains` adds
  # `; includeSubDomains`). max-age is Phoenix's default (two years).
  defp hsts_header(force_ssl) when is_list(force_ssl) do
    max_age = Keyword.get(force_ssl, :hsts_max_age, 63_072_000)
    include_subdomains = Keyword.get(force_ssl, :hsts_include_subdomains, false)

    if include_subdomains do
      "max-age=#{max_age}; includeSubDomains"
    else
      "max-age=#{max_age}"
    end
  end

  defp hsts_header(_), do: "max-age=63072000"

  defp serve_agent_card(conn, opts) do
    base_url = AshA2A.Protocol.Plug.get_base_url(conn) || opts.base_url

    if is_nil(base_url) do
      raise ArgumentError, "AshA2A.Transport.Plug requires :base_url for ash_a2a agent card requests"
    end

    card = GenServer.call(opts.agent, :get_agent_card)

    body = Jason.encode!(agent_card_json(card, opts, base_url))

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "max-age=60")
    |> put_resp_header("etag", <<?"::utf8, etag_of(body)::binary, ?"::utf8>>)
    |> put_resp_header("last-modified", last_modified())
    |> send_resp(200, body)
  end

  # Agent-card caching headers (spec §8.6.1): Cache-Control and ETag are
  # SHOULD-level, Last-Modified is MAY-level. The card is a deterministic
  # projection of the compiled capability index, so the ETag is the body
  # digest and Last-Modified is the serve time (the card body is immutable
  # for a given boot; a card that changed would change the ETag).
  defp etag_of(body) do
    :crypto.hash(:md5, body) |> Base.encode16(case: :lower)
  end

  defp last_modified do
    Calendar.strftime(DateTime.utc_now(), "%a, %d %b %Y %H:%M:%S GMT")
  end

  # -- JSON-RPC --------------------------------------------------------------

  defp handle_json_rpc(conn, opts) do
    version = AshA2A.Protocol.Version.parse_header(get_req_header(conn, "a2a-version"))

    with :ok <- AshA2A.Protocol.Version.validate(version, AshA2A.Protocol.Version.supported_default()) do
      conn = put_resp_header(conn, "a2a-version", version)

      case read_json_body(conn, opts.max_body_bytes) do
        {:ok, decoded, conn} ->
          ctx = %{agent: opts.agent, opts: opts, conn: conn, principal: caller(conn)}

          case AshA2A.Protocol.JSONRPC.handle(decoded, __MODULE__, ctx) do
            {:reply, response} ->
              send_json(conn, response)

            {:stream, "message/stream", params, id} ->
              stream_message(conn, ctx, params, id)

            {:stream, "tasks/resubscribe", params, id} ->
              resubscribe(conn, ctx, params, id)
          end

        {:error, :body_too_large} ->
          send_json(conn, Response.error(nil, Error.invalid_request("Body too large")))

        {:error, _reason} ->
          send_json(conn, Response.error(nil, Error.parse_error()))
      end
    else
      # Unsupported A2A-Version (spec §3.6): VersionNotSupportedError
      # (-32009), mirroring AshA2A.Protocol.Plug's version gate. The
      # rejected version is still echoed in the response header (§3.6.2).
      {:error, rejected} when is_binary(rejected) ->
        conn
        |> put_resp_header("a2a-version", rejected)
        |> send_json(Response.error(nil, Error.version_not_supported(rejected)))
    end
  end

  defp read_json_body(%{body_params: %Plug.Conn.Unfetched{}} = conn, max) do
    case read_body(conn, length: max) do
      {:ok, body, conn} ->
        case Jason.decode(body) do
          {:ok, decoded} when is_map(decoded) -> {:ok, decoded, conn}
          _ -> {:error, :parse_error}
        end

      {:more, _partial, _conn} ->
        {:error, :body_too_large}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_json_body(%{body_params: %{} = params} = conn, _max), do: {:ok, params, conn}

  defp send_json(conn, response) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(response))
  end

  defp auth(conn), do: conn.private |> Map.get(:a2a, %{}) |> Map.get(:auth)

  defp caller(conn) do
    case auth(conn) do
      %{identity: identity} -> Principal.key(identity)
      _ -> :anonymous
    end
  end

  # Metadata layers, later wins: init -> put_metadata -> params.metadata ->
  # verified auth. The verified auth is last so no caller field can forge it.
  defp call_opts(params, message, %{opts: opts, conn: conn}) do
    conn_metadata = AshA2A.Protocol.Plug.get_metadata(conn) || %{}

    params_metadata =
      case params["metadata"] do
        %{} = m -> Map.drop(m, ["a2a.auth", Runtime.owner_key()])
        _ -> %{}
      end

    metadata = opts.metadata |> Map.merge(conn_metadata) |> Map.merge(params_metadata)
    metadata = if auth = auth(conn), do: Map.put(metadata, "a2a.auth", auth), else: metadata

    []
    |> put_opt(:task_id, params["id"] || message.task_id)
    |> put_opt(:context_id, params["contextId"] || message.context_id)
    |> put_opt(:metadata, if(metadata == %{}, do: nil, else: metadata))
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: [{key, value} | opts]

  # -- JSONRPC behaviour -----------------------------------------------------

  @impl AshA2A.Protocol.JSONRPC
  def handle_send(message, params, ctx) do
    case call_agent(ctx.agent, message, call_opts(params, message, ctx)) do
      {:ok, %AshA2A.Protocol.Task{} = task} -> {:ok, Runtime.wire_task(task)}
      {:ok, %AshA2A.Protocol.Message{} = msg} -> {:ok, msg}
      {:error, reason} -> {:error, wire_error(reason)}
    end
  end

  @impl AshA2A.Protocol.JSONRPC
  def handle_get(task_id, _params, ctx) do
    case owned_task(ctx, task_id) do
      {:ok, task} -> {:ok, Runtime.wire_task(task)}
      {:error, _} -> {:error, Error.task_not_found()}
    end
  end

  @impl AshA2A.Protocol.JSONRPC
  def handle_cancel(task_id, _params, ctx) do
    with {:ok, _task} <- owned_task(ctx, task_id),
         :ok <- GenServer.call(ctx.agent, {:cancel, task_id}),
         {:ok, task} <- owned_task(ctx, task_id) do
      {:ok, Runtime.wire_task(task)}
    else
      {:error, :not_found} -> {:error, Error.task_not_found()}
      {:error, :not_cancelable} -> {:error, Error.task_not_cancelable()}
      {:error, reason} -> {:error, wire_error(reason)}
    end
  end

  @impl AshA2A.Protocol.JSONRPC
  def handle_list(params, ctx) do
    case GenServer.call(ctx.agent, {:ash_a2a_list_tasks, ctx.principal, params}) do
      {:ok, %{tasks: tasks} = result} ->
        {:ok, %{result | tasks: Enum.map(tasks, &Runtime.wire_task/1)}}

      {:error, :invalid_page_token} ->
        {:error, Error.invalid_params("\"pageToken\" is invalid")}

      {:error, reason} ->
        {:error, wire_error(reason)}
    end
  end

  defp owned_task(ctx, task_id) when is_binary(task_id) do
    GenServer.call(ctx.agent, {:ash_a2a_get_task, ctx.principal, task_id})
  end

  defp owned_task(_ctx, _task_id), do: {:error, :not_found}

  defp call_agent(agent, message, opts) do
    AshA2A.Protocol.call(agent, message, opts)
  catch
    :exit, reason -> {:error, SafeError.internal(:internal_error, {:agent_exit, reason})}
  end

  @doc false
  @spec wire_error(term()) :: Error.t()
  def wire_error(:not_found), do: Error.task_not_found()
  def wire_error(:not_continuable), do: Error.invalid_params("task is terminal")

  # -32000 is the JSON-RPC *server-error* code (not one of the Error module's
  # A2A-specific -32001..-32009 constructors), the free-form `data` map is
  # pinned by test/ash_a2a/transport/transport_court_test.exs, and error.ex is
  # owned by another lane -- hence the one literal left in this file.
  def wire_error(%{code: code}) when code in [:server_busy, :rate_limited],
    do: %Error{code: -32000, message: "Server busy", data: %{"reason" => Atom.to_string(code)}}

  def wire_error(%{code: code} = reason) when is_atom(code) do
    data =
      reason
      |> SafeError.redact()
      |> Map.take([:code, :ref])
      |> Map.new(fn {k, v} -> {Atom.to_string(k), to_string(v)} end)

    Error.internal_error(data)
  end

  def wire_error(reason) do
    %{ref: ref} = SafeError.internal(:internal_error, reason)
    Error.internal_error(%{"code" => "internal_error", "ref" => ref})
  end

  # -- message/stream --------------------------------------------------------

  # `tasks/resubscribe` is not a served streaming method in this plug (only
  # `message/stream` is). A subscription for a task the caller does not own
  # (unknown or foreign) must still answer the spec-mandated TaskNotFoundError
  # (-32001) rather than UnsupportedOperationError (-32004); a subscription to
  # an owned task answers UnsupportedOperationError, since this plug has no
  # resubscribe stream to attach (spec §3.16, TCK STREAM-SUB-004).
  defp resubscribe(conn, ctx, params, id) do
    case owned_task(ctx, params["id"]) do
      {:ok, _task} ->
        send_json(conn, Response.error(id, Error.unsupported_operation()))

      {:error, :not_found} ->
        send_json(conn, Response.error(id, Error.task_not_found()))
    end
  end

  defp stream_message(conn, ctx, params, jsonrpc_id) do
    message = params["message"]

    case call_agent(ctx.agent, message, call_opts(params, message, ctx)) do
      {:ok, %AshA2A.Protocol.Task{metadata: %{stream: enum}} = task} ->
        conn = start_sse(conn)
        conn = send_event(conn, jsonrpc_id, Runtime.wire_task(task))
        stream_parts(conn, jsonrpc_id, task, enum)

      {:ok, %AshA2A.Protocol.Message{} = msg} ->
        conn = start_sse(conn)
        send_event(conn, jsonrpc_id, msg)

      {:ok, %AshA2A.Protocol.Task{} = task} ->
        conn = start_sse(conn)
        conn = send_event(conn, jsonrpc_id, Runtime.wire_task(task))

        conn =
          Enum.reduce(task.artifacts, conn, fn artifact, conn ->
            send_event(
              conn,
              jsonrpc_id,
              AshA2A.Protocol.Event.ArtifactUpdate.new(task.id, artifact, context_id: task.context_id)
            )
          end)

        final =
          AshA2A.Protocol.Event.StatusUpdate.new(task.id, task.status,
            context_id: task.context_id,
            final: true
          )

        send_event(conn, jsonrpc_id, final)

      {:error, reason} ->
        send_json(conn, Response.error(jsonrpc_id, wire_error(reason)))
    end
  end

  # v1.0 §TaskArtifactUpdateEvent: the chunk frames of one streamed artifact
  # share ONE artifactId; `append: true` appends a chunk to the
  # previously-sent artifact with the same id, and `lastChunk: true` marks the
  # final chunk (so clients can reassemble by id). The first chunk is a new
  # artifact: `append` is left unset. `last_chunk` is only set on the final
  # chunk; `put_unless_nil` drops it from the earlier frames.
  defp stream_parts(conn, jsonrpc_id, task, enum) do
    # The chunk emitter and the stream_done fold share ONE stable artifact id,
    # pre-minted by the agent runtime when it wrapped the stream
    # (:stream_artifact_id on the task metadata); mint here only as a
    # fallback for paths that never stamped it.
    artifact_id =
      # Protocol.Task.metadata is typed `map()` (never nil), so the old
      # `|| %{}` fallback was dead.
      Map.get(task.metadata, :stream_artifact_id) ||
        AshA2A.Protocol.ID.generate("art")

    # A lazy stream reveals its last element only by ending, so the frame for
    # chunk i is emitted when chunk i+1 arrives and the drain emits the pending
    # final chunk. The pending flag records whether chunk i's frame already has
    # a predecessor on the wire (=> the next frame needs `append: true`).
    {conn, pending} =
      Enum.reduce(enum, {conn, nil}, fn part, {conn, pending} ->
        case pending do
          nil ->
            {conn, {:chunk, part, false}}

          {:chunk, prev_part, append?} ->
            conn = send_chunk_frame(conn, jsonrpc_id, task, artifact_id, prev_part, append_opts(append?))
            {conn, {:chunk, part, true}}
        end
      end)

    conn =
      case pending do
        nil -> conn
        {:chunk, part, append?} -> send_chunk_frame(conn, jsonrpc_id, task, artifact_id, part, append_opts(append?) ++ [last_chunk: true])
      end

    final_status(conn, jsonrpc_id, task, :completed, nil)
  rescue
    error ->
      %{ref: ref} = SafeError.internal(:internal_error, error, __STACKTRACE__)
      final_status(conn, jsonrpc_id, task, :failed, "Error: internal_error ref=#{ref}")
  end

  defp append_opts(true), do: [append: true]
  defp append_opts(false), do: []

  defp send_chunk_frame(conn, jsonrpc_id, task, artifact_id, part, opts) do
    artifact =
      [part]
      |> AshA2A.Protocol.Artifact.new()
      |> struct(artifact_id: artifact_id)

    event =
      AshA2A.Protocol.Event.ArtifactUpdate.new(task.id, artifact, [context_id: task.context_id] ++ opts)

    send_event(conn, jsonrpc_id, event)
  end

  defp final_status(conn, jsonrpc_id, task, state, text) do
    message = if text, do: AshA2A.Protocol.Message.new_agent(text)
    status = AshA2A.Protocol.Task.Status.new(state, message)
    event = AshA2A.Protocol.Event.StatusUpdate.new(task.id, status, context_id: task.context_id, final: true)
    send_event(conn, jsonrpc_id, event)
  end

  defp start_sse(conn) do
    conn
    |> put_resp_header("content-type", "text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> send_chunked(200)
  end

  # v1.0 StreamResponse frames: the JSON-RPC result is `{"task" | "statusUpdate" |
  # "artifactUpdate" => ...}`, discriminated by the wrapper key (codec-owned).
  defp send_event(conn, jsonrpc_id, struct) do
    {:ok, encoded} = AshA2A.Protocol.JSON.encode_stream_response(struct)
    data = "data: " <> Jason.encode!(Response.success(jsonrpc_id, encoded)) <> "\n\n"

    case chunk(conn, data) do
      {:ok, conn} -> conn
      {:error, _closed} -> conn
    end
  end
end
