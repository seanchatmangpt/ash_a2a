defmodule AshA2A.A2ATransport.ExtendedCard do
  @moduledoc """
  `agent/getAuthenticatedExtendedCard` for authenticated callers.

  The caller identity is the one `A2A.Plug.Auth` verified and stored in
  `conn.private[:a2a][:auth]`; this module never authenticates anything
  itself. Outcomes (fail closed):

    * no `:extended_card` provider configured on the plug -> JSON-RPC
      `-32007` (AuthenticatedExtendedCardNotConfigured);
    * provider configured but no verified identity on the conn -> HTTP 401
      with JSON-RPC `-32600` and `data: "authentication required"`;
    * provider returns `{:error, reason}` or anything other than
      `{:ok, map}` -> `-32007` with the reason as data (the public card is
      never substituted);
    * `{:ok, card}` -> JSON-RPC success whose result is `card`.

  A provider is `(identity :: map(), public_card :: map()) -> {:ok, map()} |
  {:error, term()}` or `{module, function, extra_args}` called as
  `apply(module, function, [identity, public_card | extra_args])`. It receives
  the encoded public card (the same map served on the well-known path) so it
  can add skills or fields for the identity rather than rebuilding the card.
  """

  import Plug.Conn

  alias A2A.JSONRPC.{Error, Response}

  @doc "Answers `agent/getAuthenticatedExtendedCard`."
  @spec handle(Plug.Conn.t(), term(), map()) :: Plug.Conn.t()
  def handle(conn, id, %{extended_card: nil}),
    do:
      send_json(conn, 200, Response.error(id, Error.authenticated_extended_card_not_configured()))

  def handle(conn, id, opts) do
    case A2A.Plug.Auth.get_identity(conn) do
      nil ->
        conn
        |> put_resp_header("www-authenticate", "Bearer")
        |> send_json(401, Response.error(id, Error.invalid_request("authentication required")))

      identity ->
        public = public_card(conn, opts)

        case call_provider(opts.extended_card, identity, public) do
          {:ok, card} when is_map(card) ->
            send_json(conn, 200, Response.success(id, card))

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
    base_url = A2A.Plug.get_base_url(conn) || opts.a2a.base_url
    card = GenServer.call(opts.a2a.agent, :get_agent_card)
    A2A.JSON.encode_agent_card(card, [url: base_url] ++ opts.a2a.agent_card_opts)
  end

  defp call_provider(provider, identity, public) do
    invoke(provider, identity, public)
  rescue
    e -> {:error, {:provider_raised, Exception.message(e)}}
  end

  defp invoke(fun, identity, public) when is_function(fun, 2), do: fun.(identity, public)

  defp invoke({m, f, a}, identity, public) when is_atom(m) and is_atom(f) and is_list(a),
    do: apply(m, f, [identity, public | a])

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
