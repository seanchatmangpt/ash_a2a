# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.DoctorTest.Items do
  @moduledoc false
  use Ash.Resource,
    domain: AshA2A.DoctorTest.HomeDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
    attribute(:label, :string, public?: true)
  end

  actions do
    defaults([:read, create: [:label]])
  end

  a2a do
    skill(:list_items, :read)
    skill(:add_item, :create)
  end
end

defmodule AshA2A.DoctorTest.HomeDomain do
  @moduledoc false
  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.DoctorTest.Items)
  end
end

defmodule AshA2A.DoctorTest.EchoAgent do
  @moduledoc false
  use AshA2A.Agent,
    resource_or_domain: AshA2A.DoctorTest.Items,
    name: "doctor_test_echo_agent",
    public_skills: [:list_items]
end

defmodule AshA2A.DoctorTest.MountedDomain do
  @moduledoc false
  use Ash.Domain, extensions: [AshA2A.Domain]

  agent do
    name "doctor-mounted"
  end

  transport do
    base_url "https://agents.example.com"
    mount agent: AshA2A.DoctorTest.EchoAgent, path: "/echo", binding: :jsonrpc
  end
end

defmodule AshA2A.DoctorTest do
  use ExUnit.Case, async: true

  alias AshA2A.Doctor

  defp run(env_map \\ %{}, opts \\ []) do
    Doctor.diagnose(
      Keyword.merge(
        [
          domains: [AshA2A.DoctorTest.MountedDomain],
          resources: [AshA2A.DoctorTest.Items],
          env: &Map.get(env_map, &1),
          loaded?: fn _ -> false end
        ],
        opts
      )
    )
  end

  defp codes(findings), do: Enum.map(findings, & &1.code)

  test "every finding has the documented shape" do
    for f <- run() do
      assert f.severity in [:error, :warn, :info]
      assert is_atom(f.code)
      assert is_binary(f.message)
      assert is_binary(f.fix)
    end
  end

  test "mount without a security scheme is flagged, and the card/mount mismatch is found" do
    findings = run()
    assert :mount_missing_auth in codes(findings)
    assert :card_mount_mismatch in codes(findings)
  end

  test "consequence-bearing skill without a broker warns; with a broker it does not" do
    assert :authority_broker_unset in codes(run())

    refute :authority_broker_unset in codes(
             run(%{authority_broker: AshA2A.Authority.Broker.InMemory})
           )
  end

  test "disabled caller authentication is an error and fails the gate" do
    findings = run(%{require_authenticated_caller: false})
    assert :authenticated_caller_disabled in codes(findings)
    assert Doctor.failing?(findings)
    assert hd(findings).severity == :error
  end

  test "warnings fail only under strict" do
    findings = run(%{authority_broker: AshA2A.Authority.Broker.InMemory})
    refute Enum.any?(findings, &(&1.severity == :error))
    refute Doctor.failing?(findings)
    assert Doctor.failing?(findings, true)
  end

  test "optional deps are reported through the injected probe" do
    findings = run(%{}, loaded?: fn mod -> mod == Oban end)
    present = for %{code: :optional_dep_present, message: m} <- findings, do: m
    assert Enum.any?(present, &(&1 =~ "oban"))
    assert :optional_dep_absent in codes(findings)
  end

  test "unset config keys are reported" do
    assert :config_receipt_binding_key_unset in codes(run())
    refute :config_receipt_binding_key_unset in codes(run(%{receipt_binding_key: "k"}))
  end
end
