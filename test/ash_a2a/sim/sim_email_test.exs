# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Sim.EmailTest do
  @moduledoc """
  The simulation server mirrors the email surface of ash_a2a
  (`AshA2A.Email.Plug`, DKIM, the durable replay ledger) and proves it over
  the real wire.

    * MIRROR: every email route and outcome is a surface item with a probe and
      an MCP plan.
    * WIRE: each outcome runs against a real `AshA2A.Sim.Server` (a real HTTP
      POST to the mounted plug, real RSA-signed mail, an EKV-backed ledger) and
      the Ash row is read back: an approved reply creates it, every refusal
      leaves the rows as they were.
    * SIGNER: the mail the sim signs verifies under `AshA2A.Email.Dkim` with
      the published `p=` key, and fails after one byte changes.
    * MCP: the email tools drive the same flows.
  """

  use ExUnit.Case, async: false

  alias AshA2A.Sim.{Email, Prover, Server, Surface}
  alias AshA2A.Sim.MCP.{Coverage, Tools}

  @moduletag timeout: 240_000
  @moduletag capture_log: true

  setup_all do
    {:ok, server} = Server.start_link()
    on_exit(fn -> if Process.alive?(server), do: Server.stop(server) end)
    {:ok, info: Server.info()}
  end

  defp tool!(info, name, args) do
    assert {:ok, result} = Tools.call(name, args, %{info: info})
    result
  end

  describe "mirror" do
    test "every email route and outcome is a surface item with a probe and an MCP plan" do
      email_ids = Enum.map(Email.surface_items(), & &1.id)
      assert length(email_ids) == length(Email.routes()) + length(Email.outcomes())
      assert Enum.all?(email_ids, &(&1 in Surface.ids()))

      probed = MapSet.new(Prover.probes(), & &1.surface)
      assert Enum.reject(email_ids, &MapSet.member?(probed, &1)) == []

      uncovered = Enum.map(Coverage.uncovered(), & &1.id)
      assert Enum.filter(uncovered, &String.starts_with?(&1, "email_")) == []
    end

    test "the outcomes name the refusals the library documents" do
      names = Enum.map(Email.outcomes(), & &1.name)

      for required <-
            ~w(approved_reply_dispatched replay_returns_cached_result tampered_body_refused
               forged_webhook_auth_refused dkim_length_limit_refused from_misaligned_refused
               approver_binding_refused oversized_body_refused deeply_nested_body_refused
               stale_graph_digest_refused rate_limited) do
        assert required in names
      end
    end
  end

  describe "wire" do
    for outcome <- AshA2A.Sim.Email.outcomes() do
      @outcome outcome.name
      test "#{outcome.name}", %{info: info} do
        result = Email.run(info, @outcome)
        assert {:ok, _detail} = Email.evaluate(@outcome, result)
      end
    end

    test "an approved reply changes exactly the row it names; the unapproved action does not run",
         %{
           info: info
         } do
      brief = Email.issue_brief()
      title = brief["title"]
      assert Email.row(title) == nil

      r = Email.send_reply(info, brief, text: "Approve 1.")
      assert r.status == 200
      assert r.added == [title]
      assert %{title: ^title} = Email.row(title)
      refute title in AshA2A.Sim.Note.publications()
    end

    test "replay returns the cached body with replayed: true and runs nothing", %{info: info} do
      brief = Email.issue_brief()
      mid = "replay-test-#{System.unique_integer([:positive])}@sim.example"
      first = Email.send_reply(info, brief, message_id: mid)
      second = Email.send_reply(info, brief, message_id: mid)

      assert first.status == 200 and first.landed
      assert second.status == 200 and second.json["replayed"] == true
      assert second.json["results"] == first.json["results"]
      refute second.landed
    end
  end

  describe "signer" do
    test "the signed mail verifies under the published key and fails after one byte changes", %{
      info: _info
    } do
      %{"dkim" => %{"public_key_p" => p}} = Email.facts()

      resolver = fn
        "sim.example", "sim" -> {:ok, p}
        _, _ -> {:error, :nxdomain}
      end

      brief = Email.issue_brief()
      good = Email.build_reply(brief)
      assert :ok = AshA2A.Email.Dkim.verify(good.raw, key_resolver: resolver)

      tampered = Email.build_reply(brief, tamper: :body_byte)

      assert {:error, :body_hash_mismatch} =
               AshA2A.Email.Dkim.verify(tampered.raw, key_resolver: resolver)

      truncated = Email.build_reply(brief, dkim_tags: " l=5;")

      assert {:error, :body_length_limit} =
               AshA2A.Email.Dkim.verify(truncated.raw, key_resolver: resolver)

      misaligned = Email.build_reply(brief, from_domain: "evil.example")

      assert {:error, :from_misaligned} =
               AshA2A.Email.Dkim.verify(misaligned.raw, key_resolver: resolver)
    end
  end

  describe "mcp" do
    test "issue a brief, build and send a signed reply, confirm the row", %{info: info} do
      issued = tool!(info, "sim_email_issue_brief", %{})
      assert issued["dkim"]["domain"] == "sim.example"
      assert issued["ingest_urls"]["ses"] =~ "/email/v1/email:ingest"

      built =
        tool!(info, "sim_email_send_reply", %{
          "brief_id" => issued["brief_id"],
          "build_only" => true
        })

      assert built["raw"] =~ "DKIM-Signature:"

      sent =
        tool!(info, "sim_email_send_reply", %{
          "brief_id" => issued["brief_id"],
          "raw" => built["raw"]
        })

      assert sent["status"] == 200
      assert sent["landed"] == true

      assert sent["json"]["results"] == [
               %{"action" => 1, "receipt" => "recorded", "standing" => "dispatched"}
             ] or
               match?([%{"action" => 1, "standing" => "dispatched"}], sent["json"]["results"])

      assert %{"count" => 1} = tool!(info, "sim_read_rows", %{"title" => issued["title"]})
    end

    test "a tampered reply is refused and the tool reports no row landed", %{info: info} do
      issued = tool!(info, "sim_email_issue_brief", %{})

      sent =
        tool!(info, "sim_email_send_reply", %{
          "brief_id" => issued["brief_id"],
          "tamper" => "body_byte"
        })

      assert sent["status"] == 401
      assert sent["landed"] == false
      assert %{"count" => 0} = tool!(info, "sim_read_rows", %{"title" => issued["title"]})
    end

    test "scenarios answer whether they went as expected; deliveries show the mail", %{info: info} do
      tool!(info, "sim_email_deliveries", %{"reset" => true})

      stale = tool!(info, "sim_email_send_reply", %{"scenario" => "stale_graph_digest_refused"})
      assert stale["as_expected"] == true
      assert stale["status"] == 409

      mail = tool!(info, "sim_email_deliveries", %{})

      assert [%{"subject" => "Reconfirm required", "reconfirm_brief" => %{"brief_id" => _}} | _] =
               mail["deliveries"]

      assert Enum.any?(mail["attempts"], &(&1["status"] == 409))
    end

    test "an unknown brief and an empty request are tool errors", %{info: info} do
      assert {:error, _} =
               Tools.call("sim_email_send_reply", %{"brief_id" => "nope"}, %{info: info})

      assert {:error, _} = Tools.call("sim_email_send_reply", %{}, %{info: info})
    end
  end
end
