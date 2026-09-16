defmodule AshA2A.AuthorityConfusedDeputyTest do
  @moduledoc """
  RFC-SA2A-001 S54: a peer MUST NOT use its own authority merely because
  another peer asked it to.

  The classic confused-deputy shape: peer A legitimately holds authority for
  a consequence-bearing capability. Peer B, who holds nothing, asks A to run
  it. If A's grant were consulted for B's request, B would have laundered
  authority through A. These tests drive the real `AshA2A.CommandBus`
  dispatch path, the real `AshA2A.Authority.Broker.InMemory`, and the real
  counting actuator -- no mocks.

  What makes this non-vacuous: `AshA2A.Authority.admits?/2` binds a grant to
  a *subject*, and `AshA2A.CommandBus.admit/2` compares that subject against
  the command's own `principal_id`. So the deputy cannot quietly substitute
  its own grant; it would have to rewrite the command's principal, which
  these tests show is not silent -- it changes the command fingerprint and
  the canonical decision-envelope digest, both of which land in the receipt
  chain.

  Status note, split honestly:

    * At the `AshA2A.CommandBus` boundary the property ALREADY HELD before
      this file existed -- nothing here weakens or adds a check on that path.
      These tests make it an explicit, named falsifier so a future refactor
      of `Authority.admits?/2` (say, one that stopped comparing `subject`)
      fails loudly here instead of silently opening a laundering path.
    * At the `AshA2A.Authority.Broker.InMemory` boundary it did NOT hold, and
      this session added enforcement: `verify/2` consulted only expiry and
      revocation, both keyed on `token_id` alone, so a grant whose `subject`
      had been rewritten to another peer verified cleanly. That is now
      `reason: :token_binding_mismatch`. See the test below that names it.
  """
  use ExUnit.Case

  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Authority, Command, CommandBus, Identity}
  alias AshA2A.Authority.Broker.InMemory
  alias AshA2A.Authority.Decision
  alias AshA2A.Test.ActuatorCounter
  alias AshA2A.Test.Fixture.AuthorityProbe

  @capability "AshA2A.Test.Fixture.AuthorityProbe.actuate"

  setup do
    Application.put_env(:ash_a2a, :receipt_commit_retry_delays_ms, [1, 1])
    on_exit(fn -> Application.delete_env(:ash_a2a, :receipt_commit_retry_delays_ms) end)

    start_supervised!(ActuatorCounter)

    store = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    start_supervised!({AshA2A.ReceiptStore.Memory, name: store})

    broker = Module.concat(__MODULE__, "Broker#{System.unique_integer([:positive])}")
    start_supervised!({InMemory, name: broker})

    %{store_opts: [name: store], broker: [name: broker]}
  end

  defp run(command, store_opts) do
    CommandBus.run(command, data_message(%{}), AuthorityProbe, store_opts: store_opts)
  end

  test "peer A's own real, broker-issued, currently-verifying authority does NOT admit peer B's request",
       %{store_opts: store_opts, broker: broker} do
    peer_a = Identity.principal("peer-a")
    peer_b = Identity.principal("peer-b")

    # A really does hold this capability: a real broker issued it and the
    # real broker still verifies it right now.
    assert {:ok, a_authority} = InMemory.issue(peer_a, @capability, broker)
    assert {:ok, ^a_authority} = InMemory.verify(a_authority, broker)
    assert Authority.admits?(a_authority, %{principal_id: peer_a, capability_id: @capability})

    # B asks. The deputy attaches its OWN grant to B's request.
    laundering_attempt =
      Command.new(@capability,
        command_id: "deputy-1",
        agent_id: "deputy-agent",
        principal_id: peer_b,
        authority: a_authority,
        input: %{}
      )

    assert {:error, %{code: :authority_mismatch}} = run(laundering_attempt, store_opts)
    assert ActuatorCounter.count() == 0

    # And the same refusal is reached by the portable evaluator.
    assert {:refused, %{code: :authority_mismatch}} =
             Decision.verdict(Decision.envelope(laundering_attempt, :external_do))
  end

  test "the deputy cannot re-subject its own grant: the broker refuses a token whose binding was rewritten",
       %{broker: broker} do
    # NEWLY ENFORCED THIS SESSION. Before this change,
    # `AshA2A.Authority.Broker.InMemory.verify/2` consulted only expiry and
    # revocation -- both keyed on `token_id` alone -- so the forged struct
    # below verified cleanly as `{:ok, forged}`. That was a real
    # confused-deputy hole in the broker: a peer holding a legitimate grant
    # could rewrite `subject` to the peer that asked it for a favor and have
    # the broker confirm the result. The `:token_binding_mismatch` clause in
    # `in_memory.ex` closes it; this test is its falsifier.
    peer_a = Identity.principal("peer-a")
    peer_b = Identity.principal("peer-b")

    assert {:ok, a_authority} = InMemory.issue(peer_a, @capability, broker)

    forged = %{a_authority | subject: peer_b}

    # The struct alone WOULD admit -- which is exactly why standing is the
    # broker's decision and not the struct's.
    assert Authority.admits?(forged, %{principal_id: peer_b, capability_id: @capability})

    assert {:error, %{reason: :token_binding_mismatch, token_id: token_id}} =
             InMemory.verify(forged, broker)

    assert token_id == a_authority.token_id

    # The untouched original still verifies -- so the refusal above is a real
    # binding check, not a blanket failure.
    assert {:ok, ^a_authority} = InMemory.verify(a_authority, broker)
  end

  test "rewriting the CAPABILITY of a held grant is refused by the same binding check", %{
    broker: broker
  } do
    peer_a = Identity.principal("peer-a")

    assert {:ok, a_authority} =
             InMemory.issue(peer_a, "AshA2A.Test.Fixture.AuthorityProbe.peek", broker)

    escalated = %{a_authority | capability_id: @capability}

    assert {:error, %{reason: :token_binding_mismatch}} = InMemory.verify(escalated, broker)
  end

  test "LIMITATION, asserted not assumed: InMemory verifies a token it never issued (it is a dev/test broker, not a token-authenticity oracle)",
       %{broker: broker, store_opts: store_opts} do
    # This is a real, pre-existing property that this session did NOT close:
    # `test/ash_a2a/authority_broker_in_memory_test.exs` asserts it directly
    # (two independently-started brokers hold independent revocation state,
    # so a broker must accept a token it never issued). Writing it down here
    # keeps it a known boundary rather than an unnoticed assumption.
    stranger = Identity.principal("never-issued-here")
    hand_built = Authority.new(stranger, @capability, token_id: "never-issued-token")

    assert {:ok, ^hand_built} = InMemory.verify(hand_built, broker)

    # What makes that survivable: the bus does not consult the broker. It
    # binds authority to the command's own principal, so a hand-built grant
    # still cannot launder one peer's request through another's identity.
    laundered =
      Command.new(@capability,
        command_id: "deputy-hand-built",
        agent_id: "deputy-agent",
        principal_id: Identity.principal("peer-b"),
        authority: hand_built,
        input: %{}
      )

    assert {:error, %{code: :authority_mismatch}} = run(laundered, store_opts)
    assert ActuatorCounter.count() == 0
  end

  test "the deputy cannot silently rewrite the principal: doing so changes both the command fingerprint and the decision-envelope digest",
       %{store_opts: store_opts, broker: broker} do
    peer_a = Identity.principal("peer-a")
    peer_b = Identity.principal("peer-b")

    assert {:ok, a_authority} = InMemory.issue(peer_a, @capability, broker)

    honest =
      Command.new(@capability,
        command_id: "deputy-honest",
        agent_id: "deputy-agent",
        principal_id: peer_b,
        authority: a_authority,
        input: %{}
      )

    # The only way to make the bus admit is to claim the request came from A.
    rewritten =
      Command.new(@capability,
        command_id: "deputy-rewritten",
        agent_id: "deputy-agent",
        principal_id: peer_a,
        authority: a_authority,
        input: %{}
      )

    # That rewrite is loud, not silent -- it is visible in the content
    # address that lands in the receipt chain.
    refute honest.fingerprint == rewritten.fingerprint

    at = ~U[2026-01-01 00:00:00Z]

    refute Decision.digest(Decision.envelope(honest, :external_do, evaluated_at: at)) ==
             Decision.digest(Decision.envelope(rewritten, :external_do, evaluated_at: at))

    assert {:error, %{code: :authority_mismatch}} = run(honest, store_opts)
    assert ActuatorCounter.count() == 0

    # The rewritten command IS admitted -- correctly, because it is now a
    # claim that A is acting, attributable to A in the receipt. The refusal
    # boundary is intact; what this proves is that laundering cannot happen
    # without an attributable, content-addressed change of principal.
    assert {:ok, receipt} = run(rewritten, store_opts)
    assert receipt.status == :completed
    assert ActuatorCounter.count() == 1
    assert receipt.fingerprint == rewritten.fingerprint
    assert receipt.principal_id == peer_a
  end

  test "a revoked grant stops verifying, so a deputy cannot keep re-presenting an old one", %{
    broker: broker
  } do
    peer_a = Identity.principal("peer-a")

    assert {:ok, a_authority} = InMemory.issue(peer_a, @capability, broker)
    assert {:ok, _} = InMemory.verify(a_authority, broker)
    assert :ok = InMemory.revoke(a_authority, broker)
    assert {:error, _refusal} = InMemory.verify(a_authority, broker)
  end
end
