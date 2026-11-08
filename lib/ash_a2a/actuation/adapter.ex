# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Actuation.Adapter do
  @moduledoc """
  Host-provided actuation adapter behaviour.

  The Sovereign Actuation Engine NEVER performs a real external effect
  itself: SMS/vendor/bank calls are host-provided implementations of this
  behaviour. The engine's job is integrity (ticket digest), attestation,
  authority, and settlement of the adapter's receipt.

  A real adapter MUST be idempotent over `ticket.id` on the external system
  (or refuse re-execution) — settlement in the engine does not make the
  external call safe to repeat.
  """

  @callback execute(AshA2A.Actuation.Ticket.t(), map()) ::
              {:ok, receipt :: map()} | {:error, reason :: term()}
end

defmodule AshA2A.Actuation.Adapter.Noop do
  @moduledoc """
  Test-only adapter: performs no external effect and returns a signed receipt
  stub. The "signature" is a deterministic sha256 over the ticket id + engine
  settlement context, NOT a real cryptographic attestation of an external
  action — documented test-only, do not use in production paths.
  """

  @behaviour AshA2A.Actuation.Adapter

  @impl true
  def execute(%AshA2A.Actuation.Ticket{} = ticket, ctx) do
    nonce = Map.get(ctx, :adapter_nonce, "")

    stub =
      :crypto.hash(:sha256, :erlang.term_to_binary({ticket.id, nonce}))
      |> Base.encode16(case: :lower)

    {:ok, %{adapter: __MODULE__, receipt_digest: stub, settled: false}}
  end
end
