if Code.ensure_loaded?(Plug) do
  defmodule AshA2A.Transport.GRPC.Auth do
    @moduledoc """
    Auth interceptor seam for `AshA2A.Transport.GRPC.Server` (gRPC binding).

    Closes the BIND-EQUIV-004 gap: the HTTP bindings enforce the JWT gate via
    `AshA2A.Protocol.Plug.Auth`; without this seam the gRPC binding admitted
    unauthenticated traffic.

    ## Seam contract

    `AshA2A.Transport.GRPC.Server` reads the optional endpoint option

        Application.put_env(:ash_a2a, AshA2A.Transport.GRPC.Server.Endpoint,
          auth: {AshA2A.Transport.GRPC.Auth, plug_auth_opts}
        )

    and, when present, runs `module.authenticate(mat, opts)` BEFORE dispatch
    on every RPC (unary and server-streaming). The interceptor must return:

        :ok                         -> call proceeds
        {:error, %GRPC.RPCError{}}  -> call refused with that error

    Unconfigured (no :auth in the endpoint env) the server keeps the current
    anonymous behavior — backward compatible with the TCK's anonymous gRPC
    subset and the wire tests that use an anonymous ctx by design.

    ## Reuse

    The default interceptor REUSES `AshA2A.Protocol.Plug.Auth` itself, not a
    re-implementation: `opts` is the exact map `Plug.Auth.init/1` returns
    (schemes + verify callback + security requirements), and the interceptor
    drives it through a synthetic `Plug.Conn` whose request headers are the
    gRPC call's metadata. Bearer credentials arrive as the gRPC metadata pair
    `{"authorization", "Bearer <jwt>"}` — the same header shape the HTTP
    binding extracts. Fail-closed: a crashing verify/3 callback yields
    UNAUTHENTICATED(16), never a 500-class INTERNAL.

    ## Wire refusal

    Failures map to gRPC UNAUTHENTICATED(16). The error message is the SAME
    typed body the HTTP binding emits on its 401: the JSON envelope
    `{"error":"Unauthorized"}` (see `Plug.Auth.send_unauthorized/2`), so
    clients see one refusal shape across bindings.
    """

    @grpc_unauthenticated 16
    @grpc_permission_denied 7

    @doc """
    PERMISSION_DENIED(7) refusal for an authenticated-but-forbidden caller.
    Interceptors return `{:error, :forbidden}` (or a 403 from the Auth
    pipeline) to produce it; UNAUTHENTICATED(16) stays for failed credentials.
    """
    @spec forbidden(String.t()) :: GRPC.RPCError.t()
    def forbidden(message \\ ~s({"error":"Forbidden"})),
      do: GRPC.RPCError.exception(status: @grpc_permission_denied, message: message)

    @doc """
    Runs the `AshA2A.Protocol.Plug.Auth` pipeline over a synthetic conn built
    from the gRPC call's metadata. `opts` is `AshA2A.Protocol.Plug.Auth.init/1`
    output. Returns `:ok` or `{:error, %GRPC.RPCError{}}`.
    """
    @spec authenticate(GRPC.Server.Stream.t(), map()) ::
            :ok | {:error, GRPC.RPCError.t()}
    def authenticate(mat, opts) do
      case authenticate_identity(mat, opts) do
        {:ok, _auth} -> :ok
        {:error, _} = error -> error
      end
    end

    @doc """
    Like `authenticate/2` but also returns the verified auth map
    (`%{identity: ...}`, the value `AshA2A.Protocol.Plug.Auth` stores in
    `conn.private[:a2a][:auth]`) so the server can scope the call to the
    verified principal (task ownership over gRPC). `{:ok, nil}` when the Auth
    pipeline admitted the call without an identity.
    """
    @spec authenticate_identity(GRPC.Server.Stream.t(), map()) ::
            {:ok, map() | nil} | {:error, GRPC.RPCError.t()}
    def authenticate_identity(mat, opts) do
      conn = conn_from_metadata(GRPC.Stream.get_headers(mat) || %{})

      # gRPC metadata is entirely client-controlled and the synthetic conn has
      # no TLS peer data, so a forwarded-certificate header is honoured only
      # when the endpoint explicitly vouches for its proxy
      # (`trust_forwarded_cert: true`); otherwise it is dropped.
      opts =
        if is_map(opts) and Map.get(opts, :trust_forwarded_cert) != true,
          do: Map.put(opts, :mtls_header, nil),
          else: opts

      conn = AshA2A.Protocol.Plug.Auth.call(conn, opts)

      if conn.halted do
        {:error, refusal(conn)}
      else
        {:ok, AshA2A.Protocol.Plug.Auth.get_identity(conn)}
      end
    end

    # gRPC metadata keys are ASCII-downcased already; enforce it and stringify
    # values so the header extraction in Plug.Auth (bearer / basic / api-key)
    # sees exactly what an HTTP request would carry.
    defp conn_from_metadata(metadata) when is_map(metadata) do
      req_headers =
        for {k, v} <- metadata do
          {String.downcase(to_string(k)), to_string(v)}
        end

      %Plug.Conn{
        adapter: {AshA2A.Transport.GRPC.Auth.SinkAdapter, nil},
        req_headers: req_headers,
        path_info: [],
        host: "grpc",
        method: "POST",
        query_string: "",
        owner: self()
      }
    end

    # The HTTP binding's 401 body, verbatim, on the gRPC UNAUTHENTICATED(16)
    # message: `{"error":"Unauthorized"}`. The WWW-Authenticate challenges the
    # plug appends are surfaced as the RPCError's details payload so the same
    # challenge information crosses the gRPC wire.
    defp refusal(_conn) do
      body =
        case received_refusal() do
          {401, _headers, body} -> body
          {403, _headers, body} -> {:forbidden, body}
          _ -> Jason.encode!(%{"error" => "Unauthorized"})
        end

      case body do
        {:forbidden, forbidden_body} -> forbidden(forbidden_body)
        body -> GRPC.RPCError.exception(status: @grpc_unauthenticated, message: body)
      end
    end

    defp received_refusal do
      receive do
        {:a2a_grpc_auth_refusal, status, headers, body} -> {status, headers, body}
      after
        0 -> :none
      end
    end
  end

  defmodule AshA2A.Transport.GRPC.Auth.SinkAdapter do
    @moduledoc """
    Minimal `Plug.Conn.Adapter` for the synthetic auth conn: the only adapter
    callback `AshA2A.Protocol.Plug.Auth` can invoke on the 401 path is
    `send_resp/4`; it delivers the refusal to the calling (authenticating)
    process so `authenticate/2` can read the exact body the HTTP binding
    would have sent, then the gRPC seam discards it onto the RPCError.
    """

    def send_resp(_payload, status, headers, body) do
      send(self(), {:a2a_grpc_auth_refusal, status, headers, body})
      {:ok, nil, nil}
    end
  end
end
