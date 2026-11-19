# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Sim.AuthorityTest do
  @moduledoc """
  The authority surface of the simulation server (`AshA2A.Sim.Authority`):

    * every `:authority` surface item has probes and an MCP plan, and the
      probes pass against a real `AshA2A.Sim.Server` over real listeners;
    * the MCP tools that change authority state (`sim_grant_authority` options,
      `sim_trip_kill_switch`, `sim_reset_kill_switch`, `sim_receipts`) do what
      they say on the real wire, and answer what their `outputSchema` declares;
    * the kill switch leaves the host's `:kill_switch_class` as it found it.
  """

  use ExUnit.Case, async: false

  alias AshA2A.Sim.{Authority, Note, Prover, Server, Surface}
  alias AshA2A.Sim.MCP.{AuthorityTools, Coverage, Tools}

  @moduletag timeout: 300_000
  @moduletag capture_log: true

  setup_all do
    {:ok, server} = Server.start_link()
    on_exit(fn -> if Process.alive?(server), do: Server.stop(server) end)
    {:ok, info: Server.info()}
  end

  defp call(info, tool, args) do
    assert {:ok, result} = Tools.call(tool, args, %{info: info, on_frame: fn _ -> :ok end})
    schema = Enum.find(Tools.list(), &(&1["name"] == tool))["outputSchema"]
    assert Tools.validate(schema, result, "result") == [], "#{tool} breaks its outputSchema"
    result
  end

  defp send_create(info, token, title, binding \\ "http_json") do
    call(info, "a2a_send_message", %{
      "binding" => binding,
      "skill" => "create_note",
      "data" => %{"title" => title},
      "token" => token
    })
  end

  describe "the surface" do
    test "every authority item is in the surface, has a probe and has an MCP plan" do
      items = Authority.items()
      assert items != []
      assert Enum.map(items, & &1.id) == Enum.uniq(Enum.map(items, & &1.id))
      assert Enum.all?(items, &(&1 in Surface.items(:authority)))

      probed = MapSet.new(Prover.probes(), & &1.surface)
      refute Enum.any?(items, &(not MapSet.member?(probed, &1.id)))

      assert Coverage.uncovered(items) == []
    end

    test "every consequence class is proven for each outcome it can have" do
      names = Enum.map(Authority.items(), & &1.name)

      for class <- Enum.map(Surface.items(:consequence), & &1.name) do
        assert Enum.any?(names, &String.starts_with?(&1, "outcome:#{class}:")),
               "consequence class #{class} has no outcome item"
      end

      for class <- ["change", "external_do"], outcome <- ["admitted", "refused"] do
        assert "outcome:#{class}:#{outcome}" in names
      end
    end

    test "the lease gate has one item per conjunct of the real gate" do
      conjuncts = Enum.map(AshA2A.Authority.TwoPortGate.conjuncts(), &Atom.to_string(elem(&1, 0)))
      gate = for "two_port_gate:" <> name <- Enum.map(Authority.items(), & &1.name), do: name
      assert Enum.sort(gate) == Enum.sort(conjuncts)
    end
  end

  describe "the probes" do
    test "every authority probe passes over the real wire", %{info: info} do
      results =
        Prover.run(info, only: fn probe -> String.starts_with?(probe.surface, "authority:") end)

      assert length(results) >= length(Authority.items())

      failing = Enum.reject(results, &(&1.status == :pass))

      assert failing == [],
             "authority probes that did not pass:\n" <>
               Enum.map_join(failing, "\n", &"  #{&1.surface} | #{&1.probe}\n      #{&1.detail}")
    end
  end

  describe "sim_grant_authority options" do
    test "a principal and a capability of your own choosing", %{info: info} do
      result =
        call(info, "sim_grant_authority", %{
          "principal" => "someone-else-#{System.unique_integer([:positive])}",
          "capability" => "Some.Other.capability"
        })

      assert result["principal"] =~ "someone-else-"

      assert [%{"capability_id" => "Some.Other.capability", "granted" => true} = grant] =
               result["grants"]

      assert grant["outcome"] == "granted"

      revoked =
        call(info, "sim_revoke_authority", %{
          "principal" => result["principal"],
          "capability" => "Some.Other.capability"
        })

      assert [%{"granted" => false, "outcome" => "revoked"}] = revoked["grants"]
    end

    test "an expiry, a renewal into the past, and a forced second grant", %{info: info} do
      agent = "sim-agent-opts-#{System.unique_integer([:positive])}"
      base = %{"identity" => agent, "skill" => "create_note"}

      granted = call(info, "sim_grant_authority", Map.put(base, "expires_in_seconds", 3600))
      assert [%{"granted" => true, "expires_at" => at}] = granted["grants"]
      assert is_binary(at)

      assert send_create(info, agent, "opts-#{agent}")["state"] == "TASK_STATE_COMPLETED"

      forced = call(info, "sim_grant_authority", Map.put(base, "force", true))
      assert [%{"refusal" => "token_id_taken", "granted" => true}] = forced["grants"]

      renewed = call(info, "sim_grant_authority", Map.put(base, "expires_in_seconds", -60))
      assert [%{"outcome" => "renewed", "granted" => false}] = renewed["grants"]
      assert send_create(info, agent, "opts-late-#{agent}")["state"] == "TASK_STATE_REJECTED"

      call(info, "sim_revoke_authority", base)
    end

    test "an expiry that has already passed is refused on the wire", %{info: info} do
      agent = "sim-agent-past-#{System.unique_integer([:positive])}"

      expired =
        call(info, "sim_grant_authority", %{
          "identity" => agent,
          "skill" => "create_note",
          "expires_in_seconds" => -30
        })

      assert [%{"granted" => false}] = expired["grants"]
      assert send_create(info, agent, "past-#{agent}", "grpc")["state"] == "TASK_STATE_REJECTED"
    end
  end

  describe "the kill switch" do
    test "trip refuses mutating skills on every binding, reset restores the host", %{info: info} do
      previous = Application.fetch_env(:ash_a2a, :kill_switch_class)
      agent = "sim-agent-kill-#{System.unique_integer([:positive])}"
      call(info, "sim_grant_authority", %{"identity" => agent, "skill" => "all"})

      try do
        tripped = call(info, "sim_trip_kill_switch", %{"reason" => "authority test"})
        assert %{"tripped" => true, "reason" => "authority test"} = tripped
        assert tripped["configured_class"] == Authority.kill_switch_class()

        for binding <- ["jsonrpc", "http_json", "grpc"] do
          title = "killed-#{binding}-#{agent}"
          refused = send_create(info, agent, title, binding)
          assert refused["task"] |> Jason.encode!() =~ "kill_switch_tripped"
          assert refused["state"] != "TASK_STATE_COMPLETED"
          assert Note |> Ash.read!(authorize?: false) |> Enum.all?(&(&1.title != title))
        end

        observed =
          call(info, "a2a_send_message", %{
            "binding" => "grpc",
            "skill" => "count_notes",
            "token" => agent
          })

        assert observed["state"] == "TASK_STATE_COMPLETED"

        reset = call(info, "sim_reset_kill_switch", %{})
        assert %{"tripped" => false, "outcome" => "reset"} = reset
        assert Application.fetch_env(:ash_a2a, :kill_switch_class) == previous

        assert send_create(info, agent, "resumed-#{agent}")["state"] == "TASK_STATE_COMPLETED"
      after
        _ = Authority.reset_kill_switch()
        call(info, "sim_revoke_authority", %{"identity" => agent, "skill" => "all"})
      end
    end

    test "a tripped class that is not reset by the operator's authority stays tripped" do
      try do
        :ok = Authority.trip_kill_switch("some_other_class", "authority test")

        stranger = AshA2A.Identity.principal("someone")

        authority =
          AshA2A.Authority.new(
            stranger,
            AshA2A.KillSwitch.reset_capability_id("some_other_class")
          )

        operator = AshA2A.Identity.principal("not-the-holder")

        assert {:error, :authority_mismatch} =
                 AshA2A.KillSwitch.reset("some_other_class", authority, operator)

        assert {true, "authority test"} = Authority.kill_switch_state("some_other_class")
      after
        _ = Authority.reset_kill_switch("some_other_class")
      end

      assert Authority.kill_switch_state("some_other_class") == false
    end
  end

  describe "sim_receipts" do
    test "a performed effect has a verifying receipt; an observe call and a refusal have none", %{
      info: info
    } do
      agent = "sim-agent-receipt-#{System.unique_integer([:positive])}"
      call(info, "sim_grant_authority", %{"identity" => agent, "skill" => "create_note"})
      message = "msg-test-receipt-#{agent}"

      sent =
        call(info, "a2a_send_message", %{
          "binding" => "grpc",
          "skill" => "create_note",
          "data" => %{"title" => "receipt-#{agent}"},
          "token" => agent,
          "message_id" => message
        })

      assert sent["state"] == "TASK_STATE_COMPLETED"

      assert %{"found" => true, "receipt" => receipt} =
               call(info, "sim_receipts", %{"message_id" => message})

      assert receipt["consequence"] == "change"
      assert receipt["terminal_status"] == "executed"
      assert receipt["binding_verified"] == true
      assert receipt["binding_links"] >= 1

      refused_message = "msg-test-refused-#{agent}"
      call(info, "sim_revoke_authority", %{"identity" => agent, "skill" => "create_note"})

      refused =
        call(info, "a2a_send_message", %{
          "binding" => "http_json",
          "skill" => "create_note",
          "data" => %{"title" => "refused-#{agent}"},
          "token" => agent,
          "message_id" => refused_message
        })

      assert refused["state"] == "TASK_STATE_REJECTED"

      assert %{"found" => false, "receipt" => nil} =
               call(info, "sim_receipts", %{"message_id" => refused_message})
    end

    test "the tools are in the catalog with the schemas the driver checks" do
      names = Tools.names()

      for tool <- ["sim_trip_kill_switch", "sim_reset_kill_switch", "sim_receipts"],
          do: assert(tool in names)

      assert Enum.map(AuthorityTools.list(), & &1["name"]) -- names == []
      assert Enum.all?(AuthorityTools.list(), &is_map(&1["outputSchema"]))
    end
  end

  describe "the revoking broker" do
    test "unarmed it answers as the in-memory broker, armed it withdraws the grant after one answer" do
      alias AshA2A.Sim.Authority.RevokingBroker
      subject = AshA2A.Identity.principal("revoking-#{System.unique_integer([:positive])}")
      capability = "AshA2A.Sim.Note.create"

      {:ok, _authority} = AshA2A.Authority.Grant.grant(subject, capability)
      assert RevokingBroker.granted?(subject, capability, [])

      RevokingBroker.arm(subject, 1)
      assert RevokingBroker.granted?(subject, capability, [])
      refute RevokingBroker.granted?(subject, capability, [])
      RevokingBroker.disarm(subject)
      assert RevokingBroker.granted?(subject, capability, [])

      AshA2A.Authority.Grant.revoke(subject, capability)
    end
  end
end
