defmodule AshA2A.ReceiptStore do
  @moduledoc """
  Behaviour for replay-safe command receipt storage.

  A store owns the atomic command-id claim. Implementations must distinguish
  same-id/same-fingerprint replay from same-id/different-fingerprint conflict.
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
