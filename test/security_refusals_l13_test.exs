# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SecurityRefusalsL13Test do
  @moduledoc """
  Lane L13 (UNVERIFIED: written without an Elixir toolchain, never run).

  Refusal tests for the CHANGELOG Security items, driving the real HTTP plugs,
  the real gRPC auth module and the real push sender:

    * `A2A-Version` echo limited to a short printable token
    * `JSONGuard` depth cap on HTTP bodies
    * gRPC forwarded-certificate header ignored unless `trust_forwarded_cert: true`
    * legacy push sender refuses non-public hosts
    * `forbidden` replies carry no internal detail
  """

  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias AshA2A.Protocol.Plug.Auth
  alias AshA2A.Protocol.Plug.SecurityValidators
  alias AshA2A.Protocol.PushNotificationSender.HTTP, as: PushHTTP
  alias AshA2A.Protocol.SecurityScheme.{HTTPAuth, MutualTLS}
  alias AshA2A.Test.PlugFixture.GreeterAgent

  setup do
    agent = :"l13_refusals_agent_#{System.unique_integer([:positive])}"
    {:ok, pid} = GreeterAgent.start_link(name: agent)
    on_exit(fn -> AshA2A.TestSupport.SafeStop.stop(pid) end)
    %{agent: agent}
  end

  defp http_plugs(agent) do
    base = [agent: agent, base_url: "http://localhost:4000/a2a"]

    [
      {AshA2A.Protocol.Plug, AshA2A.Protocol.Plug.init(base)},
      {AshA2A.A2ATransport.Plug, AshA2A.A2ATransport.Plug.init(base)},
      {AshA2A.Transport.Plug, AshA2A.Transport.Plug.init(base)}
    ]
  end

  defp rpc_body do
    {:ok, message} = AshA2A.Protocol.JSON.encode(AshA2A.Protocol.Message.new_user("hi"))

    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "message/send",
      "params" => %{"message" => message}
    })
  end

  defp post(mod, opts, body, headers \\ []) do
    :post
    |> conn("/", body)
    |> put_req_header("content-type", "application/json")
    |> merge_req_headers(headers)
    |> mod.call(opts)
  end

  describe "A2A-Version echo over the real HTTP plugs" do
    test "a hostile or oversize version is never echoed verbatim", %{agent: agent} do
      for {mod, opts} <- http_plugs(agent),
          hostile <- ["9." <> String.duplicate("9", 100), "1.1\r\nx-injected: 1", "9.9;<b>"] do
        resp = post(mod, opts, rpc_body(), [{"a2a-version", hostile}])

        for value <- get_resp_header(resp, "a2a-version") do
          assert value == "invalid", "#{inspect(mod)} echoed #{inspect(value)}"
        end

        assert get_resp_header(resp, "x-injected") == []
      end
    end
  end

  describe "JSONGuard depth cap over the real HTTP plugs" do
    test "a deeply nested body is refused before dispatch", %{agent: agent} do
      deep = String.duplicate("[", 50_000)

      for {mod, opts} <- tl(http_plugs(agent)) do
        resp = post(mod, opts, deep)
        assert resp.status in [200, 400, 413]
        assert {:ok, decoded} = Jason.decode(resp.resp_body)
        assert is_map(decoded)
        refute Map.has_key?(decoded, "result"), inspect(mod)
        assert Map.has_key?(decoded, "error"), inspect(mod)
      end
    end
  end

  describe "gRPC forwarded certificate" do
    defmodule HeaderAdapter do
      @moduledoc false
      # Hand-written adapter exposing the call's metadata, as the real one does.
      def get_headers(headers), do: headers
    end

    @der <<48, 3, 2, 1, 1>>

    defp fingerprint, do: Base.encode16(:crypto.hash(:sha256, @der), case: :lower)

    defp mtls_auth(extra) do
      Auth.init(
        [
          schemes: %{"mtls" => %MutualTLS{}},
          verify:
            SecurityValidators.verifier(%{"mtls" => [kind: :mtls, fingerprints: [fingerprint()]]}),
          mtls_header: "x-client-cert"
        ] ++ extra
      )
    end

    defp stream_with(headers),
      do: %GRPC.Server.Stream{adapter: HeaderAdapter, payload: headers}

    test "ignored by default and unless trust_forwarded_cert: true" do
      stream = stream_with(%{"x-client-cert" => fingerprint()})

      assert {:error, %GRPC.RPCError{}} =
               AshA2A.Transport.GRPC.Auth.authenticate_identity(stream, mtls_auth([]))

      assert {:error, %GRPC.RPCError{}} =
               AshA2A.Transport.GRPC.Auth.authenticate_identity(
                 stream,
                 mtls_auth(trust_forwarded_cert: false)
               )
    end

    test "honoured only when the endpoint vouches for its proxy" do
      stream = stream_with(%{"x-client-cert" => fingerprint()})

      assert {:ok, %{identity: %{fingerprint: fp}}} =
               AshA2A.Transport.GRPC.Auth.authenticate_identity(
                 stream,
                 mtls_auth(trust_forwarded_cert: true)
               )

      assert fp == fingerprint()
    end
  end

  describe "legacy push sender refuses non-public hosts" do
    defp config(url), do: %{url: url, token: nil, authentication: nil}

    test "private, loopback and link-local literals and localhost" do
      for host <- ["10.0.0.1", "192.168.1.1", "172.16.0.1", "[::1]", "localhost"] do
        assert {:error, {:private_host, _}} =
                 PushHTTP.deliver(config("https://#{host}/hook"), %{"t" => 1}),
               host
      end
    end
  end

  describe "forbidden replies" do
    test "a 403 from the Auth plug carries no internal detail" do
      opts =
        Auth.init(
          schemes: %{"bearer" => %HTTPAuth{scheme: "bearer", bearer_format: "JWT"}},
          security: [%{"bearer" => ["notes.read"]}],
          verify: fn _scheme, _cred, _ctx -> {:error, :insufficient_scope} end
        )

      resp =
        :post
        |> conn("/")
        |> put_req_header("authorization", "Bearer abc.def.ghi")
        |> Auth.call(opts)

      assert resp.status in [401, 403]

      for banned <- ["stacktrace", "Elixir.", "%{", "lib/", "** ("] do
        refute resp.resp_body =~ banned
      end
    end

    test "SafeError redacts non-actionable reasons" do
      assert AshA2A.Transport.SafeError.redact({:action_resolution, "pg: relation x"}) ==
               {:action_resolution, :redacted}
    end
  end
end
