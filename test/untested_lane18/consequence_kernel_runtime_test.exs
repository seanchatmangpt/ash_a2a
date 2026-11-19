defmodule AshA2A.UntestedLane18.ConsequenceKernelRuntimeTest do
  use ExUnit.Case, async: true

  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Memory

  alias AshA2A.ConsequenceKernel.Runtime.{
    CrashWindow,
    EffectorToken,
    OutcomeStage,
    PreparedDigest,
    ReconciliationStage,
    ReleaseStage,
    StoreHandle
  }

  @digest "sha256:" <> String.duplicate("b", 64)

  defp prepared,
    do: %{prepared_digest: @digest, instance: %{request_id: "rq", effect_id: "ef"}}

  defp store_at(state) do
    {:ok, pid} = Memory.start_link()
    :ok = Memory.put(pid, %{digest: @digest, state: :prepared})
    walk(pid, state)
    {pid, StoreHandle.new(Memory, pid)}
  end

  defp walk(_pid, :prepared), do: :ok

  defp walk(pid, :claimed), do: :ok = Memory.transition(pid, @digest, :prepared, :claimed)

  defp walk(pid, :applying) do
    walk(pid, :claimed)
    :ok = Memory.transition(pid, @digest, :claimed, :applying)
  end

  defp walk(pid, :unknown_outcome) do
    walk(pid, :applying)
    :ok = Memory.transition(pid, @digest, :applying, :unknown_outcome)
  end

  defp state(pid), do: elem(Memory.fetch(pid, @digest), 1).state

  test "PreparedDigest fetch" do
    assert {:ok, @digest} = PreparedDigest.fetch(prepared())
    assert {:error, :prepared_digest_missing} = PreparedDigest.fetch(%{prepared_digest: ""})
    assert {:error, :prepared_digest_missing} = PreparedDigest.fetch(%{prepared_digest: nil})
    assert {:error, :prepared_digest_missing} = PreparedDigest.fetch(%{})
  end

  test "EffectorToken binds ids, digest and owner" do
    t = EffectorToken.issue(prepared(), :me)

    assert %EffectorToken{request_id: "rq", effect_id: "ef", prepared_digest: @digest, owner: :me} =
             t

    assert t == EffectorToken.issue(prepared(), :me)
    refute t == EffectorToken.issue(prepared(), :other)
    assert_raise MatchError, fn -> EffectorToken.issue(%{instance: %{}}, :me) end
  end

  test "CrashWindow dispositions never turn ambiguity into retry" do
    assert CrashWindow.disposition(:prepared) == :safe_to_release
    assert CrashWindow.disposition(:claimed) == :safe_to_release
    assert CrashWindow.disposition(:applying) == :unknown_outcome
    assert CrashWindow.disposition(:unknown_outcome) == :reconcile_required

    for s <- [:completed, :reconciled, :compensated],
        do: assert(CrashWindow.disposition(s) == :terminal)

    assert CrashWindow.disposition(:bogus) == :refuse
  end

  describe "OutcomeStage" do
    test "ok result completes the record and returns value" do
      {pid, h} = store_at(:applying)
      assert {:ok, 42} = OutcomeStage.persist(h, prepared(), {:ok, 42})
      assert state(pid) == :completed
    end

    test "unknown result parks record in unknown_outcome" do
      {pid, h} = store_at(:applying)
      assert {:unknown, :timeout} = OutcomeStage.persist(h, prepared(), {:unknown, :timeout})
      assert state(pid) == :unknown_outcome
    end

    test "effector error after apply boundary is unknown, never retried" do
      {pid, h} = store_at(:applying)

      assert {:unknown, {:effector_error_after_apply_boundary, :boom}} =
               OutcomeStage.persist(h, prepared(), {:error, :boom})

      assert state(pid) == :unknown_outcome
    end

    test "ok from a non-applying record is refused and state is unchanged" do
      {pid, h} = store_at(:prepared)

      assert {:error, :prepared_transition_refused} =
               OutcomeStage.persist(h, prepared(), {:ok, 1})

      assert state(pid) == :prepared
    end

    test "missing digest refused" do
      {_pid, h} = store_at(:applying)
      assert {:error, :prepared_digest_missing} = OutcomeStage.persist(h, %{}, {:ok, 1})
    end
  end

  describe "ReleaseStage" do
    test "releases from prepared and claimed" do
      for from <- [:prepared, :claimed] do
        {pid, h} = store_at(from)
        assert :ok = ReleaseStage.release(h, prepared(), from)
        assert state(pid) == :released
      end
    end

    test "release after apply boundary is forbidden" do
      {pid, h} = store_at(:applying)

      assert {:error, {:release_after_apply_forbidden, :applying}} =
               ReleaseStage.release(h, prepared(), :applying)

      assert state(pid) == :applying
    end

    test "mismatched from-state is refused by the store" do
      {pid, h} = store_at(:prepared)

      assert {:error, :prepared_transition_refused} =
               ReleaseStage.release(h, prepared(), :claimed)

      assert state(pid) == :prepared
    end
  end

  describe "ReconciliationStage" do
    test "reconciled and compensated from unknown_outcome" do
      for x <- [:reconciled, :compensated] do
        {pid, h} = store_at(:unknown_outcome)
        assert :ok = ReconciliationStage.reconcile(h, @digest, x)
        assert state(pid) == x
      end
    end

    test "invalid resolution refused; non-unknown record refused" do
      {pid, h} = store_at(:unknown_outcome)

      assert {:error, {:invalid_reconciliation, :completed}} =
               ReconciliationStage.reconcile(h, @digest, :completed)

      assert state(pid) == :unknown_outcome
      {pid2, h2} = store_at(:applying)

      assert {:error, :prepared_transition_refused} =
               ReconciliationStage.reconcile(h2, @digest, :reconciled)

      assert state(pid2) == :applying
    end
  end
end
