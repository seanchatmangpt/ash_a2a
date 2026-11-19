# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.AuthSecurityHardeningTest do
  @moduledoc """
  W5: declared-scope enforcement, digest/unknown scheme refusal, mTLS peer
  certificate extraction, card_security/1 and card-vs-config preflight.
  Real Plug.Test conns through the real Auth plug and real SecurityValidators.
  """

  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias AshA2A.Authority.SecurityPreflight
  alias AshA2A.Protocol.Plug.Auth
  alias AshA2A.Protocol.Plug.SecurityValidators
  alias AshA2A.Protocol.SecurityScheme.{HTTPAuth, MutualTLS}

  @secret "w5-secret-w5-secret-w5-secret-32"

  defp b64(s), do: Base.url_encode64(s, padding: false)

  defp jwt(claims) do
    h = b64(Jason.encode!(%{"alg" => "HS256", "typ" => "JWT"}))
    # `sub` is a default required claim of the bearer validator.
    p = b64(Jason.encode!(Map.put_new(claims, "sub", "w5-user")))
    sig = :crypto.mac(:hmac, :sha256, @secret, "#{h}.#{p}") |> b64()
    "#{h}.#{p}.#{sig}"
  end

  defp exp, do: System.system_time(:second) + 600

  defp scoped_auth(config_extra \\ []) do
    Auth.init(
      schemes: %{"bearer" => %HTTPAuth{scheme: "bearer", bearer_format: "JWT"}},
      security: [%{"bearer" => ["notes.read"]}],
      verify: SecurityValidators.verifier(%{"bearer" => [secret: @secret] ++ config_extra})
    )
  end

  defp call_bearer(token, opts) do
    conn(:post, "/")
    |> put_req_header("authorization", "Bearer " <> token)
    |> Auth.call(opts)
  end

  describe "declared scope enforcement" do
    test "token with the declared scope is admitted" do
      conn = call_bearer(jwt(%{"exp" => exp(), "scope" => "notes.read other"}), scoped_auth())
      refute conn.halted
      assert %{scheme: "bearer"} = Auth.get_identity(conn)
    end

    test "token missing the declared scope gets 403 insufficient_scope" do
      conn = call_bearer(jwt(%{"exp" => exp(), "scope" => "other"}), scoped_auth())
      assert conn.halted
      assert conn.status == 403
      [challenge | _] = get_resp_header(conn, "www-authenticate")
      assert challenge =~ ~s(error="insufficient_scope")
      assert challenge =~ "notes.read"
    end

    test "explicit config required_scopes wins over declared scopes" do
      opts = scoped_auth(required_scopes: ["other"])
      conn = call_bearer(jwt(%{"exp" => exp(), "scope" => "other"}), opts)
      refute conn.halted
    end

    test "garbage token is still a plain 401" do
      conn = call_bearer("a.b.c", scoped_auth())
      assert conn.status == 401
    end
  end

  describe "HTTPAuth scheme handling" do
    test "digest is unsupported, never read as bearer" do
      opts =
        Auth.init(
          schemes: %{"d" => %HTTPAuth{scheme: "digest"}},
          verify: fn _, _, _ -> {:ok, %{id: "x"}} end
        )

      conn =
        conn(:post, "/")
        |> put_req_header("authorization", "Digest username=\"a\"")
        |> Auth.call(opts)

      assert conn.status == 401

      bearer_conn =
        conn(:post, "/")
        |> put_req_header("authorization", "Bearer tok")
        |> Auth.call(opts)

      assert bearer_conn.status == 401
    end

    test "basic challenge is capitalised" do
      opts =
        Auth.init(
          schemes: %{"b" => %HTTPAuth{scheme: "BASIC"}},
          verify: fn _, _, _ -> {:error, "no"} end
        )

      conn = conn(:post, "/") |> Auth.call(opts)
      assert conn.status == 401
      assert ["Basic realm=\"a2a\""] = get_resp_header(conn, "www-authenticate")
    end

    test "bearer_format JWT rejects a non-JWT token" do
      conn = call_bearer("opaque-token", scoped_auth())
      assert conn.status == 401
    end
  end

  describe "mTLS" do
    @der <<48, 3, 2, 1, 1>>

    defp fingerprint(der), do: Base.encode16(:crypto.hash(:sha256, der), case: :lower)

    defp mtls_opts(config, extra \\ []) do
      Auth.init(
        [
          schemes: %{"mtls" => %MutualTLS{}},
          verify: SecurityValidators.verifier(%{"mtls" => [kind: :mtls] ++ config})
        ] ++ extra
      )
    end

    test "peer certificate with an allowed fingerprint is admitted" do
      conn =
        conn(:post, "/")
        |> put_peer_data(%{address: {127, 0, 0, 1}, port: 1, ssl_cert: @der})
        |> Auth.call(mtls_opts(fingerprints: [fingerprint(@der)]))

      refute conn.halted
      assert %{identity: %{fingerprint: fp}} = Auth.get_identity(conn)
      assert fp == fingerprint(@der)
    end

    test "peer certificate not in the allowlist is refused" do
      conn =
        conn(:post, "/")
        |> put_peer_data(%{address: {127, 0, 0, 1}, port: 1, ssl_cert: @der})
        |> Auth.call(mtls_opts(fingerprints: [String.duplicate("0", 64)]))

      assert conn.status == 401
    end

    test "no allowlist configured refuses fail-closed" do
      conn =
        conn(:post, "/")
        |> put_peer_data(%{address: {127, 0, 0, 1}, port: 1, ssl_cert: @der})
        |> Auth.call(mtls_opts([]))

      assert conn.status == 401
    end

    test "no certificate and no header is unsupported (401)" do
      conn = conn(:post, "/") |> Auth.call(mtls_opts(fingerprints: [fingerprint(@der)]))
      assert conn.status == 401
    end

    test "forwarded fingerprint header is ignored unless :mtls_header is set" do
      base = conn(:post, "/") |> put_req_header("x-client-cert", fingerprint(@der))
      off = Auth.call(base, mtls_opts(fingerprints: [fingerprint(@der)]))
      assert off.status == 401

      on =
        Auth.call(
          base,
          mtls_opts([fingerprints: [fingerprint(@der)]], mtls_header: "x-client-cert")
        )

      refute on.halted
    end
  end

  describe "card consistency" do
    test "card_security/1 mirrors the plug options" do
      opts = [
        schemes: %{"bearer" => %HTTPAuth{scheme: "bearer"}},
        security: [%{"bearer" => ["a"]}],
        verify: fn _, _, _ -> {:error, "x"} end
      ]

      assert {%{"bearer" => %HTTPAuth{}}, [%{"bearer" => ["a"]}]} = Auth.card_security(opts)
    end

    test "preflight accepts consistent and flags dangling scheme references" do
      ok = %{
        security_schemes: %{"bearer" => %HTTPAuth{scheme: "bearer"}},
        security: [%{"bearer" => []}],
        skills: [%{security_requirements: [%{"bearer" => []}]}]
      }

      assert :ok = SecurityPreflight.check_card_security(ok)

      bad = %{ok | skills: [%{security_requirements: [%{"ghost" => []}]}]}

      assert {:error, [%{code: :card_security_unknown_scheme}]} =
               SecurityPreflight.check_card_security(bad)
    end
  end
end
