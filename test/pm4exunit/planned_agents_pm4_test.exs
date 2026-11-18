# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.PlannedAgentsPm4Test do
  @moduledoc """
  Plan-driven multi-agent interaction, no LLM and no hard-coded hand-off.

  An `AshPPlan.FOND` domain models an order lifecycle; `Synthesis.synthesize/3`
  yields a strong-cyclic policy (state -> action). A runner executes the policy:
  each action is a real A2A call over HTTP+JSON, and the next state is the
  observed `Task` state of the reply (completed -> approved, failed ->
  rejected). The environment's nondeterminism is real: the reviewer role is
  served by an open agent (completes) or a forbidding agent (task fails).
  Conformance paths come from the same FOND domain + policy, with visit-ordinal
  labels (pm4 token replay cannot match repeated labels).
  """
  use ExUnit.Case, async: false
  use Pm4ExUnit

  @moduletag :pm4exunit
  @moduletag :serial_shard

  alias AshA2A.Protocol.{Client, Task}
  alias AshA2A.Test.{AgentSupervisorCase, EphemeralHttp}
  alias AshA2A.Transport.HTTPJSON, as: Binding
  alias AshPPlan.FOND
  alias AshPPlan.FOND.Synthesis

  @initial :new
  @max_steps 12
  @max_visits 3

  @agents %{
    intake: AshA2A.MultiAgentPm4Test.IntakeAgent,
    approve: AshA2A.MultiAgentPm4Test.ReviewAgent,
    deny: AshA2A.Test.Fixture.LockedAgent,
    fulfil: AshA2A.MultiAgentPm4Test.FulfilAgent
  }

  # action -> role that serves it ( :review picks approve|deny per environment ).
  @binding %{submit: :intake, review: :reviewer, revise: :intake, ship: :fulfil}

  defp domain! do
    {:ok, d} =
      FOND.new(
        %{
          new: %{submit: [:submitted]},
          submitted: %{review: [:approved, :rejected]},
          rejected: %{revise: [:submitted]},
          approved: %{ship: [:shipped]},
          shipped: %{}
        },
        [:shipped]
      )

    d
  end

  defp policy!(d) do
    {:ok, p} = Synthesis.synthesize(d, @initial, :strong_cyclic)
    assert {:ok, _} = FOND.validate_policy(d, p, @initial, :strong_cyclic)
    p
  end

  defp label(from, action, to, n), do: "#{from}.#{action}->#{to}##{n}"

  # Model: every policy path to a goal, each source state visited <= @max_visits times.
  defp model_paths(d, p, state \\ @initial, visits \\ %{}, acc \\ []) do
    cond do
      MapSet.member?(d.goals, state) ->
        [Enum.reverse(acc)]

      Map.get(visits, state, 0) >= @max_visits ->
        []

      true ->
        action = Map.fetch!(p, state)
        n = Map.get(visits, state, 0)
        visits = Map.put(visits, state, n + 1)

        Enum.flat_map(FOND.outcomes(d, state, action), fn to ->
          model_paths(d, p, to, visits, [label(state, action, to, n) | acc])
        end)
    end
  end

  setup do
    {_sup, _reg} = AgentSupervisorCase.start_supervised_agents!(__MODULE__, Map.values(@agents))

    clients =
      Map.new(@agents, fn {role, agent} ->
        server =
          EphemeralHttp.start!(
            {Binding, Binding.init(agent: agent, base_url: "http://127.0.0.1/#{role}")}
          )

        {role, Client.new(server.base_url, transport: :http_json)}
      end)

    %{clients: clients}
  end

  # Observed task state -> FOND outcome for the action just executed.
  defp outcome(:submit, :completed), do: {:ok, :submitted}
  defp outcome(:revise, :completed), do: {:ok, :submitted}
  defp outcome(:review, :completed), do: {:ok, :approved}
  defp outcome(:review, :failed), do: {:ok, :rejected}
  defp outcome(:ship, :completed), do: {:ok, :shipped}
  defp outcome(_action, state), do: {:error, {:unmodeled_outcome, state}}

  # Policy runner. `reviewers` is the environment's per-visit reviewer verdict queue.
  defp run(session, clients, d, p, reviewers) do
    step(session, clients, d, p, @initial, reviewers, %{}, 0)
  end

  defp step(session, clients, d, p, state, reviewers, visits, count) do
    cond do
      MapSet.member?(d.goals, state) ->
        {:ok, state, count}

      count >= @max_steps ->
        {:error, :step_budget_exhausted}

      true ->
        action = Map.fetch!(p, state)

        with {:ok, role, rest} <- role_for(action, reviewers),
             {:ok, %Task{} = task} <- Client.send_message(Map.fetch!(clients, role), "#{action}"),
             {:ok, to} <- outcome(action, task.status.state),
             true <- to in FOND.outcomes(d, state, action) do
          n = Map.get(visits, state, 0)
          emit_event(session, "s#{count}", label(state, action, to, n), resource: task.id)
          step(session, clients, d, p, to, rest, Map.put(visits, state, n + 1), count + 1)
        else
          {:error, _} = e -> e
          false -> {:error, :outcome_outside_model}
        end
    end
  end

  defp role_for(:review, [verdict | rest]), do: {:ok, verdict, rest}
  defp role_for(:review, []), do: {:error, :environment_exhausted}
  defp role_for(action, reviewers), do: {:ok, Map.fetch!(@binding, action), reviewers}

  test "policy is strong-cyclic and its action table is exactly the plan", _ do
    d = domain!()
    p = policy!(d)

    assert p == %{new: :submit, submitted: :review, rejected: :revise, approved: :ship}
  end

  test "approve on first review: shortest plan, conforms", %{pm4_session: s, clients: c} do
    d = domain!()
    p = policy!(d)

    assert {:ok, :shipped, 3} = run(s, c, d, p, [:approve])
    assert_conformance(s, model_paths(d, p), min_fitness: 1.0)
  end

  for rejections <- 1..2 do
    test "#{rejections} rejection(s) then approval: retry branch reaches goal and conforms",
         %{pm4_session: s, clients: c} do
      d = domain!()
      p = policy!(d)
      verdicts = List.duplicate(:deny, unquote(rejections)) ++ [:approve]

      assert {:ok, :shipped, steps} = run(s, c, d, p, verdicts)
      assert steps == 3 + 2 * unquote(rejections)
      assert_conformance(s, model_paths(d, p), min_fitness: 1.0)
    end
  end

  test "every enumerated model path is realizable by some environment verdict sequence",
       %{clients: c} do
    d = domain!()
    p = policy!(d)
    paths = model_paths(d, p)
    assert length(paths) == @max_visits

    for path <- paths do
      rejections = Enum.count(path, &String.contains?(&1, "->rejected#"))
      {:ok, session} = Pm4ExUnit.Session.start_link(test_name: "realize-#{rejections}")
      verdicts = List.duplicate(:deny, rejections) ++ [:approve]
      assert {:ok, :shipped, _} = run(session, c, d, p, verdicts)
      assert_conformance(session, [path], min_fitness: 1.0)
    end
  end

  test "an environment that always rejects ends in a typed refusal, never a loop",
       %{pm4_session: s, clients: c} do
    d = domain!()
    p = policy!(d)

    assert {:error, :environment_exhausted} = run(s, c, d, p, [:deny, :deny])

    # The partial trace is a prefix of a lawful path but does not reach the goal.
    refute_conformance(s, model_paths(d, p), min_fitness: 1.0)
  end

  test "a hand-driven run that skips review violates the generated model",
       %{pm4_session: s, clients: c} do
    assert {:ok, %Task{}} = Client.send_message(c.intake, "submit")
    emit_event(s, "x0", label(:new, :submit, :submitted, 0))
    assert {:ok, %Task{}} = Client.send_message(c.fulfil, "ship")
    emit_event(s, "x1", label(:approved, :ship, :shipped, 0))

    d = domain!()
    refute_conformance(s, model_paths(d, policy!(d)), min_fitness: 1.0)
  end
end
