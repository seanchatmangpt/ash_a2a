# Repair agent-card drift

When the agent card honesty court fails, fix the projection and re-sign.
Discovery must not advertise skills the resource cannot serve.

## Contents

1. Reproduce the honesty failure
2. Fix the builder / DSL projection
3. Re-sign and re-verify
4. See Also

## 1. Reproduce the honesty failure

```bash
mix test test/ash_a2a/protocol/agent_card_honesty_test.exs
```

A failure means the card advertises a skill, input/output schema, or
security scheme that the compiled capability index does not support, or a
signature verification refused the card.

## 2. Fix the builder / DSL projection

- Skill list: ensure every advertised skill maps to a public Ash action via
  the `a2a` DSL / `AshA2A.CapabilityIndex`.
- Schemas: regenerate from `AshA2A.Schema` rather than hand-editing the card.
- Signatures: only `ES256` / `EdDSA`; refuse `alg: none`.

Mutation killers for card signature drift live in
`lib/ash_a2a/chicago/mutation/catalog.ex` (`card_*` entries). Run:

```bash
mix ash_a2a.chicago.mutate --only card_alg_allowlist_ok,card_key_alg_ok,card_signature_verify_true
```

## 3. Re-sign and re-verify

Follow [Sign agent cards](sign-agent-cards.md): sign with a real JWK, attach
the detached JWS entry, verify against the public JWKS, then re-run the
honesty court.

```bash
mix test test/ash_a2a/protocol/agent_card_honesty_test.exs \
         test/ash_a2a/protocol/agent_card_signature_test.exs
```

## 4. See Also

- [Sign agent cards](sign-agent-cards.md)
- [Agent card honesty](../reference/agent-card-honesty.md)
- [Secure an A2A deployment](secure-an-a2a-deployment.md)
