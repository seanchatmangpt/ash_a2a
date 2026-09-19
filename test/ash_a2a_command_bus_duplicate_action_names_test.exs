# b4p-f5-10 (wave finding, beam4pm capability sweep 2026-09-18): on a
# multi-resource domain -- the DEFAULT surface since every public Ash action
# is exposed as a skill -- same-named `:change` skills (e.g. `create` on 597
# resources) resolved the CommandBus re-dispatch by bare display `skill.name`,
# so `Dispatcher.fetch_skill/2` index-first-matched a DIFFERENT resource's
# namesake and `AshA2A.BrceAnchor.admit/2` refused the exact-skill anchor with
# `:capability_mismatch`. Fail-safe (typed refusal, nothing mis-admitted), but
# the entire `:change` half of the card beyond the index-first namesake was
# inoperable. This file pins the law: the addressed capability actuates, an
# ambiguous bare display name refuses typed, an unambiguous display name keeps
# resolving.
defmodule AshA2A.Test.Fixture.DupA.Resource do
  @moduledoc """
  Real fixture resource, private to this file: public `:create` ONLY (no
  `:read`), so `read` stays an unambiguous display name across the shared
  domain for the resolution test below.
  """

  use Ash.Resource,
    domain: AshA2A.Test.Fixture.Dup.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
    attribute(:label, :string, public?: true)
  end

  actions do
    create :create do
      accept([:label])
    end
  end
end

defmodule AshA2A.Test.Fixture.DupB.Resource do
  @moduledoc """
  Real fixture resource, private to this file: public `:create` AND `:read`.
  Its `create` shares the display name with `DupA.Resource`'s -- the exact
  collision class the fix governs.
  """

  use Ash.Resource,
    domain: AshA2A.Test.Fixture.Dup.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
    attribute(:label, :string, public?: true)
  end

  actions do
    create :create do
      accept([:label])
    end

    read(:read)
  end
end

defmodule AshA2A.Test.Fixture.Dup.Domain do
  @moduledoc "Real fixture domain carrying BOTH same-named-`create` resources."

  use Ash.Domain, extensions: [AshA2A]

  resources do
    resource(AshA2A.Test.Fixture.DupA.Resource)
    resource(AshA2A.Test.Fixture.DupB.Resource)
  end
end

defmodule AshA2A.Test.Fixture.DupAgent do
  @moduledoc "Real `A2A.Agent` over the whole two-resource domain (the default multi-skill surface)."

  use AshA2A.Agent,
    resource_or_domain: AshA2A.Test.Fixture.Dup.Domain,
    name: "dup_skill_name_agent"
end

defmodule AshA2ACommandBusDuplicateActionNamesTest do
  use ExUnit.Case, async: false

  import AshA2A.Test.MessageHelpers

  alias AshA2A.Test.Fixture.DupAgent

  @create_a "AshA2A.Test.Fixture.DupA.Resource.create"
  @create_b "AshA2A.Test.Fixture.DupB.Resource.create"

  setup do
    {_sup, _registry_name} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [DupAgent])

    AshA2A.Test.AuthorityGrantCase.grant!([
      {"user-1", AshA2A.Test.Fixture.DupA.Resource, ["create"]},
      {"user-1", AshA2A.Test.Fixture.DupB.Resource, ["create"]}
    ])

    handler_id = {:dup_skill_name_test, System.unique_integer([:positive])}
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:ash_a2a, :receipt, :committed],
      fn _event, _measurements, %{receipt: receipt}, _config ->
        send(test_pid, {:receipt_committed, receipt})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok
  end

  defp authenticated_call_opts(identity),
    do: [metadata: %{"a2a.auth" => %{identity: identity}}]

  test "a granted dispatch addressed by full capability id actuates the ADDRESSED " <>
         "resource's create, never the index-first namesake" do
    message =
      data_message(%{"label" => "from-b"}, %{metadata: %{skill: @create_b}})

    assert {:ok, task} = DupAgent.call(DupAgent, message, authenticated_call_opts("user-1"))
    assert task.status.state == :completed

    assert_receive {:receipt_committed, receipt}, 1_000
    assert receipt.capability_id == @create_b
    assert receipt.consequence == :change
    assert receipt.status == :completed
  end

  test "the same dispatch addressed to the OTHER namesake actuates THAT one" do
    message =
      data_message(%{"label" => "from-a"}, %{metadata: %{skill: @create_a}})

    assert {:ok, task} = DupAgent.call(DupAgent, message, authenticated_call_opts("user-1"))
    assert task.status.state == :completed

    assert_receive {:receipt_committed, receipt}, 1_000
    assert receipt.capability_id == @create_a
  end

  test "an ambiguous bare display name is refused typed, never silently index-first" do
    message = data_message(%{"label" => "ambiguous"}, %{metadata: %{skill: "create"}})

    assert {:ok, task} = DupAgent.call(DupAgent, message, authenticated_call_opts("user-1"))
    assert task.status.state == :failed

    # Typed and disclosed: the failure names the ambiguity instead of
    # silently picking the capability-index-first `create`.
    rendered = inspect(task)
    assert rendered =~ "ambiguous" or rendered =~ "capability_mismatch"

    refute_receive {:receipt_committed, _receipt}, 200
  end

  test "an unambiguous display name still resolves across the multi-resource domain" do
    # `read` exists only on DupB -- a bare display name with exactly one
    # match must keep working (backward compatibility).
    message = data_message(%{}, %{metadata: %{skill: "read"}})

    assert {:ok, task} = DupAgent.call(DupAgent, message, authenticated_call_opts("user-1"))
    assert task.status.state == :completed

    refute_receive {:receipt_committed, _receipt}, 200
  end
end
