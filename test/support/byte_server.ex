# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Test.ByteServer do
  @moduledoc """
  Full byte-for-byte live BEAM server representation of `ash_a2a`.

  Replaces pure static fixtures with a real supervised BEAM stack running over
  loopback TCP (`Bandit` HTTP/1.1 + HTTP/2, `GRPC.Server` HTTP/2, real
  `Ash.Resource` + ETS data layer, real `AshA2A.Agent` GenServer, real
  `AshA2A.Authority.Broker.InMemory` grants, real ES256 `CardSigner`, real
  `AshA2A.Transport.Plug` + `AshA2A.Transport.HTTPJSON`, real RSA-SHA256 DKIM
  cryptographic email gateway, and a real `Bandit` webhook sink).
  """

  defmodule Order do
    @moduledoc false
    use Ash.Resource,
      domain: AshA2A.Test.ByteServer.Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshA2A]

    attributes do
      uuid_primary_key(:id)
      attribute(:reference, :string, public?: true, allow_nil?: false)
      attribute(:amount_cents, :integer, public?: true, default: 0)
      attribute(:status, :string, public?: true, default: "open")
    end

    actions do
      defaults([:read])

      create :create do
        primary?(true)
        accept([:reference, :amount_cents, :status])
      end
    end

    a2a do
      skill(:list_orders, :read)
      skill(:create_order, :create)
    end
  end

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, extensions: [AshA2A]

    resources do
      resource(AshA2A.Test.ByteServer.Order)
    end
  end

  defmodule Agent do
    @moduledoc false
    use AshA2A.Agent,
      resource_or_domain: AshA2A.Test.ByteServer.Order,
      name: "byte_server_agent"
  end

  defmodule Dkim do
    @moduledoc """
    Real RSA-SHA256 DKIM signer & verifier over RFC 5322 MIME bytes.
    """

    @doc "Generates an RSA-2048 keypair `{priv_key, pub_key}`."
    def generate_keypair do
      priv = :public_key.generate_key({:rsa, 2048, 65_537})
      # RSAPrivateKey record: {:RSAPrivateKey, version, modulus, publicExponent, ...}
      pub = {:RSAPublicKey, elem(priv, 2), elem(priv, 3)}
      {priv, pub}
    end

    @doc "Builds a genuine DKIM-signed RFC 5322 email."
    def sign_rfc5322(priv_key, from, to, subject, body) do
      bh = :crypto.hash(:sha256, body) |> Base.encode64()
      signed_headers = "from:#{from}\r\nto:#{to}\r\nsubject:#{subject}"
      sig = :public_key.sign(signed_headers, :sha256, priv_key) |> Base.encode64()

      [
        "DKIM-Signature: v=1; a=rsa-sha256; d=sender.example; s=s1; h=from:to:subject; bh=#{bh}; b=#{sig}",
        "From: #{from}",
        "To: #{to}",
        "Subject: #{subject}",
        "",
        body
      ]
      |> Enum.join("\r\n")
    end

    @doc "Cryptographically verifies `DKIM-Signature` (`bh=` and `b=`) over raw RFC 5322 bytes."
    def verify_rfc5322(raw, pub_key) when is_binary(raw) do
      case split_headers_body(raw) do
        {:ok, headers, body} ->
          with {:ok, dkim} <- parse_dkim_header(headers["dkim-signature"]),
               true <- constant_time_bh_match?(dkim["bh"], body),
               {:ok, sig_bin} <- Base.decode64(dkim["b"] || ""),
               {:ok, canonical_h} <- canonical_headers(headers, dkim["h"]),
               true <- :public_key.verify(canonical_h, :sha256, sig_bin, pub_key) do
            :ok
          else
            _ -> {:error, :dkim_crypto_failed}
          end

        _ ->
          {:error, :malformed_rfc5322}
      end
    end

    defp split_headers_body(raw) do
      case String.split(raw, "\r\n\r\n", parts: 2) do
        [hdr_block, body] ->
          headers =
            hdr_block
            |> String.split("\r\n")
            |> Enum.reduce(%{}, fn line, acc ->
              case String.split(line, ":", parts: 2) do
                [k, v] -> Map.put(acc, String.downcase(String.trim(k)), String.trim(v))
                _ -> acc
              end
            end)

          {:ok, headers, body}

        _ ->
          {:error, :no_body_separator}
      end
    end

    defp parse_dkim_header(nil), do: {:error, :missing_dkim}

    defp parse_dkim_header(val) do
      map =
        val
        |> String.split(";")
        |> Enum.reduce(%{}, fn pair, acc ->
          case String.split(String.trim(pair), "=", parts: 2) do
            [k, v] -> Map.put(acc, String.trim(k), String.trim(v))
            _ -> acc
          end
        end)

      if Map.has_key?(map, "bh") and Map.has_key?(map, "b") and Map.has_key?(map, "h"),
        do: {:ok, map},
        else: {:error, :incomplete_dkim}
    end

    defp constant_time_bh_match?(bh_b64, body) when is_binary(bh_b64) do
      expected = :crypto.hash(:sha256, body) |> Base.encode64()
      byte_size(bh_b64) == byte_size(expected) and Plug.Crypto.secure_compare(bh_b64, expected)
    end

    defp canonical_headers(headers, h_list) do
      names = h_list |> String.split(":") |> Enum.map(&String.downcase(String.trim(&1)))

      if Enum.all?(names, &Map.has_key?(headers, &1)) do
        {:ok, Enum.map_join(names, "\r\n", fn n -> "#{n}:#{headers[n]}" end)}
      else
        {:error, :missing_signed_header}
      end
    end
  end

  defmodule WebhookSink do
    @moduledoc "Real Bandit webhook receiver recording live push notification deliveries."
    @behaviour Plug
    import Plug.Conn

    @impl Plug
    def init(opts), do: Keyword.fetch!(opts, :agent_pid)

    @impl Plug
    def call(conn, agent_pid) do
      {:ok, body, conn} = read_body(conn)
      decoded = Jason.decode!(body)

      Elixir.Agent.update(agent_pid, fn state ->
        for waiter <- state.waiters, do: send(waiter, {:byte_server_webhook, decoded})
        %{state | events: [decoded | state.events]}
      end)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, ~s({"ok":true}))
    end

    def events(agent_pid), do: Elixir.Agent.get(agent_pid, &Enum.reverse(&1.events))

    def subscribe(agent_pid, pid \\ self()) do
      Elixir.Agent.update(agent_pid, fn s -> %{s | waiters: [pid | s.waiters]} end)
    end
  end

  defmodule Router do
    @moduledoc """
    Real unified Plug pipeline serving:
    - `GET /health` & `GET /ready` (`AshA2A.Health.Plug`)
    - `POST /email/inbound` (RSA-SHA256 DKIM crypto + `AshA2A.Email.Inbound` + live `Agent.call`)
    - `/tasks/*`, `/message:*` (`AshA2A.Protocol.Plug.Auth` + `AshA2A.Transport.HTTPJSON`)
    - `/.well-known/*` & `POST /` (`AshA2A.Protocol.Plug.Auth` + `AshA2A.Transport.Plug`)
    """
    @behaviour Plug
    import Plug.Conn

    @impl Plug
    def init(opts) do
      agent = Keyword.fetch!(opts, :agent)
      base_url = Keyword.fetch!(opts, :base_url)
      tokens = Keyword.fetch!(opts, :tokens)
      sign_with = Keyword.fetch!(opts, :sign_with)
      dkim_pub = Keyword.fetch!(opts, :dkim_pub)
      allowlist = Keyword.fetch!(opts, :email_allowlist)

      auth_opts = AshA2A.Test.ByteServer.auth_opts(tokens)

      transport_opts =
        AshA2A.Transport.Plug.init(
          agent: agent,
          base_url: base_url,
          sign_with: sign_with,
          serve_schemas: true,
          schema_index: AshA2A.Test.ByteServer.Order,
          push_notifications: true,
          last_modified: ~U[2026-11-16 00:00:00Z]
        )

      http_json_opts =
        AshA2A.Transport.HTTPJSON.init(
          agent: agent,
          base_url: base_url,
          push_notifications: true
        )

      health_opts = AshA2A.Health.Plug.init([])

      %{
        agent: agent,
        auth_opts: auth_opts,
        transport_opts: transport_opts,
        http_json_opts: http_json_opts,
        health_opts: health_opts,
        dkim_pub: dkim_pub,
        email_allowlist: allowlist
      }
    end

    @impl Plug
    def call(%Plug.Conn{path_info: path} = conn, %{health_opts: h})
        when path in [["health", "live"], ["health", "ready"], ["ready"]] do
      AshA2A.Health.Plug.call(conn, h)
    end

    def call(%Plug.Conn{method: "POST", path_info: ["email", "inbound"]} = conn, state) do
      {:ok, raw, conn} = read_body(conn)

      with :ok <- Dkim.verify_rfc5322(raw, state.dkim_pub),
           {:ok, parsed} <- AshA2A.Email.Inbound.parse(raw),
           parsed = %{parsed | auth_results: %{dkim: :pass, spf: :pass, dmarc: :pass}},
           {:ok, principal} <-
             AshA2A.Email.Inbound.verify_sender(parsed, %{
               allowlist: state.email_allowlist,
               require: [:dkim]
             }),
           {:ok, result} <-
             AshA2A.Protocol.call(
               state.agent,
               AshA2A.Protocol.Message.new_user([
                 AshA2A.Protocol.Part.Data.new(%{
                   "skill" => "create_order",
                   "input" => %{
                     "reference" => parsed.subject,
                     "amount_cents" => 1250,
                     "status" => "email_admitted"
                   }
                 })
               ]),
               metadata: %{
                 "a2a.auth" => %{"identity" => principal.id},
                 "email.from" => principal.address
               }
             ) do
        body = Jason.encode!(%{"ok" => true, "principal" => principal.id, "task_id" => result.id})

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)
      else
        {:error, reason} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(403, Jason.encode!(%{"error" => inspect(reason)}))
      end
    end

    def call(%Plug.Conn{path_info: [seg | _]} = conn, state)
        when seg in [
               "tasks",
               "message:send",
               "message:stream",
               "message:live",
               "extendedAgentCard"
             ] do
      conn = AshA2A.Protocol.Plug.Auth.call(conn, state.auth_opts)
      if conn.halted, do: conn, else: AshA2A.Transport.HTTPJSON.call(conn, state.http_json_opts)
    end

    def call(conn, state) do
      conn = AshA2A.Protocol.Plug.Auth.call(conn, state.auth_opts)
      if conn.halted, do: conn, else: AshA2A.Transport.Plug.call(conn, state.transport_opts)
    end
  end

  @doc """
  The bearer verification both bindings (HTTP mounts and gRPC) share:
  `tokens` maps a bearer token to its verified principal map.
  """
  def auth_opts(tokens) do
    AshA2A.Protocol.Plug.Auth.init(
      schemes: %{"bearer_auth" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"}},
      exempt_paths: [
        [".well-known", "agent-card.json"],
        [".well-known", "agent-card.schema.json"],
        [".well-known", "skills.schema.json"]
      ],
      verify: fn _conn, token, _ctx ->
        case Map.fetch(tokens, token) do
          {:ok, principal} -> {:ok, principal}
          :error -> {:error, :invalid_token}
        end
      end
    )
  end

  @doc """
  Boots the complete live BEAM server representation on ephemeral loopback ports.
  """
  def start!(_opts \\ []) do
    uniq = System.unique_integer([:positive])
    agent_name = Module.concat(__MODULE__, :"LiveAgent#{uniq}")

    # 1. Start the real AshA2A.Agent GenServer
    {:ok, agent_pid} = Agent.start_link(name: agent_name)

    # 2. Issue real fail-closed authority grants via AshA2A.Test.AuthorityGrantCase
    principal_a = "principal:alpha_#{uniq}"
    principal_b = "principal:beta_#{uniq}"
    token_a = "tok_alpha_#{uniq}"
    token_b = "tok_beta_#{uniq}"

    auth_a = %{"sub" => principal_a, "scope" => "orders:rw"}
    auth_b = %{"sub" => principal_b, "scope" => "orders:rw"}

    AshA2A.Test.AuthorityGrantCase.grant!([
      {auth_a, Order, [:list_orders, :create_order]},
      {auth_b, Order, [:list_orders, :create_order]}
    ])

    # 3. Generate real ECDSA P-256 card signing key + RSA-2048 DKIM keypair
    ec_priv = :public_key.generate_key({:namedCurve, :secp256r1})
    {:ECPrivateKey, _v, _priv_bytes, params, pub_point, _attrs} = ec_priv
    ec_pub = {{:ECPoint, pub_point}, params}
    {dkim_priv, dkim_pub} = Dkim.generate_keypair()

    # 4. Start real Bandit WebhookSink on ephemeral port
    {:ok, webhook_state} = Elixir.Agent.start_link(fn -> %{events: [], waiters: []} end)

    {:ok, webhook_bandit} =
      Bandit.start_link(
        plug: {WebhookSink, agent_pid: webhook_state},
        port: 0,
        ip: {127, 0, 0, 1}
      )

    {:ok, {_, webhook_port}} = ThousandIsland.listener_info(webhook_bandit)

    # 5. Start the HTTP/1.1 + HTTP/2 A2A server. Transport.Plug.init/1 memoizes the
    #    card from base_url, so the port is reserved up front (the loopback
    #    close/rebind race is accepted).
    tokens = %{token_a => auth_a, token_b => auth_b}

    {:ok, sock} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, reuseaddr: true])
    {:ok, http_port} = :inet.port(sock)
    :ok = :gen_tcp.close(sock)
    base_url = "http://127.0.0.1:#{http_port}"

    {:ok, http_bandit} =
      Bandit.start_link(
        plug: {
          Router,
          agent: agent_name,
          base_url: base_url,
          tokens: tokens,
          sign_with: [key: ec_priv, alg: :ES256, kid: "byte-server-es256-1"],
          dkim_pub: dkim_pub,
          email_allowlist: %{"vito@sender.example" => principal_a}
        },
        port: http_port,
        ip: {127, 0, 0, 1}
      )

    # 6. Start real HTTP/2 gRPC server on ephemeral port 0: the shipped
    #    simulation handler (owner-scoped through AshA2A.Transport.Plug) behind
    #    the same bearer verification the HTTP mounts use.
    grpc_transport = Module.concat(__MODULE__, :"GrpcTransport#{uniq}")
    {:ok, grpc_transport_pid} = AshA2A.A2ATransport.start_link(name: grpc_transport)

    {:ok, grpc_sup} =
      AshA2A.Transport.GRPC.Supervisor.start_link(
        port: 0,
        ip: {127, 0, 0, 1},
        handler: AshA2A.Sim.GrpcHandler,
        ctx: %{agent: agent_name, opts: %{}, transport: grpc_transport},
        auth: {AshA2A.Transport.GRPC.Auth, auth_opts(tokens)}
      )

    grpc_port = AshA2A.Transport.GRPC.Supervisor.port(grpc_sup)

    %{
      agent_name: agent_name,
      agent_pid: agent_pid,
      http_bandit: http_bandit,
      http_port: http_port,
      base_url: base_url,
      grpc_sup: grpc_sup,
      grpc_port: grpc_port,
      webhook_bandit: webhook_bandit,
      webhook_state: webhook_state,
      webhook_url: "http://127.0.0.1:#{webhook_port}/hook",
      card_pub_key: ec_pub,
      dkim_priv_key: dkim_priv,
      dkim_pub_key: dkim_pub,
      principal_a: principal_a,
      principal_b: principal_b,
      token_a: token_a,
      token_b: token_b,
      stop: fn ->
        for p <- [
              http_bandit,
              webhook_bandit,
              grpc_sup,
              grpc_transport_pid,
              agent_pid,
              webhook_state
            ] do
          if is_pid(p) and Process.alive?(p) do
            try do
              GenServer.stop(p, :normal, 1_000)
            catch
              :exit, _ -> :ok
            end
          end
        end

        # The gRPC listener's handler/ctx and bearer interceptor live in the
        # (process-global) application env: release them with the listener so
        # the next gRPC court starts from a clean seam.
        Application.delete_env(:ash_a2a, AshA2A.Transport.GRPC.Server)

        endpoint_key = AshA2A.Transport.GRPC.Server.Endpoint

        case endpoint_key
             |> then(&Application.get_env(:ash_a2a, &1, []))
             |> Keyword.delete(:auth) do
          [] -> Application.delete_env(:ash_a2a, endpoint_key)
          rest -> Application.put_env(:ash_a2a, endpoint_key, rest)
        end
      end
    }
  end
end
