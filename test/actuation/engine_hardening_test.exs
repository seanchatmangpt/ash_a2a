# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Actuation.EngineHardeningTest do
  @moduledoc "Lane 02 hardening court: real gate, real keys, real ledger, no mocks."
  use ExUnit.Case, async: true

  doctest AshA2A.Actuation.Engine
  doctest AshA2A.Actuation.Ticket.Mint

  alias AshA2A.Actuation.{Adapter, Engine, Ticket}
  alias AshA2A.Attestation.Key

  defp mint(over \\ %{}) do
    Ticket.Mint.ticket(
      Map.merge(
        %{
          action_iri: "urn:a2a:actuation:send-sms",
          payload: %{"to" => "+1555"},
          issued_by: "agent-1",
          correlation: %{run_id: "r", step_ref: "s"}
        },
        over
      ),
      issued_at: 1_700_000_000
    )
  end

  defp ctx(key, nonce, issued_at \\ System.system_time(:second)) do
    token = Key.sign(%{"nonce" => nonce, "issued_at" => issued_at, "device" => %{"model" => "d"}}, key)
    %{attestation: {token, nonce}}
  end

  defp allow(_t, _c), do: {:ok, %{role: :court}}

  # Real counting adapter: effect counter lives in a real Agent.
  defp counting(key_agent) do
    fn t, c ->
      Agent.update(key_agent, &(&1 + 1))
      Adapter.Noop.execute(t, c)
    end
  end

  defp opts(key, adapter, extra \\ []),
    do: Keyword.merge([adapter: adapter, attestation_opts: [key: key], authorizer: &allow/2], extra)

  test "populated ledger: effect runs once; resubmit refused before dispatch" do
    key = Key.generate()
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    t = mint()
    assert {:ok, _r, ledger} = Engine.submit(t, ctx(key, "n1"), opts(key, counting(counter)))
    assert 1 = Agent.get(counter, & &1)

    assert {:refused, :already_settled} =
             Engine.submit(t, ctx(key, "n2"), opts(key, counting(counter), ledger: ledger))

    assert 1 = Agent.get(counter, & &1)
  end

  test "other tickets still settle into a populated ledger; replayed nonce refused" do
    key = Key.generate()
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    {:ok, _, ledger} = Engine.submit(mint(), ctx(key, "same"), opts(key, counting(counter)))
    other = mint(%{payload: %{"to" => "+1999"}})

    assert {:refused, :replayed_nonce} =
             Engine.submit(other, ctx(key, "same"), opts(key, counting(counter), ledger: ledger))

    assert 1 = Agent.get(counter, & &1)

    assert {:ok, _, ledger2} =
             Engine.submit(other, ctx(key, "fresh"), opts(key, counting(counter), ledger: ledger))

    assert map_size(ledger2) == 2
    assert 2 = Agent.get(counter, & &1)
  end

  test "stale token refused, adapter not run" do
    key = Key.generate()
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    old = System.system_time(:second) - 10_000

    assert {:refused, :stale} =
             Engine.submit(mint(), ctx(key, "n", old), opts(key, counting(counter)))

    assert 0 = Agent.get(counter, & &1)
  end

  test "non-standard authorizer returns are typed refusals" do
    key = Key.generate()
    for ret <- [:ok, :nope, nil, {:refused, :other}, {:error, 1}, {:refused, :a, %{}}] do
      auth = fn _t, _c -> ret end
      assert {:refused, :unauthorized} =
               Engine.submit(mint(), ctx(key, "n"), opts(key, Adapter.Noop, authorizer: auth))
    end

    raiser = fn _t, _c -> raise "boom" end
    assert {:refused, :unauthorized} =
             Engine.submit(mint(), ctx(key, "n"), opts(key, Adapter.Noop, authorizer: raiser))
  end

  test "PEP authorizer: default source denies, AllowAll admits" do
    key = Key.generate()
    assert {:refused, :unauthorized} =
             Engine.submit(mint(), ctx(key, "n"),
               opts(key, Adapter.Noop, authorizer: Engine.pep_authorizer()))

    assert {:ok, _, _} =
             Engine.submit(mint(), ctx(key, "n"),
               opts(key, Adapter.Noop,
                 authorizer: Engine.pep_authorizer(source: AshA2A.Authority.Source.AllowAll)))
  end

  test "adapter raise/throw/bad return -> typed adapter_error, ledger untouched" do
    key = Key.generate()
    bad = [
      fn _t, _c -> raise "x" end,
      fn _t, _c -> throw(:t) end,
      fn _t, _c -> exit(:e) end,
      fn _t, _c -> :weird end,
      fn _t, _c -> {:ok, "not a map"} end
    ]

    for a <- bad do
      assert {:refused, {:adapter_error, _}} = Engine.submit(mint(), ctx(key, "n"), opts(key, a))
    end
  end

  test "adapter receives attestation claims and ticket id" do
    key = Key.generate()
    {:ok, box} = Agent.start_link(fn -> nil end)
    a = fn t, c -> Agent.update(box, fn _ -> c end); Adapter.Noop.execute(t, c) end
    t = mint()
    assert {:ok, _, _} = Engine.submit(t, ctx(key, "nn"), opts(key, a))
    c = Agent.get(box, & &1)
    assert c.ticket_id == t.id
    assert c.attestation_claims["nonce"] == "nn"
  end

  test "invalid options are typed refusals" do
    key = Key.generate()
    c = ctx(key, "n")
    t = mint()
    assert {:refused, {:invalid_option, :adapter}} = Engine.submit(t, c, attestation_opts: [key: key])
    assert {:refused, {:invalid_option, :adapter}} = Engine.submit(t, c, opts(key, NoSuchAdapterMod))
    assert {:refused, {:invalid_option, :attestation_opts}} =
             Engine.submit(t, c, adapter: Adapter.Noop)
    assert {:refused, {:invalid_option, :attestation_opts}} =
             Engine.submit(t, c, adapter: Adapter.Noop, attestation_opts: [])
    assert {:refused, {:invalid_option, :authorizer}} =
             Engine.submit(t, c, opts(key, Adapter.Noop, authorizer: :nope))
    assert {:refused, {:invalid_option, :ledger}} =
             Engine.submit(t, c, opts(key, Adapter.Noop, ledger: :nope))
  end

  test "each tampered ticket field refused; adapter never runs; ledger untouched" do
    key = Key.generate()
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    t = mint()
    ledger = %{}

    tampers = [
      %{t | id: String.duplicate("0", 64)},
      %{t | action_iri: "urn:evil"},
      %{t | payload: %{"to" => "+1000"}},
      %{t | issued_by: "mallory"},
      %{t | issued_at: t.issued_at + 1},
      %{t | correlation: %{run_id: "x", step_ref: "s"}}
    ]

    for bad <- tampers do
      assert {:refused, :tampered_ticket} =
               Engine.submit(bad, ctx(key, "n"), opts(key, counting(counter), ledger: ledger))
    end

    assert 0 = Agent.get(counter, & &1)
    assert ledger == %{}
    assert {:refused, :tampered_ticket} = Engine.settle(ledger, hd(tampers), %{})
  end

  test "settlement/2 not_found" do
    assert {:error, :not_found} = Engine.settlement(%{}, mint())
  end

  test "ticket digest deterministic beyond depth 8 and keeps struct name" do
    deep = Enum.reduce(1..12, %{leaf: 1}, fn _, acc -> %{k: acc} end)
    a = mint(%{payload: deep})
    assert a.id == mint(%{payload: deep}).id
    refute a.id == mint(%{payload: Enum.reduce(1..12, %{leaf: 2}, fn _, acc -> %{k: acc} end)}).id

    refute mint(%{payload: %URI{host: "a"}}).id == mint(%{payload: Map.from_struct(%URI{host: "a"})}).id
    assert mint(%{payload: %{b: 1, a: 2}}).id == mint(%{payload: %{a: 2, b: 1}}).id
  end

  test "Mint.new validates with typed errors; ticket/2 raises ArgumentError" do
    base = %{action_iri: "u", payload: 1, issued_by: "a", correlation: %{run_id: 1, step_ref: 2}}
    assert {:error, {:invalid_field, :issued_by}} = Ticket.Mint.new(%{base | issued_by: nil})
    assert {:error, {:invalid_field, :correlation}} = Ticket.Mint.new(%{base | correlation: %{}})
    assert {:error, {:invalid_field, :issued_at}} = Ticket.Mint.new(base, issued_at: "x")
    assert {:error, {:missing_field, :payload}} = Ticket.Mint.new(Map.delete(base, :payload))
    assert_raise ArgumentError, fn -> Ticket.Mint.ticket(%{base | action_iri: 5}) end
  end
end
