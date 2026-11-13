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
| Body not valid JSON or webhook unparseable | 400 | none |
| Sender not verified (`Inbound.verify_sender/2`) | 401 | none |
| Missing `in_reply_to` | 400 | none |
| `in_reply_to` matches no brief | 404 | none |
| Unparseable intent | 422 | none |
| Tampered, missing or invalid reply token | 403 | none |
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
- `:reply_sender` `(to, subject, text -> any)`; default no-op.

The request body carries `"reply_tokens"`: action number to token
(`Brief.reply_token/2`); a token is required for every approved action.

## Test it

`test/email_plug_test.exs` exercises the loop through `Plug.Test` (standing UNVERIFIED
here; the file exists, no run cited). Unit tests: `test/email_{inbound,brief,
reply_intent,kernel_entry}_test.exs`.

## See Also

- [Authenticate agent requests](authenticate-agent-requests.md)
- [Verify authority on async paths](verify-authority-on-async-paths.md)
- [Test governed actions](test-governed-actions.md)
