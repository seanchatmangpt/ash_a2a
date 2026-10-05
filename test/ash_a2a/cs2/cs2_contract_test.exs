# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.CS2.ContractTest do
  use ExUnit.Case, async: true

  alias AshA2A.CS2.{Contract, ConsumerContract, FleetAdapter, FleetContract, XaasBridge}

  test "fleet contract wraps payload under a CONSTRUCT ceiling" do
    assert FleetContract.wrap(%{a: 1}) == %{
             schema: "cs2.fleet-contract.v1",
             subject: "RFC-CS2-001",
             work_id: "CS2-WRK-012",
             authority_ceiling: :construct,
             payload: %{a: 1}
           }
  end

  test "xaas bridge carries the exact fleet envelope" do
    packet = XaasBridge.packet(%{a: 1})
    assert packet.contract == FleetContract.wrap(%{a: 1})
    assert packet.consumer == "xaas"
    assert packet.subject == "RFC-CS2-001"
  end

  test "contract evidence and triage packets carry kind, provenance and novelty" do
    ev = Contract.evidence_packet(%{f: 1}, %{sha: "abc"})
    assert ev.kind == :cs2_evidence_packet
    assert ev.provenance == %{sha: "abc"}
    assert ev.payload == %{f: 1}

    tr = Contract.triage_packet(%{f: 1}, :novel, %{sha: "abc"})
    assert tr.kind == :cs2_triage_packet
    assert tr.novelty == :novel
    assert Contract.authority_ceiling() == :construct
    assert Contract.consumers() == ["xaas"]
  end

  test "fleet adapter triages without claiming novelty" do
    out = FleetAdapter.xaas_packet(%{f: 1}, %{sha: "abc"})
    assert out.contract == "cs2-fleet-contract/26.9.26"
    assert out.destination == "xaas.engineer_workflow"
    assert out.subject == "RFC-CS2-001"
    assert out.packet.kind == :cs2_triage_packet
    assert out.packet.novelty == :unassessed
    assert out.packet.provenance == %{sha: "abc"}
    assert ConsumerContract.subject() == "RFC-CS2-001"
  end
end
