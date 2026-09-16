defmodule AshA2A.ReceiptReplayCountingActuatorTest do
  @moduledoc """
  RFC-SA2A-001 S32: a receipt must reconstruct the semantic basis of an
  execution, and replaying it MUST NOT repeat the external consequence.

  > "Replaying evidence is not authority to re-actuate."

  Proven with a REAL counting actuator: `AshA2A.Test.Fixture.CountingActuator`
  is a real `Ash.Resource` whose `:external_do` action increments a real
  `Agent`-held integer. Every assertion below reads that real integer. If
  replay ever crossed the consequence boundary, the count would move -- there
  is no mock to make it look like it didn't.
  """
  use ExUnit.Case

  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Authority, Command, CommandBus, Identity, Receipt, SemanticSubject}
  alias AshA2A.Receipt.Replay
  alias AshA2A.Test.Fixture.{KeyedActuationCounter, CountingActuator}

  @capability "AshA2A.Test.Fixture.CountingActuator.actuate"

  setup do
    Application.put_env(:ash_a2a, :receipt_commit_retry_delays_ms, [1, 1])
    on_exit(fn -> Application.delete_env(:ash_a2a, :receipt_commit_retry_delays_ms) end)

    # The fixture resource increments the counter registered under the
    # default name, so start the real Agent there. Isolation between tests
    # comes from a unique effect key per test, not from a per-test process --
    # the counter is keyed, so one shared Agent is genuinely sufficient and
    # keeps the fixture's own call site honest (no injected process name).
    start_supervised!(KeyedActuationCounter)

    store = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    start_supervised!({AshA2A.ReceiptStore.Memory, name: store})

    %{store_opts: [name: store]}
  end

  defp actuate(command_id, effect_key, store_opts) do
    principal = Identity.principal("replay-principal")
    authority = Authority.new(principal, @capability, token_id: "replay-auth")

    command =
      Command.new(@capability,
        command_id: command_id,
        agent_id: "replay-agent",
        principal_id: principal,
        authority: authority,
        input: %{effect_key: effect_key}
      )

    {command,
     CommandBus.run(command, data_message(%{"effect_key" => effect_key}), CountingActuator,
       store_opts: store_opts
     )}
  end

  test "a real external_do executes exactly once, and replaying its receipt never re-actuates", %{
    store_opts: store_opts
  } do
    effect_key = "effect-#{System.unique_integer([:positive])}"

    assert KeyedActuationCounter.count(effect_key) == 0

    {_command, {:ok, receipt}} = actuate("replay-1", effect_key, store_opts)

    assert receipt.terminal_status == :executed
    assert receipt.consequence == :external_do
    real_count_after_execution = KeyedActuationCounter.count(effect_key)
    assert real_count_after_execution == 1

    # Replay the receipt 25 times. This is the whole claim: 25 replays, zero
    # additional crossings of the consequence boundary.
    for _ <- 1..25 do
      assert {:ok, %Replay.Basis{} = basis} = Replay.basis(receipt)
      assert basis.actuated? == false
    end

    assert KeyedActuationCounter.count(effect_key) == real_count_after_execution
    assert KeyedActuationCounter.count(effect_key) == 1
  end

  test "the basis reconstructs admission, plan selection, construction, authorization and intended effect",
       %{store_opts: store_opts} do
    principal = Identity.principal("basis-principal")
    authority = Authority.new(principal, @capability, token_id: "basis-auth")

    {:ok, subject} =
      SemanticSubject.new(
        graph_digest: sha("graph"),
        projection_digest: sha("projection"),
        manufacturer_digest: sha("manufacturer")
      )

    effect_key = "effect-basis-#{System.unique_integer([:positive])}"

    command =
      Command.new(@capability,
        command_id: "replay-basis-1",
        agent_id: "basis-agent",
        principal_id: principal,
        authority: authority,
        semantic_subject: subject,
        input: %{effect_key: effect_key}
      )

    assert {:ok, receipt} =
             CommandBus.run(
               command,
               data_message(%{"effect_key" => effect_key}),
               CountingActuator,
               store_opts: store_opts,
               plan_digest: sha("plan")
             )

    assert {:ok, basis} = Replay.basis(receipt)

    # admission
    assert basis.admission.consequence == :external_do
    assert basis.admission.terminal_status == :executed
    assert basis.admission.fingerprint == command.fingerprint

    # plan selection
    assert basis.plan_selection == %{plan_digest: sha("plan"), marker: :plan_recorded}

    # construction
    assert basis.construction.graph_digest == sha("graph")
    assert basis.construction.projection_digest == sha("projection")
    assert basis.construction.manufacturer_digest == sha("manufacturer")

    # authorization decision
    assert %Replay.AuthorityRecord{decision: :admitted, capability_id: @capability} =
             basis.authorization

    # intended effect
    assert basis.intended_effect.capability_id == @capability
    assert basis.intended_effect.actuation_id == Identity.external(receipt.actuation_id)

    assert String.starts_with?(basis.basis_digest, "sha256:")
  end

  test "an unplanned command records no_plan_recorded rather than a fabricated plan digest", %{
    store_opts: store_opts
  } do
    effect_key = "effect-noplan-#{System.unique_integer([:positive])}"
    {_command, {:ok, receipt}} = actuate("replay-noplan", effect_key, store_opts)

    assert {:ok, basis} = Replay.basis(receipt)
    assert basis.plan_selection == %{plan_digest: nil, marker: :no_plan_recorded}
    assert basis.construction.marker == :no_semantic_subject_recorded
  end

  test "the replayed authority record is a different type and CANNOT admit a fresh command", %{
    store_opts: store_opts
  } do
    effect_key = "effect-authz-#{System.unique_integer([:positive])}"
    {_command, {:ok, receipt}} = actuate("replay-authz", effect_key, store_opts)
    assert KeyedActuationCounter.count(effect_key) == 1

    assert {:ok, basis} = Replay.basis(receipt)
    record = basis.authorization

    # Structurally a different type from AshA2A.Authority.
    assert %Replay.AuthorityRecord{} = record
    refute match?(%Authority{}, record)

    # The real admission predicate refuses it. This is the structural
    # enforcement: nothing in the replayed evidence is an authority.
    refute Authority.admits?(record, %{
             principal_id: Identity.principal("replay-principal"),
             capability_id: @capability
           })

    # And driving the REAL bus with it refuses before DO -- the counter does
    # not move, which is what "replaying evidence is not authority to
    # re-actuate" means operationally.
    forged =
      Command.new(@capability,
        command_id: "replay-authz-forged",
        agent_id: "replay-agent",
        principal_id: Identity.principal("replay-principal"),
        authority: record,
        input: %{effect_key: effect_key}
      )

    assert {:error, %{code: :authority_required}} =
             CommandBus.run(forged, data_message(%{"effect_key" => effect_key}), CountingActuator,
               store_opts: store_opts
             )

    assert KeyedActuationCounter.count(effect_key) == 1
  end

  test "a receipt lacking replay identity refuses rather than reconstructing a plausible basis" do
    thin = %Receipt{
      receipt_id: Identity.runtime("r-thin"),
      command_id: Identity.command("c-thin"),
      execution_id: Identity.execution("e-thin"),
      agent_id: Identity.agent("a-thin"),
      principal_id: Identity.principal("p-thin"),
      capability_id: @capability,
      fingerprint: "deadbeef",
      consequence: :external_do,
      status: :completed,
      standing: :observed,
      recorded_at: DateTime.utc_now()
    }

    assert {:error, %{code: :insufficient_replay_identity, detail: detail}} = Replay.basis(thin)
    assert detail =~ "actuation_id"
    assert detail =~ "idempotency_key"
    assert detail =~ "input_digest"
  end

  test "two receipts for the same semantic execution share a basis digest; a different input does not",
       %{store_opts: store_opts} do
    key_a = "effect-same-#{System.unique_integer([:positive])}"
    key_b = "effect-diff-#{System.unique_integer([:positive])}"

    {_c1, {:ok, first}} = actuate("basis-cmp-1", key_a, store_opts)

    # A genuine replay through the real bus returns the same receipt identity.
    {_c1b, {:ok, replayed}} = actuate("basis-cmp-1", key_a, store_opts)
    assert replayed.replayed?
    assert Replay.same_basis?(first, replayed)
    assert KeyedActuationCounter.count(key_a) == 1

    {_c2, {:ok, other}} = actuate("basis-cmp-2", key_b, store_opts)
    refute Replay.same_basis?(first, other)
  end

  test "basis_set replays a receipt set in logical clock order and refuses a partial set", %{
    store_opts: store_opts
  } do
    {_c1, {:ok, one}} = actuate("set-1", "effect-set-a#{System.unique_integer()}", store_opts)
    {_c2, {:ok, two}} = actuate("set-2", "effect-set-b#{System.unique_integer()}", store_opts)

    assert {:ok, [first, second]} = Replay.basis_set([two, one])
    assert first.receipt_id == Identity.external(one.receipt_id)
    assert second.receipt_id == Identity.external(two.receipt_id)

    thin = %{one | actuation_id: nil}
    assert {:error, %{code: :insufficient_replay_identity}} = Replay.basis_set([one, thin, two])
  end

  defp sha(seed),
    do: "sha256:" <> (seed |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower))
end
