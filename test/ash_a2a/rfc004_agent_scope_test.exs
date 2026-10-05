# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Test.Rfc004.Scope.Item do
  @moduledoc "Real fixture resource for RFC-SA2A-004 S21 agent-scope tests."

  use Ash.Resource,
    domain: AshA2A.Test.Rfc004.Scope.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
    attribute(:label, :string, public?: true, allow_nil?: false)
  end

  actions do
    defaults([:read, create: [:label]])

    action :peek, :map do
      run(fn _input, _context -> {:ok, %{peeked: true}} end)
    end
  end

  a2a do
    semantic_requests(true)
    skill(:create_item, :create)
    skill(:list_items, :read)
    skill(:peek, :peek, consequence: :observe)
  end
end

defmodule AshA2A.Test.Rfc004.Scope.Domain do
  @moduledoc false
  use Ash.Domain, extensions: [AshA2A]

  resources do
    resource(AshA2A.Test.Rfc004.Scope.Item)
  end
end

defmodule AshA2A.Test.Rfc004.Scope.Agent do
  @moduledoc false
  use AshA2A.Agent,
    resource_or_domain: AshA2A.Test.Rfc004.Scope.Item,
    name: "rfc004_scope_agent",
    strict_observe_generic_actions: true
end

defmodule AshA2A.Test.Rfc004.Scope.OptInAgent do
  @moduledoc false
  use AshA2A.Agent,
    resource_or_domain: AshA2A.Test.Rfc004.Scope.Item,
    name: "rfc004_scope_optin_agent",
    strict_observe_generic_actions: true,
    observe_generic_actions: [:peek]
end

defmodule AshA2A.Rfc004AgentScopeTest do
  @moduledoc """
  RFC-SA2A-004 S21 (agent lane): continuation lookup is scoped to the
  verified principal, and a generic `:action` declared `consequence:
  :observe` is not silently dispatched unless explicitly opted in.

  Real collaborators throughout: real agent GenServers, real
  `CommandBus`/`ReceiptStore`/`PackageStore`. The only injected seam is the
  sanctioned `Compiler.compile/3` `generate_object` seam used to build the
  stored package without a live network LLM call (see
  `ash_a2a_agent_semantic_replan_test.exs`).
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  import AshA2A.Test.MessageHelpers

  alias AshA2A.Semantic.{Compiler, ExecutionPackage, PackageStore}
  alias AshA2A.Test.Rfc004.Scope.{Agent, Item, OptInAgent}

  setup do
    AshA2A.Test.AuthorityGrantCase.grant!([
      {"scope-a", Item, ["create_item"]},
      {"scope-b", Item, ["create_item"]}
    ])

    {_sup, _registry} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [Agent, OptInAgent])

    :ok
  end

  defp auth(identity), do: [metadata: %{"a2a.auth" => %{identity: identity}}]

  defp compile_package!(text, owner_identity) do
    extract = fn _, _, _, _ -> {:ok, extraction()} end
    plan = fn _, _, _, _ -> {:ok, plan_envelope()} end

    assert {:ok, %ExecutionPackage{} = package} =
             Compiler.compile(Item, text, generate_object: extract, plan_generate_object: plan)

    package = AshA2A.Agent.__bind_package__(package, owner_identity)
    :ok = PackageStore.put(package)
    package
  end

  defp extraction do
    AshA2A.Semantic.IR.fields()
    |> Map.new(&{Atom.to_string(&1), []})
    |> Map.put("authority", "none")
    |> Map.put("goals", [
      %{
        "id" => "create-a-labeled-item",
        "kind" => "goal",
        "description" => "create a labeled item",
        "source_quote" => "create a labeled item"
      }
    ])
  end

  defp plan_envelope do
    %{
      "request_id" => "rfc004-scope-plan-#{System.unique_integer([:positive])}",
      "authority" => "none",
      "capability_ids" => [AshA2A.CapabilityIndex.Compiler.capability_id(Item, :create)],
      "hddl" => "(:task create-item)",
      "fond" => "(:policy observe-or-replan)",
      "rationale" => "create the item, then observe the real outcome"
    }
  end

  defp close_as(identity, fingerprint) do
    message =
      data_message(%{"label" => "widget"}, %{
        metadata: %{skill: "create_item", continuation_fingerprint: fingerprint}
      })

    {:ok, task} = Agent.call(Agent, message, auth(identity))
    task
  end

  defp replan_as(identity, fingerprint) do
    message =
      data_message(%{}, %{
        metadata: %{semantic_request: true, continuation_fingerprint: fingerprint}
      })

    {:ok, task} = Agent.call(Agent, message, auth(identity) ++ [timeout: 170_000])
    task
  end

  defp error_text(%{status: %{message: %AshA2A.Protocol.Message{} = m}}), do: AshA2A.Protocol.Message.text(m)
  defp error_text(_), do: nil

  test "principal B cannot replan principal A's continuation; refusal equals not-found" do
    package = compile_package!("create a labeled item (scope)", "scope-a")
    assert close_as("scope-a", package.fingerprint).status.state == :completed

    foreign = replan_as("scope-b", package.fingerprint)
    absent = replan_as("scope-b", String.duplicate("0", 64))

    assert foreign.status.state == :failed
    assert error_text(foreign) =~ "continuation_receipt_not_found"
    # Indistinguishable from a fingerprint that never existed (modulo the echoed fingerprint).
    assert error_text(absent) =~ "continuation_receipt_not_found"
    refute error_text(foreign) =~ "continuation_package_not_found"
  end

  test "principal B holding its own receipt still cannot use A's stored package" do
    package = compile_package!("create a labeled item (scope, own receipt)", "scope-a")
    # B commits a receipt under the same fingerprint (command_id) as itself.
    assert close_as("scope-b", package.fingerprint).status.state == :completed

    task = replan_as("scope-b", package.fingerprint)
    assert task.status.state == :failed
    assert error_text(task) =~ "continuation_package_not_found"
  end

  test "an unbound (no principal) stored package is refused for every principal" do
    extract = fn _, _, _, _ -> {:ok, extraction()} end
    plan = fn _, _, _, _ -> {:ok, plan_envelope()} end

    {:ok, package} =
      Compiler.compile(Item, "create a labeled item (unbound)",
        generate_object: extract,
        plan_generate_object: plan
      )

    :ok = PackageStore.put(package)
    assert close_as("scope-a", package.fingerprint).status.state == :completed

    task = replan_as("scope-a", package.fingerprint)
    assert task.status.state == :failed
    assert error_text(task) =~ "continuation_package_not_found"
  end

  test "principal A still resolves its own continuation (never a continuation_* refusal)" do
    package = compile_package!("create a labeled item (scope, owner)", "scope-a")
    assert close_as("scope-a", package.fingerprint).status.state == :completed

    # The exact principal-scoped lookup the real replan performs before
    # re-synthesis (no live LLM): A resolves its own receipt AND package.
    assert {:ok, receipt, resolved} =
             AshA2A.Agent.__resolve_continuation__(package.fingerprint, "scope-a")

    assert receipt.command_id == AshA2A.Identity.command(package.fingerprint)
    assert receipt.principal_id == AshA2A.Identity.principal("scope-a")
    assert resolved.fingerprint == package.fingerprint

    # ... while the very same fingerprint is not-found for B (same lookup).
    assert {:error, %{code: :continuation_receipt_not_found}} =
             AshA2A.Agent.__resolve_continuation__(package.fingerprint, "scope-b")
  end

  test "a generic :action declared :observe is refused unless explicitly opted in" do
    message = data_message(%{}, %{metadata: %{skill: "peek"}})

    {:ok, refused} = Agent.call(Agent, message, auth("scope-a"))
    assert refused.status.state == :failed
    assert error_text(refused) =~ "consequence_unclassified"

    {:ok, allowed} = OptInAgent.call(OptInAgent, message, auth("scope-a"))
    assert allowed.status.state == :completed
  end

  test "a :read skill declared observe by default is unaffected" do
    message = data_message(%{}, %{metadata: %{skill: "list_items"}})
    {:ok, task} = Agent.call(Agent, message, auth("scope-a"))
    assert task.status.state == :completed
  end
end
