defmodule A2aDemo.CardSigning do
  @moduledoc false

  @doc """
  Optional signed card support: when `A2A_DEMO_CARD_KEY` is set, produces the
  JWS entries for the JSON-RPC mount's card (passed through
  `agent_card_opts: [signatures: ...]`).

  ## Why this is not a plain `CardSigning.sign/3` call

  `AshA2A.Protocol.CardSigning.sign/3` signs the STRUCT projection
  (`encode_agent_card(card, url: ...)`) — but `AshA2A.Transport.Plug` serves
  a document that also carries its own fixed `capabilities` override and the
  serve-time extension injection from `:extensions`, which `sign/3` cannot
  express. Signing the struct projection therefore produced a card whose
  signature never verified against the served bytes (digest_mismatch), so
  this helper builds the JWS over the EXACT served document instead — the
  same public encoder (`AshA2A.Transport.Plug.agent_card_json/3`), the same
  JCS canonicalization, the same HS256 detached-JWS entry shape
  `AshA2A.Protocol.CardSigning.verify/2` verifies:

      protected  = b64url(%{"alg" => "HS256", "typ" => "a2a-card", "sha256" => digest})
      signature  = b64url(HMAC-SHA256(key, protected <> "." <> jcs_bytes))

  where `jcs_bytes` is RFC 8785 of the served document minus its
  `signatures` member. `A2aDemo.Smoke` re-verifies the served bytes with
  `CardSigning.verify/2`, which proves the equivalence for real.
  """
  def maybe_signatures(base_url) do
    case System.get_env("A2A_DEMO_CARD_KEY") do
      key when key in [nil, ""] ->
        []

      key when is_binary(key) ->
        card = GenServer.call(A2aDemo.Agent, :get_agent_card)

        served =
          AshA2A.Transport.Plug.agent_card_json(card, %{
            agent_card_opts: [],
            push_notifications: false,
            extensions: [AshA2A.Semantic.Extension.capability_declaration()]
          }, base_url)

        jcs = Jcs.encode(jason_round_trip(Map.delete(served, "signatures")))
        digest = Base.encode16(:crypto.hash(:sha256, jcs), case: :lower)

        protected =
          %{"alg" => "HS256", "typ" => "a2a-card", "sha256" => digest}
          |> Jason.encode!()
          |> Base.url_encode64(padding: false)

        signature =
          :crypto.mac(:hmac, :sha256, key, protected <> "." <> jcs)
          |> Base.url_encode64(padding: false)

        [
          %{
            "protected" => protected,
            "header" => %{"alg" => "HS256", "typ" => "a2a-card"},
            "signature" => signature
          }
        ]
    end
  end

  @doc "Verify a served (decoded) card with `A2A_DEMO_CARD_KEY`."
  def verify_served(card, base_url) do
    key = System.get_env("A2A_DEMO_CARD_KEY")

    if key in [nil, ""] do
      :no_signing_configured
    else
      AshA2A.Protocol.CardSigning.verify(card, key, url: base_url)
    end
  end

  defp jason_round_trip(map), do: map |> Jason.encode!() |> Jason.decode!()
end
