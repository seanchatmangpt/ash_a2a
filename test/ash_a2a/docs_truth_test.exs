# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.DocsTruthTest do
  @moduledoc """
  Chicago court: `docs/reference/configuration.md` may not state a default for
  a key that differs from the default the code actually applies.

  Oracle independence: the documented value is parsed from the markdown text;
  the code-side value is observed by running the real public entry point with
  the application-env key deleted, never by re-reading the doc or a copied
  constant. DB-free; no mocks. The env is mutated, so this module is
  `async: false` and restores it on exit.

  v26.10.2 (RD1): every documented default row is either verified by an
  execution oracle (`@execution_oracles`) or explicitly allowlisted with a
  reason (`@documented_not_executable`) — a literal default cell with neither
  is a court failure. Rows whose default cell starts with `—` state no
  literal default and are exempt by construction.

  Also executes the README's usage examples against real fixtures (RD5):
  the declared DSL compiles and the documented dispatch result is real.
  """

  use ExUnit.Case, async: false

  alias AshA2A.{Authority, CapabilityRelease, CommandBus}

  @doc_path Path.expand("../../docs/reference/configuration.md", __DIR__)
  @readme_path Path.expand("../../README.md", __DIR__)

  # key => {shape, {module, fun, args}}; the oracle runs with the key's env
  # deleted, so it observes the code default, not the config.
  @execution_oracles %{
    :actuation_dedup => {:inspect, {CommandBus, :actuation_dedup_mode, [[]]}},
    :capability_release_mode => {:special, :capability_release_mode},
    :authority_policy => {:special, :authority_policy},
    :agents => {:inspect, {AshA2A.Application, :agents, []}},
    :env => {:inspect, {AshA2A.Application, :env, []}},
    :require_durable_receipts => {:inspect, {AshA2A.Application, :require_durable_receipts?, []}},
    :dispatch_timeout_ms => {:inspect, {CommandBus, :dispatch_timeout_ms, [[]]}},
    :durable_server_provider => {:inspect, {AshA2A.Durability.DurableServer, :provider, []}},
    :ocel_max_in_flight => {:inspect, {AshA2A.Telemetry.OcelForwarder, :max_in_flight, []}},
    :ocel_ingest_timeout_ms => {:inspect, {AshA2A.Telemetry.OcelForwarder, :ingest_timeout_ms, []}},
    :ocel_log_body => {:inspect, {AshA2A.Telemetry.OcelForwarder, :log_body?, []}},
    :ocel_log_interval_ms => {:inspect, {AshA2A.Telemetry.OcelForwarder, :log_interval_ms, []}},
    :ocel_task_supervisor => {:inspect, {AshA2A.Telemetry.OcelForwarder, :task_supervisor, []}},
    :expose_error_detail => {:inspect, {AshA2A.Transport.SafeError, :expose_detail?, []}},
    :outbox_reconciler_interval_ms => {:inspect, {AshA2A.ReceiptOutbox.Reconciler, :interval_ms, []}},
    :outbox_stuck_attempts_threshold => {:inspect, {AshA2A.ReceiptOutbox.Reconciler, :stuck_attempts_threshold, []}},
    :outbox_ready_max => {:inspect, {AshA2A.Health, :outbox_ready_max, []}},
    :hddl_timeout_ms => {:inspect, {AshA2A.Planning.HddlSolver, :timeout_ms, []}},
    :hddl_max_output_bytes => {:inspect, {AshA2A.Planning.HddlSolver, :max_output_bytes, []}},
    :graphlaw_max_queue => {:inspect, {AshA2A.GraphLaw.WasmexHost, :max_queue, []}},
    :graphlaw_subprocess_timeout_ms => {:inspect, {AshA2A.GraphLaw.Subprocess, :timeout_ms, []}},
    :health_kill_switch_classes => {:inspect, {AshA2A.Health, :health_kill_switch_classes, []}},
    :receipt_commit_retry_delays_ms => {:inspect, {CommandBus, :receipt_commit_retry_delays_ms, []}},
    :kill_switch_class => {:inspect, {CommandBus, :kill_switch_class, []}},
    :receipt_store => {:inspect, {AshA2A.Application, :receipt_store, []}},
    :receipt_store_ekv_opts => {:inspect, {AshA2A.Application, :receipt_store_ekv_opts, []}},
    :outbox_reconciler => {:inspect, {AshA2A.Application, :outbox_reconciler?, []}},
    :claim_lease_ms => {:inspect, {AshA2A.ReceiptStore.ClaimLease, :lease_ms, []}},
    :telemetry_raw_errors => {:inspect, {AshA2A.Telemetry.Redact, :raw_errors?, []}},
    :ocel_ingest_url => {:inspect, {AshA2A.Telemetry.OcelForwarder, :ingest_url, []}},
    :evidence_class => {:inspect, {AshA2A.Evidence.Class, :default, []}},
    :planning_bounds => {:inspect, {AshA2A.Semantic.Conformance, :planning_bounds, []}},
    :semantic_max_batch => {:inspect, {AshA2A.Semantic.Compiler, :max_batch, []}},
    :semantic_engine => {:inspect, {AshA2A.Semantic.Conformance, :semantic_engine, []}},
    :admitted_vocabulary => {:inspect, {AshA2A.Semantic.Conformance, :admitted_vocabulary, []}},
    :root_manifest => {:inspect, {AshA2A.Semantic.Conformance, :root_manifest, []}}
  }

  # Rows stating a literal default with no executable single-site oracle yet.
  # Each entry needs a reason; shrink this map, never grow it, by adding a
  # public reader and moving the key to @execution_oracles.
  @documented_not_executable %{
    :capability_release_closure => "CapabilityRelease.binding/2 is behavioral and per-deployment; test env configures a closure, so no env-deleted default oracle",
    :receipt_store_call_timeout_ms => "Memory store resolves per-call from state; reader pending",
    :receipt_binding_key => "default cell carries the refusal-code token; no literal default (unset refuses keyed binding)",
    :execution => "Transport.Runtime reads with default [] inline; no single-site reader yet",
    :semantic_max_text_bytes => "shared multi-key row; Compiler.max_text_bytes/1 covers it behaviorally; its own cell token is —",
    :graphlaw_host_path => "override block row; default cell carries the vectors-path token",
    :graphlaw_probe_host_path => "override block row; default cell carries the vectors-path token",
    :graphlaw_node_path => "override block row; default cell carries the vectors-path token",
    :node_executable => "override block row; default cell carries the vectors-path token",
    :graphlaw_host_script => "override block row; default cell carries the vectors-path token",
    :graphlaw_runtime_b_executable => "override block row; default cell carries the vectors-path token",
    :chicago_topology_root => "default cell carries the refusal-code token; unset refuses :chicago_topology_root_unset (v26.10.2 CR2)",
    :receipt_outbox_dir => "computed tmp-dir default, documented as unsafe-by-design",
    :prepared_journal_dir => "shared multi-key row; falls back to :receipt_outbox_dir",
    :strict_observe_generic_actions => "Agent resolves per-dispatch with per-agent opt override",
    :require_authenticated_caller => "Agent and Transport.Plug resolve per-call with per-plug opt override",
    :production => "SecurityProfile.Boot internal snapshot input",
    :security_profile => "compile-time and per-env by design (config/config.exs selects per Mix env)",
    :llm_profiles => "LLMProfiles.model_spec!/1 raises on unconfigured roles (fail-closed), no default to read",
    :ocel_egress_policy => "per-Mix-env conditional default, documented as such",
    :graph_law => "conditional default (WasmexHost when it serves the configured wasm bytes, else the node runner), documented as such",
    :graphlaw_wasm_path => "source-relative computed default (vendored artifact)",
    :graphlaw_pool_size => "shared multi-key row; no literal default",
    :graphlaw_subprocess_max_concurrency => "shared multi-key row; no literal default",
    :graphlaw_conformance_vectors_path => "source-relative computed default (vendored vectors)",
    :authority_broker => "unset refuses every consequential dispatch; verified behaviorally by the authority tests",
    :allow_legacy_authority_policy => "sentinel-gated (must equal :i_accept_privilege_escalation)",
    :health_ocel_failed_max => "shared multi-key row; no literal default",
    :standing_ledger_key => "no literal default (per-node random when unset, documented as such)"
  }
  setup do
    keys =
      Enum.uniq(
        Map.keys(@execution_oracles) ++
          Map.keys(@documented_not_executable) ++ [:authority_broker]
      )

    saved = for key <- keys, do: {key, Application.fetch_env(:ash_a2a, key)}

    Enum.each(keys, &Application.delete_env(:ash_a2a, &1))

    on_exit(fn ->
      for {key, res} <- saved do
        case res do
          {:ok, value} -> Application.put_env(:ash_a2a, key, value)
          :error -> Application.delete_env(:ash_a2a, key)
        end
      end
    end)

    :ok
  end

  # -- doc parsing -----------------------------------------------------------

  defp config_rows do
    @doc_path
    |> File.read!()
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "| `:"))
    |> Enum.map(fn row ->
      [_lead | cells] = String.split(row, "|")
      keys_cell = Enum.at(cells, 0) || ""
      default_cell = Enum.at(cells, 1) || ""

      keys =
        Regex.scan(~r/`:([a-z_0-9]+)`/, keys_cell)
        |> Enum.map(&Enum.at(&1, 1))
        # Test-only dynamic atoms from a bounded, repo-controlled doc.
        |> Enum.map(&String.to_atom/1)

      # Positional: the Nth key of a multi-key row reads the Nth backticked
      # token of the default cell (e.g. `60_000`, `5`).
      tokens = Regex.scan(~r/`([^`]*)`/, default_cell) |> Enum.map(&Enum.at(&1, 1))

      {keys, tokens}
    end)
  end

  defp documented_default(key) do
    {keys, tokens} =
      Enum.find(config_rows(), fn {row_keys, _} -> key in row_keys end) || {[], []}

    if key in keys do
      idx = Enum.find_index(keys, &(&1 == key))
      token = Enum.at(tokens, idx)
      if token in [nil, "—"], do: nil, else: String.trim(token)
    end
  end

  defp normalize(value) when is_binary(value), do: String.replace(value, "_", "")
  defp normalize(nil), do: nil

  # -- oracles ---------------------------------------------------------------

  defp code_default(key) do
    case Map.fetch(@execution_oracles, key) do
      {:ok, {:inspect, {m, f, a}}} ->
        inspect(apply(m, f, a))

      {:ok, {:special, :capability_release_mode}} ->
        case CapabilityRelease.binding("docs.truth.probe") do
          {:ok, nil} -> ":legacy"
          {:error, :capability_release_closure_missing} -> ":strict"
        end

      {:ok, {:special, :authority_policy}} ->
        principal = "docs-truth-#{System.unique_integer([:positive])}"

        case Authority.Grant.authorize(principal, "docs.truth.probe") do
          nil -> ":broker"
          %Authority{} -> ":transport_verified_grants_capability"
        end
    end
  end

  # -- courts ----------------------------------------------------------------

  test "every documented default row is oracle-verified or explicitly allowlisted" do
    {unaccounted, gated} =
      config_rows()
      |> Enum.flat_map(fn {keys, tokens} ->
        has_literal? = Enum.any?(tokens, &(&1 not in [nil, "—"]))

        if has_literal? do
          Enum.map(keys, fn key ->
            gated_key = key in Map.keys(@execution_oracles)
            {key, gated_key || Map.has_key?(@documented_not_executable, key)}
          end)
        else
          []
        end
      end)
      |> Enum.split_with(fn {_key, accounted?} -> not accounted? end)

    unaccounted_keys = Enum.map(unaccounted, &elem(&1, 0))

    assert unaccounted_keys == [],
           "configuration.md states a literal default with no execution oracle and " <>
             "no allowlist entry (add a public reader + oracle, or allowlist with a reason): " <>
             "#{inspect(unaccounted_keys)}"

    # anti-vacuity: the court must actually be gating rows
    assert length(gated) > 30,
           "configuration.md row scan found too few gated keys — the parser is broken"
  end

  for key <- Map.keys(@execution_oracles) do
    test "configuration.md default for #{inspect(key)} equals the code default" do
      key = unquote(key)
      documented = documented_default(key)

      assert documented,
             "no configuration.md row states a default for #{inspect(key)} but an " <>
               "oracle exists — update the doc or drop the oracle"

      assert normalize(documented) == normalize(code_default(key)),
             "configuration.md states #{documented} for #{inspect(key)} but the code " <>
               "default is #{code_default(key)}"
    end
  end

  test "the court is not vacuous: a wrong documented value is detected" do
    assert documented_default(:actuation_dedup) != ":off"
    assert code_default(:actuation_dedup) != ":off"
  end

  # -- README examples (RD5) ---------------------------------------------------

  describe "README usage examples (RD5)" do
    @readme_dsl_contract [
      "extensions: [AshA2A]",
      "use Ash.Resource",
      "uuid_primary_key(:id)",
      "attribute(:message, :string, public?: true)",
      "defaults([:read])",
      "use Ash.Domain, extensions: [AshA2A]"
    ]

    test "the README's DSL block declares the documented shape" do
      readme = File.read!(@readme_path)
      dsl_block = elixir_blocks(readme) |> Enum.find(&String.contains?(&1, "use Ash.Resource"))
      assert dsl_block, "README DSL example disappeared"

      missing = Enum.reject(@readme_dsl_contract, &String.contains?(dsl_block, &1))
      assert missing == [], "README DSL block lost documented parts: #{inspect(missing)}"

      assert readme =~ "AshA2A.Dispatcher.dispatch(:echo, message, MyApp.Echo)"
    end

    test "the README's dispatch example result is real (executed on the identical fixture)" do
      # AshA2A.Test.Fixture.Echo is the README's resource shape exactly (same
      # attributes/actions, `extensions: [AshA2A]`), with the skill named
      # explicitly the way the zero-config derivation names it (`:echo`).
      # Runtime-compiling the README text itself is not Ash-safe (Spark DSL
      # persistence is compile-environment-bound); the documented CONTRACT is
      # what this court executes.
      message = AshA2A.Protocol.Message.new_user([AshA2A.Protocol.Part.Data.new(%{})])

      assert {:reply, [%AshA2A.Protocol.Part.Data{data: %{results: []}}]} =
               AshA2A.Dispatcher.dispatch(:echo, message, AshA2A.Test.Fixture.Echo)
    end

    defp elixir_blocks(text) do
      Regex.scan(~r/```elixir\n(.*?)```/s, text)
      |> Enum.map(&Enum.at(&1, 1))
    end
  end

  # -- governed how-to example (pre-existing court) ----------------------------

  describe "docs/how-to/test-governed-actions.md example (AshA2A.Test.Governed)" do
    alias AshA2A.Test.Fixture.{Echo, Item}
    alias AshA2A.Test.Governed

    test "a change skill is refused without a grant, completes with one, refused after revoke" do
      gov = Governed.start!()
      capability = "AshA2A.Test.Fixture.Item.create"
      input = %{label: "widget"}

      assert {:error, %{code: :authority_required}} =
               Governed.run(gov, Item, capability, principal: "alice", input: input)

      gov = Governed.grant!(gov, "alice", capability)

      assert {:ok, receipt} =
               Governed.run(gov, Item, capability,
                 principal: "alice",
                 input: input,
                 command_id: "gov-1"
               )

      assert receipt.status == :completed
      assert receipt.consequence == :change

      assert {:ok, stored} = Governed.fetch_receipt(gov, receipt.command_id)
      assert stored.receipt_id == receipt.receipt_id

      gov = Governed.revoke!(gov, "alice", capability)

      assert {:error, %{code: :authority_revoked}} =
               Governed.run(gov, Item, capability,
                 principal: "alice",
                 input: %{label: "gadget"},
                 command_id: "gov-2"
               )
    end

    test "an observe skill needs no grant and replays by command id" do
      gov = Governed.start!()
      cap = "AshA2A.Test.Fixture.Echo.read"

      assert {:ok, first} = Governed.run(gov, Echo, cap, command_id: "gov-read")
      refute first.replayed?
      assert {:ok, again} = Governed.run(gov, Echo, cap, command_id: "gov-read")
      assert again.replayed?
      assert again.receipt_id == first.receipt_id
    end

    test "grants are isolated per context" do
      one = Governed.start!()
      two = Governed.start!()
      capability = "AshA2A.Test.Fixture.Item.create"
      Governed.grant!(one, "bob", capability)

      assert {:error, %{code: :authority_required}} =
               Governed.run(two, Item, capability, principal: "bob", input: %{label: "x"})
    end
  end
end
