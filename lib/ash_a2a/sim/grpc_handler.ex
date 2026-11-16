# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Sim.GrpcHandler do
  @moduledoc """
  The `AshA2A.Protocol.JSONRPC` handler the simulation server gives to
  `AshA2A.Transport.GRPC.Server`.

  Sends, gets, cancels and lists go through `AshA2A.Transport.Plug`, the same
  handler the JSON-RPC mount uses, so tasks are owner-scoped to the verified
  gRPC caller. Push-notification configs go through
  `AshA2A.A2ATransport.PushConfigRPC` and the same store the HTTP mounts use,
  so a config created over gRPC is visible over HTTP and the other way round.
  `AshA2A.Transport.GRPC.Server` publishes the task a send or a cancel answers
  to the shared event log, so a task finished over gRPC delivers its push
  notifications.
  `GetExtendedAgentCard` answers the same provider-extended card as the HTTP
  mounts and refuses a caller with no verified identity.
  """

  @behaviour AshA2A.Protocol.JSONRPC

  alias AshA2A.A2ATransport.{PushConfigRPC, TaskEvents}
  alias AshA2A.Protocol.JSONRPC.Error
  alias AshA2A.Protocol.PushNotificationConfig
  alias AshA2A.Transport.Plug, as: TransportPlug

  @impl true
  def handle_send(message, params, ctx), do: TransportPlug.handle_send(message, params, ctx)

  @impl true
  def handle_get(task_id, params, ctx), do: TransportPlug.handle_get(task_id, params, scoped(ctx))

  @impl true
  def handle_cancel(task_id, params, ctx),
    do: TransportPlug.handle_cancel(task_id, params, scoped(ctx))

  @impl true
  def handle_list(params, ctx), do: TransportPlug.handle_list(params, scoped(ctx))

  @impl true
  def handle_set_push_config(%PushNotificationConfig{} = config, _params, ctx) do
    raw =
      %{"id" => config.id, "url" => config.url, "token" => config.token}
      |> put_some("protocolVersion", config.protocol_version)
      |> put_some("authentication", authentication_params(config.authentication))
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    with {:ok, envelope} <-
           push("tasks/pushNotificationConfig/set", Map.put(raw, "taskId", config.task_id), ctx) do
      {:ok, lift(envelope)}
    end
  end

  @impl true
  def handle_get_push_config(task_id, config_id, _params, ctx) do
    params = %{"id" => task_id, "pushNotificationConfigId" => config_id}

    with {:ok, envelope} <- push("tasks/pushNotificationConfig/get", params, ctx) do
      {:ok, lift(envelope)}
    end
  end

  @impl true
  def handle_list_push_configs(task_id, _params, ctx) do
    case push("tasks/pushNotificationConfig/list", %{"id" => task_id}, ctx) do
      {:ok, envelopes} when is_list(envelopes) -> {:ok, Enum.map(envelopes, &lift/1)}
      # A page with no configs carries no "configs" member.
      {:ok, %{} = page} -> {:ok, page |> Map.get("configs", []) |> Enum.map(&lift/1)}
      {:error, %Error{}} = error -> error
    end
  end

  @impl true
  def handle_delete_push_config(task_id, config_id, _params, ctx) do
    params = %{"id" => task_id, "pushNotificationConfigId" => config_id}

    case push("tasks/pushNotificationConfig/delete", params, ctx) do
      {:ok, _} -> :ok
      {:error, %Error{}} = error -> error
    end
  end

  @doc """
  Answers `GetExtendedAgentCard`: the provider-extended card for a verified
  caller, `-32600` for a caller with no verified identity.
  """
  @spec handle_extended_card(map()) :: {:ok, map()} | {:error, Error.t()}
  def handle_extended_card(%{auth: %{identity: identity}} = ctx) when not is_nil(identity) do
    card = GenServer.call(ctx.agent, :get_agent_card)

    public =
      TransportPlug.agent_card_json(
        card,
        %{
          agent_card_opts: Map.get(ctx, :agent_card_opts, []),
          push_notifications: true,
          extended_card: true,
          extensions: []
        },
        Map.fetch!(ctx, :base_url)
      )

    with {:ok, extended} <- AshA2A.Sim.Auth.extended_card(identity, public) do
      {:ok, sign_extended(extended, Map.get(ctx, :sign_with))}
    end
  end

  # Over gRPC the card travels as a protobuf `AgentCard`, and a client
  # verifies the ProtoJSON form of the message it received. The signature is
  # therefore computed over that form (the card after a round trip through the
  # proto message), with the same key as the HTTP mounts.
  defp sign_extended(card, nil), do: card

  defp sign_extended(card, sign_with) do
    card
    |> Map.delete("signatures")
    |> Jason.encode!()
    |> Protobuf.JSON.decode!(Lf.A2a.V1.AgentCard)
    |> Protobuf.JSON.to_encodable()
    |> case do
      {:ok, encodable} -> encodable
      encodable when is_map(encodable) -> encodable
    end
    |> AshA2A.Protocol.Plug.CardServe.sign_card(sign_with)
  end

  def handle_extended_card(_ctx), do: {:error, Error.invalid_request("authentication required")}

  # `AshA2A.Transport.Plug` reads `ctx.principal`; an unauthenticated gRPC call
  # carries none, so it is the anonymous principal.
  defp scoped(ctx), do: Map.put_new(ctx, :principal, :anonymous)

  defp push(method, params, ctx) do
    push_ctx = %{
      agent: ctx.agent,
      transport: ctx.transport,
      push_opts: TaskEvents.push_opts(ctx.transport),
      principal: Map.get(ctx, :principal, :anonymous),
      wire: :v1,
      a2a_version: Map.get(ctx, :a2a_version)
    }

    case PushConfigRPC.handle(method, params, :sim, push_ctx) do
      %{"result" => result} ->
        {:ok, result}

      %{"error" => error} ->
        {:error, %Error{code: error["code"], message: error["message"], data: error["data"]}}
    end
  end

  defp put_some(map, _key, nil), do: map
  defp put_some(map, key, value), do: Map.put(map, key, value)

  defp lift(%{"taskId" => task_id, "pushNotificationConfig" => inner}), do: lift(task_id, inner)
  defp lift(%{"taskId" => task_id} = flat), do: lift(task_id, flat)

  defp lift(task_id, source) do
    %PushNotificationConfig{
      id: source["id"],
      task_id: task_id,
      url: source["url"],
      token: source["token"],
      authentication: lift_authentication(source["authentication"]),
      protocol_version: source["protocolVersion"]
    }
  end

  # `AuthenticationInfo` travels to the store string-keyed and comes back
  # without `credentials`, which are write-only.
  defp authentication_params(%{} = auth) do
    params =
      %{}
      |> put_some("scheme", auth[:scheme] || auth["scheme"])
      |> put_some("credentials", auth[:credentials] || auth["credentials"])

    if params == %{}, do: nil, else: params
  end

  defp authentication_params(_none), do: nil

  defp lift_authentication(%{"scheme" => scheme} = auth) when is_binary(scheme),
    do: %{scheme: scheme, credentials: auth["credentials"]}

  defp lift_authentication(_none), do: nil
end
