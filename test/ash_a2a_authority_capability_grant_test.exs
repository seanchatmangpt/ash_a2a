defmodule AshA2AAuthorityCapabilityGrantTest do
  @moduledoc """
  Regression tests for the RFC-SA2A-001 S29 ("Authentication does NOT imply
  Authority") escalation that existed on the real, default `AshA2A.Agent`
  dispatch path.

  The defect: `AshA2A.Agent.build_command/4` called
  `AshA2A.Authority.from_verified_identity(auth_identity, capability_id)`
  with a CALLER-SUPPLIED `capability_id` (`to_string(skill_name)`, taken
  straight off the inbound message's `skill` metadata). That function mints a
  full `%AshA2A.Authority{}` for whatever capability id it is handed, so
  `AshA2A.CommandBus.admit/2`'s `Authority.admits?/2` check passed by
  construction for EVERY skill on the agent card -- including every
  `:change`/`:external_do` skill. Any transport-authenticated caller
  therefore held authority for every consequential capability the agent
  exposed.

  These tests run against the real `A2A.Agent` GenServer, a real
  `AshA2A.Authority.Broker.InMemory` process, and a real
  `AshA2A.Test.Fixture.ActuationCounter` process. "Was the consequential
  action actually actuated" is answered by a real counter read, never by an
  interaction assertion. No Mock/mox/:meck/patch anywhere in this file.
  """

  use ExUnit.Case, async: false

  import AshA2A.Test.MessageHelpers

  alias AshA2A.Authority
  alias AshA2A.Authority.Broker.InMemory
  alias AshA2A.Test.Fixture.{ActuationCounter, GrantProbeAgent}

  @principal "user-grant-probe"

  setup do
    {_sup, _registry} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [GrantProbeAgent])

    start_supervised!(ActuationCounter)

    # This module's OWN broker process, uniquely named: these tests revoke,
    # and revocation state must not leak into (or out of) the run-wide broker
    # `test/test_helper.exs` starts. `async: false` is what makes the
    # `Application.put_env/3` below safe -- ExUnit runs sync modules serially,
    # after every async module has finished.
    broker_name = :"#{__MODULE__}.Broker"
    start_supervised!(Supervisor.child_spec({InMemory, name: broker_name}, id: broker_name))

    prior_policy = Application.get_env(:ash_a2a, :authority_policy)
    prior_broker = Application.get_env(:ash_a2a, :authority_broker)

    Application.put_env(:ash_a2a, :authority_policy, :broker)
    Application.put_env(:ash_a2a, :authority_broker, {InMemory, name: broker_name})

    on_exit(fn ->
      restore(:authority_policy, prior_policy)
      restore(:authority_broker, prior_broker)
    end)

    {:ok, broker: broker_name, broker_opts: [name: broker_name]}
  end

  defp restore(key, nil), do: Application.delete_env(:ash_a2a, key)
  defp restore(key, value), do: Application.put_env(:ash_a2a, key, value)

  # `A2A.Plug` populates `context.metadata["a2a.auth"]` only after real
  # credential verification; `A2A.Agent.call/3`'s `opts` become exactly
  # `context.metadata`, so this is the same real shape a verified caller
  # arrives with (identical to the helper in
  # `test/ash_a2a_agent_command_bus_test.exs`).
  defp authenticated_call_opts(identity) do
    [metadata: %{"a2a.auth" => %{identity: identity}}]
  end

  defp call(skill, data \\ %{}, opts \\ []) do
    message = data_message(data, %{metadata: %{skill: skill}})
    GrantProbeAgent.call(GrantProbeAgent, message, authenticated_call_opts(@principal) ++ opts)
  end

  describe "(a) an authenticated principal WITHOUT a capability grant" do
    test "cannot actuate an :external_do skill -- zero real actuations" do
      assert {:ok, task} = call("touch")
      assert task.status.state == :failed

      assert ActuationCounter.count() == 0
    end

    test "cannot actuate a :change skill -- zero real actuations" do
      assert {:ok, task} = call("mutate")
      assert task.status.state == :failed

      assert ActuationCounter.count() == 0
    end

    test "holds no authority at all for the capability it never asked for", ctx do
      subject = AshA2A.Identity.principal(@principal)

      refute InMemory.granted?(subject, "touch", ctx.broker_opts)
      assert Authority.Grant.authorize(@principal, "touch") == nil
    end
  end

  describe "(b) an authenticated principal WITH a real broker-issued grant" do
    test "can actuate the granted :external_do skill, exactly once" do
      subject = AshA2A.Identity.principal(@principal)
      assert {:ok, %Authority{}} = Authority.Grant.grant(subject, "touch")

      assert {:ok, task} = call("touch", %{"note" => "granted"})
      assert task.status.state == :completed

      assert ActuationCounter.count() == 1
    end

    test "a grant for one capability does NOT confer the others (S29, per-capability)" do
      subject = AshA2A.Identity.principal(@principal)
      assert {:ok, %Authority{}} = Authority.Grant.grant(subject, "mutate")

      assert {:ok, mutate_task} = call("mutate", %{"note" => "ok"})
      assert mutate_task.status.state == :completed
      assert ActuationCounter.count() == 1

      # Same authenticated principal, same agent card, DIFFERENT capability:
      # refused. This is the exact escalation the defect allowed.
      assert {:ok, touch_task} = call("touch", %{"note" => "escalation attempt"})
      assert touch_task.status.state == :failed
      assert ActuationCounter.count() == 1
    end

    test "a revoked grant fails closed again", ctx do
      subject = AshA2A.Identity.principal(@principal)
      assert {:ok, authority} = Authority.Grant.grant(subject, "touch")

      assert {:ok, first} = call("touch", %{"note" => "before revoke"})
      assert first.status.state == :completed
      assert ActuationCounter.count() == 1

      assert :ok = InMemory.revoke(authority, ctx.broker_opts)

      assert {:ok, after_revoke} = call("touch", %{"note" => "after revoke"})
      assert after_revoke.status.state == :failed
      assert ActuationCounter.count() == 1
    end
  end

  describe "(c) :observe is unaffected by the grant decision" do
    test "an ungranted authenticated principal can still call an :observe skill", ctx do
      subject = AshA2A.Identity.principal(@principal)
      refute InMemory.granted?(subject, "peek", ctx.broker_opts)

      assert {:ok, task} = call("peek")
      assert task.status.state == :completed

      assert [%A2A.Artifact{parts: [%A2A.Part.Data{data: %{peeked: true}}]}] = task.artifacts
    end
  end

  describe "(d) replay still works for an authenticated, granted caller" do
    test "the same real message sent twice replays instead of double-actuating" do
      subject = AshA2A.Identity.principal(@principal)
      assert {:ok, %Authority{}} = Authority.Grant.grant(subject, "touch")

      message =
        data_message(%{"note" => "retry-me"}, %{
          metadata: %{skill: "touch"},
          message_id: "grant-replay-stable-id-1"
        })

      assert {:ok, first} =
               GrantProbeAgent.call(
                 GrantProbeAgent,
                 message,
                 authenticated_call_opts(@principal)
               )

      assert first.status.state == :completed
      assert ActuationCounter.count() == 1

      # A genuine client retry: identical message_id, identical semantic
      # content. `AshA2A.Command.fingerprint/1` hashes the authority's
      # `token_id`, so this only replays if the grant decision produced the
      # SAME deterministic token_id on both dispatches -- the exact
      # regression `AshA2A.Authority.from_verified_identity/2`'s
      # deterministic-token_id comment documents.
      assert {:ok, second} =
               GrantProbeAgent.call(
                 GrantProbeAgent,
                 message,
                 authenticated_call_opts(@principal)
               )

      assert second.status.state == :completed

      # The real proof of replay: the action body ran exactly ONCE across two
      # dispatches, and the second reply carries the first receipt's own
      # recorded output. Compared at the `A2A.Part.Data` payload level rather
      # than on the whole `A2A.Artifact`: `artifact_id` is freshly generated
      # by `A2A` every time a reply is wrapped into an artifact and is not
      # part of the replay contract (verified by running this assertion both
      # ways -- the payloads match exactly, only the wrapper ids differ).
      assert ActuationCounter.count() == 1

      assert [%A2A.Artifact{parts: [%A2A.Part.Data{data: first_data}]}] = first.artifacts
      assert [%A2A.Artifact{parts: [%A2A.Part.Data{data: second_data}]}] = second.artifacts
      assert first_data == second_data
      assert first_data == %{actuated: true, note: "retry-me"}
    end

    test "the grant decision itself is idempotent: same deterministic token_id every call" do
      subject = AshA2A.Identity.principal(@principal)
      assert {:ok, %Authority{}} = Authority.Grant.grant(subject, "touch")

      first = Authority.Grant.authorize(@principal, "touch")
      second = Authority.Grant.authorize(@principal, "touch")

      assert %Authority{} = first
      assert first.token_id == second.token_id
      assert first.token_id == AshA2A.Identity.runtime(Authority.grant_token_id(subject, "touch"))
    end
  end

  describe "legacy :transport_verified_grants_capability policy" do
    setup do
      Application.put_env(:ash_a2a, :authority_policy, :transport_verified_grants_capability)
      :ok
    end

    test "preserves the pre-fix behavior verbatim, for callers that opt in explicitly" do
      assert {:ok, task} = call("touch", %{"note" => "legacy"})
      assert task.status.state == :completed
      assert ActuationCounter.count() == 1
    end
  end
end
