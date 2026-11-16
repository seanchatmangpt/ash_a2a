# Agent card honesty

Status: UNVERIFIED. This lane was written without an Elixir toolchain; nothing
here has been compiled or run.

`AshA2A.Protocol.AgentCard.audit(card, mounted_opts)` returns a list of
`%{code: atom, message: String.t()}` discrepancies between a card (struct or
wire map) and what is mounted and enabled. `[]` means the card claims nothing
beyond the mounted surface.

| Card claim | Checked against | Code |
|---|---|---|
| `supportedInterfaces[].protocolBinding` | `AshA2A.Domain.Info.supported_interfaces/1` (legacy `JSONRPC` when no mounts) or `:bindings` | `:unmounted_binding`, `:unknown_binding` |
| `capabilities` streaming, pushNotifications, userArtifacts, extendedAgentCard | the domain `transport` flags, or the same-named opt | `:capability_not_enabled` |
| `capabilities.live` | only the `:live` opt (no domain flag exists; default not enabled) | `:capability_not_enabled` |
| `skills[].id` | `AshA2A.Info.capability_index/1` (public actions) or `:skill_ids` | `:skill_not_public` |
| `securitySchemes` | domain `security_scheme` declarations or `:security_schemes` | `:security_scheme_not_configured` |
| `securityRequirements` | the card's own `securitySchemes` | `:security_requirement_undeclared` |

A capability with no expectation counts as not enabled, so advertising it
fails. Without `:domain`, only `JSONRPC` is accepted unless `:bindings` is set.

## Signatures passthrough

`AshA2A.Info.agent_card(domain, card_signatures: [%{...}])` places the list under
the card's `signatures` key unmodified. A value that is not a list of maps is
dropped. Nothing is signed or verified here; signing is a separate lane.

## Remaining

- The builder still defaults `streaming` to `true` when no domain is given; the
  audit flags that case, but the default is unchanged (out of scope).
- Audit does not check that a mounted agent process is actually running, only
  declared configuration.
- Test: `test/ash_a2a/protocol/agent_card_honesty_test.exs` (UNVERIFIED).
