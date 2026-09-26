defmodule AshA2A.Planning.PreflightWorkOrderTest do
  @moduledoc """
  The work-order binding edge of `AshA2A.Planning.Preflight` (v26.9.25 lane
  W7): the planner-selected actions are bound to the admitted work-order
  identity, so a replanned action cannot execute under a different work order
  than admitted.

  Real collaborators throughout, on the same conventions as
  `AshA2A.Chicago.PlanGatesTest`'s narrow preflight block: the real candidate
  pipeline `AshA2A.Chicago.Fixtures.PlanGates.planned/0` (real projection,
  packages, SELECT, CONSTRUCT, bounded plan) and the real
  `AshA2A.Planning.Preflight`. No Mock/Mox/:meck/patch.

  Missing-digest semantics follow the existing bound-field rules and are
  pinned here deliberately:

    * a step that claims NO `work_order_digest` (nothing under that key in
      `command.metadata`) is admitted -- the step identity the boundary always
      checked is `capability_id` + `input`, and the whole-plan identity already
      binds every `BoundedPlan` field;
    * a step that claims a digest against a plan preflighted WITHOUT one is
      REFUSED (fail closed): nothing was admitted, so any claim disagrees;
    * a post-preflight mutation of the plan's own `:work_order_digest` is
      refused `:preflight_identity_mismatch` naming exactly that field, like
      every other bound field.
  """

  use ExUnit.Case, async: false

  alias AshA2A.Chicago.Fixtures.PlanGates, as: Fx
  alias AshA2A.Planning.{BoundedPlan, Preflight}
  alias AshA2A.Semantic.Refusal

  @admitted "sha256:" <> String.duplicate("7", 64)
  @replanned "sha256:" <> String.duplicate("e", 64)

  defp planned_with_work_order(digest) do
    planned = Fx.planned()
    plan = %BoundedPlan{planned.plan | work_order_digest: digest}
    {:ok, preflight} = Preflight.preflight(plan)
    {planned, plan, preflight}
  end

  defp first_step(planned), do: hd(planned.plan.steps)

  describe "the pinned cross-lane refusal shape" do
    test "a step claiming the admitted digest is admitted" do
      {planned, plan, preflight} = planned_with_work_order(@admitted)
      step = first_step(planned)

      command =
        Fx.step_command(step, metadata: %{"work_order_digest" => @admitted})

      assert {:ok, ^preflight} = Preflight.admit_step(preflight, plan, command)
    end

    test "the claim is read from the atom key too" do
      {planned, plan, preflight} = planned_with_work_order(@admitted)
      step = first_step(planned)

      command = Fx.step_command(step, metadata: %{work_order_digest: @admitted})

      assert {:ok, ^preflight} = Preflight.admit_step(preflight, plan, command)
    end

    test "a replanned step claiming a different digest is refused naming the admitted plan and the claimed order" do
      {planned, plan, preflight} = planned_with_work_order(@admitted)
      step = first_step(planned)

      command =
        Fx.step_command(step, metadata: %{"work_order_digest" => @replanned})

      assert {:error,
              %{
                code: :preflight_work_order_mismatch,
                detail: %{plan_digest: plan_digest, work_order_digest: claimed}
              }} = Preflight.admit_step(preflight, plan, command)

      # `^` pins only bind variables, not module attributes, so the claimed
      # digest is compared at runtime instead of pinned in the pattern.
      assert claimed == @replanned
      assert plan_digest == preflight.plan_digest
      assert plan_digest == planned.package.plan_digest
    end

    test "a claim against a plan preflighted without a digest is refused (fail closed)" do
      planned = Fx.planned()
      step = first_step(planned)

      command =
        Fx.step_command(step, metadata: %{"work_order_digest" => @replanned})

      assert {:error, %{code: :preflight_work_order_mismatch}} =
               Preflight.admit_step(planned.preflight, planned.plan, command)
    end

    test "a step claiming no digest keeps the existing step semantics" do
      {planned, plan, preflight} = planned_with_work_order(@admitted)
      step = first_step(planned)

      assert {:ok, ^preflight} = Preflight.admit_step(preflight, plan, Fx.step_command(step))

      assert {:error, %{code: :preflight_step_not_in_plan}} =
               Preflight.admit_step(preflight, plan, %{
                 capability_id: step.capability_id,
                 input: %{"mutated" => "input"}
               })
    end
  end

  describe "the work-order digest is a bound field of the preflight identity" do
    test ":work_order_digest is declared in bound_fields/0" do
      assert :work_order_digest in Preflight.bound_fields()
    end

    test "a post-preflight mutation of the plan's digest is an identity mismatch naming that field" do
      {planned, _plan, preflight} = planned_with_work_order(@admitted)
      step = first_step(planned)

      mutated = %BoundedPlan{planned.plan | work_order_digest: @replanned}

      assert {:error,
              %{code: :preflight_identity_mismatch, detail: %{fields: [:work_order_digest]}}} =
               Preflight.admit_step(preflight, mutated, Fx.step_command(step))
    end

    test "the refusal code is classified without editing the Refusal table" do
      assert Refusal.classify(:preflight_work_order_mismatch) == :refused_identity
    end
  end
end
