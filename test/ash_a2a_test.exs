defmodule AshA2ATest do
  @moduledoc """
  Chicago-style coverage against real compiled Ash resources and the real A2A
  structs. v26.9.12 additionally proves that public Ash actions are the
  canonical capability source and that the A2A DSL is residual metadata only.
  """

  use ExUnit.Case

  import AshA2A.Test.MessageHelpers
  import Spark.Test, only: [assert_dsl_error: 2]

  alias AshA2A.Test.Fixture.Echo
  alias AshA2A.Test.Fixture.ZeroConfig
  alias AshA2A.Test.Fixture.ZeroConfigDomain

  test "AshA2A.Info.capability_index?/1 is true for the real compiled fixture" do
    assert AshA2A.Info.capability_index?(Echo)
  end

  test "the persisted override resolves to a derived capability for the real public :read action" do
    assert [
             %AshA2A.Skill{
               id: "AshA2A.Test.Fixture.Echo.read",
               name: :echo,
               resource: Echo,
               action: :read
             }
           ] = AshA2A.Info.capability_index(Echo)
  end

  test "the derived skill's domain is the real, statically resolved domain" do
    assert [%AshA2A.Skill{domain: AshA2A.Test.Fixture.Domain}] =
             AshA2A.Info.capability_index(Echo)

    assert Ash.Resource.Info.domain(Echo) == AshA2A.Test.Fixture.Domain
  end

  test "the built AgentCard uses canonical capability identity and residual display name" do
    agent_card = AshA2A.Info.agent_card(Echo, name: "echo_agent")

    assert %A2A.AgentCard{name: "echo_agent"} = agent_card

    assert [%{id: "AshA2A.Test.Fixture.Echo.read", name: "echo"}] =
             agent_card.skills
  end

  test "zero configuration projects public Ash actions and excludes private actions" do
    assert [
             %AshA2A.Skill{
               id: "AshA2A.Test.Fixture.ZeroConfig.visible",
               name: :visible,
               resource: ZeroConfig,
               action: :visible
             }
           ] = AshA2A.Info.capability_index(ZeroConfig)

    refute Enum.any?(AshA2A.Info.capability_index(ZeroConfig), &(&1.action == :internal))
  end

  test "domain capability projection deterministically composes resource public actions" do
    assert [
             %AshA2A.Skill{
               id: "AshA2A.Test.Fixture.ZeroConfig.visible",
               resource: ZeroConfig,
               action: :visible
             }
           ] = AshA2A.Info.capability_index(ZeroConfigDomain)

    ids = Enum.map(AshA2A.Info.capability_index(AshA2A.Test.Fixture.Domain), & &1.id)
    assert ids == Enum.sort(ids)
    assert "AshA2A.Test.Fixture.Echo.read" in ids
  end

  test "the skill's own resolved domain is accepted by a real Ash.Query.for_read/3 call" do
    [%AshA2A.Skill{domain: domain} = skill] = AshA2A.Info.capability_index(Echo)
    refute is_nil(domain)

    assert {:ok, []} =
             skill.resource
             |> Ash.Query.for_read(:read, %{}, domain: domain)
             |> Ash.read(domain: domain)
  end

  test "AshA2A.Dispatcher.dispatch/3 dispatches the real :echo skill without a KeyError" do
    message = data_message(%{})

    assert {:reply, [%A2A.Part.Data{data: %{results: []}}]} =
             AshA2A.Dispatcher.dispatch(:echo, message, Echo)
  end

  test "AshA2A.Dispatcher.dispatch/3 returns {:stream, _} for a real :echo read when the caller opts in" do
    message = data_message(%{"stream" => true})

    assert {:stream, stream} = AshA2A.Dispatcher.dispatch(:echo, message, Echo)
    assert Enum.to_list(stream) == []
  end

  test "AshA2A.Dispatcher.dispatch/3 returns {:error, {:unknown_skill, _}} for an unknown skill name" do
    message = data_message(%{})

    assert {:error, {:skill_lookup, {:unknown_skill, :no_such_skill}}} =
             AshA2A.Dispatcher.dispatch(:no_such_skill, message, Echo)
  end

  test "AshA2A.Dispatcher.dispatch/3 surfaces a real forbidden error as a readable class-labeled string" do
    alias AshA2A.Test.Fixture.Locked

    message = data_message(%{})
    assert {:error, reason} = AshA2A.Dispatcher.dispatch(:list, message, Locked)

    class_reason =
      case reason do
        {_stage, inner} when is_binary(inner) -> inner
        other -> other
      end

    assert is_binary(class_reason)
    assert class_reason =~ ~r/^forbidden: /
    refute class_reason =~ "{:forbidden"
    refute match?({:forbidden, _}, class_reason)
  end

  test "AshA2A.Info.skill/2 returns a real {:error, :skill_not_found} for an unknown skill name" do
    assert AshA2A.Info.skill(Echo, :no_such_skill) == {:error, :skill_not_found}
  end

  test "AshA2A.Info.skill/2 resolves the stable canonical A2A capability id" do
    assert {:ok, %AshA2A.Skill{name: :echo, action: :read}} =
             AshA2A.Info.skill(Echo, "AshA2A.Test.Fixture.Echo.read")
  end

  test "AshA2A.Verify fails closed when an override names a nonexistent action" do
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

  test "AshA2A.Verify refuses attempts to expose a private Ash action" do
    error =
      assert_dsl_error %Spark.Error.DslError{} do
        defmodule Elixir.AshA2A.Test.Fixture.PrivateActionOverride do
          use Ash.Resource,
            domain: nil,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshA2A]

          attributes do
            uuid_primary_key(:id)
          end

          actions do
            read :secret do
              public?(false)
            end
          end

          a2a do
            skill(:secret, :secret)
          end
        end
      end

    assert error.message =~ "REFUSED_ACTION_NOT_PUBLIC"
    assert error.message =~ "secret"
  end

  test "duplicate skill override names are rejected structurally by Spark" do
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

    assert error.message =~ "duplicate"
    assert error.message =~ "dup"
  end

  test "a real A2A.AgentSupervisor-started AshA2A.Agent dispatches the real :echo skill" do
    alias AshA2A.Test.Fixture.EchoAgent

    {_sup, _registry_name} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [EchoAgent])

    message = data_message(%{})

    assert {:ok, task} = EchoAgent.call(EchoAgent, message)
    assert task.status.state == :completed
    assert [%A2A.Artifact{parts: [%A2A.Part.Data{data: %{results: []}}]}] = task.artifacts
  end
end
