defmodule AshA2A.AuthorityBrokerEkvTest do
  @moduledoc """
  Chicago-school tests for `AshA2A.Authority.Broker.Ekv` against the real
  `AshA2A.Authority.Broker` behaviour contract and a real, on-disk `EKV`
  instance -- started via `start_supervised!/1` with a real temp `data_dir`
  under `System.tmp_dir!/0` and `cluster_size: 1`, the same real-local-EKV
  pattern `test/ash_a2a/receipt_store_ekv_test.exs` already uses for
  `AshA2A.ReceiptStore.Ekv`. No Mock/mox/patch/monkeypatch anywhere in this
  file, and no mocking of `EKV`, the broker, or `AshA2A.Authority`.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  alias AshA2A.{Authority, Identity}
  alias AshA2A.Authority.Broker.Ekv

  setup do
    ekv_name = :"authority_broker_ekv_test_#{System.unique_integer([:positive])}"

    data_dir =
      Path.join(
        System.tmp_dir!(),
        "ash_a2a_authority_broker_ekv_test_#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(data_dir) end)

    start_supervised!({EKV, name: ekv_name, data_dir: data_dir, cluster_size: 1})

    %{store_opts: [name: ekv_name]}
  end

  describe "issue/3" do
    test "produces a real authority that Authority.admits?/2 accepts, recorded durably in EKV",
         %{store_opts: store_opts} do
      subject = Identity.principal("issue-subject")

      assert {:ok, %Authority{} = authority} =
               Ekv.issue(subject, "widgets:read", store_opts)

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

      # The durable record itself -- read directly through the real EKV API,
      # not through the broker -- proving `issue/3` actually wrote real
      # on-disk state and did not merely construct a struct in memory.
      key = Identity.external(authority.token_id)
      name = Keyword.fetch!(store_opts, :name)
      assert %{status: :issued, capability_id: "widgets:read"} = EKV.get(name, key)
    end

    test "a caller-supplied token_id that collides with an already-issued one is refused", %{
      store_opts: store_opts
    } do
      subject = Identity.principal("collision-subject")

      assert {:ok, first} = Ekv.issue(subject, "widgets:read", store_opts)

      assert {:error, %{reason: :token_id_taken, token_id: token_id}} =
               Ekv.issue(subject, "widgets:write",
                 name: Keyword.fetch!(store_opts, :name),
                 token_id: first.token_id.value
               )

      assert token_id == first.token_id
    end
  end

  describe "revoke/2 and verify/2" do
    test "revoke/2 then verify/2 on the same authority fails closed through real durable EKV state",
         %{store_opts: store_opts} do
      subject = Identity.principal("revoke-subject")

      {:ok, authority} = Ekv.issue(subject, "widgets:delete", store_opts)

      # Still good before revocation -- proves the failure below is a real
      # state transition, not a struct that was never going to verify.
      assert {:ok, ^authority} = Ekv.verify(authority, store_opts)

      assert :ok = Ekv.revoke(authority, store_opts)

      assert {:error, %{reason: :revoked, token_id: token_id}} =
               Ekv.verify(authority, store_opts)

      assert token_id == authority.token_id
    end

    test "verify/2 fails closed on an authority already expired via Authority.expired?/1", %{
      store_opts: store_opts
    } do
      subject = Identity.principal("expired-subject")
      already_past = DateTime.add(DateTime.utc_now(), -3600, :second)

      authority = Authority.new(subject, "widgets:expire", expires_at: already_past)

      assert Authority.expired?(authority)

      assert {:error, %{reason: :expired, token_id: token_id}} =
               Ekv.verify(authority, store_opts)

      assert token_id == authority.token_id
    end

    test "verify/2 succeeds for a valid, unexpired, unrevoked authority", %{
      store_opts: store_opts
    } do
      subject = Identity.principal("valid-subject")

      {:ok, authority} = Ekv.issue(subject, "widgets:list", store_opts)

      assert {:ok, ^authority} = Ekv.verify(authority, store_opts)
    end

    test "revoke/2 fails closed even for an authority never issued through this broker", %{
      store_opts: store_opts
    } do
      subject = Identity.principal("never-issued-subject")
      authority = Authority.new(subject, "widgets:external", source: :transport_verified)

      assert {:ok, ^authority} = Ekv.verify(authority, store_opts)
      assert :ok = Ekv.revoke(authority, store_opts)
      assert {:error, %{reason: :revoked}} = Ekv.verify(authority, store_opts)
    end

    test "two independently-started Ekv brokers (distinct real EKV data_dirs) do not share revocation state" do
      broker_a_name = :"authority_broker_ekv_test_a_#{System.unique_integer([:positive])}"
      broker_b_name = :"authority_broker_ekv_test_b_#{System.unique_integer([:positive])}"

      for name <- [broker_a_name, broker_b_name] do
        data_dir =
          Path.join(
            System.tmp_dir!(),
            "ash_a2a_authority_broker_ekv_isolation_test_#{System.unique_integer([:positive])}"
          )

        on_exit(fn -> File.rm_rf!(data_dir) end)
        start_supervised!({EKV, name: name, data_dir: data_dir, cluster_size: 1})
      end

      subject = Identity.principal("cross-process-subject")

      {:ok, authority} = Ekv.issue(subject, "widgets:admin", name: broker_a_name)

      assert :ok = Ekv.revoke(authority, name: broker_a_name)
      assert {:error, %{reason: :revoked}} = Ekv.verify(authority, name: broker_a_name)

      # broker_b's real EKV instance -- a distinct data_dir -- never observed
      # the revoke against its own real on-disk state.
      assert {:ok, ^authority} = Ekv.verify(authority, name: broker_b_name)
    end
  end

  describe "list_grants/2" do
    test "reports every standing grant for a subject, and none for another", %{
      store_opts: store_opts
    } do
      subject = Identity.principal("list-grants-subject")
      other = Identity.principal("list-grants-other-subject")

      {:ok, read} = Ekv.issue(subject, "widgets:read", store_opts)
      {:ok, write} = Ekv.issue(subject, "widgets:write", store_opts)
      {:ok, _other_grant} = Ekv.issue(other, "widgets:read", store_opts)

      assert {:ok, grants} = Ekv.list_grants(subject, store_opts)

      assert MapSet.new(grants) ==
               MapSet.new([
                 %{capability_id: "widgets:read", expires_at: read.expires_at},
                 %{capability_id: "widgets:write", expires_at: write.expires_at}
               ])

      assert {:ok, other_grants} = Ekv.list_grants(other, store_opts)
      assert other_grants == [%{capability_id: "widgets:read", expires_at: nil}]
    end

    test "excludes a revoked grant and an expired grant, includes an unexpired one", %{
      store_opts: store_opts
    } do
      subject = Identity.principal("list-grants-mixed-subject")

      {:ok, revoked} = Ekv.issue(subject, "widgets:revoked", store_opts)
      :ok = Ekv.revoke(revoked, store_opts)

      {:ok, _expired} =
        Ekv.issue(
          subject,
          "widgets:expired",
          store_opts ++ [expires_at: DateTime.add(DateTime.utc_now(), -3600, :second)]
        )

      {:ok, standing} = Ekv.issue(subject, "widgets:standing", store_opts)

      assert {:ok, grants} = Ekv.list_grants(subject, store_opts)
      assert grants == [%{capability_id: "widgets:standing", expires_at: standing.expires_at}]
    end

    test "an unknown subject with no issued grants reports an empty list, not an error", %{
      store_opts: store_opts
    } do
      subject = Identity.principal("list-grants-unknown-subject")

      assert {:ok, []} = Ekv.list_grants(subject, store_opts)
    end

    test "a durable entry survives a real EKV process restart and is still enumerated" do
      ekv_name =
        :"authority_broker_ekv_list_grants_restart_test_#{System.unique_integer([:positive])}"

      data_dir =
        Path.join(
          System.tmp_dir!(),
          "ash_a2a_authority_broker_ekv_list_grants_restart_test_#{System.unique_integer([:positive])}"
        )

      on_exit(fn -> File.rm_rf!(data_dir) end)

      ekv_opts = [name: ekv_name, data_dir: data_dir, cluster_size: 1]
      store_opts = [name: ekv_name]
      child_id = {EKV, ekv_name}

      pid1 = start_supervised!({EKV, ekv_opts})

      subject = Identity.principal("list-grants-restart-subject")
      {:ok, standing} = Ekv.issue(subject, "widgets:restart-list", store_opts)

      :ok = stop_supervised(child_id)
      refute Process.alive?(pid1)

      start_supervised!({EKV, ekv_opts})

      assert {:ok, [%{capability_id: "widgets:restart-list", expires_at: expires_at}]} =
               Ekv.list_grants(subject, store_opts)

      assert expires_at == standing.expires_at
    end
  end

  describe "durability across a real EKV process restart" do
    test "a revocation survives stopping and restarting the real EKV process against the same data_dir" do
      ekv_name = :"authority_broker_ekv_restart_test_#{System.unique_integer([:positive])}"

      data_dir =
        Path.join(
          System.tmp_dir!(),
          "ash_a2a_authority_broker_ekv_restart_test_#{System.unique_integer([:positive])}"
        )

      on_exit(fn -> File.rm_rf!(data_dir) end)

      ekv_opts = [name: ekv_name, data_dir: data_dir, cluster_size: 1]
      store_opts = [name: ekv_name]
      # EKV.child_spec/1 derives id: {EKV, name} -- unique per this test's
      # unique_integer-suffixed ekv_name, and the same id used below to stop
      # and restart the exact same logical child (mirrors
      # `test/ash_a2a/receipt_store_ekv_test.exs`'s own restart test).
      child_id = {EKV, ekv_name}

      pid1 = start_supervised!({EKV, ekv_opts})

      subject = Identity.principal("restart-subject")
      {:ok, authority} = Ekv.issue(subject, "widgets:restart", store_opts)

      assert {:ok, ^authority} = Ekv.verify(authority, store_opts)
      assert :ok = Ekv.revoke(authority, store_opts)
      assert {:error, %{reason: :revoked}} = Ekv.verify(authority, store_opts)

      # Stop the real EKV process entirely (not just the logical entry) and
      # start a brand new one against the same real on-disk data_dir --
      # proving the revocation is durable on disk, not just in this
      # process's memory. `AshA2A.Authority.Broker.InMemory` cannot pass this
      # test structurally: its state lives only in one GenServer's own
      # process dictionary.
      :ok = stop_supervised(child_id)
      refute Process.alive?(pid1)

      start_supervised!({EKV, ekv_opts})

      assert {:error, %{reason: :revoked, token_id: token_id}} =
               Ekv.verify(authority, store_opts)

      assert token_id == authority.token_id
    end

    test "an issued-but-never-revoked authority also survives a real EKV process restart" do
      ekv_name = :"authority_broker_ekv_restart_issue_test_#{System.unique_integer([:positive])}"

      data_dir =
        Path.join(
          System.tmp_dir!(),
          "ash_a2a_authority_broker_ekv_restart_issue_test_#{System.unique_integer([:positive])}"
        )

      on_exit(fn -> File.rm_rf!(data_dir) end)

      ekv_opts = [name: ekv_name, data_dir: data_dir, cluster_size: 1]
      store_opts = [name: ekv_name]
      child_id = {EKV, ekv_name}

      pid1 = start_supervised!({EKV, ekv_opts})

      subject = Identity.principal("restart-issue-subject")
      {:ok, authority} = Ekv.issue(subject, "widgets:still-valid", store_opts)

      :ok = stop_supervised(child_id)
      refute Process.alive?(pid1)

      start_supervised!({EKV, ekv_opts})

      # Still valid after the restart -- a real, unbroken durable record, not
      # merely the absence of a (falsely reassuring) revoked entry.
      assert {:ok, ^authority} = Ekv.verify(authority, store_opts)
      key = Identity.external(authority.token_id)
      assert %{status: :issued} = EKV.get(ekv_name, key)
    end
  end
end
