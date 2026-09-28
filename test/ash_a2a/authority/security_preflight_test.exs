defmodule AshA2A.Authority.SecurityPreflightTest do
  @moduledoc """
  SEC-07 court for `AshA2A.Authority.SecurityPreflight`: every insecure
  production setting is a named violation, and `check!/0` raises in strict
  mode. Real application env, real filesystem paths; no doubles.
  `async: false` because it mutates `:ash_a2a` application env.
  """
  use ExUnit.Case, async: false

  alias AshA2A.Authority.SecurityPreflight

  @keys [
    :authority_policy,
    :authority_broker,
    :receipt_store,
    :receipt_store_ekv_opts,
    :strict_security,
    :allow_legacy_authority_policy
  ]

  setup do
    prior = Map.new(@keys, &{&1, Application.fetch_env(:ash_a2a, &1)})

    on_exit(fn ->
      Enum.each(prior, fn
        {k, {:ok, v}} -> Application.put_env(:ash_a2a, k, v)
        {k, :error} -> Application.delete_env(:ash_a2a, k)
      end)
    end)

    Enum.each(@keys, &Application.delete_env(:ash_a2a, &1))
    :ok
  end

  defp codes do
    case SecurityPreflight.check() do
      :ok -> []
      {:error, violations} -> violations |> Enum.map(& &1.code) |> Enum.sort()
    end
  end

  # Never created on disk: only the path's location is judged.
  defp durable_dir, do: Path.join(File.cwd!(), "_build_preflight_probe")

  test "library defaults are two named violations" do
    assert codes() == [:authority_broker_missing, :receipt_store_non_durable]
  end

  test "a secure configuration passes and check!/1 returns :ok even when forced" do
    Application.put_env(
      :ash_a2a,
      :authority_broker,
      {AshA2A.Authority.Broker.Ekv, data_dir: durable_dir()}
    )

    Application.put_env(:ash_a2a, :receipt_store, AshA2A.ReceiptStore.Ekv)
    Application.put_env(:ash_a2a, :receipt_store_ekv_opts, data_dir: durable_dir())

    assert SecurityPreflight.check() == :ok
    assert SecurityPreflight.check!(force: true) == :ok
  end

  test "the legacy escalation policy is a violation unless acknowledged" do
    Application.put_env(:ash_a2a, :authority_policy, :transport_verified_grants_capability)
    assert :legacy_authority_policy_unacknowledged in codes()

    Application.put_env(
      :ash_a2a,
      :allow_legacy_authority_policy,
      :i_accept_privilege_escalation
    )

    refute :legacy_authority_policy_unacknowledged in codes()
  end

  test "InMemory broker and EKV data_dir under tmp are violations" do
    Application.put_env(:ash_a2a, :authority_broker, AshA2A.Authority.Broker.InMemory)
    Application.put_env(:ash_a2a, :receipt_store, AshA2A.ReceiptStore.Ekv)
    # No :data_dir -> AshA2A.Application's own default under System.tmp_dir!/0.
    assert codes() == [:authority_broker_non_durable, :receipt_store_ekv_data_dir_in_tmp]

    Application.put_env(:ash_a2a, :authority_broker, AshA2A.Authority.Broker.Ekv)
    assert :authority_broker_ekv_data_dir_in_tmp in codes()

    Application.put_env(
      :ash_a2a,
      :receipt_store_ekv_opts,
      data_dir: Path.join(System.tmp_dir!(), "explicit/receipts")
    )

    assert :receipt_store_ekv_data_dir_in_tmp in codes()
  end

  test "system-wide /tmp is volatile even when $TMPDIR points elsewhere" do
    Application.put_env(:ash_a2a, :receipt_store, AshA2A.ReceiptStore.Ekv)
    Application.put_env(:ash_a2a, :receipt_store_ekv_opts, data_dir: "/tmp/ash_a2a/receipts")

    Application.put_env(
      :ash_a2a,
      :authority_broker,
      {AshA2A.Authority.Broker.Ekv, data_dir: "/dev/shm/ash_a2a_broker"}
    )

    assert codes() == [
             :authority_broker_ekv_data_dir_in_tmp,
             :receipt_store_ekv_data_dir_in_tmp
           ]
  end

  test "strict mode raises listing every violation; non-strict is a no-op" do
    Application.put_env(:ash_a2a, :strict_security, false)
    assert SecurityPreflight.check!() == :ok

    Application.put_env(:ash_a2a, :strict_security, true)

    error = assert_raise SecurityPreflight.Error, fn -> SecurityPreflight.check!() end
    assert error.message =~ "authority_broker_missing"
    assert error.message =~ "receipt_store_non_durable"
    assert length(error.violations) == 2
  end

  test "legacy_policy_allowed?/0 is closed in strict mode without the ack" do
    Application.put_env(:ash_a2a, :strict_security, false)
    assert SecurityPreflight.legacy_policy_allowed?()

    Application.put_env(:ash_a2a, :strict_security, true)
    refute SecurityPreflight.legacy_policy_allowed?()

    Application.put_env(:ash_a2a, :allow_legacy_authority_policy, :yes)
    refute SecurityPreflight.legacy_policy_allowed?()

    Application.put_env(
      :ash_a2a,
      :allow_legacy_authority_policy,
      :i_accept_privilege_escalation
    )

    assert SecurityPreflight.legacy_policy_allowed?()
  end

  test "every violation code is S42-classified" do
    Application.put_env(:ash_a2a, :authority_policy, :transport_verified_grants_capability)
    Application.put_env(:ash_a2a, :authority_broker, AshA2A.Authority.Broker.Ekv)
    Application.put_env(:ash_a2a, :receipt_store, AshA2A.ReceiptStore.Ekv)
    classified = SecurityPreflight.__sa2a_refusal_codes__()
    assert codes() != []
    assert Enum.all?(codes(), &Map.has_key?(classified, &1))
  end
end
