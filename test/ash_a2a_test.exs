defmodule AshA2ATest do
  @moduledoc """
  Chicago-style: compiles the real `AshA2A.Test.Fixture.Echo` resource
  (`test/support/fixture.ex`), a real `Ash.Resource` with `extensions:
  [AshA2A]` and a real `a2a do skill :echo, :read end` block -- no
  Mock/mox/patch, no stubbed A2A or Ash behavior.
  """

  use ExUnit.Case

  import Spark.Test, only: [assert_dsl_error: 2]

  alias AshA2A.Test.Fixture.Echo

  test "AshA2A.Info.capability_index?/1 is true for the real compiled fixture" do
    assert AshA2A.Info.capability_index?(Echo)
  end

  test "the persisted capability index contains the real :echo skill" do
    assert [%AshA2A.Skill{name: :echo, resource: Echo, action: :read}] =
             AshA2A.Info.capability_index(Echo)
  end

  test "the persisted skill's domain is the real, statically resolved domain" do
    assert [%AshA2A.Skill{domain: AshA2A.Test.Fixture.Domain}] =
             AshA2A.Info.capability_index(Echo)

    assert Ash.Resource.Info.domain(Echo) == AshA2A.Test.Fixture.Domain
  end

  test "the built AgentCard lists the real :echo skill" do
    agent_card = AshA2A.Info.agent_card(Echo, name: "echo_agent")

    assert %A2A.AgentCard{name: "echo_agent"} = agent_card
    assert [%{id: "echo", name: "echo"}] = agent_card.skills
  end

  test "the skill's own resolved domain is accepted by a real Ash.Query.for_read/3 call" do
    # Exercises the exact `domain:` opt `AshA2A.Dispatcher.build_opts/2` now
    # sources from `skill.domain` (falling back to the exec-context domain
    # only when `skill.domain` is `nil`) -- confirms it is a real,
    # Ash-accepted domain, not merely a non-nil value.
    [%AshA2A.Skill{domain: domain} = skill] = AshA2A.Info.capability_index(Echo)
    refute is_nil(domain)

    assert {:ok, []} =
             skill.resource
             |> Ash.Query.for_read(:read, %{}, domain: domain)
             |> Ash.read(domain: domain)
  end

  test "the domain also has a real (empty) verified capability index" do
    assert AshA2A.Info.capability_index?(AshA2A.Test.Fixture.Domain)
    assert AshA2A.Info.capability_index(AshA2A.Test.Fixture.Domain) == []
  end

  test "AshA2A.Dispatcher.dispatch/3 dispatches the real :echo skill without a KeyError" do
    # Real repro for the reviewed `skill.domain` KeyError: a bare `AshA2A.Skill`
    # struct with no `:domain` key would crash `Map.get(skill, :domain)` in
    # `AshA2A.Dispatcher.build_opts/2` with a `KeyError`. `AshA2A.Skill` now
    # declares `:domain` (skill.ex:23) and `BuildCapabilityIndex` fills it in
    # at compile time, so this must run cleanly against the real compiled
    # fixture, not a hand-built struct.
    message = A2A.Message.new_user([A2A.Part.Data.new(%{})])

    assert {:reply, [%A2A.Part.Data{data: %{results: []}}]} =
             AshA2A.Dispatcher.dispatch(:echo, message, Echo)
  end

  test "AshA2A.Verify fails closed when a skill names a nonexistent action" do
    # Real repro of the `:REFUSED_ACTION_NOT_FOUND` fail-closed path:
    # `AshA2A.CapabilityIndex.validate_actions_exist/1`
    # (lib/ash_a2a/capability_index.ex:107-121) is documented as one of two
    # checks `AshA2A.Verify` delegates to, but no fixture ever named a bad
    # action -- so the claimed fail-closed behavior was unverified.
    #
    # Spark verifier errors raised inside `@after_verify` are converted to
    # stderr warnings rather than propagated exceptions (per
    # `deps/spark/lib/spark/test.ex` moduledoc), so `assert_raise` around a
    # plain `Code.compile_string/1` cannot observe them. `Spark.Test
    # .assert_dsl_error/2` is Spark's own real collector mechanism for this
    # exact case: it registers the test process to receive the real
    # `Spark.Error.DslError` Elixir's compiler would otherwise only warn
    # about, still going through the genuine `Ash.Resource` compile +
    # `AshA2A.Verify` + `AshA2A.CapabilityIndex.validate/1` pipeline -- no
    # Mock/mox/patch, no hand-built refusal.
    error =
      assert_dsl_error %Spark.Error.DslError{} do
        defmodule Elixir.AshA2A.Test.Fixture.BadAction do
          use Ash.Resource,
            domain: nil,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshA2A]

          attributes do
            uuid_primary_key(:id)
          end

          actions do
            defaults([:read])
          end

          a2a do
            skill(:bogus, :not_a_real_action)
          end
        end
      end

    assert error.message =~ "REFUSED_ACTION_NOT_FOUND"
    assert error.message =~ "not_a_real_action"
  end

  test "AshA2A.Verify fails closed when two skills declare the same name" do
    # Real repro of the `:REFUSED_DUPLICATE_SKILL_NAME` fail-closed path:
    # `AshA2A.CapabilityIndex.validate_unique_names/1`
    # (lib/ash_a2a/capability_index.ex:94-105) is documented as the other of
    # the two checks `AshA2A.Verify` delegates to, but no fixture ever
    # declared two `skill/2` entries with the same name -- so the claimed
    # fail-closed behavior was unverified.
    #
    # Same real collector mechanism as the `REFUSED_ACTION_NOT_FOUND` test
    # above (`Spark.Test.assert_dsl_error/2`, imported at the top of this
    # module): `@after_verify` errors are converted to stderr warnings rather
    # than propagated exceptions, so a plain `Code.compile_string/1` +
    # `assert_raise` cannot observe them. This still compiles a real,
    # standalone `Ash.Resource` (two genuine `a2a do skill :dup, ... end`
    # declarations sharing the name `:dup`, both naming real actions so the
    # action-exists check stays clean) through the genuine `AshA2A.Verify` +
    # `AshA2A.CapabilityIndex.validate/1` pipeline -- no Mock/mox/patch, no
    # hand-built refusal.
    error =
      assert_dsl_error %Spark.Error.DslError{} do
        defmodule Elixir.AshA2A.Test.Fixture.DuplicateName do
          use Ash.Resource,
            domain: nil,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshA2A]

          attributes do
            uuid_primary_key(:id)
          end

          actions do
            defaults([:read, :destroy])
          end

          a2a do
            skill(:dup, :read)
            skill(:dup, :destroy)
          end
        end
      end

    assert error.message =~ "REFUSED_DUPLICATE_SKILL_NAME"
    assert error.message =~ "dup"
  end

  test "a real A2A.AgentSupervisor-started AshA2A.Agent dispatches the real :echo skill" do
    # Real repro for hardening task #2: `AshA2A.Application` used to start an
    # empty supervision tree, so nothing ever ran `AshA2A.Dispatcher.dispatch/3`
    # through an actual supervised process -- only as a bare function call.
    # This starts a real `A2A.AgentSupervisor` (the same child spec
    # `AshA2A.Application.start/2` now wires in) with the real
    # `AshA2A.Test.Fixture.EchoAgent` (built via `use AshA2A.Agent`), sends it
    # a real `A2A.Message` through `A2A.Agent.call/3`, and asserts on the real
    # resulting `A2A.Task`.
    alias AshA2A.Test.Fixture.EchoAgent

    {:ok, sup} =
      A2A.AgentSupervisor.start_link(
        agents: [EchoAgent],
        name: :"#{__MODULE__}.Sup",
        registry: :"#{__MODULE__}.Registry"
      )
    on_exit(fn ->
      try do
        Supervisor.stop(sup)
      catch
        :exit, _ -> :ok
      end
    end)

    message = A2A.Message.new_user([A2A.Part.Data.new(%{})])

    assert {:ok, task} = EchoAgent.call(EchoAgent, message)
    assert task.status.state == :completed
    assert [%A2A.Artifact{parts: [%A2A.Part.Data{data: %{results: []}}]}] = task.artifacts
  end
end
