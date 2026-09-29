defmodule AshA2A.SecurityProfile.BootTest do
  @moduledoc """
  RFC-SA2A-007 boot court: what each profile refuses at boot. The strict
  rule set is a pure function of a config snapshot, so it is exercised on
  real snapshots; `run!/0` is exercised against the real (test-env,
  dev_bypass) profile. No doubles.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AshA2A.Authority.SecurityPreflight.Error
  alias AshA2A.SecurityProfile.Boot

  defp durable, do: Path.join(File.cwd!(), "_build_boot_probe")

  defp good do
    %{
      outbox_key: String.duplicate("k", 32),
      outbox_dir: durable(),
      receipt_store: AshA2A.ReceiptStore.Ekv,
      capability_release_mode: :strict,
      authority_broker: AshA2A.Authority.Broker.Ekv,
      kill_switch_class: "prod",
      authority_policy: :broker
    }
  end

  defp codes(cfg), do: cfg |> then(&Boot.violations(:strict, &1)) |> Enum.map(& &1.code)

  test "a fully configured snapshot has no strict violations" do
    assert codes(good()) == []
  end

  for {label, patch, code} <- [
        {"unkeyed outbox", %{outbox_key: nil}, :outbox_key_missing},
        {"empty outbox key", %{outbox_key: ""}, :outbox_key_missing},
        {"tmp outbox dir", %{outbox_dir: "/tmp/outbox"}, :outbox_dir_not_durable},
        {"unset outbox dir", %{outbox_dir: nil}, :outbox_dir_not_durable},
        {"memory receipt store", %{receipt_store: AshA2A.ReceiptStore.Memory},
         :receipt_store_in_memory},
        {"legacy release mode", %{capability_release_mode: :legacy},
         :capability_release_mode_legacy},
        {"missing broker", %{authority_broker: nil}, :authority_broker_missing},
        {"nil kill switch class", %{kill_switch_class: nil}, :kill_switch_class_missing},
        {"transport verified policy", %{authority_policy: :transport_verified_grants_capability},
         :transport_verified_policy_forbidden}
      ] do
    test "strict refuses #{label}" do
      assert unquote(code) in codes(Map.merge(good(), unquote(Macro.escape(patch))))
    end
  end

  test "system tmp dir outbox is refused" do
    assert :outbox_dir_not_durable in codes(%{
             good()
             | outbox_dir: Path.join(System.tmp_dir!(), "ash_a2a_receipt_outbox")
           })
  end

  test "non-strict profiles report no refusal violations" do
    bad = %{good() | outbox_key: nil}
    assert Boot.violations(:dev_bypass, bad) == []
    assert Boot.violations(:legacy_compat, bad) == []
  end

  test "enforce!(:strict) raises listing every violation; dev_bypass/legacy do not raise" do
    bad = %{good() | outbox_key: nil, kill_switch_class: nil}
    err = assert_raise Error, fn -> Boot.enforce!(:strict, bad) end
    listed = Enum.map(err.violations, & &1.code)
    assert :outbox_key_missing in listed and :kill_switch_class_missing in listed

    capture_io(:stderr, fn ->
      assert :ok = Boot.enforce!(:legacy_compat, bad)
    end)
  end

  test "dev_bypass prints a loud banner and emits telemetry at boot" do
    ref = make_ref()
    me = self()
    id = {__MODULE__, ref}

    :telemetry.attach(
      id,
      [:ash_a2a, :security_profile, :dev_bypass],
      fn event, m, meta, _ -> send(me, {:tele, event, m, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)

    out = capture_io(:stderr, fn -> assert :ok = Boot.run!() end)
    assert out =~ "DEV_BYPASS"
    assert_receive {:tele, [:ash_a2a, :security_profile, :dev_bypass], %{system_time: _}, _}
  end

  test "codes are classified for refusal totality" do
    classes = Boot.__sa2a_refusal_codes__()
    for code <- codes(%{good() | outbox_key: nil}), do: assert(Map.has_key?(classes, code))
  end
end
