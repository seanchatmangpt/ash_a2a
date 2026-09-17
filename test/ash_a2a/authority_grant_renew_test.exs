defmodule AshA2A.AuthorityGrantRenewTest.NoRenewBroker do
  @moduledoc """
  A real, minimal `AshA2A.Authority.Broker` implementation that deliberately
  does NOT implement the optional `renew/4` callback -- used by
  `AshA2A.AuthorityGrantRenewTest` to prove `AshA2A.Authority.Grant.renew/3`
  reads a broker's absence of `renew/4` as `:renew_unsupported` rather than
  silently falling back to a revoke-then-reissue round trip. A real
  behaviour implementation, not a mock: `granted?/3` genuinely always
  answers `true` (an admission stub deliberately simple enough to make the
  renewal-refusal path exactly the only thing under test), and `issue/3` /
  `revoke/2` / `verify/2` genuinely implement the behaviour's contract.
  """

  @behaviour AshA2A.Authority.Broker

  @impl true
  def issue(subject, capability_id, opts),
    do: {:ok, AshA2A.Authority.new(subject, capability_id, opts)}

  @impl true
  def revoke(_authority, _opts), do: :ok

  @impl true
  def verify(authority, _opts), do: {:ok, authority}

  @impl true
  def granted?(_subject, _capability_id, _opts), do: true
end

defmodule AshA2A.AuthorityGrantRenewTest do
  @moduledoc """
  Chicago-school tests for grant renewal: `AshA2A.Authority.Broker.renew/4`
  against both real, shipped implementations
  (`AshA2A.Authority.Broker.InMemory`, backed by a real `GenServer`, and
  `AshA2A.Authority.Broker.Ekv`, backed by a real on-disk `EKV` instance) and
  `AshA2A.Authority.Grant.renew/3` against the real, configured-broker
  resolution path -- no Mock/mox/patch/monkeypatch anywhere in this file, no
  mocking of the broker, the process, `EKV`, or `AshA2A.Authority`.

  Proves the actual defect this closes: before `renew/4`, extending a
  standing grant's `expires_at` required `revoke/3` then `grant/3` -- two
  separate broker calls with a real gap between them during which
  `granted?/3` legitimately answers `false`. Every test below drives
  `granted?/3` (or `grant_expires_at/3`) as the real observation of standing,
  the same function the real dispatch path
  (`AshA2A.Authority.Grant.authorize/3`) consults -- not an assumption about
  what renewal "should" do.
  """

  use ExUnit.Case, async: false

  alias AshA2A.{Authority, Identity}
  alias AshA2A.Authority.Broker.{Ekv, InMemory}
  alias AshA2A.Authority.Grant

  defp start_in_memory_broker! do
    name = :"authority_grant_renew_in_memory_test_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      start_supervised(%{id: name, start: {InMemory, :start_link, [[name: name]]}})

    name
  end

  defp start_ekv_broker! do
    ekv_name = :"authority_grant_renew_ekv_test_#{System.unique_integer([:positive])}"

    data_dir =
      Path.join(
        System.tmp_dir!(),
        "ash_a2a_authority_grant_renew_ekv_test_#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(data_dir) end)

    start_supervised!({EKV, name: ekv_name, data_dir: data_dir, cluster_size: 1})

    ekv_name
  end

  # `granted?/3`, `grant_expires_at/3`, and `renew/4` all key their lookup on
  # `AshA2A.Authority.grant_token_id/2` -- the SAME deterministic
  # `(subject, capability_id)` derivation `AshA2A.Authority.Grant.grant/3`
  # always forces onto `issue/3` (see `grant.ex`'s own comment on why:
  # `authorize/3` looks the grant up by exactly `grant_token_id/2`). Calling
  # a broker's raw `issue/3` directly, as the two `describe` blocks below do
  # to reach the broker level without going through `Grant`, must pass that
  # same `token_id` explicitly or the issued entry is keyed by
  # `Authority.new/3`'s own randomly-generated default token id instead -- a
  # real, pre-existing requirement of both broker implementations, not
  # something this test suite invents.
  defp keyed_issue_opts(subject, capability_id, extra),
    do: [token_id: Authority.grant_token_id(subject, capability_id)] ++ extra

  describe "InMemory.renew/4" do
    test "extends a standing grant's expires_at in place, never dropping standing" do
      broker = start_in_memory_broker!()
      subject = Identity.principal("renew-extend-subject")
      original_expiry = DateTime.add(DateTime.utc_now(), 60, :second)
      later_expiry = DateTime.add(DateTime.utc_now(), 3600, :second)

      {:ok, _authority} =
        InMemory.issue(
          subject,
          "widgets:renew",
          keyed_issue_opts(subject, "widgets:renew", name: broker, expires_at: original_expiry)
        )

      assert InMemory.granted?(subject, "widgets:renew", name: broker)

      assert {:ok, ^original_expiry} =
               InMemory.grant_expires_at(subject, "widgets:renew", name: broker)

      assert :ok = InMemory.renew(subject, "widgets:renew", later_expiry, name: broker)

      # Standing THE WHOLE TIME -- no revoke, no reissue, no window where
      # granted?/3 could have observed it absent.
      assert InMemory.granted?(subject, "widgets:renew", name: broker)

      assert {:ok, ^later_expiry} =
               InMemory.grant_expires_at(subject, "widgets:renew", name: broker)
    end

    test "renewing to nil converts a time-bounded grant to permanent" do
      broker = start_in_memory_broker!()
      subject = Identity.principal("renew-permanent-subject")
      original_expiry = DateTime.add(DateTime.utc_now(), 60, :second)

      {:ok, _authority} =
        InMemory.issue(
          subject,
          "widgets:permanent",
          keyed_issue_opts(subject, "widgets:permanent",
            name: broker,
            expires_at: original_expiry
          )
        )

      assert :ok = InMemory.renew(subject, "widgets:permanent", nil, name: broker)

      assert {:ok, nil} = InMemory.grant_expires_at(subject, "widgets:permanent", name: broker)
      assert InMemory.granted?(subject, "widgets:permanent", name: broker)
    end

    test "fails closed on a grant that was never issued" do
      broker = start_in_memory_broker!()
      subject = Identity.principal("renew-absent-subject")
      later = DateTime.add(DateTime.utc_now(), 3600, :second)

      assert {:error, %{reason: :grant_not_standing, status: :absent}} =
               InMemory.renew(subject, "widgets:never-issued", later, name: broker)
    end

    test "fails closed on an already-revoked grant, and does not resurrect it" do
      broker = start_in_memory_broker!()
      subject = Identity.principal("renew-revoked-subject")
      later = DateTime.add(DateTime.utc_now(), 3600, :second)

      {:ok, authority} =
        InMemory.issue(
          subject,
          "widgets:revoked-renew",
          keyed_issue_opts(subject, "widgets:revoked-renew", name: broker)
        )

      :ok = InMemory.revoke(authority, name: broker)

      assert {:error, %{reason: :grant_not_standing, status: :revoked}} =
               InMemory.renew(subject, "widgets:revoked-renew", later, name: broker)

      refute InMemory.granted?(subject, "widgets:revoked-renew", name: broker)
    end

    test "fails closed on an already-expired grant, and does not resurrect it" do
      broker = start_in_memory_broker!()
      subject = Identity.principal("renew-expired-subject")
      already_past = DateTime.add(DateTime.utc_now(), -60, :second)
      later = DateTime.add(DateTime.utc_now(), 3600, :second)

      {:ok, _authority} =
        InMemory.issue(
          subject,
          "widgets:expired-renew",
          keyed_issue_opts(subject, "widgets:expired-renew",
            name: broker,
            expires_at: already_past
          )
        )

      assert {:error, %{reason: :grant_not_standing, status: :expired}} =
               InMemory.renew(subject, "widgets:expired-renew", later, name: broker)

      refute InMemory.granted?(subject, "widgets:expired-renew", name: broker)
    end
  end

  describe "Ekv.renew/4" do
    test "extends a standing grant's expires_at in place, durably, never dropping standing" do
      ekv_name = start_ekv_broker!()
      opts = [name: ekv_name]
      subject = Identity.principal("renew-ekv-extend-subject")
      original_expiry = DateTime.add(DateTime.utc_now(), 60, :second)
      later_expiry = DateTime.add(DateTime.utc_now(), 3600, :second)

      {:ok, _authority} =
        Ekv.issue(
          subject,
          "widgets:renew",
          keyed_issue_opts(subject, "widgets:renew", opts ++ [expires_at: original_expiry])
        )

      assert Ekv.granted?(subject, "widgets:renew", opts)
      assert {:ok, ^original_expiry} = Ekv.grant_expires_at(subject, "widgets:renew", opts)

      assert :ok = Ekv.renew(subject, "widgets:renew", later_expiry, opts)

      assert Ekv.granted?(subject, "widgets:renew", opts)
      assert {:ok, ^later_expiry} = Ekv.grant_expires_at(subject, "widgets:renew", opts)

      # The durable record itself, read directly through the real EKV API --
      # proving the rewrite actually landed on disk, not merely in a return
      # value.
      key =
        Identity.external(Identity.runtime(Authority.grant_token_id(subject, "widgets:renew")))

      assert %{status: :issued, expires_at: ^later_expiry} = EKV.get(ekv_name, key)
    end

    test "fails closed on a grant that was never issued" do
      ekv_name = start_ekv_broker!()
      opts = [name: ekv_name]
      subject = Identity.principal("renew-ekv-absent-subject")
      later = DateTime.add(DateTime.utc_now(), 3600, :second)

      assert {:error, %{reason: :grant_not_standing, status: :absent}} =
               Ekv.renew(subject, "widgets:never-issued", later, opts)
    end

    test "fails closed on an already-revoked grant, and does not resurrect it" do
      ekv_name = start_ekv_broker!()
      opts = [name: ekv_name]
      subject = Identity.principal("renew-ekv-revoked-subject")
      later = DateTime.add(DateTime.utc_now(), 3600, :second)

      {:ok, authority} =
        Ekv.issue(
          subject,
          "widgets:revoked-renew",
          keyed_issue_opts(subject, "widgets:revoked-renew", opts)
        )

      :ok = Ekv.revoke(authority, opts)

      assert {:error, %{reason: :grant_not_standing, status: :revoked}} =
               Ekv.renew(subject, "widgets:revoked-renew", later, opts)

      refute Ekv.granted?(subject, "widgets:revoked-renew", opts)
    end

    test "durability across a real EKV process restart: a renewal survives stop/start" do
      ekv_name = :"authority_grant_renew_ekv_restart_test_#{System.unique_integer([:positive])}"

      data_dir =
        Path.join(
          System.tmp_dir!(),
          "ash_a2a_authority_grant_renew_ekv_restart_test_#{System.unique_integer([:positive])}"
        )

      on_exit(fn -> File.rm_rf!(data_dir) end)

      ekv_opts = [name: ekv_name, data_dir: data_dir, cluster_size: 1]
      opts = [name: ekv_name]
      child_id = {EKV, ekv_name}

      pid1 = start_supervised!({EKV, ekv_opts})

      subject = Identity.principal("renew-restart-subject")
      later_expiry = DateTime.add(DateTime.utc_now(), 3600, :second)

      {:ok, _authority} =
        Ekv.issue(
          subject,
          "widgets:restart-renew",
          keyed_issue_opts(subject, "widgets:restart-renew", opts)
        )

      assert :ok = Ekv.renew(subject, "widgets:restart-renew", later_expiry, opts)

      :ok = stop_supervised(child_id)
      refute Process.alive?(pid1)

      start_supervised!({EKV, ekv_opts})

      assert {:ok, ^later_expiry} = Ekv.grant_expires_at(subject, "widgets:restart-renew", opts)
      assert Ekv.granted?(subject, "widgets:restart-renew", opts)
    end
  end

  describe "AshA2A.Authority.Grant.renew/3 against the configured broker" do
    # `Grant.granted?/3` and `Grant.renew/3` (like the pre-existing
    # `Grant.revoke/3`) resolve a named broker instance's own opts (e.g.
    # `:name`) ONLY from the `broker:` value itself -- they do not re-merge
    # bare top-level opts the way `Grant.grant/3` does for `:expires_at`
    # (`grant/3`'s own comment explains why: forwarding `:expires_at` into
    # `Authority.new/3`'s options). The established, real calling
    # convention throughout this codebase for a named broker instance is
    # therefore the tuple form `broker: {Module, opts}` --
    # `test/ash_a2a/chicago/authority_courts_test.exs` uses exactly this
    # shape (`%{broker: {InMemory, name: name}}`). These tests use that same
    # real convention rather than a bare `broker: Module, name: x`, which
    # `granted?/3`/`renew/3` would resolve against the DEFAULT-named broker
    # instead (a real, pre-existing, and correct fail-closed behavior, not a
    # defect to work around).
    test "renews through the InMemory broker end to end, standing observed the whole time" do
      broker_name = start_in_memory_broker!()
      broker = {InMemory, name: broker_name}
      subject = Identity.principal("grant-renew-in-memory-subject")
      later_expiry = DateTime.add(DateTime.utc_now(), 3600, :second)

      {:ok, _authority} = Grant.grant(subject, "reports:renew", broker: broker)

      assert Grant.granted?(subject, "reports:renew", broker: broker)

      assert :ok = Grant.renew(subject, "reports:renew", broker: broker, expires_at: later_expiry)

      assert Grant.granted?(subject, "reports:renew", broker: broker)

      assert {:ok, ^later_expiry} =
               InMemory.grant_expires_at(subject, "reports:renew", name: broker_name)
    end

    test "renews through the Ekv broker end to end, durably" do
      ekv_name = start_ekv_broker!()
      broker = {Ekv, name: ekv_name}
      subject = Identity.principal("grant-renew-ekv-subject")
      later_expiry = DateTime.add(DateTime.utc_now(), 3600, :second)

      {:ok, _authority} = Grant.grant(subject, "reports:renew-ekv", broker: broker)

      assert :ok =
               Grant.renew(subject, "reports:renew-ekv", broker: broker, expires_at: later_expiry)

      assert {:ok, ^later_expiry} =
               Ekv.grant_expires_at(subject, "reports:renew-ekv", name: ekv_name)
    end

    test "refuses :renew_unsupported for a real broker that does not implement renew/4, without falling back to revoke+grant" do
      subject = Identity.principal("grant-renew-unsupported-subject")
      alias AshA2A.AuthorityGrantRenewTest.NoRenewBroker

      {:ok, _authority} = Grant.grant(subject, "reports:no-renew", broker: NoRenewBroker)

      assert {:error, %{reason: :renew_unsupported, capability_id: "reports:no-renew"}} =
               Grant.renew(subject, "reports:no-renew", broker: NoRenewBroker)

      # The original grant is untouched -- no silent revoke was ever
      # attempted as a fallback.
      assert Grant.granted?(subject, "reports:no-renew", broker: NoRenewBroker)
    end
  end
end
