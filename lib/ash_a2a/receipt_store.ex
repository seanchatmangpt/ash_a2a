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

  ## Actuation claims (RFC-SA2A-001 S55)

  `claim/2` keys on the *request* (`command_id`). S55 additionally requires
  detecting a previously prepared or executed **effect** before repeating it,
  which a fresh `command_id` on a client retry defeats. The three optional
  callbacks below add that second index, keyed on
  `AshA2A.Actuation.identity/2`'s effect-derived actuation id:

    * `c:claim_actuation/3` -- called by `AshA2A.CommandBus` *after* the
      command claim succeeds and *before* DO, for `:change`/`:external_do`
      only. `{:duplicate, receipt}` means this exact effect already completed
      under some other command id, and the bus returns that receipt instead of
      crossing the boundary a second time.
    * `c:commit_actuation/3` -- records the finalized receipt against the
      actuation id once the outcome is observed.
    * `c:release_actuation/2` -- drops a prepared-but-never-executed actuation
      claim, so a refusal after the claim does not permanently wedge the
      effect.

  A store that does not implement them is unchanged: `AshA2A.CommandBus`
  checks `function_exported?/3` and skips actuation claiming entirely, which is
  why `AshA2A.ReceiptStore`'s existing three-callback contract still describes
  a complete, working store.
  """

  alias AshA2A.{Actuation, Command, Receipt}

  @type claim_result ::
          {:execute, AshA2A.Identity.t()}
          | {:replay, Receipt.t()}
          | {:error, :command_conflict | :in_flight}

  @typedoc """
  Result of claiming an actuation identity.

    * `:proceed` -- no prior prepared or executed record for this effect
    * `{:duplicate, receipt}` -- this effect already completed; the receipt is
      the prior outcome and MUST be returned rather than re-actuating
    * `{:error, :actuation_in_flight}` -- another claimant prepared this effect
      and has not finished; refuse rather than double-actuate
    * `{:error, :actuation_store_unavailable}` -- the effect-level claim store
      could not be consulted; callers enforcing idempotency must refuse before DO.
    * `{:error, :actuation_conflict}` -- the same actuation id is held with a
      different idempotency key, which means two callers disagree about what
      the external token for this effect is
  """
  @type actuation_claim_result ::
          :proceed
          | {:duplicate, Receipt.t()}
          | {:error, :actuation_in_flight | :actuation_conflict | :actuation_store_unavailable}

  @callback claim(Command.t(), keyword()) :: claim_result()
  @callback commit(Receipt.t(), keyword()) :: :ok
  @callback fetch(AshA2A.Identity.t(), keyword()) :: {:ok, Receipt.t()} | :error

  @callback claim_actuation(Actuation.t(), Command.t(), keyword()) :: actuation_claim_result()
  @callback commit_actuation(Actuation.t(), Receipt.t(), keyword()) :: :ok | {:error, term()}
  @callback release_actuation(Actuation.t(), keyword()) :: :ok

  @optional_callbacks claim_actuation: 3, commit_actuation: 3, release_actuation: 2
end
