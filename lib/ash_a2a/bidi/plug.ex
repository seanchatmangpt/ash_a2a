# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Bidi.Plug do
  @moduledoc """
  Bidirectional-streaming wire surface: a drop-in wrapper around
  `AshA2A.A2ATransport.Plug` that adds the client→server direction.

  Intercepts two per-stream paths before delegating everything else to the
  unchanged A2A transport plug:

      POST <mount>/bidi/<task_id>/input   # deliver a mid-stream input
      POST <mount>/bidi/<task_id>/close   # explicit close (finalizes input)

  Bodies are JSON-RPC envelopes (methods `bidi/input` / `bidi/close`, the
  design choice documented in `AshA2A.Bidi`): `params` carry a real A2A
  `"message"` for input (decoded with the protocol codec, so the running
  skill receives `AshA2A.Protocol.Message` structs). Success is a JSON-RPC
  success envelope; failure is the protocol's typed error envelope
  (`google.rpc.ErrorInfo`):

    * `-32001` `TASK_NOT_FOUND` — unknown task id. Owner-scoped exactly like
      `tasks/resubscribe`: a task the verified caller does not own is
      indistinguishable from a missing one.
    * `-32004` `BIDI_INPUT_CLOSED` — the task exists but its input channel is
      gone (never opened, explicitly closed, task finished, or the stream
      consumer died). This is the "late input after completion" refusal.
    * `-32600` / `-32602` — malformed envelope / invalid params.

  ## Usage

      forward "/a2a", AshA2A.Bidi.Plug,
        agent: MyAgent,
        base_url: "https://agents.example.com/a2a",
        transport: MyTransport

  All `AshA2A.A2ATransport.Plug` options pass through unchanged.
  """

  @behaviour Plug

  import Plug.Conn

  alias AshA2A.A2ATransport
  alias AshA2A.A2ATransport.Ownership
  alias AshA2A.Bidi
  alias AshA2A.Protocol.JSONRPC.{Error, Response}

  @error_info_type "type.googleapis.com/google.rpc.ErrorInfo"
  @a2a_domain "a2a-protocol.org"

  @doc false
  def init(opts), do: A2ATransport.Plug.init(opts)

  @impl Plug
  def call(%{method: "POST"} = conn, opts) do
    case bidi_suffix(conn.path_info) do
      :not_bidi ->
        A2ATransport.Plug.call(conn, opts)

      {"input", task_id} ->
        handle_input(conn, task_id, opts)

      {"close", task_id} ->
        handle_close(conn, task_id, opts)
    end
  end

  def call(conn, opts), do: A2ATransport.Plug.call(conn, opts)

  # `<mount>/bidi/<task_id>/<action>` -> `{action, task_id}`; anything else is
  # not ours (the A2A JSON-RPC path is a single segment, so no collision).
  defp bidi_suffix(path) when is_list(path) do
    case Enum.split(path, -3) do
      {_prefix, ["bidi", task_id, action]}
      when action in ~w(input close) and is_binary(task_id) ->
        {action, task_id}

      _ ->
        :not_bidi
    end
  end

  defp bidi_suffix(_path), do: :not_bidi

  # -- per-stream input endpoint -----------------------------------------------------

  defp handle_input(conn, task_id, opts) do
    with {:ok, body, conn} <- read_json(conn),
         {:ok, id, params} <- envelope(body, "bidi/input") do
      cond do
        not owned?(conn, task_id, opts) ->
          send_json(conn, id, Response.error(id, Error.task_not_found()))

        not is_map_key(params, "message") ->
          send_json(conn, id, Response.error(id, Error.invalid_params("\"message\" is required")))

        true ->
          case AshA2A.Protocol.JSON.decode(params["message"], :message) do
            {:ok, message} ->
              case Bidi.deliver(task_id, message) do
                {:ok, :accepted} ->
                  send_json(conn, id, Response.success(id, %{"accepted" => true}))

                {:error, _reason} ->
                  send_json(conn, id, Response.error(id, bidi_closed_error()))
              end

            {:error, reason} ->
              send_json(conn, id, Response.error(id, Error.invalid_params(inspect(reason))))
          end
      end
    else
      {:error, %Error{} = error, conn} -> send_json(conn, nil, Response.error(nil, error))
      {:error, %Error{} = error} -> send_json(conn, nil, Response.error(nil, error))
    end
  end

  # -- explicit close ------------------------------------------------------------------

  defp handle_close(conn, task_id, opts) do
    with {:ok, body, conn} <- read_json(conn),
         body = normalize_body(body),
         {:ok, id, _params} <- envelope(body, "bidi/close", :allow_empty_params) do
      if owned?(conn, task_id, opts) do
        Bidi.close(task_id)
        send_json(conn, id, Response.success(id, %{"closed" => true, "taskId" => task_id}))
      else
        send_json(conn, id, Response.error(id, Error.task_not_found()))
      end
    else
      {:error, %Error{} = error, conn} -> send_json(conn, nil, Response.error(nil, error))
      {:error, %Error{} = error} -> send_json(conn, nil, Response.error(nil, error))
    end
  end

  defp normalize_body(nil), do: %{"jsonrpc" => "2.0", "method" => "bidi/close", "id" => nil}
  defp normalize_body(body) when is_map(body), do: body
  defp normalize_body(_other), do: :invalid

  # -- envelope -------------------------------------------------------------------------

  # Hand-validated JSON-RPC envelope (the A2ATransport plug's Request.parse
  # family validates the protocol's own methods; `bidi/*` are extension
  # methods, so the same checks are applied here instead).
  @spec envelope(term(), String.t(), atom()) ::
          {:ok, term(), map()} | {:error, Error.t()} | :invalid
  defp envelope(body, method, empty \\ :require_params)

  defp envelope(:invalid, _method, _empty) do
    {:error, Error.parse_error()}
  end

  defp envelope(%{"jsonrpc" => "2.0", "id" => id} = body, method, empty) do
    if Map.get(body, "method") == method do
      params = Map.get(body, "params")

      cond do
        is_map(params) ->
          {:ok, id, params}

        empty == :allow_empty_params and is_nil(params) ->
          {:ok, id, %{}}

        true ->
          {:error, Error.invalid_request("\"params\" must be an object")}
      end
    else
      {:error, Error.invalid_request("expected method #{inspect(method)}")}
    end
  end

  defp envelope(_body, method, _empty),
    do: {:error, Error.invalid_request("expected method #{inspect(method)}")}

  defp owned?(conn, task_id, opts) do
    match?({:ok, _}, Ownership.fetch(opts.a2a.agent, task_id, Ownership.caller(conn)))
  end

  defp bidi_closed_error do
    # Pre-wrapped: Error.to_map/1 preserves an existing ErrorInfo, so the wire
    # carries reason BIDI_INPUT_CLOSED instead of the default
    # UNSUPPORTED_OPERATION stamp for -32004.
    Error.unsupported_operation([
      %{
        "@type" => @error_info_type,
        "domain" => @a2a_domain,
        "reason" => "BIDI_INPUT_CLOSED",
        "metadata" => %{
          "detail" => "the task's input channel is closed; late input is refused"
        }
      }
    ])
  end

  defp read_json(%{body_params: %Plug.Conn.Unfetched{}} = conn) do
    case read_body(conn) do
      {:ok, "", conn} ->
        # An empty body is legitimate for `bidi/close` (no params needed);
        # `bidi/input` refuses it as an invalid envelope instead.
        {:ok, nil, conn}

      {:ok, body, conn} ->
        case Jason.decode(body) do
          {:ok, decoded} -> {:ok, decoded, conn}
          {:error, _} -> {:error, Error.parse_error(), conn}
        end

      {:more, _partial, conn} ->
        {:error, Error.parse_error("Body too large"), conn}

      {:error, reason} ->
        {:error, Error.internal_error(inspect(reason)), conn}
    end
  end

  defp read_json(%{body_params: params} = conn), do: {:ok, params, conn}

  defp send_json(conn, _id, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(body))
  end
end
