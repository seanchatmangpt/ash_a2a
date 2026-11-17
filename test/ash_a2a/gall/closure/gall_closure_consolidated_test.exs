# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
# SPDX-License-Identifier: MIT

# ==============================================================================
# Gall Closure Consolidated Suite
# Consolidated by Worker 16 from 33 original test files.
# All test modules, test cases, and tags preserved verbatim.
# ==============================================================================


# ==============================================================================
# SECTION 1/33: test/ash_a2a/gall/closure/audit_consumer_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.Closure.AuditConsumerTest do
  use ExUnit.Case, async: true
  alias AshA2A.Gall.Closure.AuditConsumer

  test "audit consumer carries exact receipt and provenance without authority" do
    receipt = %{
      receipt_id: "r1",
      command_id: "c1",
      terminal_status: :executed,
      standing: :observed
    }

    provenance = %{candidate_digest: "cand", producer_sha: String.duplicate("a", 40)}
    projection = AuditConsumer.project(receipt, provenance)

    assert projection.receipt_id == "r1"
    assert projection.candidate_digest == "cand"
    assert projection.authority == :none
  end
end


# ==============================================================================
# SECTION 2/33: test/ash_a2a/gall/closure/authority_binding_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.Closure.AuthorityBindingTest do
  use ExUnit.Case, async: true
  alias AshA2A.Gall.Closure.AuthorityBinding

  test "authority independently binds principal, capability, scope and one-DO budget" do
    scope = %{input_digest: "sha256:x"}
    command = %{principal_id: "p1", capability_id: "Item.create"}

    authority = %{
      subject: "p1",
      capability_id: "Item.create",
      constraints: %{scope: scope, max_consequences: 1}
    }

    assert {:ok, ^authority} = AuthorityBinding.admit(authority, command, scope, 1)

    bad = put_in(authority, [:constraints, :max_consequences], 2)

    assert {:error, {:refused_gall, :authority_binding, :budget_mismatch}} =
             AuthorityBinding.admit(bad, command, scope, 1)
  end
end


# ==============================================================================
# SECTION 3/33: test/ash_a2a/gall/closure/budget_policy_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.Closure.BudgetPolicyTest do
  use ExUnit.Case, async: true
  alias AshA2A.Gall.Closure.BudgetPolicy

  test "one consequence is the only admitted budget" do
    assert {:ok, %{max_consequences: 1}} = BudgetPolicy.admit(1)
    assert {:ok, %{max_consequences: 1}} = BudgetPolicy.admit(%{max_consequences: 1})

    assert {:error, {:refused_gall, :budget_policy, {:must_equal_one, 2}}} =
             BudgetPolicy.admit(2)
  end
end


# ==============================================================================
# SECTION 4/33: test/ash_a2a/gall/closure/capability_policy_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.Closure.CapabilityPolicyTest do
  use ExUnit.Case, async: true
  alias AshA2A.Gall.Closure.CapabilityPolicy

  test "capability must be admitted and cannot be self-promoted" do
    candidate = %{capability_id: "Item.create"}
    assert {:ok, ^candidate} = CapabilityPolicy.admit(candidate, ["Item.create"])

    promoted = Map.put(candidate, :requested_capability_id, "Root.delete")

    assert {:error, {:refused_gall, :capability_policy, :self_promoted_capability}} =
             CapabilityPolicy.admit(promoted, ["Item.create"])
  end
end


# ==============================================================================
# SECTION 5/33: test/ash_a2a/gall/closure/command_binding_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.Closure.CommandBindingTest do
  use ExUnit.Case, async: true
  alias AshA2A.Gall.Closure.CommandBinding

  test "command binds exact capability and candidate digest" do
    candidate = %{
      capability_id: "Item.create",
      candidate_digest: "sha256:" <> String.duplicate("a", 64)
    }

    command = %{
      capability_id: "Item.create",
      metadata: %{gall_029_candidate_digest: candidate.candidate_digest}
    }

    assert {:ok, ^command} = CommandBinding.admit(candidate, command)

    assert {:error, {:refused_gall, :command_binding, :candidate_digest_mismatch}} =
             CommandBinding.admit(
               candidate,
               put_in(command, [:metadata, :gall_029_candidate_digest], "wrong")
             )
  end
end


# ==============================================================================
# SECTION 6/33: test/ash_a2a/gall/closure/compatibility_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.Closure.CompatibilityTest do
  use ExUnit.Case, async: true
  alias AshA2A.Gall.Closure.Compatibility

  test "only closure-v1 representation is admitted" do
    artifact = %{"schema_version" => "ash_a2a.gall.closure/v1"}
    assert {:ok, ^artifact} = Compatibility.admit(artifact)

    assert {:error, {:refused_gall, :compatibility, {:unsupported_version, "v0"}}} =
             Compatibility.admit(%{"schema_version" => "v0"})
  end
end


# ==============================================================================
# SECTION 7/33: test/ash_a2a/gall/closure/determinism_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.Closure.DeterminismTest do
  use ExUnit.Case, async: true
  alias AshA2A.Gall.Closure.Determinism

  test "map ordering is not semantic" do
    left = %{"b" => 2, "a" => %{"y" => 1, "x" => 0}}
    right = %{"a" => %{"x" => 0, "y" => 1}, "b" => 2}
    assert Determinism.digest(left) == Determinism.digest(right)
    refute Determinism.digest(left) == Determinism.digest(Map.put(right, "b", 3))
  end

  test "tuples and lists do not collide" do
    refute Determinism.digest({:a, 1}) == Determinism.digest([:a, 1])
  end

  test "atom keys and string keys do not collide" do
    refute Determinism.digest(%{a: 1}) == Determinism.digest(%{"a" => 1})
  end

  test "key order is irrelevant for mixed key types and format is preserved" do
    a = Map.new([{:z, 1}, {"y", 2}, {3, 4}])
    b = Map.new([{3, 4}, {"y", 2}, {:z, 1}])
    assert Determinism.digest(a) == Determinism.digest(b)
    assert "sha256:" <> hex = Determinism.digest(a)
    assert byte_size(hex) == 64
  end
end


# ==============================================================================
# SECTION 8/33: test/ash_a2a/gall/closure/evidence_policy_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.Closure.EvidencePolicyTest do
  use ExUnit.Case, async: true
  alias AshA2A.Gall.Closure.EvidencePolicy

  test "evidence class and digest remain independently admitted" do
    digest = "sha256:" <> String.duplicate("a", 64)
    candidate = %{evidence_digest: digest, finding_class: "conformance"}
    assert {:ok, ^candidate} = EvidencePolicy.admit(candidate, [digest])

    assert {:error, {:refused_gall, :evidence_policy, :unadmitted_evidence}} =
             EvidencePolicy.admit(candidate, [])
  end
end


# ==============================================================================
# SECTION 9/33: test/ash_a2a/gall/closure/exact_subject_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.Closure.ExactSubjectTest do
  use ExUnit.Case, async: true
  alias AshA2A.Gall.Closure.ExactSubject

  test "requires exact repo, source SHA, semantic subject and candidate digest" do
    candidate = %{
      producer_repository: "seanchatmangpt/beam4pm",
      producer_sha: String.duplicate("a", 40),
      semantic_subject_digest: "sha256:" <> String.duplicate("b", 64),
      candidate_digest: "sha256:" <> String.duplicate("c", 64)
    }

    assert {:ok, exact} = ExactSubject.admit(candidate)
    assert exact.repository == "seanchatmangpt/beam4pm"

    assert {:error, {:refused_gall, :exact_subject, :invalid_or_inexact_subject}} =
             ExactSubject.admit(Map.put(candidate, :producer_sha, "head"))
  end
end


# ==============================================================================
# SECTION 10/33: test/ash_a2a/gall/closure/falsifier_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.Closure.FalsifierTest do
  use ExUnit.Case, async: true
  alias AshA2A.Gall.Closure.Falsifier

  test "negative control names exact mismatched fields" do
    assert {:ok, :not_falsified} = Falsifier.evaluate(%{count: 1}, %{count: 1})

    assert {:error, {:falsified, [%{field: :count, expected: 1, observed: 2}]}} =
             Falsifier.evaluate(%{count: 1}, %{count: 2})
  end
end


# ==============================================================================
# SECTION 11/33: test/ash_a2a/gall/closure/fields_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.FieldsGetTest do
  use ExUnit.Case, async: true
  alias AshA2A.Gall.Fields

  test "present nil/false atom values are not skipped for the string key" do
    assert Fields.get(%{:a => false, "a" => true}, :a) == false
    assert Fields.get(%{:a => nil, "a" => 1}, :a) == nil
    assert Fields.fetch(%{:a => false, "a" => true}, :a) == {:ok, false}
  end

  test "falls back to string key and reports absence" do
    assert Fields.get(%{"a" => 2}, :a) == 2
    assert Fields.fetch(%{}, :a) == :error
    assert Fields.get(%{}, :a) == nil
  end
end


# ==============================================================================
# SECTION 12/33: test/ash_a2a/gall/closure/idempotency_policy_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.Closure.IdempotencyPolicyTest do
  use ExUnit.Case, async: true
  alias AshA2A.Gall.Closure.IdempotencyPolicy

  test "idempotency identity is derived from exact candidate identity" do
    digest = "sha256:" <> String.duplicate("a", 64)
    candidate = %{candidate_digest: digest}
    key = IdempotencyPolicy.key_for(digest)
    command = %{metadata: %{idempotency_key: key}}
    assert {:ok, ^command} = IdempotencyPolicy.admit(command, candidate)

    assert {:error, {:refused_gall, :idempotency_policy, {:key_mismatch, _, "other"}}} =
             IdempotencyPolicy.admit(%{metadata: %{idempotency_key: "other"}}, candidate)
  end

  test "a candidate without a digest is refused, not crashed on" do
    command = %{metadata: %{idempotency_key: "gall:whatever"}}

    assert {:error, {:refused_gall, :idempotency_policy, :missing_candidate_digest}} =
             IdempotencyPolicy.admit(command, %{})

    assert {:error, {:refused_gall, :idempotency_policy, :missing_candidate_digest}} =
             IdempotencyPolicy.admit(command, %{candidate_digest: nil})
  end
end


# ==============================================================================
# SECTION 13/33: test/ash_a2a/gall/closure/migration_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.Closure.MigrationTest do
  use ExUnit.Case, async: true
  alias AshA2A.Gall.Closure.Migration

  test "migration preserves exact producer and candidate identity" do
    candidate = %{
      candidate_digest: "sha256:" <> String.duplicate("a", 64),
      producer_repository: "seanchatmangpt/beam4pm",
      producer_sha: String.duplicate("b", 40)
    }

    assert {:ok, migrated} = Migration.to_v1(candidate)
    assert migrated["candidate_digest"] == candidate.candidate_digest
    assert migrated["producer_sha"] == candidate.producer_sha
    assert migrated["authority"] == "NONE"
    assert migrated["standing"] == "CANDIDATE"
  end
end


# ==============================================================================
# SECTION 14/33: test/ash_a2a/gall/closure/ocel_projection_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.Closure.OcelProjectionTest do
  use ExUnit.Case, async: true
  alias AshA2A.Gall.Closure.OcelProjection

  test "OCEL projection keeps candidate, command and receipt as separate objects" do
    candidate = %{candidate_digest: "sha256:" <> String.duplicate("a", 64)}
    command = %{command_id: "c1"}
    receipt = %{receipt_id: "r1", recorded_at: "2026-09-28T18:00:00Z"}
    projection = OcelProjection.project(candidate, command, receipt)

    assert map_size(projection["ocel:objects"]) == 3
    assert projection["ocel:objects"]["command:c1"]["ocel:type"] == "command"
    assert projection["ocel:objects"]["receipt:r1"]["ocel:type"] == "receipt"
  end
end


# ==============================================================================
# SECTION 15/33: test/ash_a2a/gall/closure/pipeline_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.Closure.PipelineTest do
  use ExUnit.Case, async: true
  alias AshA2A.Gall.Closure.{Determinism, IdempotencyPolicy, Pipeline}

  test "source admission composes into one-DO preflight without granting authority" do
    candidate = %{
      producer_repository: "seanchatmangpt/beam4pm",
      producer_sha: String.duplicate("a", 40),
      evidence_digest: "sha256:" <> String.duplicate("b", 64),
      semantic_subject_digest: "sha256:" <> String.duplicate("c", 64),
      candidate_digest: "sha256:" <> String.duplicate("d", 64),
      finding_class: "conformance",
      vocabulary: "https://w3id.org/ocel",
      capability_id: "Item.create"
    }

    policy = %{
      allowed_producers: %{"seanchatmangpt/beam4pm" => candidate.producer_sha},
      allowed_evidence_digests: [candidate.evidence_digest],
      allowed_semantic_subjects: [candidate.semantic_subject_digest],
      public_vocabularies: [candidate.vocabulary],
      allowed_capabilities: [candidate.capability_id],
      task_id: "task-1"
    }

    assert {:ok, admitted} = Pipeline.admit(candidate, policy)
    input = %{label: "x"}

    command = %{
      capability_id: "Item.create",
      input: input,
      target: "Item",
      metadata: %{
        gall_029_candidate_digest: candidate.candidate_digest,
        idempotency_key: IdempotencyPolicy.key_for(candidate.candidate_digest)
      }
    }

    scope = %{input_digest: Determinism.digest(input), target: "Item"}

    assert {:ok, ready} =
             Pipeline.preflight(admitted, command, %{
               scope: scope,
               max_consequences: 1,
               expected_postcondition: %{item_exists: true}
             })

    assert ready.budget == 1
    assert ready.provenance.authority == :none

    assert {:error, {:refused_gall, :budget_policy, {:must_equal_one, 2}}} =
             Pipeline.preflight(admitted, command, %{
               scope: scope,
               max_consequences: 2,
               expected_postcondition: %{item_exists: true}
             })
  end
end


# ==============================================================================
# SECTION 16/33: test/ash_a2a/gall/closure/planning_consumer_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.Closure.PlanningConsumerTest do
  use ExUnit.Case, async: true
  alias AshA2A.Gall.Closure.PlanningConsumer

  test "planning projection preserves candidate standing but not authority" do
    candidate = %{
      candidate_digest: "cand",
      capability_id: "Item.create",
      horizon: "FAST",
      finding_class: "conformance"
    }

    assert {:ok, projection} = PlanningConsumer.project(candidate)
    assert projection.standing == :candidate
    assert projection.authority == :none

    assert {:error, {:refused_gall, :planning_consumer, :invalid_candidate}} =
             PlanningConsumer.project(%{candidate_digest: "cand"})
  end
end


# ==============================================================================
# SECTION 17/33: test/ash_a2a/gall/closure/postcondition_policy_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.Closure.PostconditionPolicyTest do
  use ExUnit.Case, async: true
  alias AshA2A.Gall.Closure.PostconditionPolicy

  test "postcondition requires independent exact-subject verification" do
    expected = %{item_exists: true}
    assert {:ok, bound} = PostconditionPolicy.bind(expected)

    observation = %{
      independent: true,
      status: :verified,
      expected_postcondition_digest: bound.digest
    }

    assert {:ok, ^observation} = PostconditionPolicy.verify(bound, observation)

    assert {:error, {:refused_gall, :postcondition_policy, :observer_not_independent}} =
             PostconditionPolicy.verify(bound, Map.put(observation, :independent, false))
  end
end


# ==============================================================================
# SECTION 18/33: test/ash_a2a/gall/closure/producer_policy_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.Closure.ProducerPolicyTest do
  use ExUnit.Case, async: true
  alias AshA2A.Gall.Closure.ProducerPolicy

  test "pins repository and SHA jointly" do
    sha = String.duplicate("a", 40)
    candidate = %{producer_repository: "seanchatmangpt/beam4pm", producer_sha: sha}
    assert {:ok, ^candidate} = ProducerPolicy.admit(candidate, %{"seanchatmangpt/beam4pm" => sha})

    assert {:error, {:refused_gall, :producer_policy, {:sha_mismatch, _, _}}} =
             ProducerPolicy.admit(candidate, %{
               "seanchatmangpt/beam4pm" => String.duplicate("b", 40)
             })
  end
end


# ==============================================================================
# SECTION 19/33: test/ash_a2a/gall/closure/provenance_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.Closure.ProvenanceTest do
  use ExUnit.Case, async: true
  alias AshA2A.Gall.Closure.Provenance

  test "provenance retains producer, evidence, semantic and candidate identities" do
    candidate = %{
      producer_repository: "seanchatmangpt/beam4pm",
      producer_sha: String.duplicate("a", 40),
      evidence_digest: "sha256:" <> String.duplicate("b", 64),
      semantic_subject_digest: "sha256:" <> String.duplicate("c", 64),
      candidate_digest: "sha256:" <> String.duplicate("d", 64)
    }

    envelope = Provenance.build(candidate, "task-1")
    assert envelope.task_id == "task-1"
    assert envelope.authority == :none
    assert Provenance.valid?(envelope)
    refute Provenance.valid?(Map.put(envelope, :task_id, "task-2"))
  end
end


# ==============================================================================
# SECTION 20/33: test/ash_a2a/gall/closure/receipt_binding_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.Closure.ReceiptBindingTest do
  use ExUnit.Case, async: true
  alias AshA2A.Gall.Closure.ReceiptBinding

  test "receipt binds command identity, capability, fingerprint and candidate" do
    digest = "sha256:" <> String.duplicate("a", 64)
    candidate = %{candidate_digest: digest}
    command = %{command_id: "c1", capability_id: "Item.create", fingerprint: "fp"}

    receipt = %{
      command_id: "c1",
      capability_id: "Item.create",
      fingerprint: "fp",
      metadata: %{candidate_digest: digest}
    }

    assert {:ok, ^receipt} = ReceiptBinding.admit(receipt, command, candidate)

    assert {:error, {:refused_gall, :receipt_binding, :command_mismatch}} =
             ReceiptBinding.admit(Map.put(receipt, :command_id, "c2"), command, candidate)
  end
end


# ==============================================================================
# SECTION 21/33: test/ash_a2a/gall/closure/receipt_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.Closure.ReceiptTest do
  use ExUnit.Case, async: true
  alias AshA2A.Gall.Receipt

  test "receipt state transitions reseal exact evidence" do
    subject = %{repository: "seanchatmangpt/ash_a2a", sha: String.duplicate("a", 40)}
    finding = %{candidate_digest: "sha256:" <> String.duplicate("b", 64)}
    receipt = Receipt.prepare(subject, finding, %{token_id: "grant-1"}, %{max_consequences: 1})

    assert Receipt.valid?(receipt)
    assert receipt.state == :prepared
    assert receipt.standing == :unknown

    actuated = Receipt.actuated(receipt)
    assert actuated.state == :actuated
    assert Receipt.valid?(actuated)

    verified = Receipt.verified(actuated, %{status: :verified})
    assert verified.state == :completed
    assert verified.standing == :verified
    assert Receipt.valid?(verified)

    replay = Receipt.replay(verified)
    assert replay.replayed?
    assert Receipt.valid?(replay)
  end
end


# ==============================================================================
# SECTION 22/33: test/ash_a2a/gall/closure/recovery_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.Closure.RecoveryTest do
  use ExUnit.Case, async: true
  alias AshA2A.Gall.Closure.Recovery

  test "recovery routes around the failed edge without bypassing it" do
    assert {:repair, :recompute_exact_scope} =
             Recovery.route(%{status: :refused, boundary: :scope_policy})

    assert {:repair, :reconcile_actuation_identity} =
             Recovery.route(%{status: :refused, boundary: :replay_guard})

    assert {:stop, :not_a_refusal} = Recovery.route(%{status: :ok})
  end
end


# ==============================================================================
# SECTION 23/33: test/ash_a2a/gall/closure/refusal_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.Closure.RefusalTest do
  use ExUnit.Case, async: true
  alias AshA2A.Gall.Closure.Refusal

  test "typed refusal never invents retry or standing" do
    refusal = Refusal.normalize({:refused_gall, :scope_policy, :input_digest_mismatch})
    assert refusal.status == :refused
    assert refusal.boundary == :scope_policy
    assert refusal.retry == false
    assert refusal.standing == :refused
  end
end


# ==============================================================================
# SECTION 24/33: test/ash_a2a/gall/closure/replay_guard_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.Closure.ReplayGuardTest do
  use ExUnit.Case, async: true
  alias AshA2A.Gall.Closure.ReplayGuard

  test "same effect identity is exact replay, rebinding is refused" do
    previous = %{command_id: "c1", actuation_id: "a1", idempotency_key: "k1"}
    assert {:ok, :exact_replay} = ReplayGuard.classify(previous, previous)

    rebound = %{command_id: "c1", actuation_id: "a2", idempotency_key: "k2"}

    assert {:error, {:refused_gall, :replay_guard, :command_rebound_to_new_effect}} =
             ReplayGuard.classify(previous, rebound)
  end
end


# ==============================================================================
# SECTION 25/33: test/ash_a2a/gall/closure/scope_policy_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.Closure.ScopePolicyTest do
  use ExUnit.Case, async: true
  alias AshA2A.Gall.Closure.{Determinism, ScopePolicy}

  test "scope binds exact command input and target" do
    command = %{input: %{label: "x"}, target: "Item"}
    scope = %{input_digest: Determinism.digest(command.input), target: "Item"}
    assert {:ok, ^scope} = ScopePolicy.admit(scope, command)

    assert {:error, {:refused_gall, :scope_policy, :input_digest_mismatch}} =
             ScopePolicy.admit(Map.put(scope, :input_digest, "wrong"), command)
  end
end


# ==============================================================================
# SECTION 26/33: test/ash_a2a/gall/closure/semantic_subject_policy_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.Closure.SemanticSubjectPolicyTest do
  use ExUnit.Case, async: true
  alias AshA2A.Gall.Closure.SemanticSubjectPolicy

  test "semantic subject must match an admitted exact digest" do
    digest = "sha256:" <> String.duplicate("a", 64)
    candidate = %{semantic_subject_digest: digest}
    assert {:ok, ^candidate} = SemanticSubjectPolicy.admit(candidate, [digest])

    assert {:error, {:refused_gall, :semantic_subject_policy, {:subject_not_admitted, ^digest}}} =
             SemanticSubjectPolicy.admit(candidate, [])
  end
end


# ==============================================================================
# SECTION 27/33: test/ash_a2a/gall/closure/simulation_consumer_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.Closure.SimulationConsumerTest do
  use ExUnit.Case, async: true
  alias AshA2A.Gall.Closure.SimulationConsumer

  test "simulation consumer cannot cross the consequence boundary" do
    candidate = %{candidate_digest: "cand", capability_id: "Item.create"}
    projection = SimulationConsumer.project(candidate, %{input_digest: "x"}, %{item_exists: true})

    assert projection.kind == :gall_simulation_case
    assert projection.evidence_ceiling == :construct
    assert projection.authority == :none
  end
end


# ==============================================================================
# SECTION 28/33: test/ash_a2a/gall/closure/telemetry_envelope_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.Closure.TelemetryEnvelopeTest do
  use ExUnit.Case, async: true
  alias AshA2A.Gall.Closure.TelemetryEnvelope

  test "telemetry records the boundary decision without conferring authority" do
    event =
      TelemetryEnvelope.event(
        :preflight,
        %{candidate_digest: "cand", command_id: "c1"},
        :admitted
      )

    assert event.event == [:ash_a2a, :gall, :closure, :preflight]
    assert event.measurements == %{count: 1}
    assert event.metadata.outcome == :admitted
    assert event.metadata.authority == :none
  end
end


# ==============================================================================
# SECTION 29/33: test/ash_a2a/gall/closure/vocabulary_policy_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.Closure.VocabularyPolicyTest do
  use ExUnit.Case, async: true
  alias AshA2A.Gall.Closure.VocabularyPolicy

  test "admits explicit public vocabulary and refuses private namespaces" do
    candidate = %{vocabulary: "https://w3id.org/ocel"}
    assert {:ok, ^candidate} = VocabularyPolicy.admit(candidate, ["https://w3id.org/ocel"])

    assert {:error, {:refused_gall, :vocabulary_policy, :private_vocabulary}} =
             VocabularyPolicy.admit(%{vocabulary: "private:internal"}, ["private:internal"])
  end
end


# ==============================================================================
# SECTION 30/33: test/gall_closure/checkpoint_binding_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.GallClosure.CheckpointBindingTest do
  use ExUnit.Case, async: true
  alias AshA2A.GallClosure.CheckpointBinding

  test "bounded admission",
    do: assert(match?({:ok, _}, CheckpointBinding.admit(%{checkpoint: "witness"})))

  test "typed refusal", do: assert(CheckpointBinding.admit(%{}) == {:error, :missing_checkpoint})
end


# ==============================================================================
# SECTION 31/33: test/gall_closure/finding_binding_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.GallClosure.FindingBindingTest do
  use ExUnit.Case, async: true
  alias AshA2A.GallClosure.FindingBinding

  test "bounded admission",
    do: assert(match?({:ok, _}, FindingBinding.admit(%{finding_id: "witness"})))

  test "typed refusal", do: assert(FindingBinding.admit(%{}) == {:error, :missing_finding})
end


# ==============================================================================
# SECTION 32/33: test/gall_closure/intervention_closure_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.GallClosure.InterventionClosureTest do
  use ExUnit.Case, async: true
  alias AshA2A.GallClosure.InterventionClosure

  test "bounded admission",
    do: assert(match?({:ok, _}, InterventionClosure.admit(%{closure_id: "witness"})))

  test "typed refusal", do: assert(InterventionClosure.admit(%{}) == {:error, :missing_closure})
end


# ==============================================================================
# SECTION 33/33: test/gall_closure/lease_guard_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.GallClosure.LeaseGuardTest do
  use ExUnit.Case, async: true
  alias AshA2A.GallClosure.LeaseGuard

  test "bounded admission",
    do: assert(match?({:ok, _}, LeaseGuard.admit(%{lease_epoch: 7})))

  test "typed refusal", do: assert(LeaseGuard.admit(%{}) == {:error, :missing_lease})

  test "admits zero and positive epochs with guard tag" do
    assert {:ok, %{gall_guard: :lease_guard}} = LeaseGuard.admit(%{lease_epoch: 0})
    assert {:ok, _} = LeaseGuard.admit(%{lease_epoch: 42})
  end

  test "refuses negative and non-integer epochs" do
    for v <- [-1, "witness", "1", 1.0, true, nil, false, ""] do
      assert LeaseGuard.admit(%{lease_epoch: v}) == {:error, :missing_lease}
    end
  end

  describe "admit/2 value validation" do
    test "matching epoch admits" do
      assert {:ok, _} = LeaseGuard.admit(%{lease_epoch: 5}, %{epoch: 5})
    end

    test "stale epoch is refused" do
      assert LeaseGuard.admit(%{lease_epoch: 4}, %{epoch: 5}) ==
               {:refused_gall, :lease_guard, :stale_epoch}
    end

    test "epoch ahead of the authoritative lease is refused" do
      assert LeaseGuard.admit(%{lease_epoch: 6}, %{epoch: 5}) ==
               {:refused_gall, :lease_guard, :epoch_ahead}
    end

    test "expired, holder and scope mismatches are refused" do
      assert LeaseGuard.admit(%{lease_epoch: 5}, %{epoch: 5, expired: true}) ==
               {:refused_gall, :lease_guard, :expired}

      assert LeaseGuard.admit(%{lease_epoch: 5, holder: "a"}, %{epoch: 5, holder: "b"}) ==
               {:refused_gall, :lease_guard, :holder_mismatch}

      assert LeaseGuard.admit(%{lease_epoch: 5, scope: "x"}, %{epoch: 5, scope: "y"}) ==
               {:refused_gall, :lease_guard, :scope_mismatch}

      assert {:ok, _} =
               LeaseGuard.admit(%{lease_epoch: 5, holder: "a", scope: "x"}, %{
                 epoch: 5,
                 holder: "a",
                 scope: "x"
               })
    end

    test "missing lease is refused under an expectation; nil expectation is presence-only" do
      assert LeaseGuard.admit(%{}, %{epoch: 5}) == {:refused_gall, :lease_guard, :missing_lease}
      assert {:ok, _} = LeaseGuard.admit(%{lease_epoch: 1}, nil)
    end
  end
end

