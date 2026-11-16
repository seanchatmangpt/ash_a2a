# Sign agent cards (JWS, RFC 7515 detached)

Status: verified (2026-11-16, Elixir 1.20.4 / OTP 29.1.1): `mix test
test/ash_a2a/protocol/agent_card_signature_test.exs`, 8 passed.

`AshA2A.Protocol.AgentCardSignature` produces and checks standard
`AgentCardSignature` entries (`protected`, `signature`) for the card's
`signatures` field. The payload is the RFC 8785 canonical JSON of the
string-keyed card map without `"signatures"`, detached: the signing input is
`protected <> "." <> b64url(canonical_bytes)`. Algorithms: `ES256`, `EdDSA`.
Keys are JWK maps.

```elixir
alias AshA2A.Protocol.AgentCardSignature, as: Sig

{:ok, entry} = Sig.sign(card_map, private_jwk, kid: "2026-11")
signed = Sig.attach(card_map, [entry])

{:ok, ["2026-11"]} = Sig.verify(signed, %{"keys" => [public_jwk_with_kid]})
```

Verification trusts only the protected header. It refuses `alg: none`, any alg
outside `ES256`/`EdDSA`, alg/key mismatch, missing `kid`, unknown `kid`, `crit`,
tampered cards, bad signatures, and cards whose map keys are not all strings.
`verify/3` options: `:allowed_algs`, `:require` (`:any` default, or `:all`).

## Serve a signed card

Every HTTP card mount (`AshA2A.Protocol.Plug`, `AshA2A.A2ATransport.Plug`,
`AshA2A.Transport.Plug`, `AshA2A.Transport.HTTPJSON`) takes `:sign_with`. Give
it a private JWK and the served `/.well-known/agent-card.json` carries one
`signatures` entry computed over the exact served document:

```elixir
plug AshA2A.Transport.Plug,
  agent: MyApp.Agent,
  base_url: "https://agent.example/a2a",
  sign_with: [jwk: private_jwk, kid: "2026-11"]
```

`:kid` defaults to the JWK's `"kid"`; `:alg` (`"ES256"` or `"EdDSA"`) is
inferred from the key. The signed body is memoised, so the bytes and the `ETag`
are stable across requests. A key that cannot sign raises `ArgumentError` when
the card is requested: a card configured to be signed is never served unsigned.

A client verifies the decoded body with a pinned JWKS before trusting it:

```elixir
card = Jason.decode!(body)
{:ok, ["2026-11"]} = Sig.verify(card, %{"keys" => [public_jwk_with_kid]})
```

The entry shape is the A2A v1.1 `AgentCardSignature` message (`protected`,
`signature`, optional `header`). `sign_with: [key: ..., alg: :HS256, kid: ...]`
still selects the older `AshA2A.Protocol.CardSigning` scheme; the two cannot be
combined on one mount. The authenticated extended card is re-signed only by the
older scheme; with a JWK it is served without `signatures`.

`AshA2A.Sim.Server` signs every card it serves with a fresh ES256 key
(`info.card_jwks`), and `mix ash_a2a.sim --prove` verifies it on every mount.
Tests: `test/ash_a2a/protocol/agent_card_served_signature_test.exs` (real HTTP
listeners) and `test/ash_a2a/protocol/agent_card_signature_test.exs`.

## Not covered

- Duplicate or unsorted keys in raw JSON text are not detectable from a decoded
  map. Canonical sorting is done by the JCS encoder; atom/string key collisions
  are refused. A raw-JSON strict parser is not provided.
- JWKS fetching, key rotation policy and trust anchoring are the caller's job.
- `AshA2A.Protocol.CardSigning` is a separate, non-standard scheme (HS256/RS256,
  wire-projected card); the two are not interoperable.
