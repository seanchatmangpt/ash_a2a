defmodule AshA2A.Protocol.CardSigner do
  @moduledoc """
  Signs wire-shaped (string-keyed, `encode_agent_card/2`-style) agent card maps.

  `AshA2A.Protocol.CardSigning` signs `%AgentCard{}` structs. Serve paths hold
  the already-encoded JSON map, so this module decodes the map to the card
  struct, signs it via `CardSigning.sign/3` (JCS-canonical, detached JWS per
  RFC 7797) and returns the map with the new entry appended to `"signatures"`.
  Existing signatures are kept; use `strip_signatures/1` first to replace them.

  Options: `:key` (required), `:alg` (`:HS256 | :RS256 | :ES256`), `:kid`,
  `:header` (extra unprotected header members merged into the entry `"header"`;
  never covers key selection).
  """

  alias AshA2A.Protocol.{CardSigning, JSON}

  @doc "Appends a signature entry to the card map's `\"signatures\"` list."
  @spec sign(map(), keyword()) :: map()
  def sign(card_json_map, opts) when is_map(card_json_map) and is_list(opts) do
    key = Keyword.fetch!(opts, :key)
    sign_opts = Keyword.take(opts, [:alg, :kid, :url])

    {:ok, struct} =
      case JSON.decode_agent_card(card_json_map) do
        {:ok, _} = ok -> ok
        {:error, reason} -> raise ArgumentError, "cannot sign card: #{inspect(reason)}"
      end

    # Digest the projection of the card WITHOUT its prior signatures so the
    # new entry is independent of them (verify also ignores them).
    signed = CardSigning.sign(%{struct | signatures: []}, key, sign_opts)
    [entry] = signed.signatures

    entry =
      case Keyword.get(opts, :header) do
        %{} = extra -> Map.update!(entry, "header", &Map.merge(extra, &1))
        _ -> entry
      end

    existing = Map.get(card_json_map, "signatures") || []
    Map.put(card_json_map, "signatures", existing ++ [entry])
  end

  @doc "Removes the `\"signatures\"` member from the card map."
  @spec strip_signatures(map()) :: map()
  def strip_signatures(card_json_map) when is_map(card_json_map),
    do: Map.delete(card_json_map, "signatures")
end
