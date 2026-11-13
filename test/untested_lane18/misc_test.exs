defmodule AshA2A.UntestedLane18.MiscTest do
  use ExUnit.Case, async: true

  alias AshA2A.Identity.Canonical
  alias AshA2A.Identity.Canonical.{Encodable, Normalizer}
  alias AshA2A.AuthZEN.{Metadata, PolicyEvidence, PolicyEvidenceFactory, Types}
  alias AshA2A.C2.PreparedEffect
  alias AshA2A.Replan.{Proposal, ReceiptCursor, ReceiptFeedback}
  alias AshA2A.Reactor.{BuildCommand, ConfirmReceipt}

  describe "Encodable" do
    test "accepts JSON-domain values" do
      assert :ok = Encodable.validate(%{"a" => [1, nil, true, "x", %{b: 2}]})
    end

    test "typed refusals" do
      assert {:error, :canonical_float_forbidden} = Encodable.validate(1.0)
      assert {:error, :canonical_type_forbidden} = Encodable.validate({:t, 1})
      assert {:error, :canonical_type_forbidden} = Encodable.validate(self())
      assert {:error, :canonical_key_type_forbidden} = Encodable.validate(%{1 => 2})
      assert {:error, :canonical_key_collision} = Encodable.validate(%{:a => 1, "a" => 2})
      assert {:error, :canonical_invalid_utf8} = Encodable.validate(<<255, 254>>)
      assert {:error, :canonical_integer_out_of_range} = Encodable.validate(9_007_199_254_740_992)

      assert {:error, :canonical_integer_out_of_range} =
               Encodable.validate(-9_007_199_254_740_992)

      assert :ok = Encodable.validate(9_007_199_254_740_991)
    end

    test "depth cap" do
      nest = fn n -> Enum.reduce(1..n, 1, fn _, acc -> [acc] end) end
      assert :ok = Encodable.validate(nest.(30))
      assert {:error, :canonical_depth_exceeded} = Encodable.validate(nest.(40))
    end

    test "max_bytes is 1 MiB and enforced by encode" do
      assert Encodable.max_bytes() == 1_048_576

      assert {:error, :canonical_size_exceeded} =
               Canonical.encode(String.duplicate("a", 1_048_600))
    end
  end

  describe "Normalizer" do
    test "stringifies keys recursively and is idempotent" do
      {:ok, n} = Normalizer.normalize(%{a: %{b: [%{c: 1}]}})
      assert n == %{"a" => %{"b" => [%{"c" => 1}]}}
      assert {:ok, ^n} = Normalizer.normalize(n)
    end

    test "propagates validation errors" do
      assert {:error, :canonical_float_forbidden} = Normalizer.normalize(%{a: 1.5})
    end

    test "key order and atom/string spelling do not change canonical digest" do
      {:ok, d1} = Canonical.digest(%{a: 1, b: 2})
      {:ok, d2} = Canonical.digest(%{"b" => 2, "a" => 1})
      assert d1 == d2
      {:ok, d3} = Canonical.digest(%{"a" => 1, "b" => 3})
      refute d1 == d3
    end
  end

  describe "PolicyEvidenceFactory" do
    test "builds authority-free evidence bound to the effect digest" do
      effect = PreparedEffect.new("p1", "cap", %{"s" => 1}, %{"x" => 2})

      md = %Metadata{
        policy_decision_point: "https://pdp.example",
        access_evaluation_endpoint: "https://pdp.example/eval"
      }

      dec = %Types.Decision{decision: true, context: %{"why" => "ok"}}
      ev = PolicyEvidenceFactory.from_decision(dec, effect, md, 1234)

      assert %PolicyEvidence{
               decision: true,
               policy_decision_point: "https://pdp.example",
               principal: "p1",
               observed_at: 1234,
               context: %{"why" => "ok"}
             } = ev

      assert ev.effect_digest == effect.digest
      assert PolicyEvidence.allowed?(ev)
    end

    test "deny decision and nil context" do
      effect = PreparedEffect.new("p1", "cap", %{}, %{})
      md = %Metadata{policy_decision_point: "pdp", access_evaluation_endpoint: "e"}

      ev =
        PolicyEvidenceFactory.from_decision(
          %Types.Decision{decision: false, context: nil},
          effect,
          md
        )

      refute PolicyEvidence.allowed?(ev)
      assert ev.context == %{}
      assert is_integer(ev.observed_at)
    end
  end

  describe "Replan" do
    test "Proposal defaults to powerless candidate" do
      p = Proposal.new("subj", %{"plan" => 1}, :failed)
      assert %Proposal{authority: :none, standing: :candidate, attempt: 0} = p
      assert Proposal.new("s", 1, :r, 3).attempt == 3
    end

    test "ReceiptCursor projects only cursor fields" do
      c =
        ReceiptCursor.from(%{
          receipt_id: "r1",
          terminal_status: :executed,
          projection_digest: "d",
          extra: 1
        })

      assert %ReceiptCursor{receipt_id: "r1", terminal_status: :executed, projection_digest: "d"} =
               c

      assert %ReceiptCursor{receipt_id: nil} = ReceiptCursor.from(%{})
    end

    test "ReceiptFeedback routes terminal statuses to decisions" do
      mk = fn s -> %{semantic_subject: "sub", receipt_id: "r", terminal_status: s} end

      assert %{kind: :stop, subject: "sub", reason: :executed} =
               ReceiptFeedback.ingest(mk.(:executed))

      assert %{kind: :stop, reason: :refused} = ReceiptFeedback.ingest(mk.(:refused))
      assert %{kind: :replan, reason: :failed} = ReceiptFeedback.ingest(mk.(:failed))

      assert %{kind: :replan, reason: :unknown_outcome_reconcile_first} =
               ReceiptFeedback.ingest(%{semantic_subject: "sub", receipt_id: "r"})
    end
  end

  describe "Reactor steps" do
    test "BuildCommand builds a real Command" do
      args = %{
        capability_id: "cap",
        agent_id: "agent-1",
        principal_id: "principal-1",
        input: %{"a" => 1},
        authority: nil
      }

      assert {:ok, %AshA2A.Command{capability_id: "cap", input: %{"a" => 1}}} =
               BuildCommand.run(args, %{}, [])
    end

    test "BuildCommand honours explicit command_id and nil input" do
      id = Ash.UUIDv7.generate()

      args = %{
        capability_id: "cap",
        agent_id: "agent-1",
        principal_id: "principal-1",
        command_id: id
      }

      assert {:ok, cmd} = BuildCommand.run(args, %{}, [])
      assert cmd.command_id.value == id
      assert cmd.input == %{}
    end

    test "BuildCommand surfaces missing keys as typed error" do
      assert {:error, %{code: :invalid_command_input, detail: d}} =
               BuildCommand.run(%{capability_id: "c"}, %{}, [])

      assert is_binary(d)
    end

    test "ConfirmReceipt passes completed and refuses others" do
      base = %AshA2A.Receipt{
        receipt_id: "r",
        command_id: "c",
        execution_id: "e",
        agent_id: "a",
        principal_id: "p",
        capability_id: "cap",
        fingerprint: "f",
        consequence: :observe,
        status: :completed,
        standing: :derived,
        recorded_at: DateTime.utc_now()
      }

      assert {:ok, ^base} = ConfirmReceipt.run(%{receipt: base}, %{}, [])

      assert {:error, %{code: :receipt_not_completed, status: :failed}} =
               ConfirmReceipt.run(%{receipt: %{base | status: :failed}}, %{}, [])
    end
  end
end
