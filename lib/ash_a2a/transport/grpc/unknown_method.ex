# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Transport.GRPC.UnknownMethod do
  @moduledoc false
  # Cowboy handler for a path no RPC is served at.
  #
  # The gRPC adapter's router answers such a path with a bare HTTP 404: no
  # `grpc-status`, no `content-type`. gRPC requires `UNIMPLEMENTED` for a
  # method the server does not have, so `AshA2A.Transport.GRPC.Supervisor`
  # appends this handler to the listener's dispatch as the last route. A gRPC
  # request (a `content-type` starting `application/grpc`) gets a
  # Trailers-Only response: HTTP 200 with `grpc-status: 12` in the headers.
  # Anything else keeps the 404.

  @behaviour :cowboy_handler

  @impl true
  def init(req, state) do
    req =
      case :cowboy_req.header("content-type", req) do
        "application/grpc" <> _ = content_type ->
          :cowboy_req.reply(
            200,
            %{
              "content-type" => content_type,
              "grpc-status" => "12",
              "grpc-message" => grpc_message("Method not found: " <> :cowboy_req.path(req))
            },
            req
          )

        _not_grpc ->
          :cowboy_req.reply(404, req)
      end

    {:ok, req, state}
  end

  # grpc-message is percent-encoded (gRPC over HTTP/2: Status-Message).
  defp grpc_message(text), do: URI.encode(text, &(&1 in 0x20..0x7E and &1 != ?%))

  @doc """
  Appends the catch-all route to the dispatch the gRPC adapter stored for
  `endpoint`. Returns `:ok`, or `{:error, reason}` when the adapter's dispatch
  is not in the shape this module knows (the listener then keeps the adapter's
  own 404).
  """
  @spec install(module()) :: :ok | {:error, term()}
  def install(endpoint) do
    key = Module.concat(endpoint, Dispatch)

    case :persistent_term.get(key, :missing) do
      [{host, constraints, paths}] when is_list(paths) ->
        route = {:_, [], __MODULE__, %{}}

        unless route in paths do
          :persistent_term.put(key, [{host, constraints, paths ++ [route]}])
        end

        :ok

      other ->
        {:error, {:unexpected_dispatch, other}}
    end
  end
end
