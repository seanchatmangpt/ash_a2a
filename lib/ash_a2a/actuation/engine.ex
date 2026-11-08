# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Actuation.Engine do
  @moduledoc """
  Sovereign Actuation Engine — integrity, attestation, authority, settlement.

  Pipeline per `submit/3`:

    1. integrity — recompute the ticket digest via
       `AshA2A.Actuation.Ticket.Mint.digest/1`; mismatch →
       `{:refused, :tampered_ticket}` before any adapter call.
    2. attestation — delegate to `AshA2A.Attestation.Gate.verify_enclave/2`
       over `actor_context.attestation = {device_token, nonce}` with the
       configured key/opts. Anything missing/malformed →
       `{:refused, :unattested}`.
    3. authority — `AshA2A.Authority.PEP` is not yet landed as a PEP module,
       so a pluggable `authorizer` fun gates dispatch; default **DenyAll**
       (`deny_all/2`), i.e. every actuation is refused without an explicit
       grant. When `Authority.PEP` lands, wire it in as the default here.
    4. dispatch — `AshA2A.Actuation.Adapter.execute/2`, receipt returned.

  `settle/3` records the adapter receipt against the ticket in an in-memory
  ledger map. Pure: returns a NEW ledger, never mutates; a second settlement
  for the same ticket id is refused as `{:refused, :already_settled}`.
  """

  alias AshA2A.Actuation.Adapter
  alias AshA2A.Actuation.Ticket
  alias AshA2A.Attestation.Gate

  @typedoc """
  In-memory settlement ledger: ticket id -> settlement record
  (`%{ticket_id:, receipt:, receipt_digest:, settled_at:}`).
  """
  @opaque ledger :: %{optional(String.t()) => map()}

  @type refusal ::
          {:refused, :tampered_ticket | :unattested | :unauthorized | :already_settled}
          | {:refused, {:adapter_error, term()}}

  @doc """
  Default authorizer (DenyAll): every actuation refused without an explicit
  grant. Replaced via `opts[:authorizer]`.
  """
  @spec deny_all(Ticket.t(), map()) :: {:ok, map()} | {:refused, :unauthorized}
  def deny_all(_ticket, _actor_context), do: {:refused, :unauthorized}

  @doc """
  Submit an obligation ticket for actuation.

  Required opts:

    * `:adapter` — module implementing `AshA2A.Actuation.Adapter`, or a
      `(ticket, ctx) -> {:ok, receipt} | {:error, reason}` fun (test/spy use)
    * `:attestation_opts` — forwarded to `Attestation.Gate.verify_enclave/2`
      (must carry the verification `:key`)

  Optional opts:

    * `:authorizer` — `(ticket, actor_context) -> {:ok, grant} | {:refused, :unauthorized}`;
      default `&deny_all/2`
    * `:ledger` — settlement ledger map (default `%{}`)

  Returns `{:ok, receipt, ledger'}` on success; typed `{:refused, reason}`
  otherwise. The adapter runs only after integrity+attestation+authority all
  pass; failed submissions never touch the ledger.
  """
  @spec submit(Ticket.t(), map(), Keyword.t()) ::
          {:ok, map(), ledger()} | refusal()
  def submit(%Ticket{} = ticket, actor_context, opts) when is_map(actor_context) and is_list(opts) do
    adapter = Keyword.fetch!(opts, :adapter)
    attestation_opts = Keyword.fetch!(opts, :attestation_opts)
    authorizer = Keyword.get(opts, :authorizer, &deny_all/2)
    ledger = Keyword.get(opts, :ledger, %{})

    with :ok <- integrity(ticket),
         {:ok, claims} <- attestation(actor_context, attestation_opts),
         {:ok, grant} <- authorizer.(ticket, Map.put(actor_context, :attestation_claims, claims)) do
      execute =
        if is_function(adapter, 2) do
          adapter
        else
          fn ticket, ctx -> adapter.execute(ticket, ctx) end
        end

      case execute.(ticket, %{actor_context: actor_context, grant: grant}) do
        {:ok, receipt} when is_map(receipt) ->
          case settle(ledger, ticket, receipt) do
            {:ok, ledger2} -> {:ok, receipt, ledger2}
            {:refused, _} = refused -> refused
          end

        {:error, reason} ->
          {:refused, {:adapter_error, reason}}
      end
    else
      {:refused, _} = refused -> refused
    end
  end

  @doc """
  Record an adapter receipt against a ticket in the (pure, in-memory)
  ledger. Double settlement for the same ticket id is refused.
  """
  @spec settle(ledger(), Ticket.t(), map()) :: {:ok, ledger()} | {:refused, :already_settled}
  def settle(ledger, %Ticket{} = ticket, receipt) when is_map(ledger) and is_map(receipt) do
    if Map.has_key?(ledger, ticket.id) do
      {:refused, :already_settled}
    else
      record = %{
        ticket_id: ticket.id,
        receipt: receipt,
        receipt_digest:
          :crypto.hash(:sha256, :erlang.term_to_binary(receipt)) |> Base.encode16(case: :lower),
        settled_at: System.system_time(:second)
      }

      {:ok, Map.put(ledger, ticket.id, record)}
    end
  end

  @doc "Fetch a settlement record from the ledger."
  @spec settlement(ledger(), Ticket.t()) :: {:ok, map()} | {:error, :not_found}
  def settlement(ledger, %Ticket{} = ticket) do
    case Map.fetch(ledger, ticket.id) do
      {:ok, record} -> {:ok, record}
      :error -> {:error, :not_found}
    end
  end

  defp integrity(ticket) do
    if Ticket.Mint.digest(ticket) == ticket.id, do: :ok, else: {:refused, :tampered_ticket}
  end

  defp attestation(actor_context, opts) do
    case Map.get(actor_context, :attestation) do
      {device_token, nonce} when is_binary(device_token) and is_binary(nonce) ->
        Gate.verify_enclave({device_token, nonce}, opts)

      _ ->
        {:refused, :unattested}
    end
  end
end
