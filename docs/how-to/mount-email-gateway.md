# Mount the Email Gateway

Wire the inbound webhook authentication and outbound sender around the email
plug so governed actions can be operated by email.

## 1. Authenticate the provider webhook

Call `AshA2A.Email.Webhook.verify/3` before any parsing. It is fail-closed: a
missing or short (under 16 bytes) secret returns `{:error, :not_configured}`.

```elixir
:ok = AshA2A.Email.Webhook.verify(:sendgrid, conn, secret: System.fetch_env!("SG_SECRET"))
:ok = AshA2A.Email.Webhook.verify(:workspace, conn, token: System.fetch_env!("WS_TOKEN"))
```

SendGrid accepts the `x-webhook-secret` header or the Basic-auth password.
Workspace expects `Authorization: Bearer <token>`.

## 2. SES via SNS

```elixir
AshA2A.Email.Webhook.verify(:ses, raw_body,
  topic_arn: "arn:aws:sns:us-east-1:123456789012:inbound",
  signature_verifier: &MyApp.SnsRsa.verify/1
)
```

The module checks the SNS envelope structure and that `SigningCertURL` is an
https `sns.<region>.amazonaws.com` `.pem`. RSA verification is yours to supply;
without `:signature_verifier` the result is `{:error, :signature_unverified}`
unless you pass `structure_only: true`.

## 3. Send briefs

```elixir
AshA2A.Email.Sender.deliver(AshA2A.Email.Sender.Spool, %{
  to: "approver@example.com",
  from: "gateway@example.com",
  subject: "Approval needed",
  body: "..."
}, spool_dir: "/var/spool/ash_a2a")
```

`AshA2A.Email.Sender.Spool` writes one `.eml` file per message.
`AshA2A.Email.Sender.SMTP` needs `:gen_smtp` in your app and otherwise returns
`{:error, :gen_smtp_not_available}`.

## See Also

- [`operate-by-email.md`](operate-by-email.md)
