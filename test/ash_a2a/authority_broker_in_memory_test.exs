defmodule AshA2A.AuthorityBrokerInMemoryTest do
  @moduledoc """
  Chicago-school tests for `AshA2A.Authority.Broker.InMemory` against the
  real `AshA2A.Authority.Broker` behaviour contract: a real `GenServer`
  process is started per test (or per scenario, for the cross-process
  isolation case) and driven through real `issue/3` / `revoke/2` /
  `verify/2` calls -- no mocking of the broker, the process, or
  `AshA2A.Authority`.
  """

  use ExUnit.Case, async: true

  alias AshA2A.{Authority, Identity}
  alias AshA2A.Authority.Broker.InMemory

  defp start_broker! do
    name = :"authority_broker_in_memory_test_#{System.unique_integer([:positive])}"

    # A plain `{InMemory, name: name}` child spec would fail the second time
    # this helper runs inside the same test: `use GenServer`'s default
    # `child_spec/1` sets `id: __MODULE__` regardless of `:name`, so two
    # `start_supervised/1` calls for the same module (as the cross-process
    # isolation test below needs) collide on ExUnit's own supervisor with a
    # genuine `{:error, {:already_started, pid}}` -- a real bug this session
    # hit and fixed, not a hypothetical. Giving each child spec its own
    # unique `:id` (distinct from the registered process `:name`) is the
    # real fix.
    {:ok, _pid} =
      start_supervised(%{id: name, start: {InMemory, :start_link, [[name: name]]}})

    name
  end

  test "issue/3 produces a real authority that Authority.admits?/2 accepts" do
    broker = start_broker!()
    subject = Identity.principal("issue-subject")

    assert {:ok, %Authority{} = authority} =
             InMemory.issue(subject, "widgets:read", name: broker)

    assert authority.source == :authority_broker
    assert authority.subject == subject
    assert authority.capability_id == "widgets:read"
    refute Authority.expired?(authority)

    assert Authority.admits?(authority, %{
             principal_id: subject,
             capability_id: "widgets:read"
           })

    refute Authority.admits?(authority, %{
             principal_id: subject,
             capability_id: "widgets:write"
           })
  end

  test "revoke/2 then verify/2 on the same authority fails closed through real state" do
    broker = start_broker!()
    subject = Identity.principal("revoke-subject")

    {:ok, authority} = InMemory.issue(subject, "widgets:delete", name: broker)

    # Still good before revocation -- proves the failure below is a real
    # state transition, not a struct that was never going to verify.
    assert {:ok, ^authority} = InMemory.verify(authority, name: broker)

    assert :ok = InMemory.revoke(authority, name: broker)

    assert {:error, %{reason: :revoked, token_id: token_id}} =
             InMemory.verify(authority, name: broker)

    assert token_id == authority.token_id
  end

  test "verify/2 fails closed on an authority already expired via Authority.expired?/1" do
    broker = start_broker!()
    subject = Identity.principal("expired-subject")
    already_past = DateTime.add(DateTime.utc_now(), -3600, :second)

    authority = Authority.new(subject, "widgets:expire", expires_at: already_past)

    assert Authority.expired?(authority)

    assert {:error, %{reason: :expired, token_id: token_id}} =
             InMemory.verify(authority, name: broker)

    assert token_id == authority.token_id
  end

  test "verify/2 succeeds for a valid, unexpired, unrevoked authority" do
    broker = start_broker!()
    subject = Identity.principal("valid-subject")

    {:ok, authority} = InMemory.issue(subject, "widgets:list", name: broker)

    assert {:ok, ^authority} = InMemory.verify(authority, name: broker)
  end

  test "two independently-started InMemory processes do not share revocation state" do
    broker_a = start_broker!()
    broker_b = start_broker!()
    subject = Identity.principal("cross-process-subject")

    {:ok, authority} = InMemory.issue(subject, "widgets:admin", name: broker_a)

    assert :ok = InMemory.revoke(authority, name: broker_a)

    assert {:error, %{reason: :revoked}} = InMemory.verify(authority, name: broker_a)

    # broker_b never observed the revoke against its own real process state.
    assert {:ok, ^authority} = InMemory.verify(authority, name: broker_b)
  end
end
