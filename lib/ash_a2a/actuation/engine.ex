# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Actuation.Engine do
  @moduledoc """
  Sovereign Actuation Engine — integrity, attestation, authority, settlement.

  Pipeline per `submit/3`:

    0. options — `:adapter`, `:attestation_opts`, `:authorizer`, `:ledger`
       validated; invalid → `{:refused, {:invalid_option, key}}`.
    1. ledger — a ticket id already settled is refused as
       `{:refused, :already_settled}` BEFORE any adapter dispatch, so the
       external effect never runs twice.
    2. integrity — recompute the ticket digest via
       `AshA2A.Actuation.Ticket.Mint.digest/1`; mismatch →
       `{:refused, :tampered_ticket}` before any adapter call.
    3. attestation — `AshA2A.Attestation.Gate.verify_enclave/2` over
       `actor_context.attestation = {device_token, nonce}`, then
       `Gate.verify_freshness/2` on the claims. The nonce is bound to the
       ticket id at settlement; a nonce already bound to a settled ticket in
       the ledger is refused as `{:refused, :replayed_nonce}`.
    4. authority — a pluggable `authorizer` fun gates dispatch; default
       **DenyAll** (`deny_all/2`). `pep_authorizer/1` adapts
       `AshA2A.Authority.PEP.assert_standing/4` (actor = `ticket.issued_by`,
       scope = `ticket.action_iri`). Any non-`{:ok, grant}` return (or raise)
       is a typed `{:refused, :unauthorized}`.
    5. dispatch — `AshA2A.Actuation.Adapter.execute/2`; raise/throw/exit or a
       non-conforming return → `{:refused, {:adapter_error, _}}`.
    6. settlement — receipt recorded in the ledger. A settlement refusal after
       dispatch is `{:refused, {:settlement_failed, reason, :effect_ran}}`.

  `settle/3` re-verifies ticket integrity and is pure: returns a NEW ledger.

  ## Examples

      iex> AshA2A.Actuation.Engine.deny_all(nil, %{})
      {:refused, :unauthorized}

      iex> ticket =
      ...>   AshA2A.Actuation.Ticket.Mint.ticket(
      ...>     %{action_iri: "urn:x", payload: 1, issued_by: "a",
      ...>       correlation: %{run_id: 1, step_ref: 2}},
      ...>     issued_at: 1)
      iex> AshA2A.Actuation.Engine.settlement(%{}, ticket)
      {:error, :not_found}
  """

  alias AshA2A.Actuation.Ticket
  alias AshA2A.Attestation.Gate
  alias AshA2A.Authority.PEP

  @typedoc """
  In-memory settlement ledger: ticket id -> settlement record
  (`%{ticket_id:, nonce:, receipt:, receipt_digest:, settled_at:}`).
  """
  @type ledger :: %{optional(String.t()) => map()}

  @type refusal ::
          {:refused,
           :tampered_ticket
           | :unattested
           | :unauthorized
           | :already_settled
           | :replayed_nonce
           | :stale
           | :clock_skew
           | :malformed_token
           | {:invalid_option, atom()}
           | {:adapter_error, term()}
           | {:settlement_failed, term(), :effect_ran}
           | term()}

  @doc """
  Default authorizer (DenyAll): every actuation refused without an explicit
  grant. Replaced via `opts[:authorizer]`.
  """
  @spec deny_all(Ticket.t(), map()) :: {:ok, map()} | {:refused, :unauthorized}
  def deny_all(_ticket, _actor_context), do: {:refused, :unauthorized}

  @doc """
  Build an authorizer backed by `AshA2A.Authority.PEP.assert_standing/4`.
  `pep_opts` (e.g. `source: MySource`) go to the PEP; the PEP default source
  refuses everything.
  """
  @spec pep_authorizer(keyword()) :: (Ticket.t(), map() -> {:ok, map()} | {:refused, :unauthorized})
  def pep_authorizer(pep_opts \\ []) do
    fn %Ticket{} = ticket, ctx ->
      case PEP.assert_standing(ticket.issued_by, ticket.action_iri, ctx, pep_opts) do
        :ok -> {:ok, %{role: :pep, actor: ticket.issued_by, scope: ticket.action_iri}}
        _ -> {:refused, :unauthorized}
      end
    end
  end

  @doc """
  Submit an obligation ticket for actuation.

  Required opts:

    * `:adapter` — module implementing `AshA2A.Actuation.Adapter`, or a
      `(ticket, ctx) -> {:ok, receipt} | {:error, reason}` fun
    * `:attestation_opts` — keyword forwarded to `Attestation.Gate`
      (must carry the verification `:key`; `:max_staleness_sec`/`:now` are
      used for freshness)

  Optional opts:

    * `:authorizer` — `(ticket, actor_context) -> {:ok, grant}`; default
      `&deny_all/2`. `actor_context` carries `:attestation_claims`.
    * `:ledger` — settlement ledger map (default `%{}`)

  The adapter ctx is `%{actor_context:, grant:, attestation_claims:, ticket_id:}`.
  Returns `{:ok, receipt, ledger'}` or a typed `{:refused, reason}`.
  Failed submissions never touch the ledger.
  """
  @spec submit(Ticket.t(), map(), Keyword.t()) ::
          {:ok, map(), ledger()} | refusal()
  def submit(%Ticket{} = ticket, actor_context, opts) when is_map(actor_context) and is_list(opts) do
    with {:ok, adapter} <- fetch_adapter(opts),
         {:ok, attestation_opts} <- fetch_attestation_opts(opts),
         {:ok, authorizer} <- fetch_authorizer(opts),
         {:ok, ledger} <- fetch_ledger(opts),
         :ok <- not_settled(ledger, ticket),
         :ok <- integrity(ticket),
         {:ok, claims, nonce} <- attestation(actor_context, attestation_opts),
         :ok <- fresh_nonce(ledger, nonce),
         auth_ctx = Map.put(actor_context, :attestation_claims, claims),
         {:ok, grant} <- authorize(authorizer, ticket, auth_ctx) do
      ctx = %{
        actor_context: actor_context,
        grant: grant,
        attestation_claims: claims,
        ticket_id: ticket.id
      }

      case dispatch(adapter, ticket, ctx) do
        {:ok, receipt} ->
          case do_settle(ledger, ticket, receipt, nonce) do
            {:ok, ledger2} -> {:ok, receipt, ledger2}
            {:refused, reason} -> {:refused, {:settlement_failed, reason, :effect_ran}}
          end

        {:refused, _} = refused ->
          refused
      end
    end
  end

  @doc """
  Record an adapter receipt against a ticket in the (pure, in-memory)
  ledger. Re-verifies ticket integrity; double settlement for the same
  ticket id is refused.
  """
  @spec settle(ledger(), Ticket.t(), map()) ::
          {:ok, ledger()} | {:refused, :already_settled | :tampered_ticket}
  def settle(ledger, %Ticket{} = ticket, receipt) when is_map(ledger) and is_map(receipt) do
    with :ok <- integrity(ticket), do: do_settle(ledger, ticket, receipt, nil)
  end

  @doc "Fetch a settlement record from the ledger."
  @spec settlement(ledger(), Ticket.t()) :: {:ok, map()} | {:error, :not_found}
  def settlement(ledger, %Ticket{} = ticket) do
    case Map.fetch(ledger, ticket.id) do
      {:ok, record} -> {:ok, record}
      :error -> {:error, :not_found}
    end
  end

  # -- internals ---------------------------------------------------------

  defp do_settle(ledger, ticket, receipt, nonce) do
    if Map.has_key?(ledger, ticket.id) do
      {:refused, :already_settled}
    else
      record = %{
        ticket_id: ticket.id,
        nonce: nonce,
        receipt: receipt,
        receipt_digest: receipt_digest(receipt),
        settled_at: System.system_time(:second)
      }

      {:ok, Map.put(ledger, ticket.id, record)}
    end
  end

  defp receipt_digest(receipt) do
    :crypto.hash(:sha256, :erlang.term_to_binary(receipt, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  defp fetch_adapter(opts) do
    case Keyword.get(opts, :adapter) do
      f when is_function(f, 2) ->
        {:ok, f}

      m when is_atom(m) and not is_nil(m) ->
        if Code.ensure_loaded?(m) and function_exported?(m, :execute, 2),
          do: {:ok, &m.execute/2},
          else: {:refused, {:invalid_option, :adapter}}

      _ ->
        {:refused, {:invalid_option, :adapter}}
    end
  end

  defp fetch_attestation_opts(opts) do
    case Keyword.get(opts, :attestation_opts) do
      o when is_list(o) ->
        if Keyword.keyword?(o) and Keyword.get(o, :key) != nil,
          do: {:ok, o},
          else: {:refused, {:invalid_option, :attestation_opts}}

      _ ->
        {:refused, {:invalid_option, :attestation_opts}}
    end
  end

  defp fetch_authorizer(opts) do
    case Keyword.get(opts, :authorizer, &deny_all/2) do
      f when is_function(f, 2) -> {:ok, f}
      _ -> {:refused, {:invalid_option, :authorizer}}
    end
  end

  defp fetch_ledger(opts) do
    case Keyword.get(opts, :ledger, %{}) do
      l when is_map(l) -> {:ok, l}
      _ -> {:refused, {:invalid_option, :ledger}}
    end
  end

  defp not_settled(ledger, ticket) do
    if Map.has_key?(ledger, ticket.id), do: {:refused, :already_settled}, else: :ok
  end

  defp integrity(ticket) do
    if Ticket.Mint.digest(ticket) == ticket.id, do: :ok, else: {:refused, :tampered_ticket}
  end

  defp attestation(actor_context, opts) do
    case Map.get(actor_context, :attestation) do
      {device_token, nonce} when is_binary(device_token) and is_binary(nonce) ->
        with {:ok, claims} <- Gate.verify_enclave({device_token, nonce}, opts),
             :ok <- Gate.verify_freshness(claims, Keyword.take(opts, [:max_staleness_sec, :now])) do
          {:ok, claims, nonce}
        else
          {:refused, _} = refused -> refused
          _ -> {:refused, :unattested}
        end

      _ ->
        {:refused, :unattested}
    end
  end

  defp fresh_nonce(ledger, nonce) do
    if Enum.any?(ledger, fn {_id, rec} -> is_map(rec) and Map.get(rec, :nonce) == nonce end),
      do: {:refused, :replayed_nonce},
      else: :ok
  end

  defp authorize(authorizer, ticket, ctx) do
    case authorizer.(ticket, ctx) do
      {:ok, grant} -> {:ok, grant}
      _ -> {:refused, :unauthorized}
    end
  rescue
    _ -> {:refused, :unauthorized}
  catch
    _, _ -> {:refused, :unauthorized}
  end

  defp dispatch(adapter, ticket, ctx) do
    case adapter.(ticket, ctx) do
      {:ok, receipt} when is_map(receipt) -> {:ok, receipt}
      {:error, reason} -> {:refused, {:adapter_error, reason}}
      other -> {:refused, {:adapter_error, {:invalid_return, other}}}
    end
  rescue
    e -> {:refused, {:adapter_error, {:raised, e}}}
  catch
    kind, reason -> {:refused, {:adapter_error, {kind, reason}}}
  end
end
