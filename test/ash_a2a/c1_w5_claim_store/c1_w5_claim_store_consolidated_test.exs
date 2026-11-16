# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
# SPDX-License-Identifier: MIT

# ==============================================================================
# Consolidated Test Suite: C1 W5 Claim Store Suite
# Target: test/ash_a2a/c1_w5_claim_store/c1_w5_claim_store_consolidated_test.exs
# Contains original tests:
#   - test/ash_a2a/c1_w5_claim_store/claim_authenticate_test.exs
#   - test/ash_a2a/c1_w5_claim_store/claim_identity_jcs_test.exs
#   - test/ash_a2a/c1_w5_claim_store/claim_tamper_test.exs
#   - test/ash_a2a/c1_w5_claim_store/duplicate_claim_test.exs
#   - test/ash_a2a/c1_w5_claim_store/duplicate_effect_test.exs
#   - test/ash_a2a/c1_w5_claim_store/file_store_persists_test.exs
#   - test/ash_a2a/c1_w5_claim_store/protocol_begin_do_test.exs
#   - test/ash_a2a/c1_w5_claim_store/protocol_claim_test.exs
#   - test/ash_a2a/c1_w5_claim_store/receipt_chain_test.exs
#   - test/ash_a2a/c1_w5_claim_store/reconciled_retry_test.exs
#   - test/ash_a2a/c1_w5_claim_store/replay_match_test.exs
#   - test/ash_a2a/c1_w5_claim_store/replay_mismatch_test.exs
#   - test/ash_a2a/c1_w5_claim_store/standing_complete_test.exs
#   - test/ash_a2a/c1_w5_claim_store/standing_unknown_test.exs
#   - test/ash_a2a/c1_w5_claim_store/subject_bind_test.exs
#   - test/ash_a2a/c1_w5_claim_store/subject_mismatch_test.exs
#   - test/ash_a2a/c1_w5_claim_store/transition_completed_test.exs
#   - test/ash_a2a/c1_w5_claim_store/transition_doing_test.exs
#   - test/ash_a2a/c1_w5_claim_store/transition_unknown_test.exs
#   - test/ash_a2a/c1_w5_claim_store/unknown_retry_refused_test.exs
# ==============================================================================

# --- SECTION 1: Original test/ash_a2a/c1_w5_claim_store/claim_authenticate_test.exs ---
defmodule AshA2A.C1W5ClaimStore.ClaimAuthenticateTest do
  use ExUnit.Case, async: true

  test "claim_authenticate" do
    vector =
      Path.join([
        File.cwd!(),
        "priv",
        "sa2a",
        "c1",
        "w5_claim_store_vectors",
        "claim_authenticate.json"
      ])

    assert File.read!(vector) =~ "\"case\": \"claim_authenticate\""
    key = String.duplicate("k", 32)

    attrs = %{
      request_id: "req",
      effect_id: "eff",
      prepared_digest: "sha256:prep",
      subject_digest: "sha256:sub",
      owner: "owner",
      issued_at_ms: 1
    }

    {:ok, claim} = AshA2A.ConsequenceKernel.Claims.Authenticator.issue(attrs, key)
    assert :ok = AshA2A.ConsequenceKernel.Claims.Authenticator.verify(claim, key)
  end
end

# --- SECTION 2: Original test/ash_a2a/c1_w5_claim_store/claim_identity_jcs_test.exs ---
defmodule AshA2A.C1W5ClaimStore.ClaimIdentityJcsTest do
  use ExUnit.Case, async: true

  test "claim_identity_jcs" do
    vector =
      Path.join([
        File.cwd!(),
        "priv",
        "sa2a",
        "c1",
        "w5_claim_store_vectors",
        "claim_identity_jcs.json"
      ])

    assert File.read!(vector) =~ "\"case\": \"claim_identity_jcs\""

    assert {:ok, "sha256:" <> d} =
             AshA2A.ConsequenceKernel.Claims.Identity.bind(
               "req",
               "eff",
               "sha256:prep",
               "sha256:sub"
             )

    assert byte_size(d) == 64
  end
end

# --- SECTION 3: Original test/ash_a2a/c1_w5_claim_store/claim_tamper_test.exs ---
defmodule AshA2A.C1W5ClaimStore.ClaimTamperTest do
  use ExUnit.Case, async: true

  test "claim_tamper" do
    vector =
      Path.join([
        File.cwd!(),
        "priv",
        "sa2a",
        "c1",
        "w5_claim_store_vectors",
        "claim_tamper.json"
      ])

    assert File.read!(vector) =~ "\"case\": \"claim_tamper\""
    key = String.duplicate("k", 32)

    attrs = %{
      request_id: "req",
      effect_id: "eff",
      prepared_digest: "sha256:prep",
      subject_digest: "sha256:sub",
      owner: "owner",
      issued_at_ms: 1
    }

    {:ok, claim} = AshA2A.ConsequenceKernel.Claims.Authenticator.issue(attrs, key)

    assert {:error, :effect_claim_authentication_failed} =
             AshA2A.ConsequenceKernel.Claims.Authenticator.verify(%{claim | effect_id: "x"}, key)
  end
end

# --- SECTION 4: Original test/ash_a2a/c1_w5_claim_store/duplicate_claim_test.exs ---
defmodule AshA2A.C1W5ClaimStore.DuplicateClaimTest do
  use ExUnit.Case, async: true

  test "duplicate_claim" do
    vector =
      Path.join([
        File.cwd!(),
        "priv",
        "sa2a",
        "c1",
        "w5_claim_store_vectors",
        "duplicate_claim.json"
      ])

    assert File.read!(vector) =~ "\"case\": \"duplicate_claim\""
    key = String.duplicate("k", 32)

    attrs = %{
      request_id: "req",
      effect_id: "eff",
      prepared_digest: "sha256:prep",
      subject_digest: "sha256:sub",
      owner: "owner",
      issued_at_ms: 1
    }

    {:ok, claim} = AshA2A.ConsequenceKernel.Claims.Authenticator.issue(attrs, key)
    {:ok, s} = AshA2A.ConsequenceKernel.EffectClaimStore.Memory.start_link()
    assert :ok = AshA2A.ConsequenceKernel.EffectClaimStore.Memory.put(s, claim)

    assert {:error, :effect_claim_duplicate} =
             AshA2A.ConsequenceKernel.EffectClaimStore.Memory.put(s, claim)
  end
end

# --- SECTION 5: Original test/ash_a2a/c1_w5_claim_store/duplicate_effect_test.exs ---
defmodule AshA2A.C1W5ClaimStore.DuplicateEffectTest do
  use ExUnit.Case, async: true

  test "duplicate_effect" do
    vector =
      Path.join([
        File.cwd!(),
        "priv",
        "sa2a",
        "c1",
        "w5_claim_store_vectors",
        "duplicate_effect.json"
      ])

    assert File.read!(vector) =~ "\"case\": \"duplicate_effect\""
    key = String.duplicate("k", 32)

    attrs = %{
      request_id: "req",
      effect_id: "eff",
      prepared_digest: "sha256:prep",
      subject_digest: "sha256:sub",
      owner: "owner",
      issued_at_ms: 1
    }

    {:ok, claim} = AshA2A.ConsequenceKernel.Claims.Authenticator.issue(attrs, key)
    {:ok, s} = AshA2A.ConsequenceKernel.EffectClaimStore.Memory.start_link()
    assert :ok = AshA2A.ConsequenceKernel.EffectClaimStore.Memory.put(s, claim)

    {:ok, c2} =
      AshA2A.ConsequenceKernel.Claims.Authenticator.issue(
        %{attrs | prepared_digest: "sha256:other"},
        key
      )

    assert {:error, :effect_already_claimed} =
             AshA2A.ConsequenceKernel.EffectClaimStore.Memory.put(s, c2)
  end
end

# --- SECTION 6: Original test/ash_a2a/c1_w5_claim_store/file_store_persists_test.exs ---
defmodule AshA2A.C1W5ClaimStore.FileStorePersistsTest do
  use ExUnit.Case, async: true

  test "file_store_persists" do
    vector =
      Path.join([
        File.cwd!(),
        "priv",
        "sa2a",
        "c1",
        "w5_claim_store_vectors",
        "file_store_persists.json"
      ])

    assert File.read!(vector) =~ "\"case\": \"file_store_persists\""
    key = String.duplicate("k", 32)

    attrs = %{
      request_id: "req",
      effect_id: "eff",
      prepared_digest: "sha256:prep",
      subject_digest: "sha256:sub",
      owner: "owner",
      issued_at_ms: 1
    }

    {:ok, claim} = AshA2A.ConsequenceKernel.Claims.Authenticator.issue(attrs, key)

    path =
      Path.join(
        System.tmp_dir!(),
        "sa2a_claim_" <> Integer.to_string(System.unique_integer([:positive])) <> ".bin"
      )

    {:ok, s} = AshA2A.ConsequenceKernel.EffectClaimStore.File.start_link(path: path)
    assert :ok = AshA2A.ConsequenceKernel.EffectClaimStore.File.put(s, claim)
    GenServer.stop(s)
    {:ok, s2} = AshA2A.ConsequenceKernel.EffectClaimStore.File.start_link(path: path)
    assert {:ok, c} = AshA2A.ConsequenceKernel.EffectClaimStore.File.fetch(s2, claim.claim_id)
    assert c.effect_id == claim.effect_id
    GenServer.stop(s2)
    File.rm(path)
  end
end

# --- SECTION 7: Original test/ash_a2a/c1_w5_claim_store/protocol_begin_do_test.exs ---
defmodule AshA2A.C1W5ClaimStore.ProtocolBeginDoTest do
  use ExUnit.Case, async: true

  test "protocol_begin_do" do
    vector =
      Path.join([
        File.cwd!(),
        "priv",
        "sa2a",
        "c1",
        "w5_claim_store_vectors",
        "protocol_begin_do.json"
      ])

    assert File.read!(vector) =~ "\"case\": \"protocol_begin_do\""
    key = String.duplicate("k", 32)
    {:ok, s} = AshA2A.ConsequenceKernel.EffectClaimStore.Memory.start_link()

    p = %{
      prepared_digest: "sha256:prep",
      instance: %{request_id: "req", effect_id: "eff", subject_digest: "sha256:sub"}
    }

    opts = [
      claim_store: AshA2A.ConsequenceKernel.EffectClaimStore.Memory,
      claim_store_handle: s,
      claim_key: key
    ]

    {:ok, ctx} = AshA2A.ConsequenceKernel.Claims.Protocol.claim(p, "owner", opts)
    assert :ok = AshA2A.ConsequenceKernel.Claims.Protocol.begin_do(ctx)
    assert {:ok, c} = AshA2A.ConsequenceKernel.EffectClaimStore.Memory.fetch(s, ctx.claim_id)
    assert c.state == :doing
  end
end

# --- SECTION 8: Original test/ash_a2a/c1_w5_claim_store/protocol_claim_test.exs ---
defmodule AshA2A.C1W5ClaimStore.ProtocolClaimTest do
  use ExUnit.Case, async: true

  test "protocol_claim" do
    vector =
      Path.join([
        File.cwd!(),
        "priv",
        "sa2a",
        "c1",
        "w5_claim_store_vectors",
        "protocol_claim.json"
      ])

    assert File.read!(vector) =~ "\"case\": \"protocol_claim\""
    key = String.duplicate("k", 32)
    {:ok, s} = AshA2A.ConsequenceKernel.EffectClaimStore.Memory.start_link()

    p = %{
      prepared_digest: "sha256:prep",
      instance: %{request_id: "req", effect_id: "eff", subject_digest: "sha256:sub"}
    }

    opts = [
      claim_store: AshA2A.ConsequenceKernel.EffectClaimStore.Memory,
      claim_store_handle: s,
      claim_key: key
    ]

    assert {:ok, ctx} = AshA2A.ConsequenceKernel.Claims.Protocol.claim(p, "owner", opts)
    assert {:ok, c} = AshA2A.ConsequenceKernel.EffectClaimStore.Memory.fetch(s, ctx.claim_id)
    assert c.effect_id == "eff"
  end
end

# --- SECTION 9: Original test/ash_a2a/c1_w5_claim_store/receipt_chain_test.exs ---
defmodule AshA2A.C1W5ClaimStore.ReceiptChainTest do
  use ExUnit.Case, async: true

  test "receipt_chain" do
    vector =
      Path.join([
        File.cwd!(),
        "priv",
        "sa2a",
        "c1",
        "w5_claim_store_vectors",
        "receipt_chain.json"
      ])

    assert File.read!(vector) =~ "\"case\": \"receipt_chain\""

    assert {:ok, "sha256:" <> d} =
             AshA2A.ConsequenceKernel.Claims.ReceiptChain.append("sha256:root", %{
               "event" => "claimed"
             })

    assert byte_size(d) == 64
  end
end

# --- SECTION 10: Original test/ash_a2a/c1_w5_claim_store/reconciled_retry_test.exs ---
defmodule AshA2A.C1W5ClaimStore.ReconciledRetryTest do
  use ExUnit.Case, async: true

  test "reconciled_retry" do
    vector =
      Path.join([
        File.cwd!(),
        "priv",
        "sa2a",
        "c1",
        "w5_claim_store_vectors",
        "reconciled_retry.json"
      ])

    assert File.read!(vector) =~ "\"case\": \"reconciled_retry\""
    assert :ok = AshA2A.ConsequenceKernel.Claims.RecoveryGate.retry(:reconciled_not_applied)
  end
end

# --- SECTION 11: Original test/ash_a2a/c1_w5_claim_store/replay_match_test.exs ---
defmodule AshA2A.C1W5ClaimStore.ReplayMatchTest do
  use ExUnit.Case, async: true

  test "replay_match" do
    vector =
      Path.join([
        File.cwd!(),
        "priv",
        "sa2a",
        "c1",
        "w5_claim_store_vectors",
        "replay_match.json"
      ])

    assert File.read!(vector) =~ "\"case\": \"replay_match\""
    key = String.duplicate("k", 32)

    attrs = %{
      request_id: "req",
      effect_id: "eff",
      prepared_digest: "sha256:prep",
      subject_digest: "sha256:sub",
      owner: "owner",
      issued_at_ms: 1
    }

    {:ok, claim} = AshA2A.ConsequenceKernel.Claims.Authenticator.issue(attrs, key)
    r = AshA2A.ConsequenceKernel.Claims.ReplayEvidence.derive(claim)
    assert :ok = AshA2A.ConsequenceKernel.Claims.ReplayEvidence.verify(claim, r)
  end
end

# --- SECTION 12: Original test/ash_a2a/c1_w5_claim_store/replay_mismatch_test.exs ---
defmodule AshA2A.C1W5ClaimStore.ReplayMismatchTest do
  use ExUnit.Case, async: true

  test "replay_mismatch" do
    vector =
      Path.join([
        File.cwd!(),
        "priv",
        "sa2a",
        "c1",
        "w5_claim_store_vectors",
        "replay_mismatch.json"
      ])

    assert File.read!(vector) =~ "\"case\": \"replay_mismatch\""
    key = String.duplicate("k", 32)

    attrs = %{
      request_id: "req",
      effect_id: "eff",
      prepared_digest: "sha256:prep",
      subject_digest: "sha256:sub",
      owner: "owner",
      issued_at_ms: 1
    }

    {:ok, claim} = AshA2A.ConsequenceKernel.Claims.Authenticator.issue(attrs, key)
    r = AshA2A.ConsequenceKernel.Claims.ReplayEvidence.derive(claim)

    assert {:error, :replay_evidence_mismatch} =
             AshA2A.ConsequenceKernel.Claims.ReplayEvidence.verify(claim, %{r | effect_id: "x"})
  end
end

# --- SECTION 13: Original test/ash_a2a/c1_w5_claim_store/standing_complete_test.exs ---
defmodule AshA2A.C1W5ClaimStore.StandingCompleteTest do
  use ExUnit.Case, async: true

  test "standing_complete" do
    vector =
      Path.join([
        File.cwd!(),
        "priv",
        "sa2a",
        "c1",
        "w5_claim_store_vectors",
        "standing_complete.json"
      ])

    assert File.read!(vector) =~ "\"case\": \"standing_complete\""
    key = String.duplicate("k", 32)

    attrs = %{
      request_id: "req",
      effect_id: "eff",
      prepared_digest: "sha256:prep",
      subject_digest: "sha256:sub",
      owner: "owner",
      issued_at_ms: 1
    }

    {:ok, claim} = AshA2A.ConsequenceKernel.Claims.Authenticator.issue(attrs, key)
    {:ok, r1} = AshA2A.ConsequenceKernel.Claims.Receipt.build(claim, :claimed)
    {:ok, r2} = AshA2A.ConsequenceKernel.Claims.Receipt.build(claim, :doing, r1["chain_digest"])
    replay = AshA2A.ConsequenceKernel.Claims.ReplayEvidence.derive(claim)

    assert {:ok, :evidenced} =
             AshA2A.ConsequenceKernel.Claims.Standing.derive(
               claim,
               [r1, r2],
               replay,
               :completed,
               key
             )
  end
end

# --- SECTION 14: Original test/ash_a2a/c1_w5_claim_store/standing_unknown_test.exs ---
defmodule AshA2A.C1W5ClaimStore.StandingUnknownTest do
  use ExUnit.Case, async: true

  test "standing_unknown" do
    vector =
      Path.join([
        File.cwd!(),
        "priv",
        "sa2a",
        "c1",
        "w5_claim_store_vectors",
        "standing_unknown.json"
      ])

    assert File.read!(vector) =~ "\"case\": \"standing_unknown\""
    key = String.duplicate("k", 32)

    attrs = %{
      request_id: "req",
      effect_id: "eff",
      prepared_digest: "sha256:prep",
      subject_digest: "sha256:sub",
      owner: "owner",
      issued_at_ms: 1
    }

    {:ok, claim} = AshA2A.ConsequenceKernel.Claims.Authenticator.issue(attrs, key)
    {:ok, r1} = AshA2A.ConsequenceKernel.Claims.Receipt.build(claim, :claimed)
    replay = AshA2A.ConsequenceKernel.Claims.ReplayEvidence.derive(claim)

    assert {:error, :standing_unknown_outcome} =
             AshA2A.ConsequenceKernel.Claims.Standing.derive(
               claim,
               [r1],
               replay,
               :unknown_outcome,
               key
             )
  end
end

# --- SECTION 15: Original test/ash_a2a/c1_w5_claim_store/subject_bind_test.exs ---
defmodule AshA2A.C1W5ClaimStore.SubjectBindTest do
  use ExUnit.Case, async: true

  test "subject_bind" do
    vector =
      Path.join([
        File.cwd!(),
        "priv",
        "sa2a",
        "c1",
        "w5_claim_store_vectors",
        "subject_bind.json"
      ])

    assert File.read!(vector) =~ "\"case\": \"subject_bind\""
    p = %{prepared_digest: "sha256:prep", instance: %{subject_digest: "sha256:sub"}}
    c = %{prepared_digest: "sha256:prep", subject_digest: "sha256:sub"}
    assert :ok = AshA2A.ConsequenceKernel.Claims.Subject.bind(p, c)
  end
end

# --- SECTION 16: Original test/ash_a2a/c1_w5_claim_store/subject_mismatch_test.exs ---
defmodule AshA2A.C1W5ClaimStore.SubjectMismatchTest do
  use ExUnit.Case, async: true

  test "subject_mismatch" do
    vector =
      Path.join([
        File.cwd!(),
        "priv",
        "sa2a",
        "c1",
        "w5_claim_store_vectors",
        "subject_mismatch.json"
      ])

    assert File.read!(vector) =~ "\"case\": \"subject_mismatch\""
    p = %{prepared_digest: "sha256:prep", instance: %{subject_digest: "sha256:sub"}}
    c = %{prepared_digest: "sha256:other", subject_digest: "sha256:sub"}

    assert {:error, :effect_claim_exact_subject_mismatch} =
             AshA2A.ConsequenceKernel.Claims.Subject.bind(p, c)
  end
end

# --- SECTION 17: Original test/ash_a2a/c1_w5_claim_store/transition_completed_test.exs ---
defmodule AshA2A.C1W5ClaimStore.TransitionCompletedTest do
  use ExUnit.Case, async: true

  test "transition_completed" do
    vector =
      Path.join([
        File.cwd!(),
        "priv",
        "sa2a",
        "c1",
        "w5_claim_store_vectors",
        "transition_completed.json"
      ])

    assert File.read!(vector) =~ "\"case\": \"transition_completed\""
    assert :ok = AshA2A.ConsequenceKernel.Claims.Transition.admit(:doing, :completed)
  end
end

# --- SECTION 18: Original test/ash_a2a/c1_w5_claim_store/transition_doing_test.exs ---
defmodule AshA2A.C1W5ClaimStore.TransitionDoingTest do
  use ExUnit.Case, async: true

  test "transition_doing" do
    vector =
      Path.join([
        File.cwd!(),
        "priv",
        "sa2a",
        "c1",
        "w5_claim_store_vectors",
        "transition_doing.json"
      ])

    assert File.read!(vector) =~ "\"case\": \"transition_doing\""
    assert :ok = AshA2A.ConsequenceKernel.Claims.Transition.admit(:claimed, :doing)
  end
end

# --- SECTION 19: Original test/ash_a2a/c1_w5_claim_store/transition_unknown_test.exs ---
defmodule AshA2A.C1W5ClaimStore.TransitionUnknownTest do
  use ExUnit.Case, async: true

  test "transition_unknown" do
    vector =
      Path.join([
        File.cwd!(),
        "priv",
        "sa2a",
        "c1",
        "w5_claim_store_vectors",
        "transition_unknown.json"
      ])

    assert File.read!(vector) =~ "\"case\": \"transition_unknown\""
    assert :ok = AshA2A.ConsequenceKernel.Claims.Transition.admit(:doing, :unknown_outcome)
  end
end

# --- SECTION 20: Original test/ash_a2a/c1_w5_claim_store/unknown_retry_refused_test.exs ---
defmodule AshA2A.C1W5ClaimStore.UnknownRetryRefusedTest do
  use ExUnit.Case, async: true

  test "unknown_retry_refused" do
    vector =
      Path.join([
        File.cwd!(),
        "priv",
        "sa2a",
        "c1",
        "w5_claim_store_vectors",
        "unknown_retry_refused.json"
      ])

    assert File.read!(vector) =~ "\"case\": \"unknown_retry_refused\""

    assert {:error, :retry_forbidden_until_reconciliation} =
             AshA2A.ConsequenceKernel.Claims.RecoveryGate.retry(:unknown_outcome)
  end
end
