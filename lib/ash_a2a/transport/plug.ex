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

  `:versions` (default `AshA2A.Protocol.Version.supported_default/0`) is the
  accepted `A2A-Version` list (currently `["0.3", "1.0", "1.1"]`). The
  negotiated version is recorded at `conn.private[:a2a][:version]` and in the
  JSON-RPC handler ctx as `:a2a_version`.

  `:extensions` takes negotiated extension modules (`Mod | {Mod, opts}`,
  compiled at `init/1` via `AshA2A.Protocol.Extension.compile/1`) and/or
  advertise-only declaration maps. Required extensions missing from the
  `A2A-Extensions` request header answer `-32008` before dispatch; activated
  URIs are echoed in the `A2A-Extensions` response header and reach the agent
  as `context.extensions`.

  `:sign_with` (`[key:, alg:, kid:]`) signs the served card via
  `AshA2A.Protocol.CardSigner.sign/2` (memoised, stable `ETag`). The card
  route answers `304` to a matching `If-None-Match` / `If-Modified-Since`;
  `Last-Modified` is the plug's init-time (`:last_modified`) time.

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
    # `:extensions` carries two kinds of entry: negotiated extension modules
    # (`Mod | {Mod, opts}`, compiled via `Extension.compile/1` exactly like
    # `AshA2A.Protocol.Plug.init/1`) and plain declaration maps / structs that
    # are only advertised on the card.
    {ext_modules, ext_declarations} =
      opts |> Keyword.get(:extensions, []) |> List.wrap() |> Enum.split_with(&extension_entry?/1)

    %{
      agent: Keyword.fetch!(opts, :agent),
      versions: Keyword.get(opts, :versions, AshA2A.Protocol.Version.supported_default()),
      compiled_extensions: AshA2A.Protocol.Extension.compile(ext_modules),
      last_modified: Keyword.get(opts, :last_modified, DateTime.utc_now()),
      sign_with: Keyword.get(opts, :sign_with),
      base_url: Keyword.get(opts, :base_url),
      agent_card_path: Keyword.get(opts, :agent_card_path, [".well-known", "agent-card.json"]),
      json_rpc_path: Keyword.get(opts, :json_rpc_path, []),
      agent_card_opts: Keyword.get(opts, :agent_card_opts, []),
      metadata: Keyword.get(opts, :metadata, %{}),
      max_body_bytes: Keyword.get(opts, :max_body_bytes, 1_000_000),
      push_notifications: Keyword.get(opts, :push_notifications, false),
      extensions: ext_declarations,
      force_ssl: Keyword.get(opts, :force_ssl, nil)
    }
    |> Map.merge(AshA2A.Transport.SchemaEndpoints.init(opts))
  end

  # A module atom or `{module, keyword}` is a negotiated extension; a struct or
  # map is an advertise-only declaration.
  defp extension_entry?(entry) when is_atom(entry), do: true
  defp extension_entry?({mod, opts}) when is_atom(mod) and is_list(opts), do: true
  defp extension_entry?(_), do: false

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
    card_opts = [url: base_url, capabilities: capabilities(opts, card)] ++ opts.agent_card_opts
    json = AshA2A.Protocol.JSON.encode_agent_card(card, card_opts)

    case extensions(opts, json) do
      [] -> json
      extensions -> put_in(json, ["capabilities", "extensions"], extensions)
    end
  end

  defp capabilities(opts, card) do
    base = %{
      streaming: true,
      push_notifications: opts.push_notifications == true,
      state_transition_history: false,
      extended_agent_card: Map.get(opts, :extended_card) == true
    }

    # v1.1: the card's own `user_artifacts` declaration is carried through.
    if AshA2A.Protocol.ClientArtifacts.user_artifacts?(card),
      do: Map.put(base, :user_artifacts, true),
      else: base
  end

  defp extensions(opts, json) do
    advertised? =
      AshA2A.Semantic.Extension.advertisement(%{
        "capabilities" => Keyword.get(opts.agent_card_opts, :capabilities, %{})
      }) == :compatible or
        AshA2A.Semantic.Extension.advertisement(json) == :compatible

    auto = if advertised?, do: [AshA2A.Semantic.Extension.capability_declaration()], else: []

    negotiated =
      opts |> Map.get(:compiled_extensions, []) |> AshA2A.Protocol.Extension.declarations()

    (auto ++ List.wrap(opts.extensions) ++ negotiated)
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
      raise ArgumentError,
            "AshA2A.Transport.Plug requires :base_url for ash_a2a agent card requests"
    end

    card = GenServer.call(opts.agent, :get_agent_card)

    # `:sign_with` serves the memoised signed body (stable bytes => stable ETag).
    body =
      AshA2A.Protocol.Plug.CardServe.signed_body(
        agent_card_json(card, opts, base_url),
        Map.get(opts, :sign_with)
      )

    AshA2A.Protocol.Plug.CardServe.respond(
      conn,
      body,
      <<?"::utf8, etag_of(body)::binary, ?"::utf8>>,
      last_modified(opts),
      "max-age=60"
    )
  end

  # Agent-card caching headers (spec §8.6.1): Cache-Control and ETag are
  # SHOULD-level, Last-Modified is MAY-level. The card is a deterministic
  # projection of the compiled capability index, so the ETag is the body
  # digest and Last-Modified is the plug's init-time (boot/build) time -- never
  # the request time, so a revalidating client (`If-None-Match` /
  # `If-Modified-Since`, answered `304` by `CardServe.respond/5`) can hit.
  defp etag_of(body) do
    :crypto.hash(:md5, body) |> Base.encode16(case: :lower)
  end

  defp last_modified(opts) do
    opts
    |> Map.get(:last_modified, DateTime.utc_now())
    |> AshA2A.Protocol.Plug.CardServe.http_date()
  end

  # -- JSON-RPC --------------------------------------------------------------

  defp handle_json_rpc(conn, opts) do
    # Header, else the `A2A-Version` query parameter (spec §3.6.1), else "0.3".
    version = AshA2A.Protocol.Version.from_conn(conn)

    compiled = Map.get(opts, :compiled_extensions, [])
    requested = AshA2A.Protocol.Extension.parse_header(get_req_header(conn, "a2a-extensions"))

    with :ok <-
           AshA2A.Protocol.Version.validate(
             version,
             Map.get(opts, :versions, AshA2A.Protocol.Version.supported_default())
           ),
         :ok <- AshA2A.Protocol.Extension.validate_required(compiled, requested),
         {:ok, activations, activated_uris} <-
           AshA2A.Protocol.Extension.activate(compiled, requested, %{conn: conn}) do
      conn =
        conn
        |> put_resp_header("a2a-version", version)
        |> AshA2A.Protocol.Version.put_negotiated(version)
        |> put_extensions_header(activated_uris)

      case read_json_body(conn, opts.max_body_bytes) do
        {:ok, decoded, conn} ->
          decoded = alias_method(decoded)

          ctx = %{
            agent: opts.agent,
            opts: opts,
            conn: conn,
            principal: caller(conn),
            extensions: activations,
            a2a_version: version
          }

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
        |> put_resp_header("a2a-version", AshA2A.Protocol.Version.safe_echo(rejected))
        |> send_json(Response.error(nil, Error.version_not_supported(rejected)))

      # Required extension absent from the A2A-Extensions request header
      # (spec §4.5): ExtensionSupportRequiredError (-32008), before dispatch.
      {:error, missing} when is_list(missing) ->
        send_json(
          conn,
          Response.error(
            nil,
            Error.extension_support_required(
              "Client missing required extensions: " <> Enum.join(missing, ", ")
            )
          )
        )

      {:error, %Error{} = err} ->
        send_json(conn, Response.error(nil, err))
    end
  end

  # Routing-only slash aliases (`tasks/subscribe` -> `tasks/resubscribe`) that
  # AshA2A.Protocol.JSONRPC's own PascalCase table does not carry; resolved
  # here so both HTTP plugs accept the same spellings.
  defp alias_method(%{"method" => method} = decoded) when is_binary(method) do
    %{
      decoded
      | "method" => Map.get(AshA2A.A2ATransport.Plug.extra_method_aliases(), method, method)
    }
  end

  defp alias_method(decoded), do: decoded

  defp put_extensions_header(conn, []), do: conn

  defp put_extensions_header(conn, uris),
    do: put_resp_header(conn, "a2a-extensions", Enum.join(uris, ", "))

  defp read_json_body(%{body_params: %Plug.Conn.Unfetched{}} = conn, max) do
    case read_body(conn, length: max) do
      {:ok, body, conn} ->
        case AshA2A.Protocol.JSONGuard.decode(body) do
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
    |> send_resp(200, Jason.encode!(AshA2A.Protocol.DowngradeWire.body(conn, response)))
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
  #
  # `ctx` is the plug's own `%{opts:, conn:, ...}` OR a gRPC per-call ctx (no
  # conn; the verified auth rides as `ctx.auth`, set by
  # `AshA2A.Transport.GRPC.Server` after the auth interceptor ran).
  defp call_opts(params, message, ctx) do
    opts = Map.get(ctx, :opts) |> then(&if(is_map(&1), do: &1, else: %{}))
    conn = Map.get(ctx, :conn)
    conn_metadata = if conn, do: AshA2A.Protocol.Plug.get_metadata(conn) || %{}, else: %{}

    params_metadata =
      case params["metadata"] do
        %{} = m -> Map.drop(m, ["a2a.auth", Runtime.owner_key()])
        _ -> %{}
      end

    metadata =
      opts |> Map.get(:metadata, %{}) |> Map.merge(conn_metadata) |> Map.merge(params_metadata)

    verified = if conn, do: auth(conn), else: Map.get(ctx, :auth)
    metadata = if verified, do: Map.put(metadata, "a2a.auth", verified), else: metadata

    # Activated extensions reach the agent as `context.extensions` (same
    # `%{uri => activation}` map AshA2A.Protocol.Plug passes); absent when none
    # activated so callers without extensions see unchanged call options.
    extensions =
      case Map.get(ctx, :extensions, []) do
        [] -> nil
        activations -> AshA2A.Protocol.Extension.to_context_map(activations)
      end

    []
    |> put_opt(:task_id, params["id"] || message.task_id)
    |> put_opt(:context_id, params["contextId"] || message.context_id)
    |> put_opt(:metadata, if(metadata == %{}, do: nil, else: metadata))
    |> put_opt(:extensions, extensions)
    |> put_opt(:if_generation_match, Map.get(ctx, :if_generation_match))
    |> put_opt(:return_immediately, Map.get(ctx, :return_immediately))
    |> put_opt(:accepted_output_modes, Map.get(ctx, :accepted_output_modes))
    |> put_opt(:principal, Map.get(ctx, :principal))
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: [{key, value} | opts]

  # -- JSONRPC behaviour -----------------------------------------------------

  @impl AshA2A.Protocol.JSONRPC
  def handle_send(message, params, ctx) do
    alias AshA2A.Protocol.Extension

    activations = Map.get(ctx, :extensions, [])

    # handle_request/handle_response hooks of the activated extensions run
    # around the agent call (declaration order), as in AshA2A.Protocol.Plug.
    with {:ok, message, params, activations} <-
           Extension.run_request(activations, message, params) do
      ctx = Map.put(ctx, :extensions, activations)

      case call_agent(ctx.agent, message, call_opts(params, message, ctx)) do
        {:ok, %AshA2A.Protocol.Task{} = task} ->
          {:ok, task, _} = Extension.run_response(activations, task, params)

          case AshA2A.Protocol.InputModeValidator.apply_output_modes(
                 task,
                 Map.get(ctx, :accepted_output_modes)
               ) do
            {:ok, task} -> {:ok, Runtime.wire_task(task)}
            {:error, reason} -> {:error, wire_error(reason)}
          end

        {:ok, %AshA2A.Protocol.Message{} = msg} ->
          {:ok, msg, _} = Extension.run_response(activations, msg, params)
          {:ok, msg}

        {:error, reason} ->
          {:error, wire_error(reason)}
      end
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

  @doc """
  Typed `Error` for a raw send-path refusal reason, or `nil` for any other term.
  Single table shared with `AshA2A.Transport.GRPC.Dispatch.reason_to_error/1`.
  """
  @spec reason_error(term()) :: Error.t() | nil
  def reason_error(:generation_mismatch),
    do: AshA2A.Protocol.ClientArtifacts.to_error(:generation_mismatch)

  def reason_error({:unsupported_operation, :user_artifacts} = reason),
    do: AshA2A.Protocol.ClientArtifacts.to_error(reason)

  def reason_error(:context_mismatch), do: Error.invalid_params("contextId does not match task")

  def reason_error({:content_type_not_supported, _} = reason),
    do: AshA2A.Protocol.InputModeValidator.to_error(reason)

  def reason_error(:not_continuable), do: Error.unsupported_operation("task is terminal")
  def reason_error(_other), do: nil

  @doc false
  @spec wire_error(term()) :: Error.t()
  def wire_error(:not_found), do: Error.task_not_found()

  def wire_error(reason)
      when reason in [:generation_mismatch, :context_mismatch, :not_continuable],
      do: reason_error(reason)

  def wire_error({tag, _} = reason)
      when tag in [:unsupported_operation, :content_type_not_supported],
      do: reason_error(reason) || Error.internal_error()

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
  # an owned task attaches to the agent's subscriber fan-out via
  # `Protocol.Plug.SSE.subscribe_task/6`, which honours `lastSeenGeneration`
  # (no Task snapshot when the client is already current, v1.1) (spec §3.16,
  # TCK STREAM-SUB-004).
  defp resubscribe(conn, ctx, params, id) do
    case owned_task(ctx, params["id"]) do
      {:ok, task} ->
        AshA2A.Protocol.Plug.SSE.subscribe_task(
          conn,
          ctx.agent,
          task.id,
          id,
          Map.get(ctx.opts, :resubscribe_timeout, 300_000),
          params: params,
          version: ctx.a2a_version
        )

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
        conn = send_message_updates(conn, jsonrpc_id, task, ctx)
        stream_parts(conn, jsonrpc_id, task, enum)

      {:ok, %AshA2A.Protocol.Message{} = msg} ->
        conn = start_sse(conn)
        send_event(conn, jsonrpc_id, msg)

      {:ok, %AshA2A.Protocol.Task{} = task} ->
        conn = start_sse(conn)
        conn = send_event(conn, jsonrpc_id, Runtime.wire_task(task))
        conn = send_message_updates(conn, jsonrpc_id, task, ctx)

        conn =
          Enum.reduce(task.artifacts, conn, fn artifact, conn ->
            send_event(
              conn,
              jsonrpc_id,
              AshA2A.Protocol.Event.ArtifactUpdate.new(task.id, artifact,
                context_id: task.context_id,
                generation:
                  artifact.end_generation || artifact.start_generation ||
                    AshA2A.Protocol.Task.Generation.generation_of(task)
              )
            )
          end)

        final =
          AshA2A.Protocol.Event.StatusUpdate.new(task.id, task.status,
            context_id: task.context_id,
            final: true,
            generation: AshA2A.Protocol.Task.Generation.generation_of(task)
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
    # Protocol.Task.metadata is typed `map()` (never nil), so the old
    # `|| %{}` fallback was dead.
    artifact_id =
      Map.get(task.metadata, :stream_artifact_id) ||
        AshA2A.Protocol.ID.generate("art")

    # A lazy stream reveals its last element only by ending, so the frame for
    # chunk i is emitted when chunk i+1 arrives and the drain emits the pending
    # final chunk. The pending flag records whether chunk i's frame already has
    # a predecessor on the wire (=> the next frame needs `append: true`).
    # Frame generations are strictly increasing, starting above the snapshot.
    base = AshA2A.Protocol.Task.Generation.generation_of(task)

    {conn, pending, n} =
      Enum.reduce(enum, {conn, nil, 0}, fn part, {conn, pending, n} ->
        case pending do
          nil ->
            {conn, {:chunk, part, false}, n}

          {:chunk, prev_part, append?} ->
            conn =
              send_chunk_frame(
                conn,
                jsonrpc_id,
                task,
                artifact_id,
                prev_part,
                append_opts(append?) ++ [generation: base + n + 1]
              )

            {conn, {:chunk, part, true}, n + 1}
        end
      end)

    {conn, n} =
      case pending do
        nil ->
          {conn, n}

        {:chunk, part, append?} ->
          {send_chunk_frame(
             conn,
             jsonrpc_id,
             task,
             artifact_id,
             part,
             append_opts(append?) ++ [last_chunk: true, generation: base + n + 1]
           ), n + 1}
      end

    final_status(conn, jsonrpc_id, task, :completed, nil, base + n + 1)
  rescue
    error ->
      %{ref: ref} = SafeError.internal(:internal_error, error, __STACKTRACE__)

      final_status(
        conn,
        jsonrpc_id,
        task,
        :failed,
        "Error: internal_error ref=#{ref}",
        AshA2A.Protocol.Task.Generation.generation_of(task) + 1
      )
  end

  # v1.1 messageUpdate frames for the task timeline's client messages; a
  # legacy (1.0/0.3) client never receives them and gets no error.
  defp send_message_updates(conn, jsonrpc_id, task, ctx) do
    if AshA2A.Protocol.Version.at_least?(Map.get(ctx, :a2a_version), "1.1") do
      task.timeline
      |> List.wrap()
      |> Enum.reduce(conn, fn
        %AshA2A.Protocol.TimelineEntry{entry: {:message, message}, generation: gen}, conn ->
          send_event(
            conn,
            jsonrpc_id,
            AshA2A.Protocol.Event.MessageUpdate.new(task.id, message,
              context_id: task.context_id,
              generation: gen
            )
          )

        _other, conn ->
          conn
      end)
    else
      conn
    end
  end

  defp append_opts(true), do: [append: true]
  defp append_opts(false), do: []

  defp send_chunk_frame(conn, jsonrpc_id, task, artifact_id, part, opts) do
    artifact =
      [part]
      |> AshA2A.Protocol.Artifact.new()
      |> struct(artifact_id: artifact_id)

    event =
      AshA2A.Protocol.Event.ArtifactUpdate.new(
        task.id,
        artifact,
        [context_id: task.context_id] ++ opts
      )

    send_event(conn, jsonrpc_id, event)
  end

  defp final_status(conn, jsonrpc_id, task, state, text, generation) do
    message = if text, do: AshA2A.Protocol.Message.new_agent(text)
    status = AshA2A.Protocol.Task.Status.new(state, message)

    event =
      AshA2A.Protocol.Event.StatusUpdate.new(task.id, status,
        context_id: task.context_id,
        final: true,
        generation: generation
      )

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
    envelope = Response.success(jsonrpc_id, encoded)

    case AshA2A.Protocol.DowngradeWire.frame(conn, envelope) do
      :drop ->
        conn

      {:ok, envelope} ->
        case chunk(conn, "data: " <> Jason.encode!(envelope) <> "\n\n") do
          {:ok, conn} -> conn
          {:error, _closed} -> conn
        end
    end
  end
end
