# Sign agent cards (JWS, RFC 7515 detached)

Status: UNVERIFIED. The module and tests were written without an Elixir
toolchain and have never been compiled or run.

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

## Integration hook (for `agent_card.ex`, owned by lane W2-19)

Not wired yet. The card serve path should, after building the string-keyed
card map, call `Sig.sign/3` per configured key and `Sig.attach(map, entries)`.
Clients that fetch a card should call `Sig.verify/3` with a pinned JWKS before
trusting it. Sign the exact map that is served, since any later change breaks
the signature.

## Not covered

- Duplicate or unsorted keys in raw JSON text are not detectable from a decoded
  map. Canonical sorting is done by the JCS encoder; atom/string key collisions
  are refused. A raw-JSON strict parser is not provided.
- JWKS fetching, key rotation policy and trust anchoring are the caller's job.
- `AshA2A.Protocol.CardSigning` is a separate, non-standard scheme (HS256/RS256,
  wire-projected card); the two are not interoperable.
