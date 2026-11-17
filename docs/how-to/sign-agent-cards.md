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
combined on one mount.

The authenticated extended card is signed with the same key on every binding
that serves it (`agent/getAuthenticatedExtendedCard`, `GET /extendedAgentCard`):
signatures inherited from the public card are dropped and the card the
provider returned is signed as served. A gRPC host signs the card itself with
`AshA2A.Protocol.Plug.CardServe.sign_card/2` before answering
`GetExtendedAgentCard` (see `AshA2A.Sim.GrpcHandler`); there the signature is
over the ProtoJSON form of the `AgentCard` message, which is what a gRPC client
can reproduce.

`AshA2A.Sim.Server` signs every card it serves, public and extended, with a
fresh Ed25519 key (`info.card_jwks`), and `mix ash_a2a.sim --prove` verifies
them on every mount and binding.
Tests: `test/ash_a2a/protocol/agent_card_served_signature_test.exs` (real HTTP
listeners) and `test/ash_a2a/protocol/agent_card_signature_test.exs`.

## Rotate the signing key

A card carries the `kid` of the key that signed it, and a verifier looks that
`kid` up in the JWKS it trusts. Rotating without breaking clients means the
verifier trusts the new key before the server signs with it, and keeps the old
key until no cached card needs it.

1. Generate a new key pair with a new `kid` (for example `2026-11`).
2. Publish a JWKS that holds both public keys, and have clients load it.
3. Change the mount's `sign_with` to the new private JWK and `kid`, and
   restart or redeploy (the plug reads its options at init). The signed body is
   memoised per signing options, so the new key produces a new body.
4. After the longest cache lifetime of any card signed with the old key has
   passed, remove the old public key from the JWKS.

Run on 2026-11-17 with `mix run --no-start` against `AshA2A.Protocol.AgentCardSignature`
(two fresh Ed25519 keys, `kid`s `2026-10` and `2026-11`):

```text
old card, old key only : {:ok, ["2026-10"]}
new card, old key only : {:error, :unknown_kid}
old card, overlap JWKS : {:ok, ["2026-10"]}
new card, overlap JWKS : {:ok, ["2026-11"]}
old card, new key only : {:error, :unknown_kid}
```

A client that still trusts only the old key refuses the new card
(`:unknown_kid`), and a client that dropped the old key refuses a card signed
with it. Only the overlap JWKS verifies both, which is why step 2 comes first.

A hand-built card can carry both signatures during the overlap
(`Sig.attach(card, [old_entry, new_entry])`). The mounts sign with one key; to
serve two, sign the card map yourself. `Sig.verify/3` with `require: :any` (the
default) accepts the card if one entry verifies; `require: :all` needs every
entry to verify and returns `{:error, :unknown_kid}` if a client lacks one of
the keys:

```text
both sigs, new key only (any): {:ok, ["2026-11"]}
both sigs, new key only (all): {:error, :unknown_kid}
both sigs, overlap (all): {:ok, ["2026-10", "2026-11"]}
```

If the old key leaked, do not overlap: remove it from the JWKS at once. Cards
already signed with it stop verifying, which is the point.

## Not covered

- Duplicate or unsorted keys in raw JSON text are not detectable from a decoded
  map. Canonical sorting is done by the JCS encoder; atom/string key collisions
  are refused. A raw-JSON strict parser is not provided.
- JWKS fetching, how long to keep an old key, and trust anchoring are the caller's job; the order of a rotation is above.
- `AshA2A.Protocol.CardSigning` is a separate, non-standard scheme (HS256/RS256,
  wire-projected card); the two are not interoperable.
