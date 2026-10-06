# A2A TCK SUT auth/TLS variant for ash_a2a (lane DY4).
#
# Run from /Users/sac/ash_a2a (MIX_ENV=test):
#   MIX_ENV=test mix run --no-start tck_sut_auth.exs
#
# Second SUT listener variant, solely DY4-owned (tck_sut.exs is untouched by
# this lane). Boots the same real AshA2A.Agent seam behind the real owned
# transports, but:
#
#   * every A2A request requires a valid HS256 JWT bearer token (signature +
#     exp + iss + aud + scope `a2a`), enforced by the real
#     `AshA2A.Protocol.Plug.Auth` plug (RFC 7235 challenge semantics);
#   * the served agent card DECLARES the bearer security scheme
#     (spec §8.2 securitySchemes/security) so the TCK can discover it;
#   * a second TLS listener serves the same agent over HTTPS with a real
#     openssl-generated chain (CA -> server cert, SANs DNS:localhost +
#     IP:127.0.1) so the TCK client can do real certificate validation
#     (AUTH-TLS / AUTH-SERVER-001);
#   * an observation endpoint (auth-exempt) reports the `A2A-Version`
#     request headers the TCK client actually sent (VER-CLIENT evidence,
#     observed server-side);
#   * an auth-required task flow: a message whose messageId starts with
#     `tck-auth-required` parks the task in the non-terminal
#     TASK_STATE_AUTH_REQUIRED state with a status message explaining the
#     required authorization (spec §7.6.1); a Sfollow-up on the same task id
#     resumes it to completion (AUTH-INTASK-*).

defmodule TckSutAuth.Resource do
  use Ash.Resource,
    domain: TckSutAuth.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
    attribute(:message, :string, public?: true)
  end

  actions do
    defaults([:read])
  end

  a2a do
    skill(:echo, :read)
  end
end

defmodule TckSutAuth.Domain do
  use Ash.Domain
end

defmodule TckSutAuth.Agent do
  @moduledoc false

  use AshA2A.Agent,
    resource_or_domain: TckSutAuth.Resource,
    name: "tck_sut_auth_agent",
    require_authenticated_caller: false

  alias AshA2A.Protocol.Part

  @impl AshA2A.Protocol.Agent
  def handle_message(message, _ctx) do
    id = message.message_id || ""

    cond do
      String.starts_with?(id, "tck-auth-required") ->
        if message.task_id do
          # Follow-up on the parked task: fresh credentials arrived
          # out-of-band (on the resumed request's own bearer token); the
          # parked task resumes to completion (spec §7.6.1, INTASK-006).
          {:reply, [Part.Text.new("Authorized; resumed to completion")]}
        else
          # First turn: park resumably in TASK_STATE_AUTH_REQUIRED with a
          # status message explaining the required authorization.
          {:error, {:auth_required, "supply a scoped bearer token (scope: a2a)"}}
        end

      true ->
        {:reply, [Part.Text.new("Unhandled messageId prefix: " <> id)]}
    end
  end
end

defmodule TckSutAuth.Observed do
  @moduledoc """
  Server-side observation of the `A2A-Version` request headers the TCK
  client actually presented (VER-CLIENT-001/002 evidence), read back via the
  auth-exempt `GET /__tck_observed` endpoint.
  """

  def record(nil), do: :ok

  def record(version) do
    :persistent_term.put({__MODULE__, :versions}, [version | versions()])
  end

  def versions do
    :persistent_term.get({__MODULE__, :versions}, [])
  end

  def reset, do: :persistent_term.put({__MODULE__, :versions}, [])
end

defmodule TckSutAuth.JWT do
  @moduledoc """
  Minimal HS256 JWT verification for the SUT harness. Mirrors the
  `AshA2A.Protocol.Plug.JWTVerifier` contract (signature + exp + iss/aud +
  scope), compiled inline because Joken is not in this repo's test
  dependency closure (`jwt_verifier.ex` is `Code.ensure_loaded?`-guarded on
  Joken and therefore uncompiled in MIX_ENV=test).
  """

  @secret "tck-dy4-hs256-secret"
  @issuer "tck-dy4-issuer"
  @audience "a2a"

  def secret, do: @secret
  def issuer, do: @issuer
  def audience, do: @audience

  def verify(token) do
    with [h, p, s] <- String.split(token, ".", parts: 3),
         {:ok, header, claims} <- decode(h, p),
         :ok <- check_alg(header),
         :ok <- check_sig(h, p, s),
         :ok <- check_exp(claims),
         :ok <- check_iss_aud_scope(claims) do
      {:ok, claims}
    else
      [] -> {:error, "invalid JWT format"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode(h, p) do
    with {:ok, hb} <- Base.url_decode64(h, padding: false),
         {:ok, pb} <- Base.url_decode64(p, padding: false) do
      {:ok, Jason.decode!(hb), Jason.decode!(pb)}
    else
      :error -> {:error, "invalid JWT format"}
    end
  rescue
    _ -> {:error, "invalid JWT format"}
  end

  defp check_alg(%{"alg" => "HS256"}), do: :ok
  defp check_alg(_), do: {:error, "algorithm mismatch: expected HS256"}

  defp check_sig(h, p, s) do
    expected = :crypto.mac(:hmac, :sha256, @secret, h <> "." <> p)

    case Base.url_decode64(s, padding: false) do
      {:ok, sig} ->
        if Plug.Crypto.secure_compare(sig, expected) do
          :ok
        else
          {:error, "signature verification failed"}
        end

      :error ->
        {:error, "invalid JWT format"}
    end
  end

  defp check_exp(%{"exp" => exp}) when is_integer(exp) do
    if exp > System.system_time(:second), do: :ok, else: {:error, "token expired"}
  end

  defp check_exp(_), do: {:error, "missing or invalid exp claim"}

  defp check_iss_aud_scope(%{"iss" => @issuer, "aud" => @audience, "scope" => scope})
       when is_binary(scope) do
    if "a2a" in String.split(scope, ~r/\s+/) do
      :ok
    else
      {:error, "insufficient scope: a2a required"}
    end
  end

  defp check_iss_aud_scope(%{"iss" => @issuer, "aud" => _}),
    do: {:error, "audience mismatch"}

  defp check_iss_aud_scope(%{"iss" => @issuer}), do: {:error, "missing scope claim"}
  defp check_iss_aud_scope(_), do: {:error, "issuer mismatch"}
end

defmodule TckSutAuth.Pipeline do
  @moduledoc """
  Real `AshA2A.Protocol.Plug.Auth` front door: bearer scheme, JWT verify
  callback, RFC 7235 challenges on 401. The card path is exempt by default.
  """

  def auth_opts do
    AshA2A.Protocol.Plug.Auth.init(
      schemes: %{"bearer_auth" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"}},
      verify: fn _scheme, credential, _conn ->
        case TckSutAuth.JWT.verify(credential) do
          {:ok, claims} -> {:ok, %{id: claims["sub"]}}
          {:error, reason} -> {:error, reason}
        end
      end
    )
  end
end

defmodule TckSutAuth.Router do
  @moduledoc false

  # Plain-map opts: %{auth: auth_opts, jsonrpc: jsonrpc_opts, rest: rest_opts,
  # base_url: base_url}. Built once in TckSutAuth.Main.run/0 and shared by
  # both listeners; Bandit requires the module to define init/1.
  def init(opts) when is_map(opts), do: opts
  def init(opts), do: Map.new(opts)

  def call(%{path_info: ["__tck_observed"]} = conn, _opts) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(
      200,
      Jason.encode!(%{"a2a_version_headers" => TckSutAuth.Observed.versions()})
    )
  end

  def call(conn, opts) do
    TckSutAuth.Observed.record(
      List.first(Plug.Conn.get_req_header(conn, "a2a-version")) || ""
    )

    conn
    |> AshA2A.Protocol.Plug.Auth.call(opts.auth)
    |> then(fn
      %{halted: true} = conn ->
        conn

      conn ->
        case conn.path_info do
          ["a2a", "rest" | rest_path] ->
            AshA2A.Transport.HTTPJSON.call(%{conn | path_info: rest_path}, opts.rest)

          _ ->
            AshA2A.Transport.Plug.call(conn, opts.jsonrpc)
        end
    end)
  end
end

# -- TLS material -------------------------------------------------------------
# Real chain: local CA -> server cert with SANs DNS:localhost, IP:127.0.0.1.
# Generated once into /tmp/tck_dy4_tls (idempotent across re-runs).

defmodule TckSutAuth.TLS do
  @moduledoc false

  @dir "/tmp/tck_dy4_tls"

  def dir, do: @dir
  def ca_path, do: Path.join(@dir, "ca.pem")

  def ensure! do
    File.mkdir_p!(@dir)

    if File.exists?(ca_path()) do
      :ok
    else
      step(~w(req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem
                    -subj /CN=tck-dy4-test-CA -days 2
                    -addext basicConstraints=critical,CA:TRUE
                    -addext keyUsage=critical,keyCertSign,cRLSign))

      step(~w(req -newkey rsa:2048 -nodes -keyout server.key -out server.csr
                    -subj /CN=localhost))

      File.write!(Path.join(@dir, "san.ext"),
                  "subjectAltName=DNS:localhost,IP:127.0.0.1\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n")

      step(~w(x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial
                    -out server.crt -days 2 -extfile san.ext))

      :ok
    end
  end

  defp step(args) do
    {_, 0} = System.cmd("openssl", args, cd: @dir, stderr_to_stdout: true)
    :ok
  end
end

defmodule TckSutAuth.GrpcHandler do
  @moduledoc """
  gRPC handler for the auth SUT variant. Mirrors the shared SUT's
  `TckSut.GrpcHandler` (lane DY1's section of tck_sut.exs): delegates to the
  same `AshA2A.Transport.Plug` JSONRPC handlers the HTTP side uses. NOTE
  (honest blocker for BIND-EQUIV-004): the `AshA2A.Transport.GRPC.Server`
  surface exposes no auth interceptor seam in this configuration, so the
  gRPC binding is NOT behind the JWT gate — the HTTP bindings refuse
  unauthenticated traffic while gRPC admits it.
  """

  @behaviour AshA2A.Protocol.JSONRPC

  @impl AshA2A.Protocol.JSONRPC
  def handle_send(message, params, _ctx) do
    metadata =
      case params["metadata"] do
        %{} = m -> m
        _ -> %{}
      end

    opts =
      []
      |> maybe_put(:task_id, params["id"] || message.task_id)
      |> maybe_put(:context_id, params["contextId"] || message.context_id)
      |> maybe_put(:metadata, if(metadata == %{}, do: nil, else: metadata))

    case AshA2A.Protocol.call(TckSutAuth.Agent, message, opts) do
      {:ok, %AshA2A.Protocol.Task{} = task} -> {:ok, AshA2A.Transport.Runtime.wire_task(task)}
      {:ok, %AshA2A.Protocol.Message{} = msg} -> {:ok, msg}
      {:error, reason} -> {:error, AshA2A.Transport.Plug.wire_error(reason)}
    end
  end

  @impl AshA2A.Protocol.JSONRPC
  def handle_get(task_id, params, _ctx), do: AshA2A.Transport.Plug.handle_get(task_id, params, ctx())

  @impl AshA2A.Protocol.JSONRPC
  def handle_cancel(task_id, params, _ctx),
    do: AshA2A.Transport.Plug.handle_cancel(task_id, params, ctx())

  @impl AshA2A.Protocol.JSONRPC
  def handle_list(params, _ctx), do: AshA2A.Transport.Plug.handle_list(params, ctx())

  @impl AshA2A.Protocol.JSONRPC
  def handle_set_push_config(config, params, _ctx),
    do: AshA2A.Transport.Plug.handle_set_push_config(config, params, ctx())

  @impl AshA2A.Protocol.JSONRPC
  def handle_get_push_config(task_id, config_id, params, _ctx),
    do: AshA2A.Transport.Plug.handle_get_push_config(task_id, config_id, params, ctx())

  @impl AshA2A.Protocol.JSONRPC
  def handle_list_push_configs(task_id, params, _ctx),
    do: AshA2A.Transport.Plug.handle_list_push_configs(task_id, params, ctx())

  @impl AshA2A.Protocol.JSONRPC
  def handle_delete_push_config(task_id, config_id, params, _ctx),
    do: AshA2A.Transport.Plug.handle_delete_push_config(task_id, config_id, params, ctx())

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: [{key, value} | opts]

  defp ctx do
    %{agent: TckSutAuth.Agent, opts: [], transport: TckSutAuth.Transport,
      conn: %Plug.Conn{private: %{}}, principal: :anonymous}
  end
end

defmodule TckSutAuth.Main do
  @moduledoc false

  def run do
    :ok = TckSutAuth.TLS.ensure!()
    {:ok, _} = TckSutAuth.Agent.start_link([])
    TckSutAuth.Observed.reset()

    http_port = System.get_env("TCK_SUT_AUTH_PORT", "9998") |> String.to_integer()
    tls_port = System.get_env("TCK_SUT_AUTH_TLS_PORT", "9443") |> String.to_integer()
grpc_port = System.get_env("TCK_SUT_AUTH_GRPC_PORT", "9997") |> String.to_integer()
    base_url = "http://localhost:#{http_port}"

    interfaces = [
      %{url: base_url, protocol_binding: "JSONRPC", protocol_version: "1.0"},
      %{url: "#{base_url}/a2a/rest", protocol_binding: "HTTP+JSON", protocol_version: "1.0"},
      # gRPC: bare host:port (the TCK's GrpcClient passes the card URL
      # straight to grpc.insecure_channel/1; an "http://" scheme produces
      # "Misformatted domain name" UNAVAILABLE failures).
      %{url: "127.0.0.1:#{grpc_port}", protocol_binding: "GRPC", protocol_version: "1.0"}
    ]

    jsonrpc_opts =
      AshA2A.Transport.Plug.init(
        agent: TckSutAuth.Agent,
        base_url: base_url,
        agent_card_opts: [
          supported_interfaces: interfaces,
          security_schemes: %{
            "bearer_auth" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"}
          },
          security: [%{"bearer_auth" => ["a2a"]}]
        ]
      )

    rest_opts = AshA2A.Transport.HTTPJSON.init(agent: TckSutAuth.Agent, base_url: base_url)

    router_opts = %{auth: TckSutAuth.Pipeline.auth_opts(), jsonrpc: jsonrpc_opts, rest: rest_opts}

    {:ok, http_srv} =
      Bandit.start_link(
        plug: {TckSutAuth.Router, router_opts},
        port: http_port,
        ip: {127, 0, 0, 1}
      )

    {:ok, tls_srv} =
      Bandit.start_link(
        plug: {TckSutAuth.Router, router_opts},
        scheme: :https,
        port: tls_port,
        ip: {127, 0, 0, 1},
        thousand_island_options: [
          transport_options: [
            certfile: Path.join(TckSutAuth.TLS.dir(), "server.crt"),
            keyfile: Path.join(TckSutAuth.TLS.dir(), "server.key")
          ]
        ]
      )

    {:ok, {_, http_bound}} = ThousandIsland.listener_info(http_srv)
    {:ok, {_, tls_bound}} = ThousandIsland.listener_info(tls_srv)

    IO.puts("TCK auth SUT listening on http://127.0.0.1:#{http_bound}")
    IO.puts("TCK auth SUT TLS listening on https://localhost:#{tls_bound}")
    IO.puts("TLS CA bundle for the TCK run: SSL_CERT_FILE=#{TckSutAuth.TLS.ca_path()}")

    # -- gRPC binding (mirrors the shared SUT's gRPC section: same handler
    #    shape, DY4-owned copy for the auth SUT) ----------------------------
    {:ok, _} = AshA2A.A2ATransport.start_link(name: TckSutAuth.Transport)

    Application.put_env(:ash_a2a, AshA2A.Transport.GRPC.Server,
      handler: TckSutAuth.GrpcHandler,
      ctx: %{agent: TckSutAuth.Agent, opts: [], transport: TckSutAuth.Transport}
    )

    {:ok, _} = Application.ensure_all_started(:grpc)
    {:ok, _} = Application.ensure_all_started(:ranch)

    {:ok, _grpc_pid, grpc_bound} =
      GRPC.Server.start_endpoint(AshA2A.Transport.GRPC.Server.Endpoint, grpc_port)

    IO.puts("TCK auth SUT gRPC listening on 127.0.0.1:#{grpc_bound}")

    Process.sleep(:infinity)
  end
end

TckSutAuth.Main.run()
