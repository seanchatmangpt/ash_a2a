# How to mount the gRPC server in your own endpoint

Status: `install/1` and its idempotence are asserted by
`test/grpc_supervisor_restart_test.exs` ("the listener's last route answers unknown gRPC
methods"). The before/after output below was observed on 2026-11-17 with a
script that starts an endpoint of its own.

`AshA2A.Transport.GRPC.Supervisor` starts the A2A gRPC listener for you and
makes an unknown method answer `UNIMPLEMENTED`. If you instead declare your own
`GRPC.Endpoint` (to add interceptors, say) and start it yourself, one extra step
gives unknown methods the same answer.

## Why it matters

The gRPC adapter answers a path no RPC is served at with a bare HTTP `404`: no
`grpc-status`, no `content-type`. gRPC requires `UNIMPLEMENTED` (status 12) for a
method the server does not have. `AshA2A.Transport.GRPC.UnknownMethod` is a Cowboy
handler appended to the listener's dispatch as the last route. A request whose
`content-type` starts with `application/grpc` gets a Trailers-Only response
(HTTP 200, `grpc-status: 12`, a percent-encoded `grpc-message`). Anything else
keeps the 404.

## Mount

```elixir
defmodule MyApp.GRPCEndpoint do
  use GRPC.Endpoint

  # interceptors go here, before the service
  run AshA2A.Transport.GRPC.Server
end
```

Start it and configure the server as `AshA2A.Transport.GRPC.Server` describes
(`:handler` and `:ctx` in the application environment). Then install the
catch-all route right after the endpoint started:

```elixir
{:ok, _pid, _port} = GRPC.Server.start_endpoint(MyApp.GRPCEndpoint, 50051)
:ok = AshA2A.Transport.GRPC.UnknownMethod.install(MyApp.GRPCEndpoint)
```

`install/1` is idempotent: it adds the route once, and a second call returns `:ok`
without changing anything. It returns `{:error, {:unexpected_dispatch, term}}` when
the adapter's dispatch has a shape it does not know; the listener then keeps the
adapter's 404.

If you skip the call, nothing breaks: `AshA2A.Transport.GRPC.Server` installs the
route on its first RPC, for the endpoint serving it. Only a probe that arrives
before the first real RPC sees the 404. Call `install/1` yourself when a health
check or scanner can reach the port first.

## Observe it

A gRPC client that calls `/lf.a2a.v1.A2AService/NoSuchRpc`, against an endpoint
started as above (Python `grpcio`, status and detail printed):

```text
before install/1: StatusCode.UNIMPLEMENTED | Received http2 header with status: 404
after install/1 : StatusCode.UNIMPLEMENTED | Method not found: /lf.a2a.v1.A2AService/NoSuchRpc
second install/1: :ok
```

The client library maps the bare 404 to `UNIMPLEMENTED` itself; what changes is that
the server now sends the gRPC status and a message naming the method. A raw request
shows it without a client library, against the simulation server
(`mix ash_a2a.sim --grpc-port 50190`, which uses `AshA2A.Transport.GRPC.Supervisor`):

```console
$ curl -si --http2-prior-knowledge -H 'content-type: application/grpc' \
    -X POST http://127.0.0.1:50190/nothing/here
HTTP/2 200
content-length: 0
content-type: application/grpc
date: Tue, 17 Nov 2026 07:17:34 GMT
grpc-message: Method not found: /nothing/here
grpc-status: 12
server: Cowboy
```

The same path without the gRPC `content-type` answers `404`.
