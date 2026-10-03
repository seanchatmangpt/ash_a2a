defmodule AshA2A.ChicagoCaseStudy.SettlementMeshTwoPortTest do
  use ExUnit.Case, async: true

  # Chicago-style Tier 4: Two-Port Identity & Grant Enforcement
  # Invariant: work_order_digest === semantic_subject.graph_digest
  # Consequential mutations require valid, unexpired, signed Ed25519 leases.

  defmodule MockWorkOrder do
    defstruct [:identity, :title, :graph_digest, :origin_authority]
  end

  defmodule TwoPortAdmissionGate do
    @doc """
    Admit a command strictly if the work order digest matches the semantic subject digest.
    Returns {:ok, admitted_command} or {:error, %{code: code, class: class}}
    """
    def admit(%MockWorkOrder{graph_digest: wo_digest}, %{semantic_subject: %{graph_digest: sub_digest}} = command) do
      if wo_digest == sub_digest do
        {:ok, Map.put(command, :admission_standing, :ADMITTED)}
      else
        {:error, %{code: :stale_graph_identity, class: :refused_identity}}
      end
    end
  end

  test "admit/2 succeeds when graph_digest matches work_order_digest exactly" do
    raw_graph = "<urn:tx:1> <http://example.org/p> <http://example.org/o> ."
    canonical_digest = :crypto.hash(:sha256, raw_graph) |> Base.encode16(case: :lower)

    wo = %MockWorkOrder{
      identity: "WO-SETTLE-001",
      title: "Settle Green Bond #42",
      graph_digest: canonical_digest,
      origin_authority: "https://bank.example/authorities/trading-desk-1"
    }

    command = %{
      action: :settle,
      semantic_subject: %{
        id: "tx-100",
        graph_digest: canonical_digest
      },
      actor: "agent://settlement-bot-9",
      lease_id: "lease-42"
    }

    assert {:ok, admitted_command} = TwoPortAdmissionGate.admit(wo, command)
    assert admitted_command.admission_standing == :ADMITTED
  end

  test "admit/2 refuses stale_graph_identity on hash mismatch" do
    correct_digest = :crypto.hash(:sha256, "valid") |> Base.encode16(case: :lower)
    tampered_digest = :crypto.hash(:sha256, "tampered") |> Base.encode16(case: :lower)

    wo = %MockWorkOrder{
      identity: "WO-SETTLE-001",
      title: "Settle Green Bond #42",
      graph_digest: correct_digest,
      origin_authority: "https://bank.example/authorities/trading-desk-1"
    }

    command = %{
      action: :settle,
      semantic_subject: %{
        id: "tx-100",
        graph_digest: tampered_digest
      },
      actor: "agent://settlement-bot-9",
      lease_id: "lease-42"
    }

    assert {:error, refusal} = TwoPortAdmissionGate.admit(wo, command)
    assert refusal.code == :stale_graph_identity
    assert refusal.class == :refused_identity
  end
end
