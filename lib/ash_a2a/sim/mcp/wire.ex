# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

if Code.ensure_loaded?(Bandit) do
  defmodule AshA2A.Sim.MCP.Wire do
    @moduledoc """
    The real clients behind the MCP tools of `AshA2A.Sim.MCP.Tools`. Every
    function opens a real connection to a listener of `AshA2A.Sim.Server` and
    answers what came back.

    | Function | Client | Used for |
    |---|---|---|
    | `http/5` | `Req` (HTTP/1.1) | the JSON-RPC and HTTP+JSON mounts, server-sent events included |
    | `grpc/5` | `GRPC.Stub` over `Mint` (HTTP/2) | the `lf.a2a.v1.A2AService` RPCs |
    | `grpc_raw/5` | `Mint.HTTP2` | a gRPC call whose message bytes the caller chose |
    | `tcp/4` | `:gen_tcp` | bytes written straight to a listener's socket |

    Each function answers `{:ok, map}` with string keys, or `{:error, text}`
    when no response arrived (connection refused, timeout).
    """

    alias Lf.A2a.V1, as: Pb
    alias Lf.A2a.V1.A2AService.Stub

    @service "lf.a2a.v1.A2AService"

    @grpc_status %{
      0 => "OK",
      1 => "CANCELLED",
      2 => "UNKNOWN",
      3 => "INVALID_ARGUMENT",
      4 => "DEADLINE_EXCEEDED",
      5 => "NOT_FOUND",
      6 => "ALREADY_EXISTS",
      7 => "PERMISSION_DENIED",
      8 => "RESOURCE_EXHAUSTED",
      9 => "FAILED_PRECONDITION",
      10 => "ABORTED",
      11 => "OUT_OF_RANGE",
      12 => "UNIMPLEMENTED",
      13 => "INTERNAL",
      14 => "UNAVAILABLE",
      15 => "DATA_LOSS",
      16 => "UNAUTHENTICATED"
    }

    @doc "The name of a gRPC status code, for example `\"NOT_FOUND\"` for `5`."
    @spec grpc_status_name(integer()) :: String.t()
    def grpc_status_name(code), do: Map.get(@grpc_status, code, "STATUS_#{code}")

    @doc "The gRPC service name the simulation server serves."
    @spec grpc_service() :: String.t()
    def grpc_service, do: @service

    # -- HTTP ------------------------------------------------------------------

    @doc """
    Sends one HTTP request and reads the whole response.

    `headers` is a list of `{name, value}`; `body` is the exact request body
    or `nil`. Options: `:timeout` (ms, default 20 000) and `:on_frame`, a
    function called with each decoded server-sent event as it arrives.

    Answers `"status"`, `"headers"`, `"raw"` (the response body bytes) and
    `"frames"` (the decoded `data:` payload of every server-sent event).
    """
    @spec http(atom(), String.t(), [{String.t(), String.t()}], binary() | nil, keyword()) ::
            {:ok, map()} | {:error, String.t()}
    def http(method, url, headers, body, opts \\ []) do
      on_frame = Keyword.get(opts, :on_frame, fn _frame -> :ok end)

      request =
        [
          method: method,
          url: url,
          headers: headers,
          retry: false,
          decode_body: false,
          compressed: false,
          redirect: false,
          receive_timeout: Keyword.get(opts, :timeout, 20_000),
          into: fn {:data, chunk}, {req, resp} ->
            raw = (resp.private[:raw] || "") <> chunk
            pending = (resp.private[:pending] || "") <> chunk

            {events, rest} =
              if sse?(Req.Response.get_header(resp, "content-type")),
                do: split_events(pending),
                else: {[], pending}

            for event <- events, frame <- decode_event(event), do: on_frame.(frame)

            resp =
              resp
              |> Req.Response.put_private(:raw, raw)
              |> Req.Response.put_private(:pending, rest)

            {:cont, {req, resp}}
          end
        ]
        |> then(fn request -> if body, do: Keyword.put(request, :body, body), else: request end)

      case Req.request(request) do
        {:ok, resp} ->
          raw = resp.private[:raw] || ""

          headers =
            Map.new(resp.headers, fn {name, values} ->
              {name, values |> List.wrap() |> Enum.join(", ")}
            end)

          frames =
            if (headers["content-type"] || "") =~ "text/event-stream" do
              {events, rest} = split_events(raw)
              Enum.flat_map(events ++ [rest], &decode_event/1)
            else
              []
            end

          {:ok,
           %{"status" => resp.status, "headers" => headers, "raw" => raw, "frames" => frames}}

        {:error, exception} ->
          {:error, "no HTTP response from #{url}: " <> Exception.message(exception)}
      end
    end

    defp sse?(values), do: Enum.any?(List.wrap(values), &(&1 =~ "text/event-stream"))

    defp split_events(buffer) do
      parts = String.split(buffer, ~r/\r?\n\r?\n/)
      {Enum.drop(parts, -1), List.last(parts)}
    end

    defp decode_event(event) do
      data =
        for line <- String.split(event, ~r/\r?\n/), String.starts_with?(line, "data:") do
          line |> String.replace_prefix("data:", "") |> String.trim_leading()
        end

      case data do
        [] ->
          []

        lines ->
          case Jason.decode(Enum.join(lines, "\n")) do
            {:ok, decoded} -> [decoded]
            {:error, _} -> [%{"undecoded" => Enum.join(lines, "\n")}]
          end
      end
    end

    # -- gRPC ------------------------------------------------------------------

    @doc "The request and response shape of every RPC of the service, by RPC name."
    @spec grpc_rpcs() :: %{
            String.t() => %{
              request: module(),
              response: module(),
              client_stream: boolean(),
              server_stream: boolean()
            }
          }
    def grpc_rpcs do
      Map.new(Pb.A2AService.Service.__rpc_calls__(), fn
        {name, {request, client_stream}, {response, server_stream}, _options} ->
          {Atom.to_string(name),
           %{
             request: request,
             response: response,
             client_stream: client_stream,
             server_stream: server_stream
           }}
      end)
    end

    @doc """
    Calls one RPC through the generated stub.

    `request` is the request message as protobuf JSON (a map); for
    `SendLiveMessage` it is a list of `StreamRequest` maps, written in order.
    Options: `:timeout`, `:on_frame`, and for `SendLiveMessage` `:half_close`
    (send END_STREAM after the last request).

    Answers `"status"` (the gRPC status code, `0` for OK), `"status_name"`,
    `"message"` (status message), `"headers"`, `"trailers"`, `"reply"` (the
    reply as protobuf JSON, unary RPCs), `"reply_bytes"` (the reply encoded as
    protobuf) and `"frames"` (each stream reply as protobuf JSON).
    """
    @spec grpc(String.t(), String.t(), map() | [map()], map(), keyword()) ::
            {:ok, map()} | {:error, String.t()}
    def grpc(target, rpc, request, metadata, opts \\ []) do
      timeout = Keyword.get(opts, :timeout, 20_000)

      with {:ok, shape} <- fetch_rpc(rpc),
           {:ok, message} <- encode_request(shape, request),
           {:ok, channel} <- connect(target) do
        call_opts = [metadata: metadata, timeout: timeout, return_headers: true]

        task =
          Task.async(fn ->
            try do
              run_rpc(rpc, shape, channel, message, call_opts, opts)
            rescue
              e -> {:error, "gRPC client failure: " <> Exception.message(e)}
            catch
              kind, reason -> {:error, "gRPC client #{kind}: #{inspect(reason)}"}
            end
          end)

        result =
          case Task.yield(task, timeout + 2_000) || Task.shutdown(task, :brutal_kill) do
            {:ok, outcome} -> outcome
            _ -> {:error, "no gRPC answer from #{target} within #{timeout} ms"}
          end

        GRPC.Stub.disconnect(channel)
        result
      end
    end

    defp fetch_rpc(rpc) do
      case Map.fetch(grpc_rpcs(), rpc) do
        {:ok, shape} -> {:ok, shape}
        :error -> {:error, "the service has no RPC named #{inspect(rpc)}"}
      end
    end

    defp connect(target) do
      case GRPC.Stub.connect(target, adapter: GRPC.Client.Adapters.Mint) do
        {:ok, channel} -> {:ok, channel}
        {:error, reason} -> {:error, "cannot connect to gRPC #{target}: #{inspect(reason)}"}
      end
    end

    defp encode_request(%{client_stream: true, request: module}, requests)
         when is_list(requests) do
      Enum.reduce_while(requests, {:ok, []}, fn request, {:ok, acc} ->
        case decode_pb(module, request) do
          {:ok, message} -> {:cont, {:ok, acc ++ [message]}}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end

    defp encode_request(%{client_stream: true}, _other),
      do: {:error, "a client-streaming RPC takes a list of request messages"}

    defp encode_request(%{request: module}, request), do: decode_pb(module, request)

    defp decode_pb(module, map) when is_map(map) do
      case Protobuf.JSON.decode(Jason.encode!(map), module) do
        {:ok, message} ->
          {:ok, message}

        {:error, error} ->
          {:error,
           "the request is not a #{inspect(module)} in protobuf JSON, so nothing was sent: " <>
             Exception.message(error)}
      end
    rescue
      e -> {:error, "the request could not be encoded as #{inspect(module)}: " <> inspect(e)}
    end

    defp decode_pb(module, _other),
      do: {:error, "the request for #{inspect(module)} must be a JSON object"}

    defp run_rpc("SendLiveMessage", _shape, channel, messages, call_opts, opts) do
      half_close? = Keyword.get(opts, :half_close, false)
      stream = Stub.send_live_message(channel, Keyword.delete(call_opts, :return_headers))
      last = length(messages) - 1

      stream =
        messages
        |> Enum.with_index()
        |> Enum.reduce(stream, fn {message, index}, stream ->
          GRPC.Stub.send_request(stream, message, end_stream: half_close? and index == last)
        end)

      stream
      |> GRPC.Stub.recv(timeout: call_opts[:timeout], return_headers: true)
      |> stream_result(opts)
    end

    defp run_rpc(rpc, %{server_stream: true}, channel, message, call_opts, opts),
      do: rpc |> stub(channel, message, call_opts) |> stream_result(opts)

    defp run_rpc(rpc, _shape, channel, message, call_opts, _opts) do
      case stub(rpc, channel, message, call_opts) do
        {:ok, reply, meta} -> {:ok, unary_ok(reply, meta)}
        {:ok, reply} -> {:ok, unary_ok(reply, %{})}
        {:error, %GRPC.RPCError{} = error} -> {:ok, rpc_error(error, [])}
        {:error, other} -> {:error, "gRPC call failed: #{inspect(other)}"}
      end
    end

    # One clause per RPC of the service: the generated stub function is named
    # statically, so an RPC the proto gains shows up as a tool with no client
    # until a clause is added, and `AshA2A.Sim.MCP.Coverage` reports it.
    defp stub("SendMessage", ch, m, o), do: Stub.send_message(ch, m, o)
    defp stub("SendStreamingMessage", ch, m, o), do: Stub.send_streaming_message(ch, m, o)
    defp stub("GetTask", ch, m, o), do: Stub.get_task(ch, m, o)
    defp stub("ListTasks", ch, m, o), do: Stub.list_tasks(ch, m, o)
    defp stub("CancelTask", ch, m, o), do: Stub.cancel_task(ch, m, o)
    defp stub("SubscribeToTask", ch, m, o), do: Stub.subscribe_to_task(ch, m, o)

    defp stub("CreateTaskPushNotificationConfig", ch, m, o),
      do: Stub.create_task_push_notification_config(ch, m, o)

    defp stub("GetTaskPushNotificationConfig", ch, m, o),
      do: Stub.get_task_push_notification_config(ch, m, o)

    defp stub("ListTaskPushNotificationConfigs", ch, m, o),
      do: Stub.list_task_push_notification_configs(ch, m, o)

    defp stub("DeleteTaskPushNotificationConfig", ch, m, o),
      do: Stub.delete_task_push_notification_config(ch, m, o)

    defp stub("GetExtendedAgentCard", ch, m, o), do: Stub.get_extended_agent_card(ch, m, o)
    defp stub(rpc, _ch, _m, _o), do: {:error, "no client stub is wired for RPC #{rpc}"}

    @doc "The RPC names `grpc/5` has a client stub for."
    @spec grpc_stubbed() :: [String.t()]
    def grpc_stubbed do
      ~w(SendMessage SendStreamingMessage SendLiveMessage GetTask ListTasks CancelTask
         SubscribeToTask CreateTaskPushNotificationConfig GetTaskPushNotificationConfig
         ListTaskPushNotificationConfigs DeleteTaskPushNotificationConfig GetExtendedAgentCard)
    end

    defp unary_ok(reply, meta) do
      %{
        "status" => 0,
        "status_name" => "OK",
        "message" => "",
        "headers" => string_map(meta[:headers]),
        "trailers" => string_map(meta[:trailers]),
        "reply" => unpb(reply),
        "reply_bytes" => Protobuf.encode(reply),
        "frames" => []
      }
    end

    defp rpc_error(%GRPC.RPCError{} = error, frames) do
      %{
        "status" => error.status,
        "status_name" => grpc_status_name(error.status),
        "message" => to_string(error.message || ""),
        "headers" => %{},
        "trailers" => %{
          "grpc-status" => to_string(error.status),
          "grpc-message" => to_string(error.message || "")
        },
        "reply" => nil,
        "reply_bytes" => nil,
        "frames" => frames
      }
    end

    defp stream_result({:ok, replies, meta}, opts), do: collect(replies, meta[:headers], opts)
    defp stream_result({:ok, replies}, opts), do: collect(replies, %{}, opts)
    defp stream_result({:error, %GRPC.RPCError{} = error}, _opts), do: {:ok, rpc_error(error, [])}

    defp stream_result({:error, other}, _opts),
      do: {:error, "gRPC call failed: #{inspect(other)}"}

    defp stream_result(other, _opts), do: {:error, "unexpected gRPC answer: #{inspect(other)}"}

    defp collect(replies, headers, opts) do
      on_frame = Keyword.get(opts, :on_frame, fn _frame -> :ok end)

      acc =
        Enum.reduce(replies, %{frames: [], trailers: %{}, error: nil}, fn
          {:ok, frame}, acc ->
            decoded = unpb(frame)
            on_frame.(decoded)
            %{acc | frames: acc.frames ++ [decoded]}

          {:trailers, trailers}, acc ->
            %{acc | trailers: string_map(trailers)}

          {:error, %GRPC.RPCError{} = error}, acc ->
            %{acc | error: error}

          _other, acc ->
            acc
        end)

      case acc.error do
        nil ->
          {:ok,
           %{
             "status" => 0,
             "status_name" => "OK",
             "message" => "",
             "headers" => string_map(headers),
             "trailers" => acc.trailers,
             "reply" => nil,
             "reply_bytes" => nil,
             "frames" => acc.frames
           }}

        error ->
          {:ok, error |> rpc_error(acc.frames) |> Map.put("headers", string_map(headers))}
      end
    end

    defp unpb(%Google.Protobuf.Empty{}), do: %{}
    defp unpb(message), do: message |> Protobuf.JSON.encode!() |> Jason.decode!()

    defp string_map(nil), do: %{}

    defp string_map(pairs),
      do: Map.new(pairs, fn {name, value} -> {to_string(name), to_string(value)} end)

    @doc """
    Sends one gRPC call over a fresh HTTP/2 connection with message bytes the
    caller chose. `payload` is wrapped in the 5-byte gRPC length prefix unless
    `frame: false`. Answers the HTTP `"status"`, `"headers"`, `"trailers"` and
    `"raw"`, the exact DATA bytes received.
    """
    @spec grpc_raw(String.t(), String.t(), [{String.t(), String.t()}], binary(), keyword()) ::
            {:ok, map()} | {:error, String.t()}
    def grpc_raw(target, path, headers, payload, opts \\ []) do
      timeout = Keyword.get(opts, :timeout, 10_000)
      [host, port] = String.split(target, ":")

      body =
        if Keyword.get(opts, :frame, true),
          do: <<0, byte_size(payload)::32, payload::binary>>,
          else: payload

      headers =
        [{"content-type", "application/grpc"}, {"te", "trailers"}]
        |> Enum.reject(fn {name, _} -> List.keymember?(headers, name, 0) end)
        |> Kernel.++(headers)

      with {:ok, conn} <-
             Mint.HTTP.connect(:http, host, String.to_integer(port), protocols: [:http2]),
           {:ok, conn, ref} <- Mint.HTTP.request(conn, "POST", path, headers, body) do
        acc = h2_loop(conn, ref, timeout, %{status: nil, headers: [], data: "", done: false})

        {head, trailers} =
          case Enum.reverse(acc.headers) do
            [head] -> {head, []}
            [head | rest] -> {head, List.flatten(rest)}
            [] -> {[], []}
          end

        trailers =
          if trailers == [] and List.keymember?(head, "grpc-status", 0), do: head, else: trailers

        {:ok,
         %{
           "status" => acc.status,
           "headers" => string_map(head),
           "trailers" => string_map(trailers),
           "raw" => acc.data,
           "complete" => acc.done
         }}
      else
        {:error, reason} -> {:error, "no HTTP/2 answer from #{target}: #{inspect(reason)}"}
        {:error, _conn, reason} -> {:error, "HTTP/2 request failed: #{inspect(reason)}"}
      end
    end

    defp h2_loop(conn, _ref, _timeout, %{done: true} = acc) do
      Mint.HTTP.close(conn)
      acc
    end

    defp h2_loop(conn, ref, timeout, acc) do
      receive do
        message ->
          case Mint.HTTP.stream(conn, message) do
            {:ok, conn, responses} ->
              h2_loop(conn, ref, timeout, Enum.reduce(responses, acc, &h2_response(&1, ref, &2)))

            {:error, conn, _reason, responses} ->
              Mint.HTTP.close(conn)
              Enum.reduce(responses, acc, &h2_response(&1, ref, &2))

            :unknown ->
              h2_loop(conn, ref, timeout, acc)
          end
      after
        timeout ->
          Mint.HTTP.close(conn)
          acc
      end
    end

    defp h2_response({:status, ref, status}, ref, acc), do: %{acc | status: status}

    defp h2_response({:headers, ref, headers}, ref, acc),
      do: %{acc | headers: [headers | acc.headers]}

    defp h2_response({:data, ref, data}, ref, acc), do: %{acc | data: acc.data <> data}
    defp h2_response({:done, ref}, ref, acc), do: %{acc | done: true}
    defp h2_response({:error, ref, _reason}, ref, acc), do: %{acc | done: true}
    defp h2_response(_other, _ref, acc), do: acc

    # -- TCP -------------------------------------------------------------------

    @doc """
    Writes `bytes` to `host:port` and reads until the peer closes or stays
    silent for `:idle_ms` (default 1 000). Answers `"raw"`, the bytes received,
    and `"closed"`, whether the peer closed the connection.
    """
    @spec tcp(String.t(), :inet.port_number(), binary(), keyword()) ::
            {:ok, map()} | {:error, String.t()}
    def tcp(host, port, bytes, opts \\ []) do
      idle = Keyword.get(opts, :idle_ms, 1_000)

      case :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false], 5_000) do
        {:ok, socket} ->
          :ok = :gen_tcp.send(socket, bytes)
          {raw, closed} = tcp_read(socket, idle, "")
          :gen_tcp.close(socket)
          {:ok, %{"raw" => raw, "closed" => closed}}

        {:error, reason} ->
          {:error, "cannot connect to #{host}:#{port}: #{inspect(reason)}"}
      end
    end

    defp tcp_read(socket, idle, acc) do
      case :gen_tcp.recv(socket, 0, idle) do
        {:ok, data} -> tcp_read(socket, idle, acc <> data)
        {:error, :closed} -> {acc, true}
        {:error, _timeout} -> {acc, false}
      end
    end
  end
end
