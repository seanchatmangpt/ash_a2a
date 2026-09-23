# How to verify authority on async (Oban) delivery paths

A grant revoked between the moment a command was enqueued and the moment a
worker picks it up must not actuate. On the synchronous path this is
automatic — `AshA2A.CommandBus.admit/2` consults the broker per call. On
an **async** path it is your worker's job: the queue payload carries an
enqueue-time snapshot, and `CommandBus` cannot know how stale it is. This
guide shows the re-verification contract using the real
`AshA2A.Delivery.ObanAuthority` module.

This matters enough that the v26.9.17 hardening pass specifically audited
it: this repo's own shipped reference worker
(`test/support/command_worker.ex`) was found not calling `verify_live!` —
a revoked-but-unexpired authority could still actuate through it. The fix
(receipt-peek + live re-verification) landed the same day in `1f06cab`
and is the pattern below. See the CHANGELOG under `[26.9.17]` and
`docs/archive/reports/chicago-benchmark-report.md`'s "Hardening findings"
section for the original finding.

## 1. Enqueue with an authority snapshot

`AshA2A.Delivery.Oban` builds the queue payload from an admitted
`AshA2A.Command` — an **enqueue-time snapshot** of identity, capability,
input, and authority. Queue acceptance is delivery, not execution; the
command still has to survive admission again on the other side.

```elixir
{:ok, %Oban.Job{}} = AshA2A.Delivery.Oban.enqueue(MyApp.CommandWorker, command)
```

Your host app owns the Oban instance and queues — the library starts no
Oban queues for you.

## 2. Reconstruct, peek, and re-verify in the worker

The shape below is condensed from this repo's reference worker
(`test/support/command_worker.ex` — read it for the full,
fixture-realistic version). The three moves that matter:

1. **Reconstruct the authority from the payload** with
   `AshA2A.Delivery.ObanAuthority.reconstruct/2` — a faithful-but-static
   replay (it restores the token id and expiry exactly as enqueued).
2. **Peek the receipt store before re-verifying**: an already-durable
   receipt for this `command_id` means this is redelivery of an
   already-actuated command (Oban's at-least-once delivery). Replaying it
   is correct and must not fail on a grant legitimately revoked *after*
   the consequence happened — revoking authority never invalidates
   evidence of a consequence that already happened.
3. **Re-verify live** with `ObanAuthority.verify_live!/3` only when there
   is no receipt yet: it refuses `:authority_expired` before even
   querying the broker, then re-queries the *same* broker the synchronous
   path consults — a since-revoked grant comes back refused
   (`:authority_stale`), and the job fails visibly instead of actuating.

```elixir
defmodule MyApp.CommandWorker do
  use Oban.Worker, queue: :commands, max_attempts: 3

  # one worker per bounded command family, statically wired -- never trust
  # a resource/module name riding in the job args
  @resource MyApp.Item

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    principal = reconstruct_principal(args)
    command = reconstruct_command(args, principal)   # your payload shape
    authority = AshA2A.Delivery.ObanAuthority.reconstruct(args, principal)

    store = AshA2A.CommandBus.default_store()

    authority_result =
      case store.fetch(command.command_id, []) do
        {:ok, _already_durable_receipt} -> {:ok, authority}
        :error -> AshA2A.Delivery.ObanAuthority.verify_live!(authority, command.capability_id)
      end

    with {:ok, live_authority} <- authority_result,
         command = %{command | authority: live_authority},
         message = A2A.Message.new_user([A2A.Part.Data.new(command.input || %{})]) do
      AshA2A.CommandBus.run(command, message, @resource)
    end
  end
end
```

`verify_live!/3`'s `nil`-in/`{:ok, nil}`-out clause is deliberate: an
unauthenticated command was never grant-eligible, and
`CommandBus.admit/2` already refuses it `:authority_required`
downstream — the live check does not need to invent an earlier refusal.

## 3. Observe that revocation works

Every decision emits `[:ash_a2a, :authority, :decision]`, and every grant
lifecycle change emits `[:ash_a2a, :authority, :grant, :issue | :revoke |
:renew]` (see the [telemetry reference](../reference/telemetry.md)). A
drill worth running in staging: revoke a grant
(`AshA2A.Authority.Grant.revoke(subject, capability_id)`), enqueue a
command for that principal,
and confirm the worker refuses `:authority_stale` in your telemetry —
that is the whole guarantee this how-to exists for.

## See also

- [Authenticate inbound A2A requests](authenticate-agent-requests.md) —
  the synchronous-path half of the same model.
- `AshA2A.Delivery.ObanAuthority` moduledoc — the authoritative contract
  for `reconstruct/2` and `verify_live!/3`, including expiry semantics.
- `test/support/command_worker.ex` and
  `test/ash_a2a/oban_delivery_qualification_test.exs` — the reference
  worker and the real Postgres-backed qualification test for the delivery
  path.
