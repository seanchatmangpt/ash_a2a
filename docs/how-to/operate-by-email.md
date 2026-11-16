# Operate by Email

Drive governed actions from an inbox: the system mails a brief, the approver replies, and
only the approved items are dispatched.

## The loop

1. `AshA2A.Email.Brief.render/1` renders pending actions as a numbered email. The brief
   carries a graph digest and a signed reply token.
2. The approver replies with intent lines such as `approve 1,3 hold 2`.
3. The mail provider posts the inbound message to `AshA2A.Email.Plug`.
4. `AshA2A.Email.Inbound` parses and authenticates the message.
5. `AshA2A.Email.ReplyIntent` maps the reply to per-item decisions.
6. Each approved item goes to the configured `dispatch` function. Held items do not.

## Trust model: auth is not authority

- Authentication (DKIM pass, a valid reply token) proves who sent the mail. It grants no
  power by itself.
- Authority comes from the brief: only items listed in the original brief, under the
  graph state it was rendered against, can be approved.
- A reply never names new actions. Unknown item numbers are ignored or refused.

## Fail-closed rules

| Condition | Response | Dispatch |
|---|---|---|
| Provider webhook credential missing or wrong | 401 | none |
| `:webhook` or `:token_ledger` not configured | 503 | none |
| Body too large, too deep or reply text too long | 413 | none |
| Body not valid JSON or webhook unparseable | 400 | none |
| Sender not verified (`Inbound.verify_sender/2`) | 401 | none |
| Missing `in_reply_to` | 400 | none |
| `in_reply_to` matches no brief | 404 | none |
| Unparseable intent | 422 | none |
| Tampered, missing or invalid reply token | 403 | none |
| Brief names an `:approver` and the sender is another principal | 403 | none |
| Reply token already used | 409 | none |
| Graph digest differs from the brief | 409 plus a reconfirm email | none |

Per-action standing in the 200 body: `dispatched`, `held`, or `refused`. A dispatch
error or exception is recorded as `refused`, never raised.

Any doubt means no dispatch. A stale digest sends a fresh brief so the approver
reconfirms against current state.

## Configuration

`AshA2A.Email.Plug` serves `POST /v1/email:ingest`. Options (from the module doc):

- `:policy` (required) and `:brief_lookup` (required, `message_id -> {:ok, brief}`
  with optional current digests, or `:error`).
- `:dispatch` `(principal, action -> {:ok, receipt} | {:error, reason})`. Default
  `default_dispatch/3` uses `:resolver` (default refuses `:unresolvable`) and
  `:kernel_entry` (default `AshA2A.Email.KernelEntry.run/4`, via `CommandBus`).
- `:reply_sender` `(to, subject, text -> any)`; default no-op. Subjects are stripped of
  CR/LF and control characters and capped at 200 characters.
- `:webhook` (required): `{:sendgrid | :workspace | :ses, opts}` for
  `AshA2A.Email.Webhook.verify/3`, or `:trusted_ingress` when an upstream hop already
  authenticated the provider. The `auth_results` in the body are not trusted otherwise.
- `:token_ledger` (required): single-use reply tokens, message-id replay cache and per-sender
  `:rate_limit`.
- `:max_body_bytes`, `:max_reply_chars`: size caps (defaults 262144 and 16384).
- Brief key `:approver`: principal id bound to the brief; set it for per-approver briefs.

The request body carries `"reply_tokens"`: action number to token
(`Brief.reply_token/2`); a token is required for every approved action.

## Test it

`test/email_plug_test.exs` and `test/email_gateway_hardening_test.exs` exercise the loop and
the refusals above through `Plug.Test` (standing UNVERIFIED: written without an Elixir
toolchain, no run cited).

## DKIM and durable replay ledger (UNVERIFIED)

`AshA2A.Email.Dkim` (`lib/ash_a2a/email/dkim.ex`) verifies `DKIM-Signature` headers with
`:public_key`: rsa-sha256, relaxed/relaxed, `bh=`, `h=` (must cover `from`), key from your resolver
(the DNS `p=` value). It refuses `l=`, expired `x=`, unsigned or duplicated From, From not aligned
with `d=`, weak (<1024-bit) or revoked keys. Wire it as the SES `:signature_verifier`:

    webhook: {:ses, signature_verifier: AshA2A.Email.Dkim.verifier(key_resolver: &MyApp.Dns.dkim_key/2)}

The verifier takes a raw message, a map with `"content"`, or an SNS envelope whose `"Message"`
JSON carries `"content"`. It proves the signing domain vouched for the message; it confers no
authority.

`AshA2A.Email.TokenLedgerStore` (`lib/ash_a2a/email/token_ledger_store.ex`) is an EKV-backed ledger
answering the same calls as `TokenLedger`, so the plug accepts it unchanged:

    {AshA2A.TaskStore.Ekv, ...}  # child_spec(name: MyApp.EmailKv, data_dir: "...")
    {AshA2A.Email.TokenLedgerStore, name: MyApp.EmailLedger, store: MyApp.EmailKv}
    # plug option: token_ledger: MyApp.EmailLedger

Token consumption and replay results are durable and cluster-wide (EKV CAS); reply tokens are
stored hashed. Tests: `test/email_dkim_test.exs`, `test/email_token_ledger_store_test.exs`
(UNVERIFIED: written without an Elixir toolchain, no run cited).

Remaining: `rate_check/4` in `TokenLedgerStore` is node-local and in-memory; the store has no
capacity bound or eviction; `TokenLedger` itself stays in-memory single-node. DKIM supports only
RSA-SHA256 with relaxed/relaxed (no ed25519, simple canonicalization or DNS lookup; the resolver
is yours). Unit tests: `test/email_{inbound,brief,reply_intent,kernel_entry}_test.exs`.

## See Also

- [Authenticate agent requests](authenticate-agent-requests.md)
- [Verify authority on async paths](verify-authority-on-async-paths.md)
- [Test governed actions](test-governed-actions.md)
