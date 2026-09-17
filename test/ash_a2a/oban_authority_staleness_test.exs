defmodule AshA2A.ObanAuthorityStalenessTest do
  @moduledoc """
  Real, Chicago-style regression proof for the Oban delivery adapter's
  authority-staleness gap: an authority admitted through Oban's
  asynchronous/deferred execution path must reflect LIVE
  `AshA2A.Authority.Broker` standing (revocation, expiry) at `perform/1`
  time, not a frozen snapshot of what stood at enqueue time -- the
  Oban-specific instance of "none may regain ambient DO."

  Every collaborator here is real: a real `AshA2A.Authority.Broker.InMemory`
  `GenServer` (issue/revoke go through real process state, never a mock),
  real `AshA2A.Authority.Grant` calls (the SAME module the synchronous
  dispatch path consults), real `AshA2A.Delivery.Oban.payload/1`
  serialization, real `AshA2A.Delivery.ObanAuthority.reconstruct/2` /
  `verify_live!/3`, and a real `AshA2A.CommandBus.run/4` dispatch against
  `AshA2A.Test.Fixture.Item` (ETS-backed, but a genuine Ash data layer, not a
  fixture double). Assertions are state-based throughout: real returned
  refusal shapes, and (for the revocation scenario) the real absence of an
  `Ash.create`d record, not an interaction/call-count check on any of these
  collaborators.

  Deliberately does not require a live Oban queue or Postgres, unlike
  `test/ash_a2a/oban_delivery_qualification_test.exs` (which proves the
  DB-round-trip half of this same adapter against a real `oban_jobs` table
  and needs a real, separately-running Postgres for it). The gap this file
  closes lives entirely in `payload/1` -> job `args` -> `reconstruct/2` ->
  `verify_live!/3` -> `CommandBus.run/4`, none of which touch a database or a
  real Oban queue -- `AshA2A.Test.Support.CommandWorker.perform/1` calls
  exactly the same `CommandBus.run/4` this file calls directly (after the
  same `reconstruct/2` step `CommandWorker` itself now performs), so
  asserting against it here is a real proof of the fixed path, not a weaker
  stand-in for a live-queue test.
  """

  use ExUnit.Case, async: true

  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Authority, Command, CommandBus, Delivery, Identity}
  alias AshA2A.Authority.{Broker.InMemory, Grant}
  alias AshA2A.Delivery.ObanAuthority
  alias AshA2A.Test.Fixture.{Item, ItemDomain}

  @capability_id "AshA2A.Test.Fixture.Item.create"

  # Own uniquely-named broker per test (never the shared, run-wide one
  # `AshA2A.Test.AuthorityGrantCase` points at): this suite explicitly
  # revokes real grants, and revocation state must not leak across tests
  # running `async: true`.
  defp start_broker! do
    name = :"oban_authority_staleness_test_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      start_supervised(%{id: name, start: {InMemory, :start_link, [[name: name]]}})

    {InMemory, name: name}
  end

  defp store_opts! do
    name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    start_supervised!({AshA2A.ReceiptStore.Memory, name: name})
    [name: name]
  end

  defp unique_label(tag), do: "#{tag}-#{System.unique_integer([:positive, :monotonic])}"

  test "reconstruct/2 restores the ORIGINAL expires_at instead of always producing an unbounded authority" do
    broker = start_broker!()
    subject = Identity.principal("subject-expiry-restore")
    expires_at = DateTime.add(DateTime.utc_now(), 3600, :second)

    assert {:ok, %Authority{} = authority} =
             Grant.grant(subject, @capability_id, broker: broker, expires_at: expires_at)

    command =
      Command.new(@capability_id,
        command_id: "expiry-restore-cmd",
        agent_id: "agent-1",
        principal_id: subject,
        authority: authority,
        input: %{label: unique_label("expiry-restore")}
      )

    args = Delivery.Oban.payload(command)
    assert is_binary(args["authority_expires_at"])

    reconstructed = ObanAuthority.reconstruct(args, "subject-expiry-restore")

    assert %Authority{} = reconstructed
    assert reconstructed.subject == subject
    assert reconstructed.capability_id == @capability_id
    assert DateTime.compare(reconstructed.expires_at, authority.expires_at) == :eq
    refute Authority.expired?(reconstructed)
  end

  test "a real expiry that has since passed is refused by verify_live!/3, and by CommandBus itself, rather than silently re-granted" do
    broker = start_broker!()
    subject = Identity.principal("subject-expired")
    # Really in the past -- DateTime.compare(now, expires_at) == :gt -- not
    # a simulated/frozen clock.
    expires_at = DateTime.add(DateTime.utc_now(), -10, :second)

    assert {:ok, authority} =
             Grant.grant(subject, @capability_id, broker: broker, expires_at: expires_at)

    label = unique_label("expired")

    command =
      Command.new(@capability_id,
        command_id: "expiry-refuse-cmd",
        agent_id: "agent-1",
        principal_id: subject,
        authority: authority,
        input: %{label: label}
      )

    args = Delivery.Oban.payload(command)
    reconstructed = ObanAuthority.reconstruct(args, "subject-expired")

    assert Authority.expired?(reconstructed)

    assert {:error, %{reason: :authority_expired}} =
             ObanAuthority.verify_live!(reconstructed, @capability_id, broker: broker)

    # The real end effect a worker gating CommandBus.run/4 on verify_live!/3
    # gets: CommandBus's OWN admission also refuses this reconstructed
    # authority (Authority.admits?/2's `not expired?/1`), so the real
    # Ash.create never runs -- proven by the real final state below, not
    # merely by the refusal tuple.
    reconstructed_command = %{command | authority: reconstructed}

    assert {:error, %{code: :authority_mismatch}} =
             CommandBus.run(reconstructed_command, data_message(%{"label" => label}), Item,
               store_opts: store_opts!()
             )

    assert [] =
             Item
             |> Ash.read!(domain: ItemDomain)
             |> Enum.filter(&(&1.label == label))
  end

  test "a grant revoked after enqueue is refused by verify_live!/3 even though its (unbounded) authority is not itself expired" do
    broker = start_broker!()
    subject = Identity.principal("subject-revoked")
    label = unique_label("revoked")

    assert {:ok, authority} = Grant.grant(subject, @capability_id, broker: broker)

    command =
      Command.new(@capability_id,
        command_id: "revoke-cmd",
        agent_id: "agent-1",
        principal_id: subject,
        authority: authority,
        input: %{label: label}
      )

    args = Delivery.Oban.payload(command)
    reconstructed = ObanAuthority.reconstruct(args, "subject-revoked")

    # BEFORE revocation: the broker still stands, so re-verifying live is a
    # real, legitimate success -- not merely "no explicit expiry."
    assert {:ok, ^reconstructed} =
             ObanAuthority.verify_live!(reconstructed, @capability_id, broker: broker)

    # Simulates exactly the gap between Oban enqueue and perform/1 this test
    # exists to close: the principal's real broker grant is torn down while
    # the job would have been sitting in the queue.
    assert :ok = Grant.revoke(subject, @capability_id, broker: broker)

    # No time bound at all was ever set on this grant -- confirming this
    # scenario is NOT reducible to the expiry case above. Only a live
    # broker re-query (not carrying/parsing any timestamp) can catch it.
    refute Authority.expired?(reconstructed)

    assert {:error, %{reason: :authority_stale}} =
             ObanAuthority.verify_live!(reconstructed, @capability_id, broker: broker)

    # The real, currently-failing-then-passing effect this closes: a worker
    # that gates CommandBus.run/4 on verify_live!/3 (as AshA2A.Delivery.Oban's
    # moduledoc now instructs a host worker to) never reaches the real
    # Ash.create at all -- proven by the real final ETS-backed state, not
    # just the verify_live!/3 return value.
    result =
      with {:ok, _authority} <-
             ObanAuthority.verify_live!(reconstructed, @capability_id, broker: broker) do
        reconstructed_command = %{command | authority: reconstructed}

        CommandBus.run(reconstructed_command, data_message(%{"label" => label}), Item,
          store_opts: store_opts!()
        )
      end

    assert {:error, %{reason: :authority_stale}} = result

    assert [] =
             Item
             |> Ash.read!(domain: ItemDomain)
             |> Enum.filter(&(&1.label == label))
  end

  test "reconstruct/2 accepts a raw principal value, matching AshA2A.Test.Support.CommandWorker's own convention, and returns nil with no authority on the wire" do
    subject = Identity.principal("raw-principal-1")
    authority = Authority.new(subject, @capability_id, token_id: "auth-raw-1")

    command =
      Command.new(@capability_id,
        command_id: "raw-cmd-1",
        agent_id: "agent-1",
        principal_id: subject,
        authority: authority,
        input: %{}
      )

    args = Delivery.Oban.payload(command)

    assert %Authority{} = reconstructed = ObanAuthority.reconstruct(args, "raw-principal-1")
    assert reconstructed.subject == subject
    assert reconstructed.capability_id == @capability_id
    assert reconstructed.expires_at == nil

    no_authority_command =
      Command.new("AshA2A.Test.Fixture.Echo.read",
        command_id: "no-auth-1",
        agent_id: "agent-1",
        principal_id: "anonymous",
        input: %{}
      )

    no_authority_args = Delivery.Oban.payload(no_authority_command)
    assert is_nil(no_authority_args["authority_token_id"])
    assert is_nil(no_authority_args["authority_expires_at"])
    assert is_nil(ObanAuthority.reconstruct(no_authority_args, "anonymous"))
    assert {:ok, nil} = ObanAuthority.verify_live!(nil, "AshA2A.Test.Fixture.Echo.read")
  end
end
