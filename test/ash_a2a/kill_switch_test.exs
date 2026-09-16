defmodule AshA2A.KillSwitchTest do
  @moduledoc """
  Real, Chicago-style proof of `AshA2A.KillSwitch`: a real `GenServer`
  (started once, node-wide, by `AshA2A.Application` -- see its supervision
  tree), real `AshA2A.Test.Support.KillSwitchDemo.Worker` processes doing
  real (harmless) work, and a real `AshA2A.Authority` for the reset-gating
  checks. No `Mox`/`:meck`/`Mock`/`patch`/`monkeypatch` anywhere in this
  file. `async: true` is safe because every test mints its own unique
  `class` string (`unique_class/1`) against the one shared singleton
  process, so no two tests ever observe or mutate each other's state.
  """

  use ExUnit.Case, async: true

  alias AshA2A.{Authority, Identity, KillSwitch}
  alias AshA2A.Test.Support.KillSwitchDemo.Worker

  defp unique_class(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  test "trip/3 then tripped?/1 real-reflects it" do
    class = unique_class("trip-reflect")

    refute KillSwitch.tripped?(class)

    assert :ok = KillSwitch.trip(class, :incident_42)

    assert {true, :incident_42} = KillSwitch.tripped?(class)
  end

  test "real workers stop taking new work after a real trip" do
    class = unique_class("worker-halt")
    {:ok, worker} = Worker.start_link(class)

    assert {:ok, 1} = Worker.perform_work(worker)
    assert {:ok, 2} = Worker.perform_work(worker)

    assert :ok = KillSwitch.trip(class, :maintenance_window)

    assert {:refused, :maintenance_window} = Worker.perform_work(worker)
    assert {:refused, :maintenance_window} = Worker.perform_work(worker)

    status = Worker.status(worker)
    assert status.completed == 2
    assert status.refused == 2
  end

  test "reset/4 with a valid, matching Authority and matching expected_principal real-succeeds and real workers resume" do
    class = unique_class("worker-resume")
    {:ok, worker} = Worker.start_link(class)

    assert {:ok, 1} = Worker.perform_work(worker)

    assert :ok = KillSwitch.trip(class, :incident)
    assert {:refused, :incident} = Worker.perform_work(worker)

    principal = Identity.principal("kill-switch-operator")
    authority = Authority.new(principal, KillSwitch.reset_capability_id(class))

    assert :ok = KillSwitch.reset(class, authority, principal)
    refute KillSwitch.tripped?(class)

    assert {:ok, 2} = Worker.perform_work(worker)
  end

  test "reset/4 with a missing, wrong-capability, or expired Authority real-fails and class stays tripped" do
    class = unique_class("worker-refuse-reset")
    {:ok, worker} = Worker.start_link(class)

    assert :ok = KillSwitch.trip(class, :incident)

    principal = Identity.principal("kill-switch-operator")
    wrong_authority = Authority.new(principal, "Example.Resource.read")

    assert {:error, :authority_mismatch} = KillSwitch.reset(class, wrong_authority, principal)
    assert {true, :incident} = KillSwitch.tripped?(class)
    assert {:refused, :incident} = Worker.perform_work(worker)

    assert {:error, :authority_mismatch} = KillSwitch.reset(class, nil, principal)
    assert {true, :incident} = KillSwitch.tripped?(class)

    expired_authority =
      Authority.new(principal, KillSwitch.reset_capability_id(class),
        expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
      )

    assert {:error, :authority_mismatch} = KillSwitch.reset(class, expired_authority, principal)
    assert {true, :incident} = KillSwitch.tripped?(class)

    # no partial reset ever happened -- the worker never resumed.
    assert Worker.status(worker).completed == 0
  end

  test "reset/4 real-refuses a genuine, unexpired, correctly-capabilitied Authority whose subject does not match the independently-supplied expected_principal" do
    # Closes a real, adversarially-found gap: an earlier version of this
    # module compared authority.subject against itself, which any caller
    # able to construct an Authority naming the right (public) capability
    # id could satisfy regardless of whose identity it actually named.
    # This test proves the fix: a real, valid, correctly-capabilitied,
    # unexpired Authority whose subject genuinely differs from the
    # independently-supplied expected_principal is refused, not admitted.
    class = unique_class("worker-refuse-subject-mismatch")
    {:ok, worker} = Worker.start_link(class)

    assert :ok = KillSwitch.trip(class, :incident)

    real_operator = Identity.principal("kill-switch-operator")
    different_caller = Identity.principal("someone-else-entirely")

    authority_minted_for_real_operator =
      Authority.new(real_operator, KillSwitch.reset_capability_id(class))

    assert {:error, :authority_mismatch} =
             KillSwitch.reset(class, authority_minted_for_real_operator, different_caller)

    assert {true, :incident} = KillSwitch.tripped?(class)
    assert {:refused, :incident} = Worker.perform_work(worker)
  end

  test "two different classes are real-independent" do
    class_a = unique_class("indep-a")
    class_b = unique_class("indep-b")

    {:ok, worker_a} = Worker.start_link(class_a)
    {:ok, worker_b} = Worker.start_link(class_b)

    assert :ok = KillSwitch.trip(class_a, :only_a)

    assert {true, :only_a} = KillSwitch.tripped?(class_a)
    refute KillSwitch.tripped?(class_b)

    assert {:refused, :only_a} = Worker.perform_work(worker_a)
    assert {:ok, 1} = Worker.perform_work(worker_b)

    principal = Identity.principal("kill-switch-operator")
    authority = Authority.new(principal, KillSwitch.reset_capability_id(class_a))
    assert :ok = KillSwitch.reset(class_a, authority, principal)

    assert {:ok, 1} = Worker.perform_work(worker_a)
    refute KillSwitch.tripped?(class_b)
  end
end
