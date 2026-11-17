# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Authority.EkvBrokerReboundTest do
  @moduledoc """
  `AshA2A.Authority.Broker.Ekv.verify/2` refuses an authority presented with a
  standing grant's token id but another subject or capability
  (`:token_binding_mismatch`), as `AshA2A.Authority.Broker.InMemory.verify/2`
  does (RFC-SA2A-001 S54, confused deputy). A real on-disk EKV instance, no
  doubles.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard

  alias AshA2A.{Authority, Identity}
  alias AshA2A.Authority.Broker.Ekv

  setup do
    name = :"ekv_rebound_test_#{System.unique_integer([:positive])}"

    dir =
      Path.join(System.tmp_dir!(), "ash_a2a_ekv_rebound_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(dir) end)
    start_supervised!({EKV, name: name, data_dir: dir, cluster_size: 1})
    %{opts: [name: name]}
  end

  test "an authority rewritten to another subject does not verify", %{opts: opts} do
    holder = Identity.principal("holder")
    {:ok, authority} = Ekv.issue(holder, "widgets:read", opts)

    assert {:ok, _} = Ekv.verify(authority, opts)

    rebound = %{authority | subject: Identity.principal("deputy")}

    assert {:error, %{reason: :token_binding_mismatch}} = Ekv.verify(rebound, opts)
  end

  test "an authority rewritten to another capability does not verify", %{opts: opts} do
    {:ok, authority} = Ekv.issue(Identity.principal("holder"), "widgets:read", opts)
    rebound = %{authority | capability_id: "widgets:write"}

    assert {:error, %{reason: :token_binding_mismatch}} = Ekv.verify(rebound, opts)
  end

  test "revocation and expiry still win over the binding check", %{opts: opts} do
    holder = Identity.principal("holder")
    {:ok, authority} = Ekv.issue(holder, "widgets:read", opts)
    :ok = Ekv.revoke(authority, opts)

    rebound = %{authority | subject: Identity.principal("deputy")}
    assert {:error, %{reason: :revoked}} = Ekv.verify(rebound, opts)

    expired =
      Authority.new(holder, "widgets:expired",
        expires_at: DateTime.add(DateTime.utc_now(), -5, :second)
      )

    assert {:error, %{reason: :expired}} = Ekv.verify(expired, opts)
  end
end
