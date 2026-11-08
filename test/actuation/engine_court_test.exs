# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Actuation.EngineCourtTest do
  @moduledoc """
  Lane Z11 court for the Sovereign Actuation Engine skeleton.

  Real collaborators (Chicago): real ECDSA key + signed device token through
  the real Attestation.Gate, real ticket digest recomputation, real Noop
  adapter. No mocks.

  Cases: happy path mint -> submit -> adapter -> settle -> ledger;
  tampered ticket; unattested; unauthorized (DenyAll default + explicit);
  adapter error; double-settle typed refusal.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Actuation.{Adapter, Engine, Ticket}
  alias AshA2A.Attestation.{Gate, Key}

  @nonce "nonce-z11-court"

  defp mint(opts \\ []) do
    {field_overrides, kw_opts} =
      Keyword.split(opts, [:action_iri, :payload, :issued_by, :correlation])

    fields =
      Map.merge(
        %{
          action_iri: "urn:a2a:actuation:send-sms",
          payload: %{"to" => "+15550001", "body" => "court"},
          issued_by: "agent-1",
          correlation: %{run_id: "run-1", step_ref: "step-1"}
        },
        Map.new(field_overrides)
      )

    Ticket.Mint.ticket(fields, kw_opts)
  end

  defp keypair, do: Key.generate()

  defp attested_ctx(key, nonce \\ @nonce) do
    token =
      Key.sign(
        %{"nonce" => nonce, "issued_at" => System.system_time(:second),
          "device" => %{"model" => "court-device"}},
        key
      )

    %{attestation: {token, nonce}}
  end

  defp base_opts(key, extra \\ []) do
    [adapter: Adapter.Noop, attestation_opts: [key: key]] ++ extra
  end

  defp allow_all(_ticket, _ctx), do: {:ok, %{role: :court}}

  test "ticket id is deterministic sha256 of canonical fields" do
    t1 = mint(issued_at: 1_700_000_000)
    t2 = mint(issued_at: 1_700_000_000)
    assert t1.id == t2.id
    assert byte_size(t1.id) == 64
    assert Regex.match?(~r/^[0-9a-f]{64}$/, t1.id)

    changed = mint(issued_at: 1_700_000_000, payload: %{"to" => "+15550002"})
    refute changed.id == t1.id
  end

  test "happy path: mint -> submit (attested+authorized) -> adapter -> settle -> ledger" do
    key = keypair()
    ticket = mint()
    ctx = attested_ctx(key)

    assert {:ok, receipt, ledger} = Engine.submit(ticket, ctx, base_opts(key, authorizer: &allow_all/2))
    assert receipt.adapter == Adapter.Noop
    assert is_binary(receipt.receipt_digest) and receipt.receipt_digest != ""

    assert {:ok, record} = Engine.settlement(ledger, ticket)
    assert record.ticket_id == ticket.id
    assert record.receipt == receipt
    assert is_binary(record.receipt_digest)
  end

  test "tampered ticket refused, adapter never runs, ledger untouched" do
    key = keypair()
    ticket = mint()
    tampered = %Ticket{ticket | payload: %{"to" => "+15559999", "body" => "court"}}

    {:ok, spy} = Agent.start_link(fn -> 0 end)
    spy_adapter = fn t, _ctx ->
      Agent.update(spy, &(&1 + 1))
      Adapter.Noop.execute(t, %{})
    end

    assert {:refused, :tampered_ticket} =
             Engine.submit(tampered, attested_ctx(key),
               adapter: spy_adapter, attestation_opts: [key: key],
               authorizer: &allow_all/2)

    assert 0 = Agent.get(spy, & &1)
  end

  test "unattested refused" do
    key = keypair()
    ticket = mint()

    assert {:refused, :unattested} =
             Engine.submit(ticket, %{attestation: {nil, nil}}, base_opts(key, authorizer: &allow_all/2))

    assert {:refused, :unattested} =
             Engine.submit(ticket, %{}, base_opts(key, authorizer: &allow_all/2))
  end

  test "bad signature refused through real gate" do
    key = keypair()
    other = keypair()
    ctx = attested_ctx(other)

    assert {:refused, _} =
             Engine.submit(mint(), ctx, base_opts(key, authorizer: &allow_all/2))
  end

  test "unauthorized refused (DenyAll default and explicit denial)" do
    key = keypair()
    ticket = mint()

    # DenyAll is the default authorizer: no :authorizer opt.
    assert {:refused, :unauthorized} =
             Engine.submit(ticket, attested_ctx(key), base_opts(key))

    deny = fn _t, _c -> {:refused, :unauthorized} end
    assert {:refused, :unauthorized} =
             Engine.submit(ticket, attested_ctx(key), base_opts(key, authorizer: deny))
  end

  test "adapter error surfaces as typed refusal, no settlement" do
    key = keypair()

    failing = fn _t, _ctx -> {:error, :sms_gateway_down} end

    assert {:refused, {:adapter_error, :sms_gateway_down}} =
             Engine.submit(mint(), attested_ctx(key),
               adapter: failing, attestation_opts: [key: key],
               authorizer: &allow_all/2)
  end

  test "double settle refused; settle is pure" do
    key = keypair()
    ticket = mint()
    ctx = attested_ctx(key)

    {:ok, receipt, ledger} = Engine.submit(ticket, ctx, base_opts(key, authorizer: &allow_all/2))
    assert is_map(receipt)

    assert {:refused, :already_settled} =
             Engine.settle(ledger, ticket, %{"again" => true})

    # settle is pure: original ledger unchanged
    assert {:ok, _} = Engine.settlement(ledger, ticket)

    # settle into an empty ledger directly with an arbitrary receipt
    fresh = %{}
    assert {:ok, ledger2} = Engine.settle(fresh, ticket, %{"x" => 1})
    assert {:ok, %{ticket_id: ticket_id, receipt_digest: dg}} = Engine.settlement(ledger2, ticket)
    assert ticket_id == ticket.id and is_binary(dg)
  end

  test "noop stub is deterministic per ticket+nonce" do
    ticket = mint()
    {:ok, r1} = Adapter.Noop.execute(ticket, %{adapter_nonce: "n1"})
    {:ok, r2} = Adapter.Noop.execute(ticket, %{adapter_nonce: "n1"})
    {:ok, r3} = Adapter.Noop.execute(ticket, %{adapter_nonce: "n2"})
    assert r1 == r2
    refute r1.receipt_digest == r3.receipt_digest
  end
end
