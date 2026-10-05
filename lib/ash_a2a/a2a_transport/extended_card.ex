# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.A2ATransport.ExtendedCard do
  @moduledoc """
  `agent/getAuthenticatedExtendedCard` for authenticated callers.

  The caller identity is the one `AshA2A.Protocol.Plug.Auth` verified and stored in
  `conn.private[:a2a][:auth]`; this module never authenticates anything
  itself. Outcomes (fail closed):

    * no `:extended_card` provider configured on the plug -> JSON-RPC
      `-32007` (AuthenticatedExtendedCardNotConfigured);
    * provider configured but no verified identity on the conn -> HTTP 401
      with JSON-RPC `-32600` and `data: "authentication required"`;
    * provider returns `{:error, reason}` or anything other than
      `{:ok, map}` -> `-32007` with the reason as data (the public card is
      never substituted);
    * `{:ok, card}` -> JSON-RPC success whose result is `card`, with the same
      internal credential keys the task path strips
      (`AshA2A.A2ATransport.Ownership.strip_wire/1`:
      `"a2a.auth"`, `"ash_a2a.owner"`, `:stream`) removed from the card map
      recursively before it is encoded and served. A provider cannot stream
      credentials onto the wire by embedding them in the output card.

  A provider is `(identity :: map(), public_card :: map()) -> {:ok, map()} |
  {:error, term()}` or `{module, function, extra_args}` called as
  `module.function(identity, public_card, ...extra_args)` via
  `AshA2A.CallbackRegistry` (the `{module, function, arity}` must be a registry
  member, otherwise the provider yields `{:error, %{code: :callback_not_permitted}}`). It receives
  the encoded public card (the same map served on the well-known path) so it
  can add skills or fields for the identity rather than rebuilding the card.
  """

  import Plug.Conn

  alias AshA2A.Protocol.JSONRPC.{Error, Response}

  # The same internal key convention as `AshA2A.A2ATransport.Ownership`
  # (`@internal_keys`, kept in sync by court): the verified-caller identity,
  # the recorded owner key and the raw stream reference never reach the wire.
  @internal_keys ["a2a.auth", "ash_a2a.owner", :stream]

  @doc "Answers `agent/getAuthenticatedExtendedCard`."
  @spec handle(Plug.Conn.t(), term(), map()) :: Plug.Conn.t()
  def handle(conn, id, %{extended_card: nil}),
    do:
      send_json(conn, 200, Response.error(id, Error.authenticated_extended_card_not_configured()))

  def handle(conn, id, opts) do
    case AshA2A.Protocol.Plug.Auth.get_identity(conn) do
      nil ->
        conn
        |> put_resp_header("www-authenticate", "Bearer")
        |> send_json(401, Response.error(id, Error.invalid_request("authentication required")))

      identity ->
        public = public_card(conn, opts)

        case call_provider(opts.extended_card, identity, public) do
          {:ok, card} when is_map(card) ->
            send_json(conn, 200, Response.success(id, strip_internal_keys(card)))

          {:error, reason} ->
            send_json(
              conn,
              200,
              Response.error(
                id,
                Error.authenticated_extended_card_not_configured(inspect(reason))
              )
            )

          other ->
            send_json(
              conn,
              200,
              Response.error(
                id,
                Error.authenticated_extended_card_not_configured(
                  "provider returned #{inspect(other)}"
                )
              )
            )
        end
    end
  end

  @doc false
  def public_card(conn, opts) do
    base_url = AshA2A.Protocol.Plug.get_base_url(conn) || opts.a2a.base_url
    card = GenServer.call(opts.a2a.agent, :get_agent_card)
    AshA2A.Protocol.JSON.encode_agent_card(card, [url: base_url] ++ opts.a2a.agent_card_opts)
  end

  defp call_provider(provider, identity, public) do
    invoke(provider, identity, public)
  rescue
    e -> {:error, {:provider_raised, Exception.message(e)}}
  end

  defp invoke(fun, identity, public) when is_function(fun, 2), do: fun.(identity, public)

  defp invoke({m, f, a}, identity, public) when is_atom(m) and is_atom(f) and is_list(a),
    do: AshA2A.CallbackRegistry.invoke(m, f, [identity, public | a])

  # Deep drop of `@internal_keys` from every map in the card (the card is not a
  # task, so `Ownership.strip_wire/1`'s top-level `"metadata"`-only shape does
  # not apply -- a provider can embed credentials inside `skills`, nested
  # metadata or any other field, so the drop is recursive over maps and lists).
  defp strip_internal_keys(%{} = card),
    do: card |> Map.drop(@internal_keys) |> Map.new(fn {k, v} -> {k, strip_internal_keys(v)} end)

  defp strip_internal_keys(list) when is_list(list), do: Enum.map(list, &strip_internal_keys/1)
  defp strip_internal_keys(other), do: other

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
