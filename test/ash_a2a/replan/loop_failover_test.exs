defmodule AshA2A.Replan.LoopFailoverTest do
  use ExUnit.Case, async: true

  defmodule FailedProvider do
    def supports?(:hddl), do: true
    def supports?(_), do: false
    def propose(_request, _opts), do: {:error, :provider_down}
  end

  defmodule WorkingProvider do
    def supports?(:hddl), do: true
    def supports?(_), do: false
    def propose(request, _opts), do: {:ok, %{subject: request.subject, plan: [:ok]}}
  end

  test "failure excludes only the failed provider and consumes the attempt budget" do
    providers = [failed: FailedProvider, working: WorkingProvider]

    assert {:ok, %{provider: :working, attempt: 1, candidate: %{subject: "s"}}} =
             AshA2A.Replan.Loop.run("s", %{formalism: :hddl}, providers, max_attempts: 2)
  end

  test "budget exhaustion stops before an unbounded provider loop" do
    providers = [failed: FailedProvider]

    assert {:error, %{code: :replan_provider_unavailable}} =
             AshA2A.Replan.Loop.run("s", %{formalism: :hddl}, providers, max_attempts: 1)
  end
end
