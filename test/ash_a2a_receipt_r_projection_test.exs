defmodule AshA2A.ReceiptRProjectionTest do
  @moduledoc """
  `AshA2A.Receipt.RProjection` audited against REAL receipts only.

  Every receipt projected here was produced by the real `AshA2A.CommandBus`
  dispatching into real fixture Ash resources over real stores (an on-disk
  `AshA2A.ReceiptStore.Ekv` for the durable path, `AshA2A.ReceiptStore.Memory`
  for the dishonesty guard), or by the real `AshA2A.Receipt` production
  constructors (`from_reply/5`, `pending/4`, `finalize/2`, `reconcile/2`,
  `compensate/2`, `mark_unknown_outcome/2`). No doubles anywhere in this
  file, per the Chicago-style testing discipline.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard

  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Authority, Command, CommandBus, Identity, Receipt, SemanticSubject}
  alias AshA2A.Identity.Canonical
  alias AshA2A.Receipt.RProjection
  alias AshA2A.ReceiptStore.{Ekv, Memory}
  alias AshA2A.Test.Fixture.{Crashy, Echo, Item}

  # Caller-supplied git anchors, pattern-validated only: the projector runs
  # no git, so these are plain constants the caller (this test) asserts are
  # the verified clean-tree HEAD of the anchor repo.
  @repo "/Users/sac/ash_a2a"
  @subject_sha String.duplicate("a", 40)
  @base_sha String.duplicate("b", 40)

  setup do
    Application.put_env(:ash_a2a, :receipt_commit_retry_delays_ms, [1, 1])
    on_exit(fn -> Application.delete_env(:ash_a2a, :receipt_commit_retry_delays_ms) end)
    :ok
  end

  # ---------------------------------------------------------------------
  # Real collaborators
  # ---------------------------------------------------------------------

  defp start_ekv_store! do
    ekv_name = :"r_projection_ekv_#{System.unique_integer([:positive])}"

    data_dir =
      Path.join(File.cwd!(), "tmp_r_projection_ekv_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(data_dir) end)

    # A real, on-disk EKV instance (the `:ekv` hex library's GenServer), the
    # exact same real-local-EKV pattern as
    # `test/ash_a2a/receipt_store_ekv_test.exs:36` -- `AshA2A.ReceiptStore.Ekv`
    # is a behaviour module over it, keyed by this name.
    start_supervised!({EKV, name: ekv_name, data_dir: data_dir, cluster_size: 1})
    [name: ekv_name]
  end

  defp start_memory_store! do
    name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    start_supervised!({Memory, name: name})
    [name: name]
  end

  defp digest(seed),
    do: "sha256:" <> (seed |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower))

  defp anchors(extra \\ []) do
    Keyword.merge(
      [repo: @repo, subject_sha: @subject_sha, base_sha: @base_sha],
      extra
    )
  end

  defp observe_command(command_id) do
    Command.new("AshA2A.Test.Fixture.Echo.read",
      command_id: command_id,
      agent_id: "agent-rproj",
      principal_id: "anonymous",
      input: %{}
    )
  end

  defp change_command(command_id, extra \\ []) do
    principal = Identity.principal("subject-rproj")
    capability = "AshA2A.Test.Fixture.Item.create"

    authority =
      Authority.new(principal, capability,
        token_id: "auth-#{command_id}",
        constraints: %{external_idempotency_token: "idem-#{command_id}"}
      )

    {:ok, subject} =
      SemanticSubject.new(
        graph_digest: digest("graph-rproj"),
        projection_digest: digest("projection-rproj"),
        manufacturer_digest: digest("manufacturer-rproj")
      )

    Command.new(capability,
      command_id: command_id,
      agent_id: "agent-rproj",
      principal_id: principal,
      authority: authority,
      semantic_subject: subject,
      input: %{label: "widget-#{command_id}"},
      metadata: Keyword.get(extra, :metadata, %{})
    )
  end

  # ---------------------------------------------------------------------
  # ALIVE over a real durable store
  # ---------------------------------------------------------------------

  describe "ALIVE over a real durable EKV store" do
    test "a real CommandBus run over real on-disk EKV projects ALIVE with exit 0" do
      store_opts = start_ekv_store!()

      assert {:ok, receipt} =
               CommandBus.run(
                 change_command("rproj-alive-1"),
                 data_message(%{"label" => "widget-rproj-alive-1"}),
                 Item,
                 store: Ekv,
                 store_opts: store_opts,
                 plan_digest: digest("plan-rproj")
               )

      assert receipt.terminal_status == :executed
      assert receipt.standing == :durable

      assert {:ok, r} = RProjection.project(receipt, anchors(work_order_id: "WO-RPROJ-1"))

      # Standing: ALIVE, monotone in the evidence, no broken term.
      assert r["standing"]["value"] == "ALIVE"
      refute Map.has_key?(r["standing"], "broken_term")
      assert r["standing"]["derived_from"] =~ "AshA2A.Test.Fixture.Item.create"
      assert r["standing"]["derived_from"] =~ @subject_sha

      # The exit gate and the one replay command.
      assert r["replay"]["commands"] == [
               %{"cmd" => "AshA2A.Test.Fixture.Item.create", "cwd" => @repo, "exit" => 0}
             ]

      assert r["replay"]["durable_location"] == "ash_a2a:receipt:" <> Identity.external(receipt.receipt_id)

      # Identity: caller-supplied anchors echoed, receipt-carried digests projected.
      assert r["identity"]["subject"] == "WO-RPROJ-1"
      assert r["identity"]["repo"] == @repo
      assert r["identity"]["subject_sha"] == @subject_sha
      assert r["identity"]["base_sha"] == @base_sha
      assert r["identity"]["graph_hash"] == receipt.semantic_subject.graph_digest
      assert r["identity"]["subject_digest"] == %{
               "algorithm" => "sha256",
               "value" => String.slice(receipt.input_digest, -64, 64)
             }

      # Authority: the receipt's own grant; the ceiling is the fixed map.
      assert r["authority"]["ceiling"] == "CONSTRUCT"
      assert r["authority"]["grant"] == "runtime:auth-rproj-alive-1"
      assert r["origin_authority"] == r["authority"]
      assert r["provider"] == %{
               "name" => "ash_a2a",
               "authority_ceiling" => "CONSTRUCT",
               "receipt_protocol" => "RFC-SA2A-001 S31"
             }

      assert r["provider_execution_id"] == Identity.external(receipt.execution_id)

      # Consequence: a receipt never claims commits; nothing changed on disk.
      assert r["consequence"]["commits"] == []
      assert r["consequence"]["files_changed"] == []
      assert r["consequence"]["remote_effects"] == []

      # Replay binding: real actuation + command identities and the real head link.
      assert r["replay_binding"]["event_ids"] == [
               Identity.external(receipt.actuation_id),
               Identity.external(receipt.command_id)
             ]

      assert r["replay_binding"]["chain_head_hash"] ==
               List.last(receipt.binding.links).digest

      # The sealed self-digest recomputes exactly.
      ext = r["provider_ext.ash_a2a"]
      assert ext["self_digest"] =~ ~r/\Asha256:[0-9a-f]{64}\z/
      assert ext["input_digest"] == receipt.input_digest
      assert ext["plan_digest"] == digest("plan-rproj")

      without_self =
        Map.put(Map.delete(r, "provider_ext.ash_a2a"), "provider_ext.ash_a2a", Map.delete(ext, "self_digest"))

      assert {:ok, recomputed} = Canonical.digest(without_self)
      assert recomputed == ext["self_digest"]

      # subject_before/subject_after are OMITTED, never fabricated.
      refute Map.has_key?(r, "subject_before")
      refute Map.has_key?(r, "subject_after")
    end

    test "the dishonesty guard: the same command over Memory refuses rather than claiming durability" do
      store_opts = start_memory_store!()

      assert {:ok, receipt} =
               CommandBus.run(change_command("rproj-dishonest-1"),
                 data_message(%{"label" => "widget-rproj-dishonest-1"}),
                 Item,
                 store_opts: store_opts,
                 plan_digest: digest("plan-rproj")
               )

      # The real Memory store never upgrades standing (an in-process Map is
      # lost on restart), so the executed receipt honestly refuses to project.
      assert receipt.terminal_status == :executed
      assert receipt.standing == :observed

      assert {:error, %{code: :r_projection_standing_not_durable}} =
               RProjection.project(receipt, anchors(work_order_id: "WO-RPROJ-2"))
    end

    test "an :observed reconciled receipt refuses exactly like an :observed executed one" do
      store_opts = start_memory_store!()

      assert {:ok, executed} =
               CommandBus.run(observe_command("rproj-reconcile-obs-1"), data_message(%{}), Echo,
                 store_opts: store_opts
               )

      reconciled = Receipt.reconcile(executed, %{source: :test})

      assert {:error, %{code: :r_projection_standing_not_durable}} =
               RProjection.project(reconciled, anchors(work_order_id: "WO-RPROJ-3"))
    end
  end

  # ---------------------------------------------------------------------
  # Ceiling map (no caller override)
  # ---------------------------------------------------------------------

  describe "ceiling map" do
    test "real Echo.read projects OBSERVE, real Item.create projects CONSTRUCT" do
      store_opts = start_ekv_store!()

      assert {:ok, echo_receipt} =
               CommandBus.run(observe_command("rproj-ceil-observe"), data_message(%{}), Echo,
                 store: Ekv,
                 store_opts: store_opts
               )

      assert {:ok, r} = RProjection.project(echo_receipt, anchors(work_order_id: "WO-CEIL-1"))
      assert r["authority"]["ceiling"] == "OBSERVE"
      assert r["provider"]["authority_ceiling"] == "OBSERVE"
      assert r["consequence"]["remote_effects"] == []
      assert r["replay"]["commands"] == [
               %{"cmd" => "AshA2A.Test.Fixture.Echo.read", "cwd" => @repo, "exit" => 0}
             ]

      # No semantic subject was bound to the observe command, so no graph hash
      # is fabricated and no subject digest rides on a missing input digest.
      refute Map.has_key?(r["identity"], "graph_hash")

      assert {:ok, item_receipt} =
               CommandBus.run(change_command("rproj-ceil-construct"),
                 data_message(%{"label" => "widget-rproj-ceil-construct"}),
                 Item,
                 store: Ekv,
                 store_opts: store_opts
               )

      assert {:ok, r} = RProjection.project(item_receipt, anchors(work_order_id: "WO-CEIL-2"))
      assert r["authority"]["ceiling"] == "CONSTRUCT"
      assert r["consequence"]["remote_effects"] == []
      assert r["standing"]["value"] == "ALIVE"
    end

    test "external DO via the real production constructors projects the DO ceiling" do
      start_ekv_store!()

      # The durable standing below mirrors `AshA2A.CommandBus.mark_standing/2`
      # exactly -- a plain struct update gated on the store's real
      # `durable?/0` -- because what is under test here is the ceiling map,
      # not the durability machinery (that is the ALIVE test above, which
      # proves it end to end through real `CommandBus.run/4`).
      assert Ekv.durable?()

      command = change_command("rproj-ceil-do")
      execution_id = Identity.execution("rproj-ceil-do-exec")

      receipt =
        command
        |> Receipt.pending(execution_id, :external_do, [])
        |> Receipt.finalize({:reply, %{"ok" => true}})
        |> then(fn receipt -> %{receipt | standing: :durable} end)

      assert receipt.terminal_status == :executed

      assert {:ok, r} = RProjection.project(receipt, anchors(work_order_id: "WO-CEIL-3"))

      assert r["authority"]["ceiling"] == "DO"
      assert r["provider"]["authority_ceiling"] == "DO"
      assert r["consequence"]["remote_effects"] == [command.capability_id]
      assert r["standing"]["value"] == "ALIVE"
      assert r["replay"]["commands"] == [
               %{"cmd" => "AshA2A.Test.Fixture.Item.create", "cwd" => @repo, "exit" => 0}
             ]
    end

    test "an :unknown consequence refuses instead of guessing a ceiling" do
      start_memory_store!()

      receipt =
        Receipt.from_reply(
          observe_command("rproj-ceil-unknown"),
          Identity.execution("rproj-ceil-unknown-exec"),
          :unknown,
          {:reply, "mystery"}
        )

      assert {:error, %{code: :r_projection_consequence_unknown, detail: %{observed: :unknown}}} =
               RProjection.project(receipt, anchors(work_order_id: "WO-CEIL-4"))
    end
  end

  # ---------------------------------------------------------------------
  # Standing table
  # ---------------------------------------------------------------------

  describe "standing table" do
    test "a real pre-DO refusal projects REFUSED(<code>) with the mapped broken term" do
      receipt =
        Receipt.from_reply(
          change_command("rproj-refused-1"),
          Identity.execution("rproj-refused-1-exec"),
          :change,
          {:error, %{code: :authority_required}}
        )

      assert receipt.terminal_status == :refused

      assert {:ok, r} = RProjection.project(receipt, anchors(work_order_id: "WO-REFUSED-1"))

      assert r["standing"]["value"] == "REFUSED(authority_required)"
      assert r["standing"]["broken_term"] == "R_missing_authority"
      assert r["replay"]["commands"] == [
               %{"cmd" => "AshA2A.Test.Fixture.Item.create", "cwd" => @repo, "exit" => 1}
             ]

      refute Map.has_key?(r["replay"], "durable_location")

      # Refused before DO: nothing remote is claimed either way.
      assert r["consequence"]["remote_effects"] == []
    end

    test "the remaining pre-DO refusal broken-term map holds: kill switch and admission vacuity" do
      kill_switch =
        Receipt.from_reply(
          change_command("rproj-refused-kill"),
          Identity.execution("rproj-refused-kill-exec"),
          :change,
          {:error, %{code: :kill_switch_tripped}}
        )

      assert {:ok, r} = RProjection.project(kill_switch, anchors(work_order_id: "WO-REFUSED-2"))
      assert r["standing"]["value"] == "REFUSED(kill_switch_tripped)"
      assert r["standing"]["broken_term"] == "mu_unlawful"

      conflict =
        Receipt.from_reply(
          change_command("rproj-refused-conflict"),
          Identity.execution("rproj-refused-conflict-exec"),
          :change,
          {:error, %{code: :command_conflict}}
        )

      assert {:ok, r} = RProjection.project(conflict, anchors(work_order_id: "WO-REFUSED-3"))
      assert r["standing"]["value"] == "REFUSED(command_conflict)"
      assert r["standing"]["broken_term"] == "admission_vacuous"
    end

    test "a real dispatch crash projects BUILD_BROKEN with R_missing_consequence" do
      store_opts = start_memory_store!()

      command =
        Command.new("AshA2A.Test.Fixture.Crashy.detonate",
          command_id: "rproj-crashy-1",
          agent_id: "agent-rproj",
          principal_id: "anonymous",
          input: %{}
        )

      assert {:ok, receipt} =
               CommandBus.run(command, data_message(%{}), Crashy, store_opts: store_opts)

      assert receipt.terminal_status == :failed
      assert {:error, %{code: :dispatch_crashed}} = receipt.reply

      assert {:ok, r} = RProjection.project(receipt, anchors(work_order_id: "WO-CRASHY-1"))

      assert r["standing"]["value"] == "BUILD_BROKEN"
      assert r["standing"]["broken_term"] == "R_missing_consequence"
      assert r["replay"]["commands"] == [
               %{"cmd" => "AshA2A.Test.Fixture.Crashy.detonate", "cwd" => @repo, "exit" => 1}
             ]
    end

    test "a really compensated actuation projects PARTIAL_ALIVE with no broken term" do
      store_opts = start_memory_store!()

      assert {:ok, executed} =
               CommandBus.run(observe_command("rproj-compensated-1"), data_message(%{}), Echo,
                 store_opts: store_opts
               )

      compensated = Receipt.compensate(executed, %{reversal_receipt_id: "runtime:rev-rproj-1"})

      assert compensated.terminal_status == :compensated

      assert {:ok, r} =
               RProjection.project(compensated, anchors(work_order_id: "WO-COMPENSATED-1"))

      assert r["standing"]["value"] == "PARTIAL_ALIVE"
      refute Map.has_key?(r["standing"], "broken_term")
      assert r["replay"]["commands"] == [
               %{"cmd" => "AshA2A.Test.Fixture.Echo.read", "cwd" => @repo, "exit" => 1}
             ]
    end

    test "unknown outcome and pending project UNKNOWN" do
      store_opts = start_memory_store!()

      assert {:ok, executed} =
               CommandBus.run(observe_command("rproj-unknown-1"), data_message(%{}), Echo,
                 store_opts: store_opts
               )

      unknown = Receipt.mark_unknown_outcome(executed, :post_do_crash_window)

      assert {:ok, r} = RProjection.project(unknown, anchors(work_order_id: "WO-UNKNOWN-1"))
      assert r["standing"]["value"] == "UNKNOWN"
      refute Map.has_key?(r["standing"], "broken_term")

      pending = Receipt.pending(change_command("rproj-pending-1"), Identity.execution("rproj-pending-1-exec"), :change)

      assert pending.terminal_status == nil

      assert {:ok, r} = RProjection.project(pending, anchors(work_order_id: "WO-PENDING-1"))
      assert r["standing"]["value"] == "UNKNOWN"
      assert r["replay"]["commands"] == [
               %{"cmd" => "AshA2A.Test.Fixture.Item.create", "cwd" => @repo, "exit" => 1}
             ]
    end

    test "a reconciled durable outcome projects ALIVE with exit 0" do
      store_opts = start_ekv_store!()

      assert {:ok, executed} =
               CommandBus.run(observe_command("rproj-reconciled-1"), data_message(%{}), Echo,
                 store: Ekv,
                 store_opts: store_opts
               )

      reconciled = Receipt.reconcile(executed, %{source: :test})
      assert reconciled.terminal_status == :reconciled
      assert reconciled.standing == :durable

      assert {:ok, r} = RProjection.project(reconciled, anchors(work_order_id: "WO-RECONCILED-1"))

      assert r["standing"]["value"] == "ALIVE"
      assert r["replay"]["commands"] == [
               %{"cmd" => "AshA2A.Test.Fixture.Echo.read", "cwd" => @repo, "exit" => 0}
             ]

      assert r["replay_binding"]["chain_head_hash"] ==
               List.last(reconciled.binding.links).digest
    end
  end

  # ---------------------------------------------------------------------
  # Fail-closed preconditions
  # ---------------------------------------------------------------------

  describe "anchors fail closed" do
    test "missing anchors refuse :r_projection_anchor_missing" do
      receipt = refused_receipt("rproj-anchor-missing")

      assert {:error, %{code: :r_projection_anchor_missing}} = RProjection.project(receipt, [])
      assert {:error, %{code: :r_projection_anchor_missing, detail: %{field: :base_sha}}} =
               RProjection.project(receipt, repo: @repo, subject_sha: @subject_sha)

      assert {:error, %{code: :r_projection_anchor_missing, detail: %{field: :subject_sha}}} =
               RProjection.project(receipt, repo: @repo)
    end

    test "malformed anchors refuse :r_projection_anchor_malformed" do
      receipt = refused_receipt("rproj-anchor-malformed")

      assert {:error, %{code: :r_projection_anchor_malformed, detail: %{field: :subject_sha}}} =
               RProjection.project(receipt, anchors(subject_sha: String.duplicate("a", 39)))

      assert {:error, %{code: :r_projection_anchor_malformed, detail: %{field: :subject_sha}}} =
               RProjection.project(
                 receipt,
                 anchors(subject_sha: String.upcase(String.duplicate("a", 40)))
               )

      assert {:error, %{code: :r_projection_anchor_malformed, detail: %{field: :subject_sha}}} =
               RProjection.project(receipt, anchors(subject_sha: "sha256:" <> String.duplicate("a", 40)))

      assert {:error, %{code: :r_projection_anchor_malformed, detail: %{field: :base_sha}}} =
               RProjection.project(receipt, anchors(base_sha: String.duplicate("c", 39)))

      # An empty string is an absent anchor, not a present-but-malformed one.
      assert {:error, %{code: :r_projection_anchor_missing, detail: %{field: :repo, observed: ""}}} =
               RProjection.project(receipt, anchors(repo: ""))
    end
  end

  describe "receipt shape and binding fail closed" do
    test "a non-receipt refuses :r_projection_receipt_required" do
      assert {:error, %{code: :r_projection_receipt_required}} =
               RProjection.project(%{}, anchors(work_order_id: "WO-NONE"))
    end

    test "a tampered receipt refuses :r_projection_binding_unverified" do
      store_opts = start_memory_store!()

      assert {:ok, executed} =
               CommandBus.run(observe_command("rproj-tamper-1"), data_message(%{}), Echo,
                 store_opts: store_opts
               )

      tampered = %{executed | input_digest: digest("tampered")}

      assert {:error, %{code: :r_projection_binding_unverified, detail: %{refused: :receipt_binding_field_mismatch}}} =
               RProjection.project(tampered, anchors(work_order_id: "WO-TAMPER-1"))
    end
  end

  describe "work-order id resolution" do
    test "metadata.work_order_digest wins over the opts fallback" do
      store_opts = start_ekv_store!()

      command = change_command("rproj-wo-meta", metadata: %{work_order_digest: "wo-meta-1"})

      assert {:ok, receipt} =
               CommandBus.run(command,
                 data_message(%{"label" => "widget-rproj-wo-meta"}),
                 Item,
                 store: Ekv,
                 store_opts: store_opts
               )

      assert receipt.metadata.work_order_digest == "wo-meta-1"

      assert {:ok, r} =
               RProjection.project(
                 receipt,
                 anchors(work_order_id: "WO-OPT-FALLBACK")
               )

      assert r["work_order_id"] == "wo-meta-1"
      assert r["identity"]["subject"] == "wo-meta-1"
    end

    test "with no metadata and no opt, the projection refuses" do
      store_opts = start_ekv_store!()

      assert {:ok, receipt} =
               CommandBus.run(observe_command("rproj-wo-none"), data_message(%{}), Echo,
                 store: Ekv,
                 store_opts: store_opts
               )

      assert {:error, %{code: :r_projection_work_order_unavailable}} =
               RProjection.project(receipt, anchors())
    end
  end

  # ---------------------------------------------------------------------
  # Determinism and totality
  # ---------------------------------------------------------------------

  describe "determinism and the exit gate" do
    test "the same receipt projects byte-identical JSON twice" do
      store_opts = start_ekv_store!()

      assert {:ok, receipt} =
               CommandBus.run(change_command("rproj-determinism-1"),
                 data_message(%{"label" => "widget-rproj-determinism-1"}),
                 Item,
                 store: Ekv,
                 store_opts: store_opts
               )

      opts = anchors(work_order_id: "WO-DET-1", transport: "jsonrpc")

      assert {:ok, r1} = RProjection.project(receipt, opts)
      assert {:ok, r2} = RProjection.project(receipt, opts)

      assert JSON.encode!(r1) == JSON.encode!(r2)

      # The transport opt rides through provider.
      assert r1["provider"]["transport"] == "jsonrpc"
    end

    test "exit == 0 iff ALIVE, and commits are always [], over every projectable terminal shape" do
      ekv = start_ekv_store!()
      memory = start_memory_store!()

      assert {:ok, alive} =
               CommandBus.run(observe_command("rproj-totality-alive"), data_message(%{}), Echo,
                 store: Ekv,
                 store_opts: ekv
               )

      reconciled = Receipt.reconcile(alive, %{source: :test})

      refused =
        Receipt.from_reply(
          change_command("rproj-totality-refused"),
          Identity.execution("rproj-totality-refused-exec"),
          :change,
          {:error, %{code: :authority_required}}
        )

      assert {:ok, crashy} =
               CommandBus.run(
                 Command.new("AshA2A.Test.Fixture.Crashy.detonate",
                   command_id: "rproj-totality-crashy",
                   agent_id: "agent-rproj",
                   principal_id: "anonymous",
                   input: %{}
                 ),
                 data_message(%{}),
                 Crashy,
                 store_opts: memory
               )

      assert {:ok, observed} =
               CommandBus.run(observe_command("rproj-totality-observed"), data_message(%{}), Echo,
                 store_opts: memory
               )

      cases = [
        alive,
        reconciled,
        refused,
        crashy,
        Receipt.compensate(observed, %{reversal_receipt_id: "runtime:rev-t"}),
        Receipt.mark_unknown_outcome(observed, :post_do_crash_window),
        Receipt.pending(change_command("rproj-totality-pending"), Identity.execution("rproj-totality-pending-exec"), :change)
      ]

      projections =
        Enum.map(cases, fn receipt ->
          assert {:ok, r} = RProjection.project(receipt, anchors(work_order_id: "WO-TOTALITY"))
          r
        end)

      for r <- projections do
        # Totality: the exit gate is exactly the ALIVE gate.
        assert [%{"exit" => exit}] = r["replay"]["commands"]
        assert (exit == 0) == (r["standing"]["value"] == "ALIVE")

        # ...and never a commit a receipt did not make.
        assert r["consequence"]["commits"] == []
        assert length(r["replay"]["commands"]) == 1
      end

      assert hd(projections)["standing"]["value"] == "ALIVE"
      assert Enum.at(projections, 1)["standing"]["value"] == "ALIVE"
      assert Enum.at(projections, 2)["standing"]["value"] == "REFUSED(authority_required)"
      assert Enum.at(projections, 3)["standing"]["value"] == "BUILD_BROKEN"
      assert Enum.at(projections, 4)["standing"]["value"] == "PARTIAL_ALIVE"
      assert Enum.at(projections, 5)["standing"]["value"] == "UNKNOWN"
      assert Enum.at(projections, 6)["standing"]["value"] == "UNKNOWN"
    end
  end

  # ---------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------

  defp refused_receipt(command_id) do
    Receipt.from_reply(
      change_command(command_id),
      Identity.execution("#{command_id}-exec"),
      :change,
      {:error, %{code: :authority_required}}
    )
  end
end
