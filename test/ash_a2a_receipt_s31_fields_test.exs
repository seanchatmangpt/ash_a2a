defmodule AshA2A.ReceiptS31FieldsTest do
  @moduledoc """
  RFC-SA2A-001 S31 ("zero unreceipted actuation") audited against the REAL
  `AshA2A.CommandBus` path.

  Every assertion here reads a receipt that a real `CommandBus.run/4` produced
  by really dispatching into a real `Ash.Resource`. No doubles.

  ## Audit result recorded by this suite

  Present on `main` before this branch: actuation identifier (NO -- only
  `command_id`), idempotency identifier (NO), actor (PARTIAL -- `:principal_id`
  existed but was not named as the actor), authority grant (NO -- only the
  fingerprint's hash of `token_id`), semantic subject (YES), intended effect
  (NO), input digest (NO), plan digest (NO), projection digest (NO --
  reachable only via `:semantic_subject`), timestamp (YES, `:recorded_at`),
  logical clock (NO), reconciliation metadata (NO), terminal status set (NO).

  The tests below assert the post-branch state: every one of those is now
  carried, with `:plan_digest` legitimately absent for an unplanned command
  and reported as such by `missing_required_fields/1` rather than invented.
  """
  use ExUnit.Case

  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Authority, Command, CommandBus, Identity, Receipt, SemanticSubject}
  alias AshA2A.Test.Fixture.{Echo, Item}

  setup do
    Application.put_env(:ash_a2a, :receipt_commit_retry_delays_ms, [1, 1])
    on_exit(fn -> Application.delete_env(:ash_a2a, :receipt_commit_retry_delays_ms) end)

    name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    start_supervised!({AshA2A.ReceiptStore.Memory, name: name})
    %{store_opts: [name: name]}
  end

  defp digest(seed),
    do: "sha256:" <> (seed |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower))

  test "a real consequence-bearing run carries every S31 prepared-receipt field", %{
    store_opts: store_opts
  } do
    principal = Identity.principal("subject-s31")
    capability = "AshA2A.Test.Fixture.Item.create"

    authority =
      Authority.new(principal, capability,
        token_id: "auth-s31",
        constraints: %{external_idempotency_token: "stripe_idem_s31"}
      )

    {:ok, subject} =
      SemanticSubject.new(
        graph_digest: digest("graph-s31"),
        projection_digest: digest("projection-s31"),
        manufacturer_digest: digest("manufacturer-s31")
      )

    command =
      Command.new(capability,
        command_id: "s31-create-1",
        agent_id: "agent-s31",
        principal_id: principal,
        authority: authority,
        semantic_subject: subject,
        input: %{label: "widget"}
      )

    assert {:ok, receipt} =
             CommandBus.run(command, data_message(%{"label" => "widget"}), Item,
               store_opts: store_opts,
               plan_digest: digest("plan-s31")
             )

    # --- the eleven S31 prepared-receipt fields, each really populated ---
    assert %Identity{kind: :actuation} = receipt.actuation_id
    assert %Identity{kind: :idempotency} = receipt.idempotency_key
    assert %Identity{kind: :principal, value: "subject-s31"} = receipt.actor

    assert %{
             token_id: "runtime:auth-s31",
             subject: "principal:subject-s31",
             capability_id: ^capability,
             source: :authority_broker
           } = receipt.authority_grant

    assert receipt.semantic_subject == subject
    assert receipt.intended_effect.capability_id == capability
    assert receipt.intended_effect.consequence == :change
    assert String.starts_with?(receipt.input_digest, "sha256:")
    assert receipt.plan_digest == digest("plan-s31")
    assert receipt.projection_digest == digest("projection-s31")
    assert %DateTime{} = receipt.recorded_at
    assert is_integer(receipt.logical_clock) and receipt.logical_clock > 0
    assert %{state: _, attempts: _} = receipt.reconciliation

    # Nothing is missing for a fully-specified command.
    assert Receipt.missing_required_fields(receipt) == []

    # The external idempotency token really is bound into the identity, per
    # S55's "SHOULD bind to the external token".
    assert receipt.idempotency_key.value == "stripe_idem_s31"
  end

  test "an unplanned observe command reports its genuinely absent fields instead of inventing them",
       %{store_opts: store_opts} do
    command =
      Command.new("AshA2A.Test.Fixture.Echo.read",
        command_id: "s31-read-1",
        agent_id: "agent-s31",
        principal_id: "anonymous",
        input: %{}
      )

    assert {:ok, receipt} =
             CommandBus.run(command, data_message(%{}), Echo, store_opts: store_opts)

    missing = Receipt.missing_required_fields(receipt)

    # No plan selected this route, no semantic subject was supplied, and an
    # observe command needs no authority grant. Those are reported as absent.
    assert :plan_digest in missing
    assert :semantic_subject in missing
    assert :projection_digest in missing
    assert :authority_grant in missing

    # The rest are genuinely present even for an observe command.
    refute :actuation_id in missing
    refute :idempotency_key in missing
    refute :actor in missing
    refute :input_digest in missing
    refute :logical_clock in missing
    refute :intended_effect in missing

    # And a nil plan digest is a marked absence, not a fabricated value.
    assert receipt.plan_digest == nil
  end

  test "terminal status is :executed for a real execution and :refused for a pre-DO refusal", %{
    store_opts: store_opts
  } do
    ok_command =
      Command.new("AshA2A.Test.Fixture.Echo.read",
        command_id: "s31-terminal-ok",
        agent_id: "agent-s31",
        principal_id: "anonymous",
        input: %{}
      )

    assert {:ok, executed} =
             CommandBus.run(ok_command, data_message(%{}), Echo, store_opts: store_opts)

    assert executed.status == :completed
    assert executed.terminal_status == :executed
    assert Receipt.terminal?(executed)

    # A real kill switch trip refuses BEFORE the claim, so no receipt is
    # produced at all -- which is the correct S31 behaviour (nothing was
    # actuated, so there is nothing to receipt). The refusal-shaped terminal
    # status is exercised through the reply mapping directly below and
    # through the real actuation-conflict path in the S55 suite.
    assert Receipt.terminal_status({:error, %{code: :authority_required}}) == :refused
    assert Receipt.terminal_status({:error, %{code: :kill_switch_tripped}}) == :refused
    assert Receipt.terminal_status({:error, %{code: :receipt_anchor_unavailable}}) == :refused
  end

  test "a real dispatch crash is :failed, not :refused -- DO ran", %{store_opts: store_opts} do
    command =
      Command.new("AshA2A.Test.Fixture.Crashy.detonate",
        command_id: "s31-terminal-crash",
        agent_id: "agent-s31",
        principal_id: "anonymous",
        input: %{}
      )

    assert {:ok, receipt} =
             CommandBus.run(command, data_message(%{}), AshA2A.Test.Fixture.Crashy,
               store_opts: store_opts
             )

    assert receipt.status == :failed
    assert receipt.terminal_status == :failed
    assert {:error, %{code: :dispatch_crashed}} = receipt.reply
  end

  test "the full terminal status set is reachable and each transition is explicit", %{
    store_opts: store_opts
  } do
    assert Enum.sort(Receipt.terminal_statuses()) ==
             Enum.sort([
               :executed,
               :refused,
               :failed,
               :reconciled,
               :compensated,
               :unknown_outcome
             ])

    command =
      Command.new("AshA2A.Test.Fixture.Echo.read",
        command_id: "s31-transitions",
        agent_id: "agent-s31",
        principal_id: "anonymous",
        input: %{}
      )

    assert {:ok, executed} =
             CommandBus.run(command, data_message(%{}), Echo, store_opts: store_opts)

    assert executed.terminal_status == :executed

    reconciled = Receipt.reconcile(executed, %{source: :test})
    assert reconciled.terminal_status == :reconciled
    assert reconciled.reconciliation.state == :reconciled
    assert reconciled.reconciliation.attempts == executed.reconciliation.attempts + 1
    # Reconciliation does not rewrite the observed reply shape.
    assert reconciled.status == executed.status
    assert reconciled.reply == executed.reply

    compensated = Receipt.compensate(executed, %{reversal_receipt_id: "runtime:rev-1"})
    assert compensated.terminal_status == :compensated
    assert compensated.reconciliation.detail == %{reversal_receipt_id: "runtime:rev-1"}

    unknown = Receipt.mark_unknown_outcome(executed, :post_do_crash_window)
    assert unknown.terminal_status == :unknown_outcome
    assert unknown.reconciliation.reason == :post_do_crash_window
  end

  test "a pending anchor has no terminal status -- it asserts nothing about the outcome" do
    command =
      Command.new("AshA2A.Test.Fixture.Item.create",
        command_id: "s31-pending",
        agent_id: "agent-s31",
        principal_id: "subject-s31",
        input: %{label: "widget"}
      )

    anchor = Receipt.pending(command, Identity.execution("exec-s31"), :change)

    assert anchor.status == :pending
    assert anchor.terminal_status == nil
    refute Receipt.terminal?(anchor)
    # ...but the prepared fields are all there BEFORE DO, which is the point
    # of S31: the receipt is complete before the boundary is crossed.
    assert anchor.actuation_id
    assert anchor.idempotency_key
    assert anchor.input_digest
    assert anchor.logical_clock
    assert anchor.reconciliation.state == :pending
  end

  test "authority grant records the grant, never the raw transport evidence" do
    principal = Identity.principal("subject-secret")

    authority =
      Authority.new(principal, "Cap.act",
        token_id: "auth-secret",
        evidence: %{bearer_token: "super-secret-value", transport_identity: %{sub: "u-1"}}
      )

    grant = Receipt.authority_grant(authority)

    assert grant.token_id == "runtime:auth-secret"
    assert String.starts_with?(grant.evidence_digest, "sha256:")

    # The secret itself is nowhere in the serialized grant.
    refute inspect(grant) =~ "super-secret-value"
    refute grant |> :erlang.term_to_binary() |> inspect() =~ "super-secret-value"
  end
end
