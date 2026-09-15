defmodule AshA2A.ReceiptStore do
  @moduledoc """
  Behaviour for replay-safe command receipt storage.

  A store owns the atomic command-id claim. Implementations must distinguish
  same-id/same-fingerprint replay from same-id/different-fingerprint conflict.

  "Replay" here means idempotent command re-submission / command dedup (the
  Stripe-style idempotency-key pattern): a claim keys on a single
  `command_id` and compares it against a content-hash `fingerprint` computed
  from that one command (`AshA2A.Command.fingerprint/1`). This is distinct
  from process-mining token-replay / conformance checking (Rozinat & van der
  Aalst, "Conformance checking of processes based on monitoring real
  behavior," Information Systems 33(1), 2008), which replays an ordered
  trace of events sharing a case identifier through a reference process
  model -- no trace or process model is involved in this claim/commit path.
  """

  alias AshA2A.{Command, Receipt}

  @type claim_result ::
          {:execute, AshA2A.Identity.t()}
          | {:replay, Receipt.t()}
          | {:error, :command_conflict | :in_flight}

  @callback claim(Command.t(), keyword()) :: claim_result()
  @callback commit(Receipt.t(), keyword()) :: :ok
  @callback fetch(AshA2A.Identity.t(), keyword()) :: {:ok, Receipt.t()} | :error
end
