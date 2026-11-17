# NOTE: 1 module(s) removed from this consolidated file because the repaired originals (kept as separate files) define the same modules; see docs/reference/test-consolidation-merge.md.
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
# SPDX-License-Identifier: MIT

# ==============================================================================
# Consolidated Test Suite: Root Semantic Policy, Cards, & Attestation
# Target File: test/root_semantic_policy_cards_consolidated_test.exs
# Consolidated from 22 original test files:
#   - test/ash_a2a_receipt_s31_fields_test.exs
#   - test/ash_a2a_refusal_crosswalk_test.exs
#   - test/ash_a2a_registry_test.exs
#   - test/ash_a2a_runtime_providers_integration_test.exs
#   - test/ash_a2a_sa2a_corpus_test.exs
#   - test/ash_a2a_sa2a_graphlaw_live_test.exs
#   - test/ash_a2a_schema_extension_test.exs
#   - test/ash_a2a_security_mutation_witness_test.exs
#   - test/ash_a2a_self_card_test.exs
#   - test/ash_a2a_semantic_agent_card_test.exs
#   - test/ash_a2a_semantic_attestation_test.exs
#   - test/ash_a2a_semantic_conformance_test.exs
#   - test/ash_a2a_semantic_cross_peer_test.exs
#   - test/ash_a2a_semantic_extension_test.exs
#   - test/ash_a2a_semantic_policy_phenotype_court_probe_test.exs
#   - test/ash_a2a_semantic_policy_phenotype_harden45_test.exs
#   - test/ash_a2a_semantic_policy_phenotype_hardening_test.exs
#   - test/ash_a2a_semantic_policy_phenotype_test.exs
#   - test/ash_a2a_semantic_policy_phenotype_transport_fence_test.exs
#   - test/ash_a2a_semantic_policy_phenotype_transport_test.exs
#   - test/ash_a2a_semantic_policy_population_rdf_test.exs
#   - test/ash_a2a_semantic_policy_population_test.exs
# ==============================================================================

# ==============================================================================
# SECTION 1: Original test/ash_a2a_receipt_s31_fields_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ReceiptS31FieldsTest do
  @moduledoc """
  RFC-SA2A-001 S31 ("zero unreceipted actuation") audited against the REAL
  `AshA2A.CommandBus` path.

  Every assertion here reads a receipt that a real `CommandBus.run/4` produced
  by really dispatching into a real `Ash.Resource`. No doubles.

  ## Audit result recorded by this suite

  Present on `main` before this branch: actuation identifier (NO -- only
  `command_id`), idempotency identifier (NO), actor (PARTIAL -- `:principal_id`
  existed but was not named as the actor), authority grant (NO -- only the
  fingerprint's hash of `token_id`), semantic subject (YES), intended effect
  (NO), input digest (NO), plan digest (NO), projection digest (NO --
  reachable only via `:semantic_subject`), timestamp (YES, `:recorded_at`),
  logical clock (NO), reconciliation metadata (NO), terminal status set (NO).

  The tests below assert the post-branch state: every one of those is now
  carried, with `:plan_digest` legitimately absent for an unplanned command
  and reported as such by `missing_required_fields/1` rather than invented.
  """
  use ExUnit.Case

  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Authority, Command, CommandBus, Identity, Receipt, SemanticSubject}
  alias AshA2A.Test.Fixture.{Echo, Item}

  setup do
    Application.put_env(:ash_a2a, :receipt_commit_retry_delays_ms, [1, 1])
    on_exit(fn -> Application.delete_env(:ash_a2a, :receipt_commit_retry_delays_ms) end)

    name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    start_supervised!({AshA2A.ReceiptStore.Memory, name: name})
    %{store_opts: [name: name]}
  end

  defp digest(seed),
    do: "sha256:" <> (seed |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower))

  test "a real consequence-bearing run carries every S31 prepared-receipt field", %{
    store_opts: store_opts
  } do
    principal = Identity.principal("subject-s31")
    capability = "AshA2A.Test.Fixture.Item.create"

    authority =
      Authority.new(principal, capability,
        token_id: "auth-s31",
        constraints: %{external_idempotency_token: "stripe_idem_s31"}
      )

    {:ok, subject} =
      SemanticSubject.new(
        graph_digest: digest("graph-s31"),
        projection_digest: digest("projection-s31"),
        manufacturer_digest: digest("manufacturer-s31")
      )

    command =
      Command.new(capability,
        command_id: "s31-create-1",
        agent_id: "agent-s31",
        principal_id: principal,
        authority: authority,
        semantic_subject: subject,
        input: %{label: "widget"}
      )

    assert {:ok, receipt} =
             CommandBus.run(command, data_message(%{"label" => "widget"}), Item,
               store_opts: store_opts,
               plan_digest: digest("plan-s31")
             )

    # --- the eleven S31 prepared-receipt fields, each really populated ---
    assert %Identity{kind: :actuation} = receipt.actuation_id
    assert %Identity{kind: :idempotency} = receipt.idempotency_key
    assert %Identity{kind: :principal, value: "subject-s31"} = receipt.actor

    assert %{
             token_id: "runtime:auth-s31",
             subject: "principal:subject-s31",
             capability_id: ^capability,
             source: :authority_broker
           } = receipt.authority_grant

    assert receipt.semantic_subject == subject
    assert receipt.intended_effect.capability_id == capability
    assert receipt.intended_effect.consequence == :change
    assert String.starts_with?(receipt.input_digest, "sha256:")
    assert receipt.plan_digest == digest("plan-s31")
    assert receipt.projection_digest == digest("projection-s31")
    assert %DateTime{} = receipt.recorded_at
    assert is_integer(receipt.logical_clock) and receipt.logical_clock > 0
    assert %{state: _, attempts: _} = receipt.reconciliation

    # Nothing is missing for a fully-specified command.
    assert Receipt.missing_required_fields(receipt) == []

    # The external idempotency token really is bound into the identity, per
    # S55's "SHOULD bind to the external token".
    assert receipt.idempotency_key.value == "stripe_idem_s31"
  end

  test "an unplanned observe command reports its genuinely absent fields instead of inventing them",
       %{store_opts: store_opts} do
    command =
      Command.new("AshA2A.Test.Fixture.Echo.read",
        command_id: "s31-read-1",
        agent_id: "agent-s31",
        principal_id: "anonymous",
        input: %{}
      )

    assert {:ok, receipt} =
             CommandBus.run(command, data_message(%{}), Echo, store_opts: store_opts)

    missing = Receipt.missing_required_fields(receipt)

    # No plan selected this route, no semantic subject was supplied, and an
    # observe command needs no authority grant. Those are reported as absent.
    assert :plan_digest in missing
    assert :semantic_subject in missing
    assert :projection_digest in missing
    assert :authority_grant in missing

    # The rest are genuinely present even for an observe command.
    refute :actuation_id in missing
    refute :idempotency_key in missing
    refute :actor in missing
    refute :input_digest in missing
    refute :logical_clock in missing
    refute :intended_effect in missing

    # And a nil plan digest is a marked absence, not a fabricated value.
    assert receipt.plan_digest == nil
  end

  test "terminal status is :executed for a real execution and :refused for a pre-DO refusal", %{
    store_opts: store_opts
  } do
    ok_command =
      Command.new("AshA2A.Test.Fixture.Echo.read",
        command_id: "s31-terminal-ok",
        agent_id: "agent-s31",
        principal_id: "anonymous",
        input: %{}
      )

    assert {:ok, executed} =
             CommandBus.run(ok_command, data_message(%{}), Echo, store_opts: store_opts)

    assert executed.status == :completed
    assert executed.terminal_status == :executed
    assert Receipt.terminal?(executed)

    # A real kill switch trip refuses BEFORE the claim, so no receipt is
    # produced at all -- which is the correct S31 behaviour (nothing was
    # actuated, so there is nothing to receipt). The refusal-shaped terminal
    # status is exercised through the reply mapping directly below and
    # through the real actuation-conflict path in the S55 suite.
    assert Receipt.terminal_status({:error, %{code: :authority_required}}) == :refused
    assert Receipt.terminal_status({:error, %{code: :kill_switch_tripped}}) == :refused
    assert Receipt.terminal_status({:error, %{code: :receipt_anchor_unavailable}}) == :refused
  end

  test "a real dispatch crash is :failed, not :refused -- DO ran", %{store_opts: store_opts} do
    command =
      Command.new("AshA2A.Test.Fixture.Crashy.detonate",
        command_id: "s31-terminal-crash",
        agent_id: "agent-s31",
        principal_id: "anonymous",
        input: %{}
      )

    assert {:ok, receipt} =
             CommandBus.run(command, data_message(%{}), AshA2A.Test.Fixture.Crashy,
               store_opts: store_opts
             )

    assert receipt.status == :failed
    assert receipt.terminal_status == :failed
    assert {:error, %{code: :dispatch_crashed}} = receipt.reply
  end

  test "the full terminal status set is reachable and each transition is explicit", %{
    store_opts: store_opts
  } do
    assert Enum.sort(Receipt.terminal_statuses()) ==
             Enum.sort([
               :executed,
               :refused,
               :failed,
               :reconciled,
               :compensated,
               :unknown_outcome
             ])

    command =
      Command.new("AshA2A.Test.Fixture.Echo.read",
        command_id: "s31-transitions",
        agent_id: "agent-s31",
        principal_id: "anonymous",
        input: %{}
      )

    assert {:ok, executed} =
             CommandBus.run(command, data_message(%{}), Echo, store_opts: store_opts)

    assert executed.terminal_status == :executed

    reconciled = Receipt.reconcile(executed, %{source: :test})
    assert reconciled.terminal_status == :reconciled
    assert reconciled.reconciliation.state == :reconciled
    assert reconciled.reconciliation.attempts == executed.reconciliation.attempts + 1
    # Reconciliation does not rewrite the observed reply shape.
    assert reconciled.status == executed.status
    assert reconciled.reply == executed.reply

    compensated = Receipt.compensate(executed, %{reversal_receipt_id: "runtime:rev-1"})
    assert compensated.terminal_status == :compensated
    assert compensated.reconciliation.detail == %{reversal_receipt_id: "runtime:rev-1"}

    unknown = Receipt.mark_unknown_outcome(executed, :post_do_crash_window)
    assert unknown.terminal_status == :unknown_outcome
    assert unknown.reconciliation.reason == :post_do_crash_window
  end

  test "a pending anchor has no terminal status -- it asserts nothing about the outcome" do
    command =
      Command.new("AshA2A.Test.Fixture.Item.create",
        command_id: "s31-pending",
        agent_id: "agent-s31",
        principal_id: "subject-s31",
        input: %{label: "widget"}
      )

    anchor = Receipt.pending(command, Identity.execution("exec-s31"), :change)

    assert anchor.status == :pending
    assert anchor.terminal_status == nil
    refute Receipt.terminal?(anchor)
    # ...but the prepared fields are all there BEFORE DO, which is the point
    # of S31: the receipt is complete before the boundary is crossed.
    assert anchor.actuation_id
    assert anchor.idempotency_key
    assert anchor.input_digest
    assert anchor.logical_clock
    assert anchor.reconciliation.state == :pending
  end

  test "authority grant records the grant, never the raw transport evidence" do
    principal = Identity.principal("subject-secret")

    authority =
      Authority.new(principal, "Cap.act",
        token_id: "auth-secret",
        evidence: %{bearer_token: "super-secret-value", transport_identity: %{sub: "u-1"}}
      )

    grant = Receipt.authority_grant(authority)

    assert grant.token_id == "runtime:auth-secret"
    assert String.starts_with?(grant.evidence_digest, "sha256:")

    # The secret itself is nowhere in the serialized grant.
    refute inspect(grant) =~ "super-secret-value"
    refute grant |> :erlang.term_to_binary() |> inspect() =~ "super-secret-value"
  end
end

# ==============================================================================
# SECTION 2: Original test/ash_a2a_refusal_crosswalk_test.exs
# ==============================================================================

defmodule AshA2A.RefusalCrosswalkTest do
  @moduledoc """
  Crosswalk court: pins the ggen-marketplace `refusal-vocabulary-pack`
  crosswalk's ash_a2a column (S42 refusal class -> JSON-RPC wire code)
  against what `AshA2A.Protocol.JSONRPC.Error` and
  `AshA2A.Transport.Plug.wire_error/1` actually emit.

  Three assertions:
    (a) every wire code the crosswalk assigns is a code ash_a2a's protocol
        actually emits (fail-closed on unknown class or unknown code);
    (b) the pin matches the LIVE sibling ontology at test time (re-parsed
        from `/Users/sac/ggen-marketplace`, skipped when absent);
    (c) sabotage twin — mutating one pinned code makes the comparator fail,
        proving the pin is non-vacuous.
  """

  use ExUnit.Case, async: true

  @sibling_ontology "/Users/sac/ggen-marketplace/packs/refusal-vocabulary-pack/ontology.ttl"

  # Pinned copy of the crosswalk's ash_a2a column (re-pinned 2026-10-13,
  # verified against sibling ontology at ggen-marketplace commit 4273adf24
  # "feat(crosswalk): ash_graphlaw fifth column (40/40 mapped) + count
  # canary"). The fifth column's rv:GraphlawMapping subjects carry
  # rv:ashA2aClass but NO rv:jsonRpcCode edges, so every wire-code set below
  # is UNCHANGED from the prior pin; the only parser change is recognizing
  # rv:gm-* GraphlawMapping subjects so their class edges fold into their own
  # entries instead of clobbering the last A2aWireMapping subject's class.
  # Derived from rv:RefusalMapping / rv:A2aWireMapping / rv:GraphlawMapping
  # subjects in the sibling ontology: every rv:ashA2aClass ->
  # rv:jsonRpcCode edge, folded
  # to a set per refusal class. A class with an empty set carries no wire
  # code in the crosswalk (rv:jsonRpcCode is emitted only where the A2A
  # JSON-RPC law of lib/ash_a2a/protocol/jsonrpc/error.ex applies).
  @pin %{
    "refused_identity" => MapSet.new(),
    "refused_namespace" => MapSet.new(),
    "refused_structure" => MapSet.new([-32_600, -32_602]),
    "refused_shacl" => MapSet.new([-32_602]),
    "refused_rule" => MapSet.new(),
    "refused_falsifier" => MapSet.new(),
    "refused_provenance" => MapSet.new(),
    "refused_profile" => MapSet.new([-32_600]),
    "refused_plan" => MapSet.new(),
    "refused_capability" => MapSet.new([-32_001]),
    "refused_authority" => MapSet.new(),
    "refused_consequence" => MapSet.new(),
    "refused_receipt" => MapSet.new(),
    "refused_bounds" => MapSet.new([-32_000]),
    "refused_meta_rigor" => MapSet.new(),
    "blocked_unknown" => MapSet.new(),
    "blocked_resource" => MapSet.new([-32_000]),
    "unsupported_profile" => MapSet.new([-32_005, -32_009])
  }

  # Wire codes ash_a2a's protocol actually emits, derived from the live
  # constructors (not hardcoded): the 5 standard JSON-RPC codes, the 9
  # A2A-specific codes, plus -32000 via Plug.wire_error/1's designated
  # server-range code for server_busy/rate_limited.
  defp protocol_wire_codes do
    error_mod = AshA2A.Protocol.JSONRPC.Error

    base =
      [
        error_mod.parse_error(),
        error_mod.invalid_request(),
        error_mod.method_not_found(),
        error_mod.invalid_params(),
        error_mod.internal_error(),
        error_mod.task_not_found(),
        error_mod.task_not_cancelable(),
        error_mod.push_notification_not_supported(),
        error_mod.unsupported_operation(),
        error_mod.content_type_not_supported(),
        error_mod.invalid_agent_response(),
        error_mod.authenticated_extended_card_not_configured(),
        error_mod.extension_support_required(),
        error_mod.version_not_supported()
      ]
      |> Enum.map(& &1.code)
      |> MapSet.new()

    # Plug.wire_error/1 designates -32000 (JSON-RPC 2.0 spec-reserved
    # server-implementation range -32000..-32099) for the transport-native
    # server_busy / rate_limited refusals (transport/runtime.ex dispatch_check/1).
    busy_code =
      AshA2A.Transport.Plug.wire_error(%{
        code: :server_busy,
        message: "server busy",
        class: :refused_bounds
      }).code

    MapSet.put(base, busy_code)
  end

  # Live S42 classes straight from ash_a2a's own refusal module.
  defp live_classes do
    AshA2A.Semantic.Refusal.classes()
    |> Enum.map(&to_string/1)
    |> MapSet.new()
  end

  # Diffs two class -> codes tables. Classes present in only one side are
  # diffs too (live-parse yields all live classes with defaults).
  defp diff_tables(pinned, live) do
    keys = MapSet.union(MapSet.new(Map.keys(pinned)), MapSet.new(Map.keys(live)))

    for k <- MapSet.to_list(keys), Map.get(pinned, k) != Map.get(live, k), into: %{} do
      {k, {Map.get(pinned, k), Map.get(live, k)}}
    end
  end

  describe "crosswalk ash_a2a wire-code column" do
    test "every pinned class is a live ash_a2a refusal class (fail-closed)" do
      live = live_classes()
      pinned = MapSet.new(Map.keys(@pin))

      unknown = MapSet.difference(pinned, live)
      missing = MapSet.difference(live, pinned)

      assert MapSet.equal?(pinned, live),
             "pin/live class mismatch; unknown: #{inspect(MapSet.to_list(unknown))}, " <>
               "missing-from-pin: #{inspect(MapSet.to_list(missing))}"
    end

    test "every pinned wire code is one the protocol actually emits" do
      emitted = protocol_wire_codes()

      for {cls, codes} <- @pin,
          code <- codes do
        assert MapSet.member?(emitted, code),
               "class #{cls} pinned to wire code #{code}, which ash_a2a's protocol " <>
                 "does not emit; emitted set: #{inspect(Enum.sort(MapSet.to_list(emitted)))}"
      end
    end

    # Real ExUnit skip, resolved at compile time: no sibling checkout on this
    # host means a NAMED skip (visible via `mix test --include skip`), never a
    # bare `:ok` green pass. Tagged `:sibling_repos` (the tag test_helper.exs
    # actually excludes), not the previously-dead `:sibling`.
    @tag :sibling_repos
    @tag skip:
           if(File.exists?(@sibling_ontology),
             do: nil,
             else:
               "sibling checkout absent: #{@sibling_ontology} — crosswalk pin live-check skipped"
           )

    test "pin matches the live sibling ontology" do
      live = parse_sibling!()
      diffs = diff_tables(@pin, live)

      assert diffs == %{},
             "crosswalk pin drifted from live sibling ontology: #{inspect(diffs)}"
    end

    test "sabotage twin: mutating a pinned code is detected" do
      assert File.exists?(@sibling_ontology),
             "sabotage twin requires the sibling checkout: #{@sibling_ontology}"

      live = parse_sibling!()

      # Sabotage: -32602 -> -32601 for refused_shacl (a plausible wrong code).
      sabotaged =
        Map.update!(@pin, "refused_shacl", fn codes ->
          MapSet.new(Enum.map(codes, fn c -> if c == -32_602, do: -32_601, else: c end))
        end)

      diffs = diff_tables(sabotaged, live)

      expected_key = if File.exists?(@sibling_ontology), do: "refused_shacl", else: nil

      assert map_size(diffs) == 1 and Map.has_key?(diffs, expected_key) and
               elem(diffs["refused_shacl"], 0) == MapSet.new([-32_601]),
             "sabotaged pin was NOT detected as expected: #{inspect(diffs)}"
    end

    test "live sibling derivation is stable across two parses" do
      a = parse_sibling!()
      b = parse_sibling!()
      assert a == b, "sibling ontology parse is nondeterministic"
    end
  end

  # Re-derives the class -> wire-code table from the live sibling ontology.
  # Turtle is parsed statement-wise (split on '.' terminators), tracking the
  # current rv:code-N / rv:a2a-* / rv:gm-* mapping subject and folding each
  # rv:ashA2aClass / rv:jsonRpcCode edge into a per-class code set. Classes
  # absent from any mapping default to the empty set. rv:gm-* (GraphlawMapping,
  # fifth crosswalk column, commit 4273adf24) subjects are recognized so their
  # rv:ashA2aClass edges do not fold into a stale prior subject.
  defp parse_sibling! do
    txt = File.read!(@sibling_ontology)

    {folded, _} =
      txt
      |> String.split(~r/\.\s*\n/)
      |> Enum.reduce({%{}, nil}, fn st, {acc, cur} ->
        cur =
          case Regex.run(
                 ~r/^rv:(code-[\w-]+|a2a-[\w-]+|gm-[\w-]+)\s+a rv:(RefusalMapping|A2aWireMapping|GraphlawMapping)/m,
                 st
               ) do
            [_ | _] ->
              [subject | _] = Regex.scan(~r/rv:(code-[\w-]+|a2a-[\w-]+|gm-[\w-]+)/, st)
              "rv:" <> Enum.at(subject, 1)

            _ ->
              cur
          end

        case cur do
          nil ->
            {acc, nil}

          subject ->
            entry = Map.get(acc, subject, %{cls: nil, codes: MapSet.new()})

            entry =
              case Regex.run(~r/rv:ashA2aClass\s+(rv:[\w-]+)/, st) do
                [_, cls] -> %{entry | cls: cls}
                _ -> entry
              end

            entry =
              case Regex.scan(~r/rv:jsonRpcCode\s+(-\d+)/, st) do
                [] -> entry
                cs -> %{entry | codes: MapSet.union(entry.codes, code_set(cs))}
              end

            # If the statement ends the mapping subject (next subject begins),
            # we simply keep accumulating under the same subject; the class/codes
            # edges are what we need and are unambiguous per subject.
            {Map.put(acc, subject, entry), subject}
        end
      end)

    by_class =
      folded
      |> Map.values()
      |> Enum.filter(& &1.cls)
      |> Enum.flat_map(fn %{cls: cls, codes: codes} ->
        class_name =
          cls
          |> String.trim_leading("rv:cls-")
          |> String.replace("-", "_")

        [{class_name, codes}]
      end)
      |> Enum.reduce(%{}, fn {k, v}, acc ->
        Map.update(acc, k, v, &MapSet.union(&1, v))
      end)

    # Every live class gets a default empty set so absent classes diff correctly.
    Map.merge(Map.new(live_classes(), fn c -> {c, MapSet.new()} end), by_class, fn _k, a, b ->
      MapSet.union(a, b)
    end)
  end

  defp code_set(codes) do
    Enum.reduce(codes, MapSet.new(), fn [_, raw], acc ->
      MapSet.put(acc, String.to_integer(raw))
    end)
  end
end

# ==============================================================================
# SECTION 3: Original test/ash_a2a_registry_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2ARegistryTest do
  @moduledoc """
  Chicago-style multi-agent `AshA2A.Protocol.Registry` collision test (ash_a2a task #22).

  Compiles two distinct real fixture resources
  (`AshA2A.Test.Fixture.Echo`/`AshA2A.Test.Fixture.Widget`,
  `test/support/fixture.ex`) into two distinct real `AshA2A.Agent` modules
  (`EchoAgent`/`WidgetAgent`), starts both under one real
  `AshA2A.Protocol.AgentSupervisor` (the same child spec `AshA2A.Application.start/2`
  wires in) with its integrated `AshA2A.Protocol.Registry`, and asserts on the real
  registry state -- no Mock/mox/patch, no hand-built registry entries.
  """

  use ExUnit.Case

  alias AshA2A.Test.Fixture.{EchoAgent, WidgetAgent}

  test "two distinct AshA2A.Agent modules register distinct AshA2A.Protocol.Registry identities" do
    {sup, registry_name} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [
        EchoAgent,
        WidgetAgent
      ])

    # Both agent processes are real, independently-supervised children of
    # the same real supervisor -- not the same process under two names.
    children = Supervisor.which_children(sup)
    assert length(children) == 3

    echo_pid = GenServer.whereis(EchoAgent)
    widget_pid = GenServer.whereis(WidgetAgent)

    assert is_pid(echo_pid)
    assert is_pid(widget_pid)
    refute echo_pid == widget_pid

    # `AshA2A.Protocol.Registry` keys its ETS table by agent *module* (registry.ex:104-111),
    # populated at real `init/1` time from each agent's own real
    # `agent_card/0` -- assert on the actual registered entries, not on the
    # agent modules' identity alone.
    assert {:ok, echo_card} = AshA2A.Protocol.Registry.get(registry_name, EchoAgent)
    assert {:ok, widget_card} = AshA2A.Protocol.Registry.get(registry_name, WidgetAgent)

    assert echo_card.name == "echo_agent"
    assert widget_card.name == "widget_agent"
    refute echo_card == widget_card

    # The real skill sets baked into each card (via
    # `AshA2A.Info.agent_card/2` -> the resource/domain's own compiled
    # capability index) are likewise distinct -- confirms the two entries
    # are genuinely different agents, not one card registered twice.
    # Real current shape (fbc3213 "derive canonical skills from public Ash
    # actions"): `id` is the fully-qualified "<Resource>.<action>" identity;
    # `name` carries the short, declared skill name.
    assert [%{id: "AshA2A.Test.Fixture.Echo.read", name: "echo"}] = echo_card.skills
    assert [%{id: "AshA2A.Test.Fixture.Widget.read", name: "inspect"}] = widget_card.skills

    all_entries = AshA2A.Protocol.Registry.all(registry_name)
    registered_modules = Enum.map(all_entries, fn {mod, _card} -> mod end)

    assert length(all_entries) == 2
    assert Enum.sort(registered_modules) == Enum.sort([EchoAgent, WidgetAgent])
    # No collision: as many distinct registry keys as distinct agent modules.
    assert length(Enum.uniq(registered_modules)) == 2

    # Both agents are independently dispatchable through the shared
    # supervisor/registry -- distinct identity, not just distinct metadata.
    echo_message = AshA2A.Protocol.Message.new_user([AshA2A.Protocol.Part.Data.new(%{})])
    widget_message = AshA2A.Protocol.Message.new_user([AshA2A.Protocol.Part.Data.new(%{})])

    assert {:ok, echo_task} = EchoAgent.call(EchoAgent, echo_message)
    assert {:ok, widget_task} = WidgetAgent.call(WidgetAgent, widget_message)

    assert echo_task.status.state == :completed
    assert widget_task.status.state == :completed
    refute echo_task.id == widget_task.id
  end
end

# ==============================================================================
# SECTION 4: Original test/ash_a2a_runtime_providers_integration_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.RuntimeProvidersIntegrationTest do
  @moduledoc """
  Exercises the configured runtime-provider boundaries --
  `AshA2A.Execution.FLAME` (Placement), `AshA2A.Durability.DurableServer`
  (Durability), and `AshA2A.Topology.Presence` (Topology) -- against actual
  FLAME, DurableServer, Phoenix Presence, and Phoenix PubSub
  implementations, rather than substitute provider modules.

  Each describe block also asserts the boundary that makes these adapters
  safe to compose: none of them ever carry Ash command execution, task
  completion, or authority standing of their own -- only observed provider
  evidence via `AshA2A.RuntimeReceipt`.
  """
  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  alias AshA2A.Durability.DurableServer, as: Durability
  alias AshA2A.Execution.FLAME, as: Placement
  alias AshA2A.Identity
  alias AshA2A.Test.DurableServerFixture
  alias AshA2A.Test.PresenceFixture

  describe "Placement (AshA2A.Execution.FLAME)" do
    test "available?/0 resolves against the real flame dependency" do
      assert Placement.available?()
    end
  end

  describe "Durability (AshA2A.Durability.DurableServer)" do
    setup do
      sup_name = :"ash_a2a_test_durable_sup_#{System.unique_integer([:positive])}"

      # EKVStore is a real embedded/local durable_server storage backend,
      # backed by the real :ekv package's own on-disk durable KV store --
      # used here instead of the default ObjectStore/S3 backend so this
      # test exercises real durability semantics without requiring cloud
      # storage credentials.
      ekv_name = :"#{sup_name}_ekv"

      data_dir =
        Path.join(System.tmp_dir!(), "ash_a2a_ekv_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(data_dir)
      on_exit(fn -> File.rm_rf!(data_dir) end)

      # cluster_size: 1 -- a real single-voter CAS quorum, sufficient for a
      # single-node test; DurableServer.Backends.EKVStore requires CAS to
      # be configured (cluster_size not nil) to accept writes.
      start_supervised!({EKV, name: ekv_name, data_dir: data_dir, cluster_size: 1})

      start_supervised!(
        {DurableServer.Supervisor,
         name: sup_name,
         prefix: "ash-a2a-test/",
         backend: {DurableServer.Backends.EKVStore, name: ekv_name}}
      )

      %{sup: sup_name}
    end

    test "available?/0 resolves against the real durable_server dependency" do
      assert Durability.available?()
      assert Durability.provider() == DurableServer.Supervisor
    end

    test "ensure_task/delete_task drive an actual DurableServer-managed GenServer", %{sup: sup} do
      task_id = Identity.new(:task, "runtime-providers-#{System.unique_integer([:positive])}")

      assert {:ok,
              %AshA2A.RuntimeReceipt{provider: :durable_server, operation: :ensure_started_child}} =
               Durability.ensure_task(sup, DurableServerFixture, task_id, %{count: 0})

      {pid, _meta} = DurableServer.Supervisor.lookup(sup, Durability.key(task_id))
      assert is_pid(pid)
      assert GenServer.call(pid, :get) == 0
      assert GenServer.call(pid, :increment) == 1
      assert GenServer.call(pid, :increment) == 2

      assert {:ok, %AshA2A.RuntimeReceipt{provider: :durable_server}} =
               Durability.delete_task(sup, task_id)

      refute Process.alive?(pid)
    end

    test "receipts carry only observed provider standing, no Ash command/task completion", %{
      sup: sup
    } do
      task_id =
        Identity.new(:task, "runtime-providers-boundary-#{System.unique_integer([:positive])}")

      {:ok, receipt} = Durability.ensure_task(sup, DurableServerFixture, task_id, %{count: 0})

      assert receipt.provider == :durable_server
      assert receipt.standing == :observed
      refute Map.has_key?(receipt, :command_id)
    end
  end

  describe "Topology (AshA2A.Topology.Presence)" do
    setup do
      start_supervised!({Phoenix.PubSub, name: AshA2A.Test.PubSubFixture})
      start_supervised!(PresenceFixture)
      :ok
    end

    test "available?/1 resolves against the real phoenix/phoenix_pubsub dependencies" do
      assert AshA2A.Topology.Presence.available?(PresenceFixture)
    end

    test "track/list/untrack drive an actual Phoenix.Presence process" do
      alias AshA2A.Topology.Presence

      identity =
        Identity.new(:agent, "runtime-providers-topology-#{System.unique_integer([:positive])}")

      topic = "runtime-providers:test"

      assert {:ok, %AshA2A.RuntimeReceipt{provider: :phoenix_presence, operation: :track}} =
               Presence.track(PresenceFixture, self(), topic, identity, %{role: :test})

      present = Presence.list(PresenceFixture, topic)
      key = Presence.key(identity)
      assert Map.has_key?(present, key)

      assert {:ok, %AshA2A.RuntimeReceipt{provider: :phoenix_presence, operation: :untrack}} =
               Presence.untrack(PresenceFixture, self(), topic, identity)

      {:ok, track_receipt} = Presence.track(PresenceFixture, self(), topic, identity, %{})
      assert track_receipt.standing == :observed
      refute Map.has_key?(track_receipt, :command_id)
    end
  end
end

# ==============================================================================
# SECTION 5: Original test/ash_a2a_sa2a_corpus_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2ASA2ACorpusTest do
  @moduledoc """
  Chicago-school tests over the REAL SA2A conformance corpus on disk.

  No mocks, no stubs, no fabricated fixtures: every assertion is over real file
  bytes in `priv/sa2a_conformance/`, real SHA-256 digests recomputed here by
  `:crypto`, and the real typed values decoded from the real sidecars. The
  drift tests copy the real corpus to a real temp directory and really mutate a
  real byte, then assert the loader really fails closed.
  """
  use ExUnit.Case, async: true

  alias AshA2A.SA2A.Corpus
  alias AshA2A.SA2A.Corpus.Vector

  setup_all do
    {:ok, corpus: Corpus.load!()}
  end

  describe "load/1 integrity gate" do
    test "loads the shipped corpus with every manifested sha256 matching", %{corpus: corpus} do
      assert %Corpus{} = corpus
      assert map_size(corpus.files) == 30
      assert corpus.dir |> Path.basename() == "sa2a_conformance"
    end

    test "every manifested sha256 really is the sha256 of the real file bytes", %{corpus: corpus} do
      for {rel, entry} <- corpus.files do
        bytes = File.read!(Path.join(corpus.dir, rel))
        actual = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

        assert actual == entry["sha256"], "sha256 drift in #{rel}"
        assert entry["bytes"] == byte_size(bytes), "size drift in #{rel}"
        assert String.length(entry["blake3"]) == 64
      end
    end

    test "a single flipped byte fails the load closed" do
      tmp = temp_corpus()
      victim = Path.join(tmp, "base.ttl")
      File.write!(victim, File.read!(victim) <> "\n# drift\n")

      assert {:error, %{code: :sa2a_corpus_digest_mismatch, detail: detail}} =
               Corpus.load(dir: tmp)

      assert detail.file == "base.ttl"
      assert detail.algorithm == :sha256
      refute detail.expected == detail.actual
    end

    test "a deleted manifested file fails the load closed" do
      tmp = temp_corpus()
      File.rm!(Path.join(tmp, "rules/denials.n3"))

      assert {:error, %{code: :sa2a_corpus_file_missing, detail: %{file: "rules/denials.n3"}}} =
               Corpus.load(dir: tmp)
    end

    test "an extra unmanifested file fails the load closed" do
      tmp = temp_corpus()
      File.write!(Path.join(tmp, "negative/smuggled.ttl"), "@prefix ex: <http://x/> .\n")

      assert {:error, %{code: :sa2a_corpus_unmanifested_file, detail: extra}} =
               Corpus.load(dir: tmp)

      assert "negative/smuggled.ttl" in extra
    end

    test "a missing directory fails the load closed" do
      assert {:error, %{code: :sa2a_corpus_dir_missing}} =
               Corpus.load(dir: Path.join(System.tmp_dir!(), "sa2a_no_such_corpus_#{uniq()}"))
    end
  end

  describe "vectors" do
    test "the RFC S61 minimum falsifier suite is present, one vector per class", %{corpus: corpus} do
      classes = corpus |> Corpus.vectors() |> Enum.map(& &1.class) |> Enum.sort()

      assert classes == [
               "canonicalization_distinctness",
               "canonicalization_isomorphism",
               "graph_global_falsifier",
               "malformed_turtle",
               "positive_baseline",
               "shacl_violation",
               "shacl_violation_over_warning",
               "shacl_warning_only",
               "shex_invalid_structure",
               "unadmitted_predicate"
             ]
    end

    test "every expected value is a digest or a typed refusal code, never RDF text", %{
      corpus: corpus
    } do
      for v <- Corpus.vectors(corpus) do
        assert v.expected_admission in [:admitted, :refused]
        assert v.graph_digest =~ ~r/\A[0-9a-f]{64}\z/
        assert v.law_graph_digest =~ ~r/\A[0-9a-f]{64}\z/

        case v.expected_refusal do
          nil ->
            assert v.expected_admission == :admitted

          %{code: code} ->
            assert v.expected_admission == :refused
            assert is_atom(code)
            assert Atom.to_string(code) =~ ~r/\Asa2a_/
        end
      end
    end

    test "refusal codes are a closed vocabulary -- an invented one fails the load" do
      tmp = temp_corpus()
      sidecar = Path.join(tmp, "negative/shacl_violation.expected.json")

      File.read!(sidecar)
      |> String.replace("\"sa2a_shacl_violation\"", "\"sa2a_invented_code\"")
      |> then(&File.write!(sidecar, &1))

      remanifest(tmp, "negative/shacl_violation.expected.json")

      assert {:error, %{code: :sa2a_corpus_vector_invalid, detail: detail}} =
               Corpus.load(dir: tmp)

      assert detail.unknown_refusal_code == "sa2a_invented_code"
    end

    test "each vector's graph is the real file content on disk", %{corpus: corpus} do
      for v <- Corpus.vectors(corpus) do
        assert v.graph == File.read!(Path.join(corpus.dir, v.file))
      end
    end

    test "fetch_vector!/2 raises for an unknown name", %{corpus: corpus} do
      assert %Vector{name: "base"} = Corpus.fetch_vector!(corpus, "base")
      assert_raise KeyError, fn -> Corpus.fetch_vector!(corpus, "no_such_vector") end
    end
  end

  describe "RFC S12 -- canonical graph identity" do
    test "the isomorphism vector demands the base digest and records that it FAILS today", %{
      corpus: corpus
    } do
      iso = Corpus.fetch_vector!(corpus, "base_bnode_relabelled")
      base = Corpus.fetch_vector!(corpus, "base")

      # The RFC requirement, held at the RFC's value rather than weakened to the engine's.
      assert iso.digest_must_equal_vector == "base"
      assert iso.expected_admission == :admitted

      # ...and the honest, measured state of the pinned engine.
      assert iso.conformance == :failing_on_pinned_engine
      assert iso.failure =~ "BLANK NODE RELABELLING"
      refute iso.graph_digest == base.graph_digest
    end

    test "the one-triple-changed vector is lawful but must not collide with base", %{
      corpus: corpus
    } do
      changed = Corpus.fetch_vector!(corpus, "one_triple_changed")
      base = Corpus.fetch_vector!(corpus, "base")

      assert changed.digest_must_differ_from_vector == "base"
      assert changed.conformance == :holds
      assert changed.expected_admission == :admitted
      refute changed.graph_digest == base.graph_digest

      # It really does differ from base by exactly one triple's object: take the
      # statement lines of both files (dropping the comment headers, which
      # legitimately differ) and diff them.
      base_stmts = statements(base.graph)
      changed_stmts = statements(changed.graph)

      assert length(base_stmts) == length(changed_stmts)
      assert base_stmts -- changed_stmts == [~s(ex:tier "1"^^xsd:integer .)]
      assert changed_stmts -- base_stmts == [~s(ex:tier "9"^^xsd:integer .)]
    end

    test "all ten vector digests are pairwise distinct", %{corpus: corpus} do
      digests = corpus |> Corpus.vectors() |> Enum.map(& &1.graph_digest)
      assert length(Enum.uniq(digests)) == length(digests)
    end
  end

  describe "RFC S15 -- a sh:Warning must not override a failing sh:Violation" do
    test "the severity partition decides admission on every SHACL vector", %{corpus: corpus} do
      for name <-
            ~w(base shacl_warning_only shacl_violation shacl_violation_and_warning unadmitted_predicate) do
        v = Corpus.fetch_vector!(corpus, name)
        p = Vector.shacl_partition(v)
        viol = p["violations_only"]["status"]

        assert Vector.admission_from_severity(viol) == v.expected_admission,
               "S15 derivation disagrees with the sidecar for #{name}"
      end
    end

    test "warning-only is REFUSED by graphlaw's conforms but ADMITTED by SA2A", %{corpus: corpus} do
      v = Corpus.fetch_vector!(corpus, "shacl_warning_only")
      p = Vector.shacl_partition(v)

      assert v.measured["dialects"]["SHACL"] == "REFUSED"
      assert p["full"]["status"] == "REFUSED"
      assert p["violations_only"]["status"] == "ADMITTED"
      assert p["warnings_only"]["status"] == "REFUSED"

      assert Vector.severity_class("ADMITTED", "REFUSED") == :warning_only
      assert v.expected_admission == :admitted
      assert v.expected_refusal == nil
      assert v.conformance == :holds
    end

    test "a violation alongside a warning still refuses, attributed to the violation", %{
      corpus: corpus
    } do
      v = Corpus.fetch_vector!(corpus, "shacl_violation_and_warning")
      p = Vector.shacl_partition(v)

      assert p["full"]["results"] == 2
      assert p["violations_only"]["results"] == 1
      assert p["warnings_only"]["results"] == 1
      assert Vector.severity_class("REFUSED", "REFUSED") == :violation
      assert v.expected_admission == :refused
      assert v.expected_refusal.code == :sa2a_shacl_violation
      assert v.expected_refusal.severity == "sh:Violation"
    end

    test "a clean graph classifies as clean, not as warning-only", %{corpus: corpus} do
      p = corpus |> Corpus.fetch_vector!("base") |> Vector.shacl_partition()
      assert Vector.severity_class(p["violations_only"]["status"], p["full"]["status"]) == :clean
    end
  end

  describe "dialect isolation -- each negative vector names one cause" do
    test "each single-dialect vector refuses exactly the dialect it targets", %{corpus: corpus} do
      expected = %{
        "shex_structure" => "SHEX",
        "shacl_violation" => "SHACL",
        "unadmitted_predicate" => "SHACL",
        "falsifier_positive" => "N3_DENIAL"
      }

      for {name, dialect} <- expected do
        v = Corpus.fetch_vector!(corpus, name)
        refused = for {d, "REFUSED"} <- v.measured["dialects"], do: d

        assert refused == [dialect],
               "#{name} should refuse only #{dialect}, refused #{inspect(refused)}"

        assert v.expected_refusal.dialect == dialect
      end
    end

    test "the base vector admits on every dialect", %{corpus: corpus} do
      v = Corpus.fetch_vector!(corpus, "base")
      assert Map.values(v.measured["dialects"]) |> Enum.uniq() == ["ADMITTED"]
      assert v.expected_admission == :admitted
    end
  end

  describe "law graph composition" do
    test "law_graph/2 is the subject graph plus the admitted rules and hooks", %{corpus: corpus} do
      v = Corpus.fetch_vector!(corpus, "base")
      law = Corpus.law_graph(corpus, v)

      assert law ==
               Enum.join(
                 [v.graph, Corpus.part(corpus, :rules), Corpus.part(corpus, :hooks)],
                 "\n"
               )

      assert law =~ "=> false ."
      assert law =~ "kh:Hook"
      assert String.starts_with?(law, v.graph)
    end

    test "the fixed parts are the real files", %{corpus: corpus} do
      for {key, file} <- [
            profile: "profile.ttl",
            shapes: "shapes.shacl.ttl",
            shapes_violations: "shapes.violations.shacl.ttl",
            shapes_warnings: "shapes.warnings.shacl.ttl",
            shex_schema: "schema.shex",
            shape_map: "shape_map.json",
            rules: "rules/denials.n3",
            hooks: "hooks/admitted_hooks.ttl",
            event: "event.ttl"
          ] do
        assert Corpus.part(corpus, key) == File.read!(Path.join(corpus.dir, file))
      end
    end

    test "the severity-partitioned shapes really are severity-partitioned", %{corpus: corpus} do
      # Compare STATEMENTS, not raw text: each partition's comment header
      # explains both severities, so a substring check over the whole file would
      # be measuring prose rather than shapes.
      viol = corpus |> Corpus.part(:shapes_violations) |> statements() |> Enum.join("\n")
      warn = corpus |> Corpus.part(:shapes_warnings) |> statements() |> Enum.join("\n")
      full = corpus |> Corpus.part(:shapes) |> statements() |> Enum.join("\n")

      refute viol =~ "sh:Warning"
      assert viol =~ "sh:severity sh:Violation"

      assert warn =~ "sh:severity sh:Warning"
      refute warn =~ "sh:Violation"

      assert full =~ "sh:severity sh:Warning"
      assert full =~ "sh:severity sh:Violation"

      # The partition is exhaustive: every severity-bearing statement in the
      # full shapes graph appears in exactly one of the two partitions.
      severities = fn text ->
        text |> statements() |> Enum.filter(&String.starts_with?(&1, "sh:severity"))
      end

      assert Enum.sort(severities.(Corpus.part(corpus, :shapes))) ==
               Enum.sort(
                 severities.(Corpus.part(corpus, :shapes_violations)) ++
                   severities.(Corpus.part(corpus, :shapes_warnings))
               )
    end

    test "the shape map is the [[node, shape], ...] shape validate_all/5 parses", %{
      corpus: corpus
    } do
      assert {:ok, pairs} = JSON.decode(Corpus.part(corpus, :shape_map))
      assert length(pairs) == 2
      for pair <- pairs, do: assert(length(pair) == 2)
    end

    test "the ShEx schema is ShExJ, which is what the wasm boundary actually takes", %{
      corpus: corpus
    } do
      assert {:ok, schema} = JSON.decode(Corpus.part(corpus, :shex_schema))
      assert schema["type"] == "Schema"
      assert [%{"type" => "ShapeDecl", "id" => id}] = schema["shapes"]
      assert id == "http://example.org/sa2a/AgentShexShape"
    end
  end

  describe "engine pinning and honest deferrals" do
    test "the manifest pins the exact wasm artifact the values were measured against", %{
      corpus: corpus
    } do
      e = Corpus.engine(corpus)

      assert e["graphlaw_version"] == "praxis-graphlaw v26.7.5"
      assert e["wasm_sha256"] =~ ~r/\A[0-9a-f]{64}\z/
      assert e["wasm_bytes"] == 3_249_361

      # The pinned engine's own BLAKE3 self-test equals the published vector for "abc".
      assert e["blake3_self_test"]["digest"] ==
               "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85"
    end

    test "the vendored wasm every checkout contains has the real sha256 the manifest pins", %{
      corpus: corpus
    } do
      # The corpus pins the engine it was measured against by sha256. That
      # engine is vendored at `priv/graphlaw/praxis_graphlaw.wasm`, so the pin
      # is checkable on EVERY checkout -- not only where a sibling praxis
      # workspace happens to exist. (This test previously joined
      # "/Users/sac/praxis" with a manifest path that already starts with
      # "praxis/", a path that never existed, so it always took its "not
      # checkable here" branch and never compared a digest.)
      actual =
        AshA2A.GraphLaw.wasm_path()
        |> File.read!()
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      assert actual == Corpus.engine(corpus)["wasm_sha256"]

      assert byte_size(File.read!(AshA2A.GraphLaw.wasm_path())) ==
               Corpus.engine(corpus)["wasm_bytes"]
    end

    test "every measured divergence from the RFC is recorded, not hidden", %{corpus: corpus} do
      ids = corpus |> Corpus.deferred() |> Enum.map(& &1["id"]) |> Enum.sort()

      assert ids == [
               "hooks_never_register_through_wasm_run_hooks",
               "malformed_turtle_is_not_refused_by_the_engine",
               "profile_graph_axioms_are_not_applied_to_the_data_graph",
               "shacl_result_severity_not_exposed_by_pinned_wasm"
             ]

      for entry <- Corpus.deferred(corpus) do
        assert entry["status"] in ~w(BLOCKED_ON_PINNED_ENGINE WORKED_AROUND HOST_GATE_REQUIRED OBSERVED)
        assert String.length(entry["measured"]) > 80
        assert String.length(entry["consequence"]) > 40
      end
    end

    test "the malformed vector is honestly marked as needing a host-side gate", %{corpus: corpus} do
      v = Corpus.fetch_vector!(corpus, "malformed")

      assert v.expected_admission == :refused
      assert v.expected_refusal.code == :sa2a_malformed_graph
      assert v.expected_refusal.dialect == "HOST_PARSE_GATE"
      assert v.conformance == :host_gate_required
    end

    test "run_hooks was really measured on every vector, and the result is recorded as-is", %{
      corpus: corpus
    } do
      for v <- Corpus.vectors(corpus) do
        hooks = v.measured["run_hooks"]
        assert hooks["status"] == "ADMITTED"
        # Recorded exactly as measured, including the empty schedule that the
        # `hooks_never_register_through_wasm_run_hooks` deferral explains.
        assert hooks["schedule"] == []
      end
    end

    test "the manifest states the qualification's exact scope and its non-claims", %{
      corpus: corpus
    } do
      claim = corpus.manifest["qualification_claim"]

      assert corpus.manifest["qualification"] == "SA2A Portable Semantic Execution Conformance"
      assert claim =~ "over THIS finite suite"
      assert claim =~ "does not establish universal semantic equivalence"
      assert claim =~ "cross-IMPLEMENTATION"
    end

    test "replay verification on the pinned engine was byte-identical", %{corpus: corpus} do
      d = corpus.manifest["determinism"]

      assert d["graph_hash_run2"] == d["graph_hash_run3"]
      assert d["validate_all_replay"]["status"] == "ADMITTED"
      assert d["validate_all_replay"]["first_hash"] == d["validate_all_replay"]["second_hash"]
    end
  end

  # --- real helpers, no fakes -------------------------------------------

  defp temp_corpus do
    src = Corpus.load!().dir
    dest = Path.join(System.tmp_dir!(), "sa2a_corpus_#{uniq()}")
    File.mkdir_p!(dest)
    File.cp_r!(src, dest)
    on_exit(fn -> File.rm_rf(dest) end)
    dest
  end

  # Re-stamps one file's sha256 in a temp corpus's manifest, so a test that is
  # about a DIFFERENT failure mode (an unknown refusal code) is not short-
  # circuited by the digest gate firing first.
  defp remanifest(dir, rel) do
    path = Path.join(dir, "MANIFEST.json")
    {:ok, manifest} = JSON.decode(File.read!(path))
    bytes = File.read!(Path.join(dir, rel))

    updated =
      put_in(manifest, ["files", rel], %{
        "bytes" => byte_size(bytes),
        "sha256" => Base.encode16(:crypto.hash(:sha256, bytes), case: :lower),
        "blake3" => manifest["files"][rel]["blake3"]
      })

    File.write!(path, JSON.encode!(updated))
  end

  defp uniq, do: System.unique_integer([:positive, :monotonic])

  # Statement lines of a Turtle document: comments and blank lines dropped,
  # whitespace normalized. Comment headers legitimately differ between vectors.
  defp statements(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
  end
end

# ==============================================================================
# SECTION 6: Original test/ash_a2a_sa2a_graphlaw_live_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2ASA2AGraphlawLiveTest do
  @moduledoc """
  Live re-verification of the SA2A conformance corpus against the REAL pinned
  GraphLaw wasm, through a REAL `node` subprocess.

  Chicago-school throughout: a real OS subprocess, the real 3.2 MB wasm
  artifact, the real corpus files on disk, and assertions on real returned
  digests and statuses. Nothing is mocked -- in particular the engine is never
  stubbed, because a fabricated engine answer would defeat the only thing this
  corpus exists to establish.

  On a machine without `node` or without the praxis wasm checkout, these tests
  **skip visibly** with a named reason rather than silently substituting a
  double. `AshA2ASA2ACorpusTest` still holds there: it asserts over the recorded
  measurements and the real file digests, which need no engine.
  """
  use ExUnit.Case, async: true

  alias AshA2A.SA2A.{Corpus, Graphlaw}
  alias AshA2A.SA2A.Corpus.Vector

  @moduletag :graphlaw

  setup_all do
    corpus = Corpus.load!()

    # One real subprocess run for the whole module: the driver measures every
    # vector in one pass, so this is one real engine execution, not one per test.
    case Graphlaw.measure(corpus.dir) do
      {:ok, live} ->
        {:ok, corpus: corpus, live: live}

      {:error, err} ->
        # Not a silent skip: `test_helper.exs` already excludes this whole module
        # with a printed reason when the engine is unavailable, so reaching here
        # means the engine WAS available and the real run genuinely failed.
        raise "SA2A live graphlaw run failed: #{inspect(err)}"
    end
  end

  describe "the pinned engine is the engine the corpus was measured against" do
    test "the running wasm's real sha256 and version match the manifest", ctx do
      live = ctx.live
      engine = Corpus.engine(ctx.corpus)

      assert live["wasm_sha256"] == engine["wasm_sha256"]
      assert live["wasm_bytes"] == engine["wasm_bytes"]
      assert live["graphlaw_version"] == engine["graphlaw_version"]
    end

    test "the running wasm computes the published BLAKE3 vector for \"abc\"", ctx do
      assert ctx.live["blake3_abc"] ==
               "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85"
    end
  end

  describe "every recorded expectation still holds against a real engine run" do
    test "every vector's recorded graph and law-graph digests are reproduced live", ctx do
      live = ctx.live

      for v <- Corpus.vectors(ctx.corpus) do
        measured = live["vectors"][v.name]
        assert measured, "no live measurement for #{v.name}"
        assert measured["graph_hash"] == v.graph_digest, "graph digest drift in #{v.name}"
        assert measured["law_graph_hash"] == v.law_graph_digest, "law digest drift in #{v.name}"
      end
    end

    test "every vector's recorded dialect statuses are reproduced live", ctx do
      live = ctx.live

      for v <- Corpus.vectors(ctx.corpus) do
        assert live["vectors"][v.name]["dialects"] == v.measured["dialects"],
               "dialect status drift in #{v.name}"
      end
    end

    test "the S15 severity partition is reproduced live and still decides admission", ctx do
      live = ctx.live

      for v <- Corpus.vectors(ctx.corpus), v.class =~ "shacl" or v.class == "positive_baseline" do
        partition = live["vectors"][v.name]["shacl_by_severity_partition"]

        assert partition == Vector.shacl_partition(v), "partition drift in #{v.name}"

        assert Vector.admission_from_severity(partition["violations_only"]["status"]) ==
                 v.expected_admission,
               "live S15 derivation disagrees with the sidecar for #{v.name}"
      end
    end

    test "the warning-only vector really admits while graphlaw really refuses", ctx do
      m = ctx.live["vectors"]["shacl_warning_only"]

      assert m["dialects"]["SHACL"] == "REFUSED"
      assert m["shacl_by_severity_partition"]["violations_only"]["status"] == "ADMITTED"

      assert Vector.severity_class(
               m["shacl_by_severity_partition"]["violations_only"]["status"],
               m["shacl_by_severity_partition"]["full"]["status"]
             ) == :warning_only

      assert Corpus.fetch_vector!(ctx.corpus, "shacl_warning_only").expected_admission ==
               :admitted
    end

    test "replay verification is byte-identical on every vector", ctx do
      for {name, m} <- ctx.live["vectors"] do
        assert m["replay"]["status"] == "ADMITTED", "replay not admitted for #{name}"
        assert m["replay"]["first_hash"] == m["replay"]["second_hash"], "replay drift in #{name}"
      end
    end
  end

  describe "the two RFC requirements the pinned engine does NOT meet" do
    test "S12 blank-node isomorphism still FAILS live, exactly as recorded", ctx do
      live = ctx.live
      iso = live["vectors"]["base_bnode_relabelled"]["graph_hash"]
      base = live["vectors"]["base"]["graph_hash"]

      # The RFC requires these to be equal. They are not. The corpus says so.
      refute iso == base

      assert Corpus.fetch_vector!(ctx.corpus, "base_bnode_relabelled").conformance ==
               :failing_on_pinned_engine
    end

    test "graph-declared hooks still never register live, exactly as recorded", ctx do
      for {name, m} <- ctx.live["vectors"] do
        assert m["run_hooks"]["status"] == "ADMITTED"
        assert m["run_hooks"]["schedule"] == [], "unexpected live hook schedule for #{name}"
      end

      deferral =
        ctx.corpus
        |> Corpus.deferred()
        |> Enum.find(&(&1["id"] == "hooks_never_register_through_wasm_run_hooks"))

      assert deferral["status"] == "BLOCKED_ON_PINNED_ENGINE"
    end
  end

  describe "error typing at the native boundary" do
    test "a missing wasm is a typed refusal, not a crash", %{corpus: corpus} do
      assert {:error, %{code: :sa2a_graphlaw_unavailable, detail: :wasm_not_built}} =
               Graphlaw.measure(corpus.dir,
                 wasm_path:
                   Path.join(
                     System.tmp_dir!(),
                     "no_such_graphlaw_#{:erlang.unique_integer([:positive])}.wasm"
                   )
               )
    end

    test "a missing corpus directory is a typed refusal from the real driver", _ctx do
      missing =
        Path.join(System.tmp_dir!(), "no_such_corpus_#{:erlang.unique_integer([:positive])}")

      assert {:error, %{code: :sa2a_graphlaw_driver_error, detail: detail, exit: exit_code}} =
               Graphlaw.measure(missing)

      assert detail =~ "MANIFEST.json not found"
      assert exit_code == 4
    end
  end
end

# ==============================================================================
# SECTION 7: Original test/ash_a2a_schema_extension_test.exs
# ==============================================================================

defmodule AshA2A.Test.SchemaExtensionFixture do
  @moduledoc """
  Real ETS fixture surface for lane V25, defined inside this test's own file
  (same established pattern as `AshA2A.Test.ProtocolExtensionE2EFixture`).

  `AshA2A.Test.SchemaExtensionFixture.Note` is a genuine `Ash.Resource` with
  the `AshA2A` extension, exposing two real skills with different argument
  serializability:

    * `search` — fully serializable (required `:string` + optional
      `:integer`), so its schema lands in `params[:schemas]`,
    * `snapshot` — carries an unserializable `:term` argument, so it is
      omitted from `params[:schemas]` and listed under `params[:omitted]`
      with the typed `{:unserializable_type, :term}` reason.

  `search_skill_id/0` / `snapshot_skill_id/0` expose the canonical
  capability ids (`AshA2A.CapabilityIndex.Compiler.capability_id/2`) so the
  assertions never hand-copy them.
  """

  def search_skill_id, do: "AshA2A.Test.SchemaExtensionFixture.Note.search"
  def snapshot_skill_id, do: "AshA2A.Test.SchemaExtensionFixture.Note.snapshot"

  defmodule Note do
    @moduledoc """
    Real ETS fixture resource: two skills, one schema-serializable, one not.
    """

    use Ash.Resource,
      domain: AshA2A.Test.SchemaExtensionFixture.Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshA2A]

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults([:read])

      action :search, :string do
        argument(:query, :string, allow_nil?: false)
        argument(:limit, :integer, default: 10)

        run(fn _input, _context -> {:ok, "ok"} end)
      end

      action :snapshot, :term do
        argument(:state, :term, allow_nil?: false)

        run(fn _input, _context -> {:ok, nil} end)
      end
    end

    # No `a2a do skill ... end` declarations on purpose: public Ash actions
    # are exposed through the capability index without declarations, and an
    # explicit `skill(:snapshot, :snapshot)` override would trip the tree's
    # own `AshA2A.Verifiers.VerifySkills` refusal warning
    # (`refused_type_not_json_serializable`) on the :term argument -- which
    # fails `mix compile --warnings-as-errors`. The :term skill is still in
    # the index (and still lands in params[:omitted] via
    # `AshA2A.Schema.for_skill/2`'s typed error), which is exactly the path
    # this extension exists to cover.
  end

  defmodule Domain do
    @moduledoc """
    Real fixture domain for the Note resource. `validate_config_inclusion?:
    false` -- same established pattern as the other test-only fixture
    domains in this codebase.
    """

    use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

    resources do
      resource(AshA2A.Test.SchemaExtensionFixture.Note)
    end
  end
end

defmodule AshA2A.SchemaExtensionTest do
  @moduledoc """
  Real, end-to-end test for lane V25 (per-skill JSON Schema as an A2A v1.0
  agent extension): a real ETS Ash fixture resource with two exposed skills
  — one fully serializable (`:search`, string + integer arguments) and one
  with an unserializable `:term` argument (`:snapshot`) — driven through the
  REAL pipeline:

    1. `AshA2A.Protocol.Extensions.Schema.declaration/2` projects
       `AshA2A.Schema.for_skill/2` schemas for every public skill, omits the
       `:term` skill into `params[:omitted]` with its typed reason, and
       never fails the card,
    2. `attach/2` appends exactly one extension entry to the real
       `AshA2A.Info.agent_card/1` output — and to card-builder opts —
       idempotently (double attach => still one),
    3. `AshA2A.Protocol.JSON.encode_agent_card/2` puts the declaration on
       the wire (V2's preservation path) and a Jason round-trip loses
       nothing: uri/required/params.schemas/params.omitted with the typed
       reason `%{"reason" => "unserializable_type", "type" => "Ash.Type.Term"}`
       all survive.

  No `Mock`/`mox`/`patch`/`monkeypatch` anywhere: the resource is a real
  `Ash.Resource` on the ETS data layer, the card is the real
  `AshA2A.Info.agent_card/1` projection, and the wire encoding is the real
  unmodified codec.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Protocol.Extensions.Schema
  alias AshA2A.Test.SchemaExtensionFixture

  @search_id SchemaExtensionFixture.search_skill_id()
  @snapshot_id SchemaExtensionFixture.snapshot_skill_id()

  describe "declaration/2" do
    test "projects schemas for serializable skills, omits the :term skill with its typed reason" do
      ext = Schema.declaration(SchemaExtensionFixture.Note)

      assert %AshA2A.Protocol.AgentExtension{} = ext
      assert ext.uri == "urn:sa2a:extension:schema:v1"
      assert ext.required == false
      assert ext.params[:version] == "1"

      search_schema = ext.params.schemas[@search_id]
      assert %{"type" => "object", "required" => ["query"]} = search_schema
      assert %{"type" => "string"} = search_schema["properties"]["query"]
      assert %{"type" => "integer"} = search_schema["properties"]["limit"]

      refute Map.has_key?(ext.params.schemas, @snapshot_id)

      assert [
               %{skill: @snapshot_id, reason: "unserializable_type", type: "Ash.Type.Term"}
             ] = ext.params.omitted
    end

    test "covers every public skill in the compiled capability index (id join with the card)" do
      ext = Schema.declaration(SchemaExtensionFixture.Note)
      card = AshA2A.Info.agent_card(SchemaExtensionFixture.Note)

      schema_ids = Map.keys(ext.params.schemas) ++ Enum.map(ext.params.omitted, & &1.skill)
      card_skill_ids = card.skills |> Enum.map(& &1.id) |> MapSet.new()

      assert MapSet.new(schema_ids) == card_skill_ids
      assert MapSet.size(card_skill_ids) > 0
      assert @search_id in card_skill_ids
    end
  end

  describe "attach/2" do
    test "appends the declaration to a real agent card's capabilities.extensions" do
      card = AshA2A.Info.agent_card(SchemaExtensionFixture.Note)
      assert card.capabilities[:extensions] == nil

      attached = Schema.attach(card, SchemaExtensionFixture.Note)

      assert [%AshA2A.Protocol.AgentExtension{} = ext] = attached.capabilities.extensions
      assert ext.uri == Schema.uri()
      assert ext.params.schemas[@search_id]["required"] == ["query"]
      # The rest of the card is untouched.
      assert attached.skills == card.skills
      assert attached.url == card.url
    end

    test "double attach is idempotent: exactly one same-URI entry" do
      attached_twice =
        SchemaExtensionFixture.Note
        |> AshA2A.Info.agent_card()
        |> Schema.attach(SchemaExtensionFixture.Note)
        |> Schema.attach(SchemaExtensionFixture.Note)

      assert [%AshA2A.Protocol.AgentExtension{} = ext] =
               attached_twice.capabilities.extensions

      assert ext.uri == Schema.uri()
      assert ext.params.schemas[@search_id]["required"] == ["query"]
    end

    test "attaches onto card-builder opts, replacing same-URI entries idempotently" do
      existing = %AshA2A.Protocol.AgentExtension{uri: Schema.uri(), params: %{"stale" => true}}

      opts =
        [capabilities: %{streaming: true, extensions: [existing]}]
        |> Schema.attach(SchemaExtensionFixture.Note)
        |> Schema.attach(SchemaExtensionFixture.Note)

      assert [%AshA2A.Protocol.AgentExtension{} = ext] = opts[:capabilities][:extensions]
      assert ext.uri == Schema.uri()
      assert ext.params[:version] == "1"
      # The stale same-URI entry was replaced, not appended after.
      assert length(opts[:capabilities][:extensions]) == 1
      # Other capability keys survive.
      assert opts[:capabilities][:streaming] == true
    end

    test "empty builder opts get a capabilities map with the declaration" do
      opts = Schema.attach([], SchemaExtensionFixture.Note)
      assert [%AshA2A.Protocol.AgentExtension{uri: uri} = ext] = opts[:capabilities][:extensions]
      assert uri == Schema.uri()
      assert ext.params.schemas[@search_id]["required"] == ["query"]
    end
  end

  describe "wire survival" do
    test "encoded card carries the extension through the real codec and a Jason round-trip" do
      card =
        SchemaExtensionFixture.Note
        |> AshA2A.Info.agent_card()
        |> Schema.attach(SchemaExtensionFixture.Note)

      encoded =
        card
        |> AshA2A.Protocol.JSON.encode_agent_card(url: card.url)
        |> Jason.encode!()

      wire = Jason.decode!(encoded)

      assert %{
               "capabilities" => %{
                 "extensions" => [
                   %{
                     "uri" => "urn:sa2a:extension:schema:v1",
                     "required" => false,
                     "description" => description,
                     "params" => %{
                       "version" => "1",
                       "schemas" => schemas,
                       "omitted" => [omitted]
                     }
                   }
                 ]
               }
             } = wire

      assert %{"type" => "object", "required" => ["query"]} = schemas[@search_id]
      assert %{"type" => "string"} = schemas[@search_id]["properties"]["query"]

      assert %{
               "skill" => @snapshot_id,
               "reason" => "unserializable_type",
               "type" => "Ash.Type.Term"
             } = omitted

      assert description =~ "JSON Schema"
    end

    test "Jason decode -> encode round-trip is stable (idempotent wire form)" do
      card =
        SchemaExtensionFixture.Note
        |> AshA2A.Info.agent_card()
        |> Schema.attach(SchemaExtensionFixture.Note)

      encoded =
        card
        |> AshA2A.Protocol.JSON.encode_agent_card(url: card.url)
        |> Jason.encode!()

      assert encoded |> Jason.decode!() |> Jason.encode!() |> Jason.decode!() ==
               Jason.decode!(encoded)
    end
  end
end

# ==============================================================================
# SECTION 8: Original test/ash_a2a_security_mutation_witness_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SecurityMutationWitnessTest do
  @moduledoc """
  Every security gate (owner scope, forged identity, :strict boot refusals,
  authority_policy, ReceiptStore.boot_check) has a mutation catalog entry that
  names the court that must flip. Read-only: builds mutant plans
  (`Mutation.prepare/1`) but never hot-loads one, so it is safe under async.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Chicago.Mutation
  alias AshA2A.Chicago.Mutation.Catalog

  @root Path.expand("..", __DIR__)

  defp entries_for(module, function, arity) do
    Enum.filter(
      Catalog.entries(),
      &(&1.module == module and &1.function == function and &1.arity == arity)
    )
  end

  test "every security gate has at least one catalog entry" do
    for {gate, module, function, arity} <- Catalog.security_gates() do
      assert entries_for(module, function, arity) != [],
             "security gate #{inspect(gate)} (#{inspect(module)}.#{function}/#{arity}) has no mutation entry"
    end
  end

  test "every security entry names a killer family and an on-disk ExUnit court" do
    for {gate, module, function, arity} <- Catalog.security_gates(),
        m <- entries_for(module, function, arity) do
      assert m.killers != [], "#{gate}/#{m.id}: no killers named"
      assert is_binary(m.guard) and m.guard != "", "#{gate}/#{m.id}: no guard text"
      assert is_binary(m.description), "#{gate}/#{m.id}: no court description"

      paths = Regex.scan(~r{test/[\w/\.]+\.exs}, m.description) |> List.flatten()
      assert paths != [], "#{gate}/#{m.id}: description names no court file"

      for p <- paths do
        assert File.exists?(Path.join(@root, p)), "#{gate}/#{m.id}: court file #{p} missing"
      end
    end
  end

  test "every security entry's target resolves to a buildable mutant" do
    for {gate, module, function, arity} <- Catalog.security_gates(),
        m <- entries_for(module, function, arity) do
      assert {:ok, plan} = Mutation.prepare(m), "#{gate}/#{m.id}: target does not resolve"
      assert plan.clauses_mutated >= 1
    end
  end

  test "security entry ids are unique across the catalog" do
    ids = Catalog.ids()
    assert ids == Enum.uniq(ids)
  end
end

# ==============================================================================
# SECTION 9: Original test/ash_a2a_self_card_test.exs
# ==============================================================================

defmodule AshA2a.SelfCardTest do
  @moduledoc """
  Real-run court for the self agent card: builds the card from the compiled
  capability surface, encodes it with the shipped codec, and round-trips the
  on-disk artifact through `AshA2A.Protocol.JSON.decode_agent_card/1`.
  """

  use ExUnit.Case, async: false

  @output "priv/sa2a/self-agent-card.json"

  test "generated card decodes through the shipped codec (round-trip)" do
    card = Mix.Tasks.AshA2a.SelfCard.build_self_card()

    map = AshA2A.Protocol.JSON.encode_agent_card(card, url: card.url)

    assert %{} = map

    assert map["protocolVersion"] == AshA2A.Protocol.Version.protocol_version() or
             map["protocolVersion"] == nil

    assert {:ok, %AshA2A.Protocol.AgentCard{} = decoded} =
             AshA2A.Protocol.JSON.decode_agent_card(map)

    assert decoded.name == "ash_a2a"
    assert decoded.url == "http://localhost:4000"
    assert length(decoded.skills) == 7

    ids = decoded.skills |> Enum.map(& &1.id) |> Enum.sort()

    assert ids == [
             "capability_index.compile",
             "card.sign_verify",
             "codec.encode_decode",
             "plug.serve_a2a",
             "semantic.admission",
             "semantic.graphlaw",
             "semantic.graphlaw_engine"
           ]

    Enum.each(decoded.skills, fn skill ->
      assert is_binary(skill.description) and skill.description != ""
      assert skill.tags != []
      refute skill.description =~ "`"
      refute skill.description =~ "\n"
    end)

    # served-shape: every supported_interface carries the current protocol version
    Enum.each(decoded.supported_interfaces, fn iface ->
      assert iface.protocol_version == AshA2A.Protocol.Version.protocol_version()
      assert iface.protocol_binding == "JSONRPC"
    end)
  end

  test "on-disk artifact exists, parses as JSON, and round-trips" do
    assert File.exists?(@output), "run `mix ash_a2a.self_card` to generate #{@output}"

    assert {:ok, map} = @output |> File.read!() |> Jason.decode()

    assert {:ok, %AshA2A.Protocol.AgentCard{} = decoded} =
             AshA2A.Protocol.JSON.decode_agent_card(map)

    assert decoded.skills != []
    assert length(decoded.skills) == 7
  end

  test "generation is deterministic (byte-stable across two real regenerations)" do
    dir = Path.join(System.tmp_dir!(), "self_card_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    one = Path.join(dir, "one.json")
    two = Path.join(dir, "two.json")

    Mix.Tasks.AshA2a.SelfCard.run(["--output", one])
    Mix.Tasks.AshA2a.SelfCard.run(["--output", two])

    assert File.read!(one) == File.read!(two)
    assert File.read!(one) == File.read!(@output)
  end
end

# ==============================================================================
# SECTION 10: Original test/ash_a2a_semantic_agent_card_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SemanticAgentCardTest do
  @moduledoc """
  RFC-SA2A-001 S10 -- semantic capability declarations.

  Every declaration under test is derived from the **real compiled**
  `AshA2A.CapabilityIndex` of a real `Ash.Resource`
  (`AshA2A.Test.SemanticPeerFixture.Ordering`), which is itself derived from
  `Ash.Resource.Info.public_actions/1`. Nothing here hand-builds a skill
  struct to feed the derivation, so a drift between the semantic declaration
  and the real A2A capability surface would fail these tests rather than
  hide.

  The central assertion is the negative one: a declaration is a statement
  that machinery exists, not a grant. `grant?/1` is `false` for every
  declaration of every consequence class, and the struct carries no field
  that could function as a credential.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Semantic.{AgentCard, Extension}
  alias AshA2A.Test.SemanticPeerFixture.Ordering

  setup do
    declarations = AgentCard.for_subject(Ordering)
    %{declarations: declarations, by_iri: Map.new(declarations, &{&1.capability_iri, &1})}
  end

  describe "derivation from the real compiled capability index" do
    test "one declaration per real public Ash action, no more and no fewer", %{
      declarations: declarations
    } do
      index = AshA2A.Info.capability_index!(Ordering)

      assert length(declarations) == length(index)
      assert declarations != []

      # The real compiled index for this fixture: `:read`, `:create`, `:destroy`.
      assert Enum.sort(Enum.map(index, & &1.action)) == [:create, :destroy, :read]
    end

    test "capability IRIs are derived from the canonical {resource, action} id", %{
      by_iri: by_iri
    } do
      expected =
        "urn:sa2a:capability:AshA2A.Test.SemanticPeerFixture.Ordering.create"

      assert Map.has_key?(by_iri, expected)
    end

    test "input and output shape IRIs are declared per capability", %{by_iri: by_iri} do
      declaration =
        Map.fetch!(by_iri, "urn:sa2a:capability:AshA2A.Test.SemanticPeerFixture.Ordering.create")

      assert declaration.input_shape ==
               "urn:sa2a:shape:AshA2A.Test.SemanticPeerFixture.Ordering.create:input"

      assert declaration.output_shape ==
               "urn:sa2a:shape:AshA2A.Test.SemanticPeerFixture.Ordering.create:output"
    end

    test "semantic_basis names canonical Ash introspection, not a second model", %{
      declarations: declarations
    } do
      assert Enum.all?(declarations, &(&1.semantic_basis =~ "ash:public_actions"))
    end

    test "version tracks the negotiated profile version", %{declarations: declarations} do
      assert Enum.all?(declarations, &(&1.version == Extension.profile_version()))
    end
  end

  describe "consequence, authority requirement and receipt class travel together" do
    test "a :read capability is :observe, needs no authority, emits no receipt", %{
      by_iri: by_iri
    } do
      declaration =
        Map.fetch!(by_iri, "urn:sa2a:capability:AshA2A.Test.SemanticPeerFixture.Ordering.read")

      assert declaration.consequence_class == :observe
      assert declaration.authority_requirement == :none
      assert declaration.receipt_class == :none
    end

    test "a :create capability is :change, needs CommandBus admission, emits a receipt", %{
      by_iri: by_iri
    } do
      declaration =
        Map.fetch!(by_iri, "urn:sa2a:capability:AshA2A.Test.SemanticPeerFixture.Ordering.create")

      assert declaration.consequence_class == :change
      assert declaration.authority_requirement == :command_bus_admission
      assert declaration.receipt_class == :command_receipt
    end

    test "a :destroy capability is also consequence-bearing", %{by_iri: by_iri} do
      declaration =
        Map.fetch!(by_iri, "urn:sa2a:capability:AshA2A.Test.SemanticPeerFixture.Ordering.destroy")

      assert declaration.consequence_class == :change
      assert declaration.authority_requirement == :command_bus_admission
    end

    test "an :unknown consequence maps to :unclassified authority, never to :none" do
      skill = %AshA2A.Skill{
        id: "Some.Resource.mystery",
        resource: Some.Resource,
        action: :mystery,
        consequence: :unknown
      }

      declaration = AgentCard.from_skill(skill)

      # The exact failure mode this guards: an unclassified generic action
      # silently declaring that it needs no authority, and thereby becoming
      # the route a real consequence takes around admission.
      assert declaration.authority_requirement == :unclassified
      refute declaration.authority_requirement == :none
      assert declaration.receipt_class == :command_receipt
    end
  end

  describe "preconditions, effects and planner compatibility come from real declarations" do
    test "declared HDDL operators surface as real precondition and effect terms", %{
      by_iri: by_iri
    } do
      declaration =
        Map.fetch!(by_iri, "urn:sa2a:capability:AshA2A.Test.SemanticPeerFixture.Ordering.create")

      assert declaration.preconditions == ["(available item)"]
      assert Enum.sort(declaration.effects) == ["(ordered order)", "not (available item)"]
      assert declaration.planner_compatibility == [:hddl]
    end

    test "a capability with no declared operators claims no planner compatibility", %{
      by_iri: by_iri
    } do
      declaration =
        Map.fetch!(by_iri, "urn:sa2a:capability:AshA2A.Test.SemanticPeerFixture.Ordering.read")

      assert declaration.preconditions == []
      assert declaration.effects == []
      assert declaration.planner_compatibility == []
    end

    test "an undeclared cost envelope is :unbounded, not a fabricated number", %{
      declarations: declarations
    } do
      assert Enum.all?(declarations, &(&1.cost_envelope == :unbounded))
    end
  end

  describe "a declaration is NOT a grant" do
    test "grant?/1 is false for every declaration of every consequence class", %{
      declarations: declarations
    } do
      assert Enum.all?(declarations, &(AgentCard.grant?(&1) == false))
    end

    test "standing/1 is :declaration, never :admitted", %{declarations: declarations} do
      assert Enum.all?(declarations, &(AgentCard.standing(&1) == :declaration))
      refute Enum.any?(declarations, &(AgentCard.standing(&1) == :admitted))
    end

    test "the struct carries no authority token, capability handle or credential", %{
      declarations: [declaration | _]
    } do
      fields = declaration |> Map.from_struct() |> Map.keys() |> Enum.map(&to_string/1)

      # `authority_requirement` states what a caller would need. Nothing here
      # supplies it.
      assert "authority_requirement" in fields

      refute Enum.any?(fields, fn field ->
               field in ~w(authority token credential grant capability_handle secret signature)
             end)
    end

    test "the RDF projection says grantsAuthority false explicitly", %{
      declarations: declarations
    } do
      turtle = AgentCard.to_turtle(declarations)

      assert turtle =~ "sa2a:grantsAuthority false"
      refute turtle =~ "sa2a:grantsAuthority true"
    end
  end

  describe "RDF projection" do
    @tag :graphlaw_engine
    test "the Turtle projection is accepted and hashed by the REAL GraphLaw engine", %{
      declarations: declarations
    } do
      turtle = AgentCard.to_turtle(declarations)

      case AshA2A.Semantic.GraphLaw.graph_hash(turtle) do
        {:ok, digest} ->
          assert String.match?(digest, ~r/\A[0-9a-f]{64}\z/)

          # The same declarations must hash identically on a second real
          # engine invocation -- a fresh wasm instance, no shared state.
          assert {:ok, ^digest} = AshA2A.Semantic.GraphLaw.graph_hash(turtle)

        {:error, %{code: :graphlaw_unavailable} = refusal} ->
          flunk("""
          The real praxis-graphlaw engine was not reachable, so this test could \
          not verify the RDF projection against it: #{inspect(refusal)}

          This is a real environment failure, not a passing test. Configure \
          :ash_a2a, AshA2A.Semantic.GraphLaw.Wasm, wasm_path: ... or set \
          GRAPHLAW_WASM.
          """)
      end
    end

    test "the projection is byte-stable for the same declarations", %{
      declarations: declarations
    } do
      assert AgentCard.to_turtle(declarations) == AgentCard.to_turtle(declarations)

      # And order-independent in the input list, since declarations are
      # sorted by IRI before rendering.
      assert AgentCard.to_turtle(declarations) ==
               AgentCard.to_turtle(Enum.reverse(declarations))
    end

    test "for_subject/1 on a module with no compiled index returns [], it does not raise" do
      assert AgentCard.for_subject(Enum) == []
    end
  end
end

# ==============================================================================
# SECTION 11: Original test/ash_a2a_semantic_attestation_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Semantic.AttestationTest do
  @moduledoc """
  RFC-SA2A-001 S33 semantic attestation, built from receipts a real
  `AshA2A.CommandBus.run/4` actually produced.
  """
  use ExUnit.Case

  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Authority, Command, CommandBus, Identity, Receipt, SemanticSubject}
  alias AshA2A.Semantic.Attestation
  alias AshA2A.Test.Fixture.{KeyedActuationCounter, CountingActuator, Echo}

  @capability "AshA2A.Test.Fixture.CountingActuator.actuate"

  setup do
    Application.put_env(:ash_a2a, :receipt_commit_retry_delays_ms, [1, 1])
    on_exit(fn -> Application.delete_env(:ash_a2a, :receipt_commit_retry_delays_ms) end)

    start_supervised!(KeyedActuationCounter)
    store = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    start_supervised!({AshA2A.ReceiptStore.Memory, name: store})
    %{store_opts: [name: store]}
  end

  defp sha(seed),
    do: "sha256:" <> (seed |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower))

  defp fully_specified_run(command_id, store_opts) do
    principal = Identity.principal("attest-principal")
    authority = Authority.new(principal, @capability, token_id: "attest-auth")

    {:ok, subject} =
      SemanticSubject.new(
        graph_digest: sha("attest-graph"),
        projection_digest: sha("attest-projection"),
        manufacturer_digest: sha("attest-manufacturer")
      )

    effect_key = "attest-#{System.unique_integer([:positive])}"

    command =
      Command.new(@capability,
        command_id: command_id,
        agent_id: "attest-agent",
        principal_id: principal,
        authority: authority,
        semantic_subject: subject,
        input: %{effect_key: effect_key}
      )

    {:ok, receipt} =
      CommandBus.run(command, data_message(%{"effect_key" => effect_key}), CountingActuator,
        store_opts: store_opts,
        plan_digest: sha("attest-plan")
      )

    receipt
  end

  test "an attestation identifies every S33 revision from a real execution", %{
    store_opts: store_opts
  } do
    receipt = fully_specified_run("attest-1", store_opts)

    assert {:ok, attestation} = Attestation.from_receipts([receipt])

    assert attestation.semantic_revision == sha("attest-graph")
    assert attestation.plan_revision == sha("attest-plan")
    assert attestation.manufacturer_revision == sha("attest-manufacturer")
    assert attestation.projected_artifact_digest == sha("attest-projection")

    assert %{decision: :admitted, capability_id: @capability, token_id: "runtime:attest-auth"} =
             attestation.authority_decision

    assert [%{receipt_id: receipt_id, terminal_status: :executed}] = attestation.receipt_set
    assert receipt_id == Identity.external(receipt.receipt_id)
    assert String.starts_with?(attestation.receipt_set_digest, "sha256:")

    assert attestation.observed_post_state.status == :completed
    assert attestation.observed_post_state.terminal_status == :executed
    assert attestation.observed_post_state.consequence == :external_do

    # Everything claimable was observed, so nothing is listed as unobserved.
    assert attestation.unobserved == []
    assert Enum.all?(Attestation.claimable_fields(), &Attestation.claims?(attestation, &1))

    assert :ok = Attestation.verify(attestation, [receipt])
  end

  test "an attestation over a command with no semantic subject claims nothing it did not observe",
       %{store_opts: store_opts} do
    command =
      Command.new("AshA2A.Test.Fixture.Echo.read",
        command_id: "attest-thin-1",
        agent_id: "attest-agent",
        principal_id: "anonymous",
        input: %{}
      )

    assert {:ok, receipt} =
             CommandBus.run(command, data_message(%{}), Echo, store_opts: store_opts)

    assert {:ok, attestation} = Attestation.from_receipts([receipt])

    # The fields that were genuinely not observed are nil AND named.
    assert attestation.semantic_revision == nil
    assert attestation.plan_revision == nil
    assert attestation.manufacturer_revision == nil
    assert attestation.projected_artifact_digest == nil

    for field <- [
          :semantic_revision,
          :plan_revision,
          :manufacturer_revision,
          :projected_artifact_digest
        ] do
      assert field in attestation.unobserved
      refute Attestation.claims?(attestation, field)
    end

    # The fields that WERE observed are still claimed -- absence of one
    # revision does not void the attestation.
    assert Attestation.claims?(attestation, :observed_post_state)
    assert Attestation.claims?(attestation, :authority_decision)
    assert attestation.authority_decision.decision == :not_required

    assert :ok = Attestation.verify(attestation, [receipt])
  end

  test "an attestation edited to claim evidence the receipts never carried fails verify/2", %{
    store_opts: store_opts
  } do
    command =
      Command.new("AshA2A.Test.Fixture.Echo.read",
        command_id: "attest-forged-1",
        agent_id: "attest-agent",
        principal_id: "anonymous",
        input: %{}
      )

    assert {:ok, receipt} =
             CommandBus.run(command, data_message(%{}), Echo, store_opts: store_opts)

    assert {:ok, honest} = Attestation.from_receipts([receipt])
    assert :ok = Attestation.verify(honest, [receipt])

    # Someone edits in a semantic revision that no receipt ever carried.
    forged = %{honest | semantic_revision: sha("a-graph-that-was-never-executed")}

    assert {:error, %{code: :attestation_claims_unobserved_evidence, detail: :semantic_revision}} =
             Attestation.verify(forged, [receipt])

    # And the internal contradiction (a value sitting in a field still listed
    # as unobserved) is caught too.
    assert :semantic_revision in forged.unobserved

    forged_plan = %{honest | plan_revision: sha("a-plan-that-never-ran")}

    assert {:error, %{code: :attestation_claims_unobserved_evidence, detail: :plan_revision}} =
             Attestation.verify(forged_plan, [receipt])
  end

  test "S70: a receipt carrying an UNEARNED evidence class does not yield a verifying attestation",
       %{store_opts: store_opts} do
    alias AshA2A.Evidence.{
      Class,
      HostedCI,
      LocalTest,
      Merge,
      Production,
      Publication,
      RuntimeAlive
    }

    command =
      Command.new("AshA2A.Test.Fixture.Echo.read",
        command_id: "attest-evidence-chain-1",
        agent_id: "attest-agent",
        principal_id: "anonymous",
        input: %{}
      )

    assert {:ok, receipt} =
             CommandBus.run(command, data_message(%{}), Echo, store_opts: store_opts)

    # The receipt the real CommandBus wrote carries the default root class,
    # which is earned at rank 1, so the honest attestation verifies.
    assert {:ok, honest} = Attestation.from_receipts([receipt])
    assert honest.evidence_class.__struct__ == LocalTest
    assert :ok = Attestation.verify(honest, [receipt])

    # `Merge.new/1` builds an unlinked root at rank 6: the right struct, no
    # promotion chain behind it.
    forged_receipt = %{receipt | evidence_class: Merge.new(%{pr: 9})}
    assert {:ok, forged} = Attestation.from_receipts([forged_receipt])
    assert forged.evidence_class.__struct__ == Merge

    assert {:error, %{code: :evidence_class_not_earned}} =
             Attestation.verify(forged, [forged_receipt])

    # A hand-built struct with a made-up link is refused as a broken chain.
    hand_built = %Merge{
      evidence_digest: Class.digest(%{pr: 9}),
      observed_at: DateTime.utc_now(),
      chain_digest: "sha256:whatever"
    }

    hand_built_receipt = %{receipt | evidence_class: hand_built}
    assert {:ok, hand_built_attestation} = Attestation.from_receipts([hand_built_receipt])

    assert {:error, %{code: :evidence_chain_broken}} =
             Attestation.verify(hand_built_attestation, [hand_built_receipt])

    # The same rank, EARNED by real promotions with distinct evidence per
    # step, verifies.
    earned =
      Enum.reduce(
        [
          {HostedCI, %{job: "ci-1"}},
          {Production, %{deploy: "d-1"}},
          {RuntimeAlive, %{probe: "p-1"}},
          {Publication, %{release: "r-1"}},
          {Merge, %{pr: 9}}
        ],
        LocalTest.new(%{suite: "mix test", run: 1}),
        fn {target, basis}, current ->
          {:ok, next} = Class.promote(current, target, basis)
          next
        end
      )

    earned_receipt = %{receipt | evidence_class: earned}
    assert {:ok, earned_attestation} = Attestation.from_receipts([earned_receipt])
    assert earned_attestation.evidence_class.__struct__ == Merge
    assert :ok = Attestation.verify(earned_attestation, [earned_receipt])
  end

  test "an attestation verified against a different receipt set is refused", %{
    store_opts: store_opts
  } do
    first = fully_specified_run("attest-set-1", store_opts)
    second = fully_specified_run("attest-set-2", store_opts)

    assert {:ok, attestation} = Attestation.from_receipts([first])

    assert {:error, %{code: :attestation_receipt_set_mismatch}} =
             Attestation.verify(attestation, [second])
  end

  test "an attestation requires at least one receipt and one actuation" do
    assert {:error, %{code: :attestation_without_receipts}} = Attestation.from_receipts([])

    assert {:error, %{code: :attestation_requires_receipts}} =
             Attestation.from_receipts([%{not: :a_receipt}])
  end

  test "an attestation spanning two different actuations is refused", %{store_opts: store_opts} do
    first = fully_specified_run("attest-multi-1", store_opts)
    second = fully_specified_run("attest-multi-2", store_opts)

    refute first.actuation_id == second.actuation_id

    assert {:error, %{code: :attestation_spans_multiple_actuations, detail: ids}} =
             Attestation.from_receipts([first, second])

    assert length(ids) == 2
  end

  test "the attestation evidence class is the WEAKEST across the receipt set, never the strongest" do
    base = %Receipt{
      receipt_id: Identity.runtime("r-1"),
      command_id: Identity.command("c-1"),
      execution_id: Identity.execution("e-1"),
      agent_id: Identity.agent("a-1"),
      principal_id: Identity.principal("p-1"),
      capability_id: "Cap.act",
      fingerprint: "fp",
      consequence: :external_do,
      status: :completed,
      standing: :observed,
      recorded_at: DateTime.utc_now(),
      actuation_id: Identity.actuation("act-1"),
      idempotency_key: Identity.idempotency("idem-1"),
      actor: Identity.principal("p-1"),
      intended_effect: %{capability_id: "Cap.act", consequence: :external_do},
      input_digest: "sha256:abc",
      logical_clock: 1,
      terminal_status: :executed
    }

    weak = %{base | evidence_class: AshA2A.Evidence.LocalTest.new(%{run: 1}), logical_clock: 1}

    strong = %{
      base
      | receipt_id: Identity.runtime("r-2"),
        evidence_class: AshA2A.Evidence.Merge.new(%{pr: 9}),
        logical_clock: 2
    }

    assert {:ok, attestation} = Attestation.from_receipts([strong, weak])
    assert attestation.evidence_class.__struct__ == AshA2A.Evidence.LocalTest
  end
end

# ==============================================================================
# SECTION 12: Original test/ash_a2a_semantic_conformance_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT


# ==============================================================================
# SECTION 13: Original test/ash_a2a_semantic_cross_peer_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SemanticCrossPeerTest do
  @moduledoc """
  RFC-SA2A-001 S8/S49/S50/S51/S75/S76 -- the central cross-peer test.

  ## What is proved here

      Message_A -> Candidate_B -> GraphLaw_B -> O*_B

  and never

      Message_A -> O*_B

  Peer A builds a real `AshA2A.Semantic.Envelope`, attaches it to a real
  `AshA2A.Protocol.Message` through the real A2A extension mechanism, and sends it to
  peer B over the **real A2A transport**: a real `AshA2A.Protocol.Plug` JSON-RPC
  `message/send` request, serialized to real JSON, driven through the real
  unmodified in-repo `AshA2A.Protocol.*` runtime into a real supervised `AshA2A.Protocol.Agent` GenServer.

  Peer B treats it as a candidate and runs its **own**
  `AshA2A.Semantic.GraphLaw` engine -- the real prebuilt `praxis-graphlaw`
  WebAssembly module -- against its **own** SHACL shapes before anything
  gains standing.

  ## Assertions are on peer B's internal standing transitions

  A reply saying "admitted" is peer B's word for what it did. That is not
  what these tests check. They read peer B's real
  `AshA2A.Semantic.Standing.Ledger` -- a real supervised process recording
  every standing edge peer B actually took -- and assert the path is
  `[:received, :candidate, :admitted]`. A peer that replied "admitted"
  without passing through `:candidate` would fail here even though its reply
  looked correct.

  ## No mocks

  Real `Ash.Resource`, real `AshA2A.Protocol.Agent` GenServer, real `AshA2A.Protocol.Plug`, real
  JSON-RPC envelope, real wasm engine subprocess, real ledger process, real
  SHACL violations. Every assertion is on real returned state -- digests,
  standing values, decoded HTTP response bodies -- never on "was X called".
  """

  use ExUnit.Case, async: false
  @moduletag :graphlaw_engine

  @moduletag :serial
  @moduletag :serial_shard
  alias AshA2A.Semantic.{Envelope, Extension, GraphLaw, Peer, Standing}
  alias AshA2A.Semantic.Standing.Ledger
  alias AshA2A.Test.SemanticPeerFixture.{Graphs, PeerB}

  @peer_a "peer-a"
  @peer_b "peer-b"
  @base_url "http://localhost:4200/a2a"

  setup do
    unless GraphLaw.impl().available?() do
      flunk("""
      The real praxis-graphlaw engine is not reachable from this runtime, so \
      the cross-peer admission claim cannot be exercised at all.

      Resolved wasm path: #{AshA2A.Semantic.GraphLaw.Wasm.wasm_path()}
      Resolved host shim: #{AshA2A.Semantic.GraphLaw.Wasm.host_script()}

      This is a real environment failure reported as a failure, not a silent \
      skip and not a mock substitution.
      """)
    end

    unique = System.unique_integer([:positive])
    agent_name = :"sa2a_cross_peer_b_#{unique}"
    ledger_name = :"sa2a_cross_peer_ledger_#{unique}"

    {:ok, ledger} = start_supervised({Ledger, name: ledger_name})
    {:ok, agent_pid} = start_supervised({PeerB, name: agent_name})

    plug_opts =
      AshA2A.Protocol.Plug.init(
        agent: agent_name,
        base_url: @base_url,
        agent_card_opts: Extension.advertise(url: @base_url)
      )

    # Peer B's own advertisement is the card its real AshA2A.Protocol.Plug serves
    # (RFC-SA2A-002 §55: semantic standing crosses only a boundary this peer
    # itself advertises -- SA2A-NEG-005).
    served_card =
      :get
      |> Plug.Test.conn("/.well-known/agent-card.json")
      |> AshA2A.Protocol.Plug.call(plug_opts)
      |> Map.fetch!(:resp_body)
      |> Jason.decode!()

    :ok =
      configure_peer(agent_name,
        name: @peer_b,
        ledger: ledger_name,
        shapes: Graphs.peer_b_shapes(),
        mode: :strict,
        agent_card: served_card
      )

    on_exit(fn ->
      PeerB.deconfigure(agent_name)
      :persistent_term.erase({PeerB, nil})
    end)

    %{
      agent: agent_name,
      agent_pid: agent_pid,
      ledger: ledger,
      ledger_name: ledger_name,
      plug_opts: plug_opts
    }
  end

  # -- Real transport helper ---------------------------------------------------
  #
  # Measured constraint of the ported `AshA2A.Protocol.Agent` runtime
  # (SEC-02/SEC-08 worker isolation): `handle_message/2` runs in a spawned,
  # unregistered worker process, so the fixture's `registered_name()` lookup
  # is `nil` inside the worker and the worker reads its peer configuration
  # from `{PeerB, nil}`. The fixture's own per-agent key is still installed
  # through `PeerB.configure/2` (its card path uses it), and this helper
  # mirrors the SAME real `Peer` struct under the key the worker actually
  # reads. Safe because this module is `async: false` and `:serial`.
  defp configure_peer(agent_name, opts) do
    :ok = PeerB.configure(agent_name, opts)
    :persistent_term.put({PeerB, nil}, PeerB.peer(agent_name))
    :ok
  end

  #
  # A real JSON-RPC `message/send` request, JSON-encoded exactly as a remote
  # peer A would put it on the wire, driven through the real AshA2A.Protocol.Plug.
  defp send_over_real_transport(plug_opts, %AshA2A.Protocol.Message{} = message) do
    {:ok, encoded_message} = AshA2A.Protocol.JSON.encode(message)

    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => System.unique_integer([:positive]),
        "method" => "message/send",
        "params" => %{"message" => encoded_message}
      })

    conn =
      :post
      |> Plug.Test.conn("/", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> AshA2A.Protocol.Plug.call(plug_opts)

    {conn.status, Jason.decode!(conn.resp_body)}
  end

  # The real JSON-RPC `message/send` result shape produced by the in-repo
  # ported codec (`AshA2A.Protocol.*`, a2a-elixir 0.3.0 semantics):
  # `result.task.artifacts[].parts[].data`.
  defp reply_data(response), do: reply_data_from_task(task_result(response))

  defp reply_data_from_task(%{"artifacts" => [%{"parts" => parts} | _]}),
    do: Enum.find_value(parts, fn part -> Map.get(part, "data") end)

  defp task_result(%{"result" => %{"task" => task}}), do: task

  # A real graph digest, from the SAME real engine peer B will independently
  # recompute -- not a placeholder. The `:graph_digest` opt lets a test
  # deliberately supply a WRONG one (the forged-digest test below).
  defp real_envelope(graph, opts \\ []) do
    digest = Keyword.get_lazy(opts, :graph_digest, fn -> elem(GraphLaw.graph_hash(graph), 1) end)

    Envelope.new!(
      [
        envelope_id: "urn:uuid:sa2a-cross-peer-" <> Ash.UUIDv7.generate(),
        kind: "sa2a:Request",
        # RFC-SA2A-002 §54: an envelope with no semantic basis has no standing
        # to earn (SA2A-ENV-004).
        semantic_basis: ["urn:sa2a:basis:peer-b-order-shapes:v1"],
        provenance: %{"agent" => @peer_a},
        graph: %{media_type: "text/turtle", digest: digest, content: graph}
      ] ++ Keyword.take(opts, [:consequence_class, :capability_iri])
    )
  end

  defp peer_a_message(graph, opts \\ []) do
    envelope = real_envelope(graph, opts)

    message =
      "semantic request"
      |> AshA2A.Protocol.Message.new_user()
      |> Extension.activate(Envelope.to_map(envelope))

    {envelope, message}
  end

  # ---------------------------------------------------------------------------
  # THE CENTRAL TEST
  # ---------------------------------------------------------------------------

  describe "Message_A -> Candidate_B -> GraphLaw_B -> O*_B" do
    test "a conforming envelope crosses the real transport and is admitted only after peer B's own GraphLaw run",
         %{plug_opts: plug_opts, ledger: ledger} do
      {envelope, message} = peer_a_message(Graphs.conforming_order())

      {status, response} = send_over_real_transport(plug_opts, message)

      assert status == 200
      data = reply_data(response)
      assert data["standing"] == "admitted"
      assert data["envelope_id"] == envelope.envelope_id

      # Peer B's own engine produced this digest; peer A never supplied one.
      assert String.match?(data["graph_digest"], ~r/\A[0-9a-f]{64}\z/)

      # THE ASSERTION THAT MATTERS: peer B's real internal standing path.
      assert Ledger.path(ledger, envelope.envelope_id) == [:received, :candidate, :admitted]

      [received_to_candidate, candidate_to_admitted] =
        Ledger.entries(ledger, envelope.envelope_id)

      assert received_to_candidate.from == :received
      assert received_to_candidate.to == :candidate
      assert received_to_candidate.reason == :envelope_parsed

      assert candidate_to_admitted.from == :candidate
      assert candidate_to_admitted.to == :admitted
      assert candidate_to_admitted.reason == :graphlaw_admitted
    end

    test "peer B's admitted digest is the digest of the graph peer B actually received", %{
      plug_opts: plug_opts
    } do
      graph = Graphs.conforming_order()
      {_envelope, message} = peer_a_message(graph)

      {200, response} = send_over_real_transport(plug_opts, message)

      # Independently computed, by this test process, from the same real
      # engine. Real state comparison -- not "was the engine called".
      {:ok, independent_digest} = GraphLaw.graph_hash(graph)

      assert reply_data(response)["graph_digest"] == independent_digest
    end

    test "there is NO transition edge from :received to :admitted, at all" do
      refute Standing.legal_edge?(:received, :admitted)
      refute :admitted in Standing.successors(:received)

      # The chain's OWN internal :received (reached FROM :candidate, real
      # transport evidence) can only proceed to :parsed, or to any terminal.
      # Peer.ex's bootstrap "message arrived" :received is a distinct,
      # peer-level pre-envelope observation -- see
      # AshA2A.Semantic.Standing.Ledger's `legal_ledger_edge?/2` moduledoc
      # comment -- and is not this function's concern.
      assert Standing.successors(:received) ==
               [:parsed | Standing.terminal_states()]
    end

    test "the ledger physically refuses to record Message_A -> O*_B", %{ledger: ledger} do
      assert {:error, :illegal_standing_transition} =
               Ledger.record(ledger, "forged-envelope", {:received, :admitted}, :forged)

      # Nothing was written. A history skipping :candidate is not producible.
      assert Ledger.entries(ledger, "forged-envelope") == []
    end

    test "a non-conforming envelope is REFUSED by peer B's own shapes, and stops at :candidate -> :refused",
         %{plug_opts: plug_opts, ledger: ledger} do
      {envelope, message} = peer_a_message(Graphs.nonconforming_order())

      {200, response} = send_over_real_transport(plug_opts, message)

      data = reply_data(response)
      assert data["standing"] == "refused"
      assert data["code"] == "semantic_shape_violation"
      assert data["detail"] =~ "SHACL"

      assert Ledger.path(ledger, envelope.envelope_id) == [:received, :candidate, :refused]
      refute :admitted in Ledger.path(ledger, envelope.envelope_id)
    end

    test "peer A's claim of admitted standing is refused outright, before peer B's own admission ever runs",
         %{
           plug_opts: plug_opts,
           ledger: ledger
         } do
      # A hostile peer A hand-writes a payload asserting its graph is already
      # admitted with full authority. `Envelope.new/1` cannot express this,
      # so this test writes the raw wire payload directly -- which is exactly
      # what a hostile remote peer would do.
      #
      # This tightened from "accepted, but the claim is recorded and ignored
      # while peer B admits on its own evidence" to "refused outright, before
      # an envelope is even constructed" when `AshA2A.Semantic.Envelope`
      # closed a real, adversarially-found forgeable-standing defect: a
      # self-declared `"standing"` is now REFUSED at `from_json/1`/
      # `from_map/1` (`:standing_self_declared`, `REFUSED_META_RIGOR`), not
      # merely stripped and remembered. That is a strictly stronger
      # guarantee than this test originally asserted, not a different one --
      # a forged claim can no longer influence anything downstream, because
      # nothing downstream is ever reached.
      {envelope, honest_message} = peer_a_message(Graphs.conforming_order())

      forged_payload =
        envelope
        |> Envelope.to_map()
        |> Map.put("standing", "admitted")
        |> Map.put("authority", "root")

      forged_message = Extension.activate(honest_message, forged_payload)

      {200, response} = send_over_real_transport(plug_opts, forged_message)
      data = reply_data(response)

      # Refused at parse time -- peer B's own GraphLaw admission never runs,
      # regardless of how conforming the underlying graph is.
      assert data["standing"] == "refused"
      assert data["code"] == "standing_self_declared"
      refute Map.has_key?(data, "over_claimed")

      # No real envelope_id exists yet (construction itself was refused), so
      # the ledger records the bridge-derived id peer.ex uses for that case
      # -- consistent with every other refused-before-:candidate test below.
      assert [%{from: :received, to: :refused}] = Ledger.entries(ledger)

      # And direct construction confirms the same refusal, independent of
      # the transport round trip.
      assert {:error, refusal} = Envelope.from_map(forged_payload)
      assert refusal.code == :standing_self_declared
    end

    test "a forged graph digest is refused: peer B hashes the graph itself", %{
      plug_opts: plug_opts,
      ledger: ledger
    } do
      {envelope, message} =
        peer_a_message(Graphs.conforming_order(),
          graph_digest: String.duplicate("f", 64)
        )

      {200, response} = send_over_real_transport(plug_opts, message)
      data = reply_data(response)

      assert data["standing"] == "refused"
      assert data["code"] == "semantic_digest_mismatch"
      assert data["detail"] =~ String.duplicate("f", 64)

      assert Ledger.path(ledger, envelope.envelope_id) == [:received, :candidate, :refused]
    end
  end

  # ---------------------------------------------------------------------------
  # S12-adjacent: the portability property the admission depends on
  # ---------------------------------------------------------------------------

  describe "canonical graph identity (the property the cross-peer claim rests on)" do
    test "two byte-different serializations of the same graph admit to the SAME digest", %{
      plug_opts: plug_opts
    } do
      {_e1, message_1} = peer_a_message(Graphs.conforming_order())
      {_e2, message_2} = peer_a_message(Graphs.conforming_order_reordered())

      {200, response_1} = send_over_real_transport(plug_opts, message_1)
      {200, response_2} = send_over_real_transport(plug_opts, message_2)

      data_1 = reply_data(response_1)
      data_2 = reply_data(response_2)

      assert data_1["standing"] == "admitted"
      assert data_2["standing"] == "admitted"

      # Different prefix labels, different triple order, different bytes --
      # one engine graph digest. This is the real engine's prefix- and
      # triple-order-invariant `graph_hash`, not a sort-then-hash
      # approximation -- and not RDFC-1.0 (it is not blank-node-relabel
      # invariant; RFC S12 identity is AshA2A.Semantic.CanonicalGraph).
      refute Graphs.conforming_order() == Graphs.conforming_order_reordered()
      assert data_1["graph_digest"] == data_2["graph_digest"]
    end

    test "a materially different graph admits to a DIFFERENT digest", %{plug_opts: plug_opts} do
      {_e1, message_1} = peer_a_message(Graphs.conforming_order())

      other = String.replace(Graphs.conforming_order(), "\"widget\"", "\"sprocket\"")
      {_e2, message_2} = peer_a_message(other)

      {200, response_1} = send_over_real_transport(plug_opts, message_1)
      {200, response_2} = send_over_real_transport(plug_opts, message_2)

      assert reply_data(response_1)["graph_digest"] != reply_data(response_2)["graph_digest"]
    end
  end

  # ---------------------------------------------------------------------------
  # S75 / S76: the non-Semantic bridge and downgrade prevention
  # ---------------------------------------------------------------------------

  describe "S75 -- traffic from a non-Semantic A2A peer inherits NO standing" do
    test "an ordinary A2A message over the real transport is answered but gains no standing", %{
      plug_opts: plug_opts,
      ledger: ledger
    } do
      message = AshA2A.Protocol.Message.new_user("just an ordinary A2A request")

      {200, response} = send_over_real_transport(plug_opts, message)
      data = reply_data(response)

      assert data["standing"] == "unsupported"
      assert data["code"] == "profile_not_negotiated"

      envelope_id = "sa2a-nonsemantic-" <> message.message_id
      assert Ledger.path(ledger, envelope_id) == [:received, :unsupported]

      # Not admitted, and specifically not refused either: peer B did not
      # evaluate a graph, because there was none.
      refute :admitted in Ledger.path(ledger, envelope_id)
      refute :refused in Ledger.path(ledger, envelope_id)
    end

    test "a message whose plain text IS valid Turtle still gains no standing", %{
      plug_opts: plug_opts
    } do
      message = AshA2A.Protocol.Message.new_user(Graphs.conforming_order())

      {200, response} = send_over_real_transport(plug_opts, message)

      # The bytes would have admitted had they been an envelope. They are
      # not, because the profile was never negotiated.
      assert reply_data(response)["standing"] == "unsupported"
    end

    test "an envelope declaring a DIFFERENT profile is typed UNSUPPORTED, not downgraded", %{
      plug_opts: plug_opts
    } do
      {envelope, message} = peer_a_message(Graphs.conforming_order())

      wrong_profile =
        envelope |> Envelope.to_map() |> Map.put("profile", "SA2A-PROFILE-v99.0.0")

      message = Extension.activate(message, wrong_profile)

      {200, response} = send_over_real_transport(plug_opts, message)
      data = reply_data(response)

      # UNSUPPORTED_PROFILE is its own S42 class and terminal standing
      # (`Refusal.terminal_standing/1`), never collapsed into REFUSED
      # (RFC-SA2A-002 §101, SA2A-ENV-007). Still not admitted, still not
      # downgraded.
      assert data["standing"] == "unsupported"
      assert data["code"] == "unknown_profile"
    end
  end

  describe "S76 -- a Strict peer MUST NOT silently downgrade a consequence-bearing task" do
    test "strict + consequence-bearing + unnegotiated => UNSUPPORTED_PROFILE", %{
      agent: agent_name,
      ledger_name: ledger_name,
      plug_opts: plug_opts,
      ledger: ledger
    } do
      # The old `message.metadata["consequenceBearing"]` flag this test used
      # to set is now ignored on purpose (see AshA2A.Semantic.Peer's real
      # S76 fix -- the counterparty may not answer its own downgrade
      # question). Consequence-bearing-ness is now read from THIS peer's own
      # capability surface, so this test configures one here (scoped to this
      # test only -- other tests in this module must not see it, since a
      # configured capability surface changes the bridge-path S75 tests'
      # outcome too): the real AshA2A.Test.SemanticPeerFixture.Domain
      # fixture already used by test/ash_a2a_semantic_agent_card_test.exs,
      # whose sole real skill (place_order, via :create) is
      # consequence-bearing -- exactly what this test needs to exercise.
      :ok =
        configure_peer(agent_name,
          name: @peer_b,
          ledger: ledger_name,
          shapes: Graphs.peer_b_shapes(),
          mode: :strict,
          capabilities: AshA2A.Test.SemanticPeerFixture.Domain
        )

      message = AshA2A.Protocol.Message.new_user("place an order for 3 widgets")

      {200, response} = send_over_real_transport(plug_opts, message)
      data = reply_data(response)

      assert data["standing"] == "unsupported"
      assert data["code"] == "unsupported_profile"
      assert data["detail"] =~ "will not downgrade"
      assert data["detail"] =~ Extension.profile_id()

      envelope_id = "sa2a-nonsemantic-" <> message.message_id
      refute :admitted in Ledger.path(ledger, envelope_id)
    end

    test "a PERMISSIVE peer answers the same consequence-bearing task as ordinary A2A, still with no standing" do
      permissive =
        Peer.new(name: "permissive-peer", shapes: Graphs.peer_b_shapes(), mode: :permissive)

      message = %{
        AshA2A.Protocol.Message.new_user("place an order")
        | metadata: %{"consequenceBearing" => true}
      }

      outcome = Peer.receive_message(permissive, message, consequence_bearing?: true)

      # The difference between strict and permissive is the refusal CODE, not
      # the standing. Neither mode ever yields standing to unnegotiated
      # traffic.
      assert outcome.standing == :unsupported
      assert outcome.code == :profile_not_negotiated
      refute outcome.standing == :admitted
    end

    test "a strict peer still answers a NON-consequence-bearing unnegotiated request" do
      strict = Peer.new(name: "strict-peer", shapes: Graphs.peer_b_shapes(), mode: :strict)

      outcome =
        Peer.receive_message(strict, AshA2A.Protocol.Message.new_user("what time is it?"),
          consequence_bearing?: false
        )

      assert outcome.standing == :unsupported
      assert outcome.code == :profile_not_negotiated
    end
  end

  # ---------------------------------------------------------------------------
  # S49 / S50
  # ---------------------------------------------------------------------------

  describe "S49 -- an A2A Task is not authority" do
    test "every real task state yields authority :none", %{plug_opts: plug_opts} do
      {_envelope, message} = peer_a_message(Graphs.conforming_order())
      {200, response} = send_over_real_transport(plug_opts, message)

      # A real completed task, produced by the real agent runtime over the
      # real transport.
      task_json = task_result(response)
      assert task_json["status"]["state"] == "TASK_STATE_COMPLETED"

      {:ok, task} = AshA2A.Protocol.JSON.decode(task_json, :task)
      assert %AshA2A.Protocol.Task{status: %AshA2A.Protocol.Task.Status{state: :completed}} = task

      assert Peer.authority_from_task(task) == :none

      for state <- [:submitted, :working, :completed, :failed, :canceled, :input_required] do
        staged = put_in(task.status.state, state)
        assert Peer.authority_from_task(staged) == :none
      end
    end

    test "a completed task does not let a follow-up message skip admission", %{
      plug_opts: plug_opts,
      ledger: ledger
    } do
      {_first, first_message} = peer_a_message(Graphs.conforming_order())
      {200, first_response} = send_over_real_transport(plug_opts, first_message)
      task_id = task_result(first_response)["id"]
      assert is_binary(task_id)

      # A second, NON-conforming envelope riding the same completed task.
      {second, second_message} = peer_a_message(Graphs.nonconforming_order())
      riding_message = %{second_message | task_id: task_id}

      {200, riding_response} = send_over_real_transport(plug_opts, riding_message)

      # Measured, real behavior of the ported `AshA2A.Protocol.Agent` runtime
      # (a2a-elixir 0.3.0 semantics): a `:completed` task is not continuable
      # at all. The prior task is not a channel a later message can inherit
      # anything through -- it is not even a channel. The refusal is the
      # spec's own UnsupportedOperationError.
      assert riding_response["error"]["code"] == -32004

      assert Enum.any?(riding_response["error"]["data"], fn d ->
               d["@type"] == "type.googleapis.com/google.rpc.ErrorInfo" and
                 d["domain"] == "a2a-protocol.org" and
                 d["reason"] == "UNSUPPORTED_OPERATION"
             end)

      assert Ledger.entries(ledger, second.envelope_id) == []

      # And as a fresh task, the same non-conforming envelope is refused on
      # its own merits. The earlier completed task bought it nothing.
      {200, fresh_response} = send_over_real_transport(plug_opts, second_message)

      assert reply_data(fresh_response)["standing"] == "refused"
      assert Ledger.path(ledger, second.envelope_id) == [:received, :candidate, :refused]
    end
  end

  describe "S50 -- an A2A Artifact gains no standing from being an Artifact" do
    test "every artifact has standing :received, whatever it contains" do
      artifact =
        AshA2A.Protocol.Artifact.new([AshA2A.Protocol.Part.Text.new(Graphs.conforming_order())])

      assert Peer.standing_from_artifact(artifact) == :received
      refute Standing.admitted?(Peer.standing_from_artifact(artifact))
    end

    test "an artifact produced by a REAL admitted exchange still has standing :received", %{
      plug_opts: plug_opts
    } do
      {_envelope, message} = peer_a_message(Graphs.conforming_order())
      {200, response} = send_over_real_transport(plug_opts, message)

      assert reply_data(response)["standing"] == "admitted"

      {:ok, artifact} =
        response
        |> task_result()
        |> Map.fetch!("artifacts")
        |> hd()
        |> AshA2A.Protocol.JSON.decode(:artifact)

      # The exchange was admitted. The artifact carrying its result is still
      # only :received -- container-ness confers nothing.
      assert Peer.standing_from_artifact(artifact) == :received
    end

    test "an envelope carried inside an artifact with a self-declared standing is refused, not downgraded to candidate" do
      # Tightened the same way the message-path over-claim test above was:
      # `Envelope.from_map/1` now refuses ANY self-declared `"standing"`
      # outright (`:standing_self_declared`) rather than admitting it at a
      # forced-down `:candidate`. An artifact is a different container, not
      # a way around that -- `Peer.envelope_from_artifact/1` goes through the
      # same `Envelope.from_map/1`.
      {envelope, _message} = peer_a_message(Graphs.conforming_order())

      artifact =
        AshA2A.Protocol.Artifact.new([AshA2A.Protocol.Part.Text.new("payload")],
          metadata: %{
            Extension.extension_key() =>
              envelope |> Envelope.to_map() |> Map.put("standing", "admitted")
          }
        )

      assert {:error, refusal} = Peer.envelope_from_artifact(artifact)
      assert refusal.code == :standing_self_declared
    end

    test "an artifact with no semantic payload yields :profile_not_activated" do
      artifact =
        AshA2A.Protocol.Artifact.new([AshA2A.Protocol.Part.Text.new("nothing semantic here")])

      assert {:error, %{code: :profile_not_activated}} = Peer.envelope_from_artifact(artifact)
    end
  end

  # ---------------------------------------------------------------------------
  # Fail-closed and out-of-order admission
  # ---------------------------------------------------------------------------

  describe "fail-closed" do
    test "a peer whose engine is genuinely unreachable returns :unsupported, never :admitted" do
      # A real unavailability, not a substituted collaborator: the real
      # `AshA2A.Semantic.GraphLaw.Wasm` runner is pointed at a wasm path that
      # genuinely does not exist on this filesystem, so the real
      # `File.exists?/1` guard in the real runner fires. This module is
      # `async: false`, so the scoped config change cannot race another test.
      previous = Application.get_env(:ash_a2a, AshA2A.Semantic.GraphLaw.Wasm)

      absent =
        Path.join(
          System.tmp_dir!(),
          "definitely-not-a-wasm-module-#{System.unique_integer([:positive])}.wasm"
        )

      refute File.exists?(absent)

      Application.put_env(:ash_a2a, AshA2A.Semantic.GraphLaw.Wasm, wasm_path: absent)

      try do
        unreachable = Peer.new(name: "engine-less-peer", shapes: Graphs.peer_b_shapes())

        # A placeholder digest, not a real one: the engine this test just made
        # unreachable is the same one `real_envelope/2`'s default would call
        # to compute a real digest, which would defeat the point of this test.
        envelope =
          real_envelope(Graphs.conforming_order(), graph_digest: String.duplicate("0", 64))

        outcome = Peer.admit(unreachable, envelope)

        assert outcome.standing == :unsupported
        assert outcome.code == :graphlaw_unavailable
        assert outcome.detail =~ absent
        refute Standing.admitted?(outcome.standing)
      after
        if previous do
          Application.put_env(:ash_a2a, AshA2A.Semantic.GraphLaw.Wasm, previous)
        else
          Application.delete_env(:ash_a2a, AshA2A.Semantic.GraphLaw.Wasm)
        end
      end
    end

    test "admitting an already-decided envelope is refused as out of order" do
      peer = Peer.new(name: @peer_b, shapes: Graphs.peer_b_shapes())
      envelope = real_envelope(Graphs.conforming_order())

      decided = %{envelope | standing: :admitted}
      outcome = Peer.admit(peer, decided)

      assert outcome.standing == :refused
      assert outcome.code == :illegal_standing_transition
    end

    test ":refused is terminal, :admitted is not (it continues toward planning); :unsupported is not admitted" do
      # `:admitted` was asserted terminal here under cross-peer's own,
      # peer-boundary-scoped model (an admitted envelope is nothing further
      # to THIS peer's admission concern). RFC-SA2A-001's full chain
      # continues past :admitted into :plannable/:selected/.../:attested
      # (see AshA2A.Semantic.Standing's moduledoc), so :admitted is
      # correctly NOT one of the five absorbing terminal states -- only
      # `Standing.admitted?/1` (a peer-boundary-scoped predicate this module
      # still owns) captures the narrower claim peer.ex actually needs.
      refute Standing.terminal?(:admitted)
      assert Standing.terminal?(:refused)
      assert Standing.terminal?(:unsupported)
      refute Standing.admitted?(:unsupported)
      refute Standing.admitted?(:candidate)
      refute Standing.admitted?(:received)
      assert Standing.admitted?(:admitted)
    end

    test "the engine reports which dialects it did NOT exercise", %{plug_opts: plug_opts} do
      {_envelope, message} = peer_a_message(Graphs.conforming_order())
      {200, response} = send_over_real_transport(plug_opts, message)

      unexercised = reply_data(response)["unexercised"]

      # Peer B supplied SHACL shapes and no ShEx schema and no OWL profile.
      # The receipt must say so rather than implying the full ladder ran:
      # UNSUPPORTED is not ADMITTED.
      dialects = Enum.map(unexercised, & &1["dialect"])
      assert "SHEX" in dialects
      assert "OWL_RL" in dialects
      refute "SHACL" in dialects
    end
  end
end

# ==============================================================================
# SECTION 14: Original test/ash_a2a_semantic_extension_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SemanticExtensionTest do
  @moduledoc """
  RFC-SA2A-001 S9 -- Semantic A2A profile negotiation over the real A2A
  extension mechanism.

  Everything here runs against the real, unmodified in-repo `AshA2A.Protocol.*`
  codec: the real `AshA2A.Protocol.JSON` encoder/decoder, a real `AshA2A.Protocol.Agent` GenServer, and a
  real `AshA2A.Protocol.Plug` HTTP pipeline driven by `Plug.Test.conn/3`. No mock, no
  stub, no patched transport -- the assertions are on real encoded JSON and
  real HTTP response bodies.

  One of these tests asserts a *measured* fact about the codec (whether
  `capabilities.extensions` survives the wire). That is measured here rather
  than assumed, because `AshA2A.Semantic.Extension`'s choice of advertisement
  site depends on it and the reason must stay checkable.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Semantic.Extension
  alias AshA2A.Test.SemanticPeerFixture.PeerB

  @base_url "http://localhost:4100/a2a"

  setup do
    agent_name = :"sa2a_ext_peer_#{System.unique_integer([:positive])}"
    {:ok, pid} = PeerB.start_link(name: agent_name)

    on_exit(fn ->
      AshA2A.TestSupport.SafeStop.stop(pid)
      PeerB.deconfigure(agent_name)
    end)

    %{agent: agent_name}
  end

  describe "profile identity" do
    test "the profile identifier is exactly the one the RFC names" do
      assert Extension.profile_id() == "SA2A-PROFILE-v26.9.20"
      assert Extension.profile_version() == "v26.9.20"
      assert Extension.profile_uri() == "urn:sa2a:profile:v26.9.20"
    end

    test "the capability declaration is A2A-specification shaped" do
      declaration = Extension.capability_declaration()

      assert %{uri: uri, description: description, required: required, params: params} =
               declaration

      assert uri == Extension.profile_uri()
      assert is_binary(description) and description != ""

      # Deliberately not required: a Semantic A2A agent must still answer
      # ordinary A2A traffic (S75), it simply grants it no standing.
      assert required == false
      assert params["profileId"] == Extension.profile_id()
      assert params["messageExtensionKey"] == Extension.extension_key()
    end
  end

  describe "measured constraint: where the advertisement can actually ride" do
    test "the ported encoder PRESERVES capabilities.extensions (a2a 0.3.0 semantics)" do
      card = %AshA2A.Protocol.AgentCard{
        name: "probe",
        description: "probe",
        url: @base_url,
        version: "0.1.0",
        skills: []
      }

      declaration = Extension.capability_declaration()

      encoded =
        AshA2A.Protocol.JSON.encode_agent_card(card,
          url: @base_url,
          capabilities: %{
            streaming: true,
            extensions: [
              struct(AshA2A.Protocol.AgentExtension, Map.to_list(declaration))
            ]
          }
        )

      # The real, measured behavior of `AshA2A.Protocol.JSON.encode_capabilities/1`
      # after the 0.3.0 port: `capabilities.extensions` rides the wire. The
      # encoder accepts only `%AshA2A.Protocol.AgentExtension{}` structs
      # (a plain declaration map raises FunctionClauseError), so the
      # spec-shaped declaration is carried as the struct.
      assert encoded["capabilities"]["streaming"] == true

      assert encoded["capabilities"]["extensions"] == [
               %{
                 "uri" => Extension.profile_uri(),
                 "description" => declaration.description,
                 "required" => false,
                 "params" => declaration.params
               }
             ]

      # And it makes a real JSON round trip: the decoded card carries the
      # declaration back as an `AshA2A.Protocol.AgentExtension` struct.
      {:ok, decoded} =
        encoded |> Jason.encode!() |> Jason.decode!() |> AshA2A.Protocol.JSON.decode_agent_card()

      assert [%AshA2A.Protocol.AgentExtension{} = carried] = decoded.capabilities.extensions

      assert carried.uri == Extension.profile_uri()
      assert carried.description == declaration.description
      assert carried.required == false
      assert carried.params == declaration.params
    end

    test "capabilities.extensions advertisement survives a real encode/decode round trip" do
      card = %AshA2A.Protocol.AgentCard{
        name: "probe",
        description: "probe",
        url: @base_url,
        version: "0.1.0",
        skills: []
      }

      opts = Extension.advertise(url: @base_url)
      encoded = AshA2A.Protocol.JSON.encode_agent_card(card, opts)

      uri = Extension.profile_uri()
      assert [%{"uri" => ^uri}] = encoded["capabilities"]["extensions"]

      # No custom binding rides supportedInterfaces: the v1.1 decoder closes
      # the protocolBinding set.
      refute Enum.any?(
               encoded["supportedInterfaces"],
               &(&1["protocolBinding"] == Extension.profile_id())
             )

      wire = encoded |> Jason.encode!() |> Jason.decode!()
      assert Extension.advertised?(wire)
      assert {:ok, _card} = AshA2A.Protocol.JSON.decode_agent_card(wire)
    end

    test "advertise/1 declares via capabilities.extensions, keeps JSONRPC, is idempotent" do
      once = Extension.advertise(url: @base_url)
      twice = Extension.advertise(once)

      assert Keyword.fetch!(once, :capabilities) == Keyword.fetch!(twice, :capabilities)
      refute Keyword.has_key?(once, :supported_interfaces)
      assert [%{uri: _}] = Keyword.fetch!(once, :capabilities).extensions
    end
  end

  describe "the advertisement over a real AshA2A.Protocol.Plug HTTP pipeline" do
    test "a real GET to the agent-card path serves the SA2A profile advertisement", %{
      agent: agent
    } do
      plug_opts =
        AshA2A.Protocol.Plug.init(
          agent: agent,
          base_url: @base_url,
          agent_card_opts: Extension.advertise(url: @base_url)
        )

      conn =
        Plug.Test.conn(:get, "/.well-known/agent-card.json")
        |> AshA2A.Protocol.Plug.call(plug_opts)

      assert conn.status == 200
      served = Jason.decode!(conn.resp_body)

      assert Extension.advertised?(served)

      assert {:ok, _card} = AshA2A.Protocol.JSON.decode_agent_card(served)
    end

    test "an agent that does NOT advertise serves a card with no SA2A binding", %{agent: agent} do
      plug_opts = AshA2A.Protocol.Plug.init(agent: agent, base_url: @base_url)

      conn =
        Plug.Test.conn(:get, "/.well-known/agent-card.json")
        |> AshA2A.Protocol.Plug.call(plug_opts)

      served = Jason.decode!(conn.resp_body)
      refute Extension.advertised?(served)
    end
  end

  describe "negotiate/2 requires BOTH peers (S9)" do
    setup do
      advertising =
        AshA2A.Protocol.JSON.encode_agent_card(
          %AshA2A.Protocol.AgentCard{
            name: "a",
            description: "a",
            url: @base_url,
            version: "1",
            skills: []
          },
          # The v1.1 decoder closes the protocolBinding set, so the decodable
          # advertisement rides capabilities.extensions (the spec's own site).
          url: @base_url,
          capabilities: %{extensions: [Extension.capability_declaration()]}
        )

      plain =
        AshA2A.Protocol.JSON.encode_agent_card(
          %AshA2A.Protocol.AgentCard{
            name: "b",
            description: "b",
            url: @base_url,
            version: "1",
            skills: []
          },
          url: @base_url
        )

      {:ok, advertising_card} = AshA2A.Protocol.JSON.decode_agent_card(advertising)
      {:ok, plain_card} = AshA2A.Protocol.JSON.decode_agent_card(plain)

      %{advertising: advertising_card, plain: plain_card}
    end

    test "both advertising negotiates", %{advertising: card} do
      assert {:ok, "SA2A-PROFILE-v26.9.20"} = Extension.negotiate(card, card)
    end

    test "remote silent refuses with :unsupported_profile", %{
      advertising: advertising,
      plain: plain
    } do
      assert {:error, %{code: :unsupported_profile, detail: detail}} =
               Extension.negotiate(advertising, plain)

      assert detail =~ "remote peer"
    end

    test "local silent refuses with :unsupported_profile", %{
      advertising: advertising,
      plain: plain
    } do
      assert {:error, %{code: :unsupported_profile, detail: detail}} =
               Extension.negotiate(plain, advertising)

      assert detail =~ "local peer"
    end

    test "neither advertising refuses", %{plain: plain} do
      assert {:error, %{code: :unsupported_profile}} = Extension.negotiate(plain, plain)
    end
  end

  describe "ordinary A2A traffic is NEVER silently semantic" do
    test "a plain text message is not activated" do
      refute Extension.activated?(AshA2A.Protocol.Message.new_user("place an order"))
    end

    test "a message whose text happens to be Turtle is still not activated" do
      turtle = "@prefix ex: <http://example.org/> .\nex:a ex:p ex:b .\n"
      refute Extension.activated?(AshA2A.Protocol.Message.new_user(turtle))
    end

    test "a message carrying some OTHER A2A extension is not activated" do
      message = %{
        AshA2A.Protocol.Message.new_user("hi")
        | extensions: %{"some-other-ext" => %{"x" => 1}}
      }

      refute Extension.activated?(message)
      assert {:error, %{code: :profile_not_activated}} = Extension.payload(message)
    end

    test "activate/1 marks a message and preserves other extensions" do
      message =
        %{AshA2A.Protocol.Message.new_user("hi") | extensions: %{"other" => %{"keep" => true}}}
        |> Extension.activate(%{"profile" => Extension.profile_id()})

      assert Extension.activated?(message)
      assert message.extensions["other"] == %{"keep" => true}
      assert {:ok, %{"profile" => "SA2A-PROFILE-v26.9.20"}} = Extension.payload(message)
    end

    test "activation survives a real AshA2A.Protocol.JSON message encode/decode round trip" do
      message =
        Extension.activate(AshA2A.Protocol.Message.new_user("hi"), %{
          "profile" => Extension.profile_id()
        })

      {:ok, encoded} = AshA2A.Protocol.JSON.encode(message)

      {:ok, decoded} =
        encoded |> Jason.encode!() |> Jason.decode!() |> AshA2A.Protocol.JSON.decode(:message)

      assert Extension.activated?(decoded)
      assert {:ok, %{"profile" => "SA2A-PROFILE-v26.9.20"}} = Extension.payload(decoded)
    end
  end
end

# ==============================================================================
# SECTION 15: Original test/ash_a2a_semantic_policy_phenotype_court_probe_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Court.PolicyPhenotypeProbeTest do
  # Court probe (ash_a2a#45 @ d35394a0). Real module, no doubles.
  use ExUnit.Case, async: true
  alias AshA2A.Semantic.PolicyPhenotype, as: P

  defp opts(axis, extra \\ []) do
    [
      capability_iri: "urn:sa2a:capability:Example.Search.read",
      policy_family: "planner:MCTS",
      conditionable_axes: %{axis => %{min: 0.0, max: 1.0}},
      condition: %{axis => 0.5}
    ] ++ extra
  end

  defp code(r),
    do:
      (case r do
         {:error, %{code: c}} -> c
         {:ok, _} -> :ADMITTED
       end)

  @split [
    "gr_ant",
    "execution_gr_ant",
    "execution-g-rant",
    "le_ase",
    "tok-en",
    "d_o",
    "GRant",
    "executionGRant",
    "LEase",
    "TOken",
    "su_do",
    "gra͏nt",
    "execution͏gr͏ant"
  ]
  for a <- @split do
    test "separator/camel/invisible-mark split refused: #{inspect(a)}" do
      assert code(P.new(opts(unquote(a)))) == :temperament_cannot_encode_authority
    end
  end

  test "range map cannot carry a grant/token field" do
    o =
      opts("boldness")
      |> Keyword.put(
        :conditionable_axes,
        %{"boldness" => %{min: 0.0, max: 1.0, grant: :do, token: "secret"}}
      )

    r = P.new(o)
    assert code(r) != :ADMITTED, "admitted: #{inspect(r)}"
  end

  test "reaction norm cannot carry an authority field" do
    o =
      opts("boldness",
        reaction_norms: %{"boldness" => %{slope: 0.1, authority: :execute, token: "t"}}
      )

    r = P.new(o)
    assert code(r) != :ADMITTED, "admitted: #{inspect(r)}"
  end

  test "forged struct with injected grant field is refused by condition/2" do
    {:ok, p} = P.new(opts("boldness", reaction_norms: %{"boldness" => %{slope: 0.1}}))
    forged = Map.put(p, :execution_grant, "token-abc")
    r = P.condition(forged, 1.0)
    assert code(r) != :ADMITTED, "admitted: #{inspect(r)}"
  end

  # Controls: the fence the PR does claim.
  for a <- ["execution_grant", "ExecutionGrant", "grаnt", "auth_ority", "HTTPGrant", "grantlevel"] do
    test "control refused: #{inspect(a)}" do
      assert code(P.new(opts(unquote(a)))) == :temperament_cannot_encode_authority
    end
  end
end

# ==============================================================================
# SECTION 16: Original test/ash_a2a_semantic_policy_phenotype_harden45_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Semantic.PolicyPhenotypeHarden45Test do
  @moduledoc """
  Second-court falsifiers for `AshA2A.Semantic.PolicyPhenotype` (ash_a2a#45
  @ 67f48618). Every test drives the real module with real inputs and asserts
  on the real returned value or refusal; nothing is replaced.

  Defects this file killed (each admitted or raised on 67f48618):

    * H1 interior split: a forbidden token or affix root split across token
      boundaries in the middle of a name (`boldness_gr_ant_level`,
      `d_o_action`, `x_to_ken_budget`) was admitted, while the unsplit
      spelling was refused.
    * H2 digit-for-letter spellings (`auth0rity`, `gr4nt_level`, `l3ase`,
      `permi55ion`) were admitted.
    * H3 Latin dotless i / Latin alpha look-alikes (`authorıty`) were admitted.
    * H4 `admin` spellings were admitted beside `sudo`/`superuser`.
    * H5 a struct with a non-map axis field presented to `condition/2` raised
      BadMapError instead of refusing.
    * H6 improper lists (options, pair lists, evidence refs) raised
      FunctionClauseError instead of refusing.
    * H7 `condition/2` on a non-phenotype raised FunctionClauseError.
  """
  use ExUnit.Case, async: true

  alias AshA2A.Semantic.PolicyPhenotype
  alias AshA2A.Semantic.Refusal

  @cap "urn:sa2a:capability:Example.Search.read"

  defp opts(axis, extra \\ []) do
    [
      capability_iri: @cap,
      policy_family: "planner:MCTS",
      conditionable_axes: %{axis => %{min: 0.0, max: 1.0}}
    ] ++ extra
  end

  defp code({:error, %{code: code}}), do: code
  defp code({:ok, _}), do: :ADMITTED

  # Roots whose unsplit spelling the fence refuses; each must stay refused
  # however it is split, and wherever in the name it sits.
  @roots ["grant", "lease", "token", "do", "sudo", "admin", "authority", "permission"]

  defp splits(root) do
    n = String.length(root)

    two = for i <- 1..(n - 1)//1, do: [String.slice(root, 0, i), String.slice(root, i..-1//1)]

    three =
      for i <- 1..(n - 2)//1, j <- (i + 1)..(n - 1)//1 do
        [String.slice(root, 0, i), String.slice(root, i, j - i), String.slice(root, j..-1//1)]
      end

    two ++ three
  end

  describe "H1 a root split across interior token boundaries is refused" do
    test "every 2- and 3-way split of every root, at the start, middle and end of a name" do
      for root <- @roots, parts <- splits(root), sep <- ["_", "-", " "] do
        split = Enum.join(parts, sep)

        for axis <- [split, "boldness_" <> split <> "_level", "boldness_" <> split] do
          assert code(PolicyPhenotype.new(opts(axis))) == :temperament_cannot_encode_authority,
                 "admitted split root #{inspect(axis)}"
        end
      end
    end

    test "the named 67f48618 escapes are refused with the authority code" do
      for axis <- [
            "boldness_gr_ant_level",
            "d_o_action",
            "x_to_ken_budget",
            "yyyyyyyyyyyyyyyyyyyygra_nt_level",
            "exploration_le_ase_window",
            "initiativeGrAnt"
          ] do
        result = PolicyPhenotype.new(opts(axis))

        assert {:error, %{code: :temperament_cannot_encode_authority, detail: ^axis}} = result
        assert Refusal.classify(:temperament_cannot_encode_authority) == :refused_authority
      end
    end

    test "a split root nested as a key inside a range is refused as an unknown option" do
      range = %{min: 0.0, max: 1.0, gr_ant_level: 1}

      assert {:error,
              %{code: :invalid_policy_phenotype, detail: {:unknown_option, :gr_ant_level}}} =
               PolicyPhenotype.new(
                 capability_iri: @cap,
                 policy_family: "planner:MCTS",
                 conditionable_axes: %{"boldness" => range}
               )
    end
  end

  describe "H2/H3/H4 look-alike spellings are refused" do
    test "digit-for-letter spellings" do
      for axis <- [
            "auth0rity",
            "gr4nt_level",
            "permi55ion",
            "l3ase",
            "t0ken_budget",
            "pr1vilege",
            "privi1ege",
            "cr3dential",
            "d0_action",
            "4dmin"
          ] do
        assert code(PolicyPhenotype.new(opts(axis))) == :temperament_cannot_encode_authority,
               "admitted #{inspect(axis)}"
      end
    end

    test "Latin dotless i and Latin alpha look-alikes" do
      for axis <- ["authorıty", "grɑnt_level", "ɑdmin"] do
        assert code(PolicyPhenotype.new(opts(axis))) == :temperament_cannot_encode_authority,
               "admitted #{inspect(axis)}"
      end
    end

    test "admin spellings" do
      for axis <- ["admin", "admin_level", "adm_in", "Administrator", "boldnessAdmins"] do
        assert code(PolicyPhenotype.new(opts(axis))) == :temperament_cannot_encode_authority,
               "admitted #{inspect(axis)}"
      end
    end
  end

  describe "the widened fence keeps ordinary behavioral names" do
    test "default axes, numbered axes and look-alike English words are admitted" do
      for axis <-
            PolicyPhenotype.default_axes() ++
              [
                "exploration_2",
                "tier3_boldness",
                "phase_10_activity",
                "boldness_v2",
                "undo_tolerance",
                "domain_focus",
                "dormancy",
                "fragrant_novelty",
                "releaseCadence",
                "please_seeking",
                "selfModelPlasticity",
                "risk_tolerance",
                "go_to_goal"
              ] do
        assert {:ok, _} = PolicyPhenotype.new(opts(axis)), "false positive on #{inspect(axis)}"
      end
    end

    test "the full default vocabulary with norms still conditions" do
      axes = PolicyPhenotype.default_axes()

      assert {:ok, p} =
               PolicyPhenotype.new(
                 capability_iri: @cap,
                 policy_family: "planner:MCTS",
                 conditionable_axes: Map.new(axes, &{&1, %{min: 0.0, max: 1.0}}),
                 reaction_norms: Map.new(axes, &{&1, %{slope: 0.1}})
               )

      assert {:ok, q} = PolicyPhenotype.condition(p, 2.0)
      assert Enum.all?(q.condition, fn {_axis, v} -> v >= 0.0 and v <= 1.0 end)
    end
  end

  describe "the window check is bounded on adversarial lengths" do
    test "a 10_000-token benign name is decided (admitted) without quadratic blow-up" do
      axis = List.duplicate("a", 10_000) |> Enum.join("_")
      {us, result} = :timer.tc(fn -> PolicyPhenotype.new(opts(axis)) end)
      assert {:ok, _} = result
      # linear: 10_000 tokens x 14 windows; a quadratic window scan is ~5e7 joins
      assert us < 2_000_000, "10_000-token name took #{us}us"
    end

    test "a split root at the far end of a long name is still refused" do
      axis = (List.duplicate("a", 5_000) |> Enum.join("_")) <> "_gr_ant"
      assert code(PolicyPhenotype.new(opts(axis))) == :temperament_cannot_encode_authority
    end
  end

  describe "H5/H7 malformed subjects handed to condition/2 are refused, never raised" do
    setup do
      {:ok, p} =
        PolicyPhenotype.new(
          capability_iri: @cap,
          policy_family: "planner:MCTS",
          conditionable_axes: %{"boldness" => %{min: 0.0, max: 1.0}},
          reaction_norms: %{"boldness" => %{slope: 0.5}}
        )

      %{p: p}
    end

    test "non-map axis containers", %{p: p} do
      for {field, value} <- [
            conditionable_axes: [1],
            conditionable_axes: nil,
            condition: nil,
            condition: "boldness",
            reaction_norms: 5,
            reaction_norms: MapSet.new(["boldness"])
          ] do
        forged = Map.put(p, field, value)

        assert {:error, %{code: :invalid_policy_phenotype, detail: {:expected_axis_map, ^field}}} =
                 PolicyPhenotype.condition(forged, 0.5)
      end
    end

    test "non-list or improper evidence refs", %{p: p} do
      for refs <- [:evidence, "urn:e", ["urn:e" | :tail]] do
        assert {:error, %{code: :invalid_policy_phenotype, detail: {:invalid_evidence_ref, _}}} =
                 PolicyPhenotype.condition(%{p | evidence_refs: refs}, 0.5)
      end
    end

    test "a non-phenotype first argument" do
      for subject <- [nil, %{}, %{capability_iri: @cap}, "phenotype", 42, %URI{}] do
        assert {:error, %{code: :invalid_policy_phenotype, detail: :expected_policy_phenotype}} =
                 PolicyPhenotype.condition(subject, 0.5)
      end
    end

    test "the untouched phenotype still conditions after the forgeries", %{p: p} do
      assert {:ok, q} = PolicyPhenotype.condition(p, 1.0)
      assert q.condition == %{"boldness" => 0.5}
    end
  end

  describe "H6 improper lists are refused, never raised" do
    test "improper option list" do
      assert {:error, %{code: :invalid_policy_phenotype, detail: :expected_keyword_list}} =
               PolicyPhenotype.new([{:capability_iri, @cap} | :tail])
    end

    test "improper pair list for an axis field" do
      assert {:error,
              %{
                code: :invalid_policy_phenotype,
                detail: {:expected_axis_map, :conditionable_axes}
              }} =
               PolicyPhenotype.new(
                 capability_iri: @cap,
                 policy_family: "planner:MCTS",
                 conditionable_axes: [{"boldness", %{min: 0.0, max: 1.0}} | :tail]
               )
    end

    test "improper evidence ref list" do
      assert {:error, %{code: :invalid_policy_phenotype, detail: {:invalid_evidence_ref, _}}} =
               PolicyPhenotype.new(opts("boldness", evidence_refs: ["urn:e" | :tail]))
    end
  end
end

# ==============================================================================
# SECTION 17: Original test/ash_a2a_semantic_policy_phenotype_hardening_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Semantic.PolicyPhenotypeHardeningTest do
  @moduledoc """
  Adversarial falsifiers for `AshA2A.Semantic.PolicyPhenotype` (ash_a2a#41).

  Every test drives the real module with real inputs and asserts on the real
  returned value or refusal; no collaborator is replaced. Each block names the
  attack it falsifies: disguised authority axes, malformed input that used to
  raise instead of refusing, duplicate delivery of one axis, smuggled
  authority-bearing options, tampered structs presented to `condition/2`, and
  replay/reordering determinism of the reaction-norm step.
  """
  use ExUnit.Case, async: true

  alias AshA2A.Semantic.PolicyPhenotype
  alias AshA2A.Semantic.Refusal

  @cap "urn:sa2a:capability:Example.Search.read"

  defp base(extra \\ []) do
    [
      capability_iri: @cap,
      policy_family: "planner:Astar",
      conditionable_axes: %{"exploration" => %{min: 0.0, max: 1.0}}
    ] ++ extra
  end

  defp code({:error, %{code: code}}), do: code
  defp code(other), do: flunk("expected refusal, got #{inspect(other)}")

  describe "authority fence cannot be bypassed by spelling" do
    @disguised [
      "execution-grant",
      "Execution Grant",
      "execution.authority",
      "auth​ority",
      "perm­ission",
      "﻿do",
      "ＡＵＴＨＯＲＩＴＹ",
      "permissions",
      "grant_level",
      "initiative_authority",
      "lease",
      "credential",
      "  --DO--  ",
      :authority,
      :execution_grant,
      # camelCase / PascalCase / acronym boundaries (ash_a2a#41 court probe)
      "ExecutionGrant",
      "executionAuthority",
      "grantLevel",
      "AuthorityLevel",
      "doAction",
      "HTTPGrant",
      :executionGrant,
      # concatenations with no boundary at all
      "executiongrant",
      "executionauthority",
      "grantlevel",
      "preauthorized",
      "unpermitted",
      # plurals, participles, synonyms
      "leases",
      "tokens",
      "authorizations",
      "authorized",
      "authorized_level",
      "permitted",
      "privilege",
      "credentials_scope",
      "entitlement",
      # Cyrillic/Greek homoglyphs NFKC does not fold
      "\u0430uthority",
      "gr\u0430nt_level",
      "\u0440ermission",
      "p\u03B5rmit_scope",
      # not valid UTF-8: cannot be normalized, so the fence fails closed
      <<"authority", 0xFF>>,
      <<"execution_grant", 0x80>>,
      <<"exploration", 0xFF>>
    ]

    for axis <- @disguised do
      @axis axis
      test "refuses disguised authority axis #{inspect(axis)} with the authority code" do
        axis = @axis

        for opts <- [
              [conditionable_axes: %{axis => %{min: 0.0, max: 1.0}}],
              [
                conditionable_axes: %{
                  "exploration" => %{min: 0.0, max: 1.0},
                  axis => %{min: 0.0, max: 1.0}
                },
                reaction_norms: %{axis => %{slope: 1.0}}
              ]
            ] do
          result =
            PolicyPhenotype.new([capability_iri: @cap, policy_family: "planner:Astar"] ++ opts)

          assert {:error, %{code: :temperament_cannot_encode_authority, detail: ^axis}} = result
          assert Refusal.classify(code(result)) == :refused_authority
        end
      end
    end

    test "every default behavioral axis survives the fence (no false positives)" do
      axes = Map.new(PolicyPhenotype.default_axes(), &{&1, %{min: 0.0, max: 1.0}})

      assert {:ok, phenotype} =
               PolicyPhenotype.new(
                 capability_iri: @cap,
                 policy_family: "planner:Astar",
                 conditionable_axes: axes
               )

      assert map_size(phenotype.conditionable_axes) == length(PolicyPhenotype.default_axes())
    end

    test "ordinary words containing 'do' as a substring are not refused" do
      for axis <- ["domain_focus", "dormancy", "undo_tolerance", "domainFocus"] do
        assert {:ok, _} =
                 PolicyPhenotype.new(
                   capability_iri: @cap,
                   policy_family: "planner:Astar",
                   conditionable_axes: %{axis => %{min: 0.0, max: 1.0}}
                 )
      end
    end
  end

  describe "fence stays precise on ordinary behavioral names" do
    test "camelCase behavioral names and look-alike English words are admitted" do
      for axis <- [
            "selfModelPlasticity",
            "riskTolerance",
            "releaseCadence",
            "fragrant_novelty",
            "please_seeking",
            "Exploration_Level"
          ] do
        result =
          PolicyPhenotype.new(
            capability_iri: @cap,
            policy_family: "planner:Astar",
            conditionable_axes: %{axis => %{min: 0.0, max: 1.0}}
          )

        assert {:ok, _} = result, "false positive on #{inspect(axis)}"
      end
    end
  end

  describe "normalization fast path is equivalent to the Unicode reference" do
    # Reference implementation written independently in the test: the exact
    # regex pipeline the module uses for non-ASCII names (format characters Cf
    # AND combining marks Mn are dropped, so a combining grapheme joiner cannot
    # split a root into fake separators). The ASCII fast path must agree with
    # it byte-for-byte on every ASCII input.
    defp reference(axis) do
      axis
      |> :unicode.characters_to_nfkc_binary()
      |> String.replace(~r/[\p{Cf}\p{Mn}]/u, "")
      |> String.replace(~r/(?<=[\p{Ll}\p{N}])(?=\p{Lu})|(?<=\p{Lu})(?=\p{Lu}\p{Ll})/u, "_")
      |> String.downcase()
      |> String.replace(~r/[^\p{L}\p{N}]+/u, "_")
      |> String.trim("_")
    end

    test "exhaustive single/double-byte ASCII and a seeded random corpus agree" do
      singles = for c <- 0..127, do: <<c>>
      doubles = for a <- 0..127, b <- [?a, ?Z, ?_, ?-, ?\s, ?0], do: <<a, b>>
      triples = for a <- [?a, ?A, ?0, ?_], b <- [?A, ?b], c <- [?a, ?B, ?1, ?-], do: <<a, b, c>>

      :rand.seed(:exsss, {26, 9, 26})

      randoms =
        for _ <- 1..5_000 do
          len = :rand.uniform(24)
          for _ <- 1..len, into: <<>>, do: <<:rand.uniform(128) - 1>>
        end

      for axis <- singles ++ doubles ++ triples ++ randoms ++ PolicyPhenotype.default_axes() do
        assert PolicyPhenotype.normalize_axis_name(axis) == reference(axis),
               "fast path diverged on #{inspect(axis)}"
      end
    end

    test "non-ASCII names take the reference path" do
      for axis <- [
            "auth\u200Bority",
            "ＡＵＴＨＯＲＩＴＹ",
            "Éxploration",
            "perm\u00ADission",
            # U+034F COMBINING GRAPHEME JOINER (Mn): stripped, not turned into
            # a separator, so `gra\u034Fnt` normalizes to `grant`.
            "gra\u034Fnt",
            "execution\u034Fgrant"
          ] do
        assert PolicyPhenotype.normalize_axis_name(axis) == reference(axis)
      end

      assert PolicyPhenotype.normalize_axis_name("gra\u034Fnt") == "grant"
    end

    test "invalid UTF-8 and non-string terms pass through unchanged" do
      assert PolicyPhenotype.normalize_axis_name(<<0xFF, 0xFE>>) == <<0xFF, 0xFE>>
      assert PolicyPhenotype.normalize_axis_name(42) == 42
      assert PolicyPhenotype.normalize_axis_name(:Execution_Grant) == "execution_grant"
    end

    test "camelCase and acronym boundaries split into tokens" do
      assert PolicyPhenotype.normalize_axis_name("ExecutionGrant") == "execution_grant"
      assert PolicyPhenotype.normalize_axis_name("executionAuthority") == "execution_authority"
      assert PolicyPhenotype.normalize_axis_name("HTTPGrant") == "http_grant"
      assert PolicyPhenotype.normalize_axis_name("v2Grant") == "v2_grant"
      assert PolicyPhenotype.normalize_axis_name("AUTHORITY") == "authority"
      assert PolicyPhenotype.normalize_axis_name("selfModelPlasticity") == "self_model_plasticity"
      assert PolicyPhenotype.normalize_axis_name("ÉxplorationLevel") == "éxploration_level"
    end

    test "a camelCase spelling collides with its snake_case twin" do
      assert {:error,
              %{
                code: :invalid_policy_phenotype,
                detail: {:duplicate_axis, :conditionable_axes, "self_model_plasticity"}
              }} =
               PolicyPhenotype.new(
                 capability_iri: @cap,
                 policy_family: "planner:Astar",
                 conditionable_axes: %{
                   "self_model_plasticity" => %{min: 0.0, max: 1.0},
                   "selfModelPlasticity" => %{min: 0.0, max: 1.0}
                 }
               )
    end
  end

  describe "smuggled authority-bearing options" do
    test "unknown options are refused rather than silently dropped" do
      for {key, value} <- [
            authority: :do,
            grant: "urn:grant:1",
            token: "secret",
            command_handle: make_ref()
          ] do
        assert {:error, %{code: :invalid_policy_phenotype, detail: {:unknown_option, ^key}}} =
                 PolicyPhenotype.new(base([{key, value}]))
      end
    end

    test "a duplicated option (second delivery) is refused, not last-wins" do
      opts = base(condition: %{"exploration" => 0.1}) ++ [condition: %{"exploration" => 0.9}]

      assert {:error, %{code: :invalid_policy_phenotype, detail: {:duplicate_option, :condition}}} =
               PolicyPhenotype.new(opts)
    end
  end

  describe "malformed input is refused, never raised" do
    test "non-enumerable axis maps" do
      for key <- [:conditionable_axes, :condition, :reaction_norms],
          bad <- ["exploration", 42, :atom, [1, 2], %URI{}] do
        opts = Keyword.put(base(), key, bad)

        assert {:error, %{code: :invalid_policy_phenotype, detail: {:expected_axis_map, ^key}}} =
                 PolicyPhenotype.new(opts)
      end
    end

    test "non-keyword list and non-list opts" do
      for bad <- [[1, 2], [{"capability_iri", @cap}], [{nil, 1}], %{capability_iri: @cap}, nil] do
        result = PolicyPhenotype.new(bad)
        assert code(result) == :invalid_policy_phenotype
        assert Refusal.classify(code(result)) == :refused_structure
      end
    end

    test "empty or non-binary identity" do
      for {iri, family} <- [{"", "planner:Astar"}, {@cap, ""}, {:cap, "p"}, {@cap, nil}] do
        assert {:error,
                %{code: :invalid_policy_phenotype, detail: :capability_and_policy_family_required}} =
                 PolicyPhenotype.new(
                   capability_iri: iri,
                   policy_family: family,
                   conditionable_axes: %{}
                 )
      end
    end

    test "degenerate or inverted ranges" do
      for range <- [%{min: 1.0, max: 1.0}, %{min: 1.0, max: 0.0}, %{min: "0", max: 1}, %{max: 1}] do
        assert {:error, %{code: :invalid_condition_axis_range}} =
                 PolicyPhenotype.new(
                   capability_iri: @cap,
                   policy_family: "planner:Astar",
                   conditionable_axes: %{"exploration" => range}
                 )
      end
    end

    test "condition values outside the declared range or non-numeric" do
      assert {:error, %{code: :condition_out_of_range}} =
               PolicyPhenotype.new(base(condition: %{"exploration" => 1.0000001}))

      assert {:error, %{code: :condition_out_of_range}} =
               PolicyPhenotype.new(base(condition: %{"exploration" => -0.1}))

      assert {:error, %{code: :invalid_policy_phenotype, detail: {:invalid_condition, _}}} =
               PolicyPhenotype.new(base(condition: %{"exploration" => "0.5"}))

      assert {:error, %{code: :unknown_condition_axis, detail: "sociability"}} =
               PolicyPhenotype.new(base(condition: %{"sociability" => 0.5}))
    end

    test "reaction norms with missing or non-numeric slope/reference cue" do
      for norm <- [%{}, %{slope: "1"}, %{slope: 1.0, reference_cue: :zero}, 1.0] do
        assert {:error, %{code: :invalid_reaction_norm}} =
                 PolicyPhenotype.new(base(reaction_norms: %{"exploration" => norm}))
      end
    end

    test "evidence refs must be non-empty strings" do
      for refs <- [[123], [""], ["urn:ok", :atom], %{a: 1}] do
        assert {:error, %{code: :invalid_policy_phenotype, detail: {:invalid_evidence_ref, _}}} =
                 PolicyPhenotype.new(base(evidence_refs: refs))
      end

      assert {:ok, %{evidence_refs: ["urn:evidence:one"]}} =
               PolicyPhenotype.new(base(evidence_refs: "urn:evidence:one"))

      assert {:ok, %{evidence_refs: []}} = PolicyPhenotype.new(base(evidence_refs: nil))
    end

    test "reaction arithmetic that overflows is refused, not raised" do
      for {norm, cue} <- [
            {%{slope: 1.0e308}, 1.0e10},
            {%{slope: -1.0e308}, 1.0e10},
            {%{slope: 1.0, reference_cue: -1.0e308}, 1.0e308},
            {%{slope: 10 ** 400}, 1.0}
          ] do
        {:ok, p} = PolicyPhenotype.new(base(reaction_norms: %{"exploration" => norm}))
        result = PolicyPhenotype.condition(p, cue)

        assert {:error, %{code: :invalid_reaction_norm, detail: {:overflow, "exploration", ^cue}}} =
                 result

        assert Refusal.classify(code(result)) == :refused_structure
      end
    end

    test "large but representable reaction arithmetic still clamps" do
      {:ok, p} = PolicyPhenotype.new(base(reaction_norms: %{"exploration" => %{slope: 1.0e300}}))
      assert {:ok, %{condition: %{"exploration" => 1.0}}} = PolicyPhenotype.condition(p, 1.0)
      assert {:ok, %{condition: %{"exploration" => low}}} = PolicyPhenotype.condition(p, -1.0)
      assert low == 0.0
    end

    test "non-numeric cue" do
      {:ok, p} = PolicyPhenotype.new(base())

      for cue <- ["1.0", nil, :high] do
        assert {:error, %{code: :invalid_policy_phenotype, detail: :cue_must_be_numeric}} =
                 PolicyPhenotype.condition(p, cue)
      end
    end
  end

  describe "duplicate delivery of one axis" do
    test "a pair list naming an axis twice is refused instead of last-wins" do
      assert {:error,
              %{
                code: :invalid_policy_phenotype,
                detail: {:duplicate_axis, :condition, "exploration"}
              }} =
               PolicyPhenotype.new(base(condition: [{"exploration", 0.1}, {"exploration", 0.9}]))
    end

    test "two spellings that normalize to one axis are refused as a collision" do
      assert {:error,
              %{
                code: :invalid_policy_phenotype,
                detail: {:duplicate_axis, :conditionable_axes, "exploration"}
              }} =
               PolicyPhenotype.new(
                 capability_iri: @cap,
                 policy_family: "planner:Astar",
                 conditionable_axes: %{
                   "exploration" => %{min: 0.0, max: 1.0},
                   "Exploration" => %{min: 0.0, max: 1.0}
                 }
               )
    end

    test "a pair list with distinct axes is accepted and equals the map form" do
      pairs = [{"exploration", 0.2}]
      assert {:ok, from_pairs} = PolicyPhenotype.new(base(condition: pairs))
      assert {:ok, from_map} = PolicyPhenotype.new(base(condition: Map.new(pairs)))
      assert from_pairs == from_map
    end
  end

  describe "tampered structs presented to condition/2 (stale or forged subject)" do
    setup do
      {:ok, p} =
        PolicyPhenotype.new(
          base(
            condition: %{"exploration" => 0.5},
            reaction_norms: %{"exploration" => %{slope: 0.5}}
          )
        )

      %{p: p}
    end

    test "authority axis injected after construction is refused", %{p: p} do
      forged = %{
        p
        | conditionable_axes: Map.put(p.conditionable_axes, "grant", %{min: 0, max: 1})
      }

      assert {:error, %{code: :temperament_cannot_encode_authority, detail: "grant"}} =
               PolicyPhenotype.condition(forged, 1.0)
    end

    test "identity stripped after construction is refused", %{p: p} do
      assert {:error, %{detail: :capability_and_policy_family_required}} =
               PolicyPhenotype.condition(%{p | capability_iri: nil}, 1.0)

      assert {:error, %{detail: :capability_and_policy_family_required}} =
               PolicyPhenotype.condition(%{p | policy_family: ""}, 1.0)
    end

    test "condition pushed out of range after construction is refused", %{p: p} do
      assert {:error, %{code: :condition_out_of_range}} =
               PolicyPhenotype.condition(%{p | condition: %{"exploration" => 7.0}}, 0.0)
    end

    test "non-string evidence injected after construction is refused", %{p: p} do
      assert {:error, %{detail: {:invalid_evidence_ref, 1}}} =
               PolicyPhenotype.condition(%{p | evidence_refs: [1]}, 0.0)
    end

    test "grant?/1 stays false even for a forged struct", %{p: p} do
      refute PolicyPhenotype.grant?(%{
               p
               | conditionable_axes: %{"authority" => %{min: 0, max: 1}}
             })
    end
  end

  # ash_a2a#45 court verdict REFUSED d35394a with 3 MAJOR admission_vacuous
  # defects; each test here kills exactly one of them on the repaired module.
  describe "v26.9.26 court repair: the three refused defects are killed" do
    test "D1 invisible-mark split (U+034F) cannot admit a forbidden root", %{} do
      # Mn mark stripped by normalization, so the joined skeleton is `grant`.
      for axis <- ["gra\u034Fnt", "execution\u034Fgrant\u034F", "le\u034Fase"] do
        assert {:error, %{code: :temperament_cannot_encode_authority, detail: ^axis}} =
                 PolicyPhenotype.new(
                   capability_iri: @cap,
                   policy_family: "planner:Astar",
                   conditionable_axes: %{axis => %{min: 0.0, max: 1.0}}
                 ),
               "admitted despite Mn marks: #{inspect(axis)}"
      end
    end

    test "D1 separator splits rejoin to a forbidden root in the skeleton" do
      for axis <- ["gr_ant", "d_o", "tok_en", "le_ase", "execution_gr_ant", "GRant"] do
        assert {:error, %{code: :temperament_cannot_encode_authority}} =
                 PolicyPhenotype.new(
                   capability_iri: @cap,
                   policy_family: "planner:Astar",
                   conditionable_axes: %{axis => %{min: 0.0, max: 1.0}}
                 ),
               "admitted despite joined forbidden root: #{inspect(axis)}"
      end
    end

    test "D1 benign words with the same letters stay admitted (no joined-check false positive)" do
      for axis <- ["fragrant_novelty", "releaseCadence", "undo_tolerance", "domain_focus"] do
        assert {:ok, _} =
                 PolicyPhenotype.new(
                   capability_iri: @cap,
                   policy_family: "planner:Astar",
                   conditionable_axes: %{axis => %{min: 0.0, max: 1.0}}
                 ),
               "false positive on #{inspect(axis)}"
      end
    end

    test "D2 authority-named key inside a range map is refused at any depth" do
      for range <- [
            %{min: 0.0, max: 1.0, execution_grant: "token"},
            %{min: 0.0, max: 1.0, meta: %{"token" => "secret"}},
            %{min: 0.0, max: 1.0, nested: [%{lease: true}]}
          ] do
        assert {:error, %{code: :invalid_policy_phenotype, detail: {:unknown_option, key}}} =
                 PolicyPhenotype.new(
                   capability_iri: @cap,
                   policy_family: "planner:Astar",
                   conditionable_axes: %{"exploration" => range}
                 ),
               "admitted range #{inspect(range)}"

        assert key in [:execution_grant, "token", :lease]
      end
    end

    test "D2 authority-named key inside a reaction norm is refused" do
      assert {:error, %{code: :invalid_policy_phenotype, detail: {:unknown_option, :authority}}} =
               PolicyPhenotype.new(
                 capability_iri: @cap,
                 policy_family: "planner:Astar",
                 conditionable_axes: %{"exploration" => %{min: 0.0, max: 1.0}},
                 reaction_norms: %{"exploration" => %{slope: 0.1, authority: :execute}}
               )
    end

    test "D2 unknown non-authority keys are also refused, never preserved" do
      assert {:error, %{code: :invalid_condition_axis_range}} =
               PolicyPhenotype.new(
                 capability_iri: @cap,
                 policy_family: "planner:Astar",
                 conditionable_axes: %{"exploration" => %{min: 0.0, max: 1.0, color: "red"}}
               )

      assert {:error, %{code: :invalid_reaction_norm}} =
               PolicyPhenotype.new(
                 capability_iri: @cap,
                 policy_family: "planner:Astar",
                 conditionable_axes: %{"exploration" => %{min: 0.0, max: 1.0}},
                 reaction_norms: %{"exploration" => %{slope: 0.1, color: "red"}}
               )
    end

    test "D3 a field forged onto the struct after construction is refused by condition/2" do
      {:ok, p} =
        PolicyPhenotype.new(
          capability_iri: @cap,
          policy_family: "planner:Astar",
          conditionable_axes: %{"exploration" => %{min: 0.0, max: 1.0}},
          condition: %{"exploration" => 0.5},
          reaction_norms: %{"exploration" => %{slope: 0.5}}
        )

      forged = Map.put(p, :execution_grant, "token-abc")

      assert {:error,
              %{code: :invalid_policy_phenotype, detail: {:unknown_option, :execution_grant}}} =
               PolicyPhenotype.condition(forged, 1.0),
             "forged :execution_grant was honored"
    end

    test "D3 every non-schema forged field is refused, and a legit phenotype still conditions" do
      {:ok, p} =
        PolicyPhenotype.new(
          capability_iri: @cap,
          policy_family: "planner:Astar",
          conditionable_axes: %{"exploration" => %{min: 0.0, max: 1.0}},
          condition: %{"exploration" => 0.5},
          reaction_norms: %{"exploration" => %{slope: 0.5}}
        )

      for field <- [:command_handle, :authority_lease, :do_token] do
        assert {:error, %{code: :invalid_policy_phenotype, detail: {:unknown_option, ^field}}} =
                 PolicyPhenotype.condition(Map.put(p, field, :forged), 0.5)
      end

      assert {:ok, %{condition: %{"exploration" => 0.9}}} = PolicyPhenotype.condition(p, 0.8)
    end
  end

  describe "committed benchmark receipt is bound to its subject" do
    test "receipt names the exact blob of the module it measured" do
      subject_path = "lib/ash_a2a/semantic/policy_phenotype.ex"
      receipt = "receipts/v26.9.26/policy_phenotype_bench.json" |> File.read!() |> :json.decode()
      content = File.read!(subject_path)

      blob_sha1 =
        :crypto.hash(:sha, ["blob ", Integer.to_string(byte_size(content)), 0, content])
        |> Base.encode16(case: :lower)

      assert receipt["subject_path"] == subject_path

      assert receipt["subject_blob_sha1"] == blob_sha1,
             "benchmark receipt is stale: re-run with POLICY_PHENOTYPE_BENCH_RECEIPT=1"

      assert receipt["measured_on_parent"] =~ ~r/\A[0-9a-f]{40}\z/
    end
  end

  describe "replay and reordering determinism" do
    setup do
      axes = Map.new(PolicyPhenotype.default_axes(), &{&1, %{min: 0.0, max: 1.0}})

      norms =
        PolicyPhenotype.default_axes()
        |> Enum.with_index()
        |> Map.new(fn {axis, i} -> {axis, %{slope: (i - 4) / 10, reference_cue: 0.5}} end)

      condition = Map.new(PolicyPhenotype.default_axes(), &{&1, 0.5})

      %{axes: axes, norms: norms, condition: condition}
    end

    test "replaying the same cue sequence yields an identical phenotype", ctx do
      {:ok, p} =
        PolicyPhenotype.new(
          capability_iri: @cap,
          policy_family: "planner:MCTS",
          conditionable_axes: ctx.axes,
          condition: ctx.condition,
          reaction_norms: ctx.norms
        )

      cues = [0.0, 1.0, 0.25, -3.0, 9.0, 0.5]

      run = fn ->
        Enum.reduce(cues, p, fn cue, acc -> elem(PolicyPhenotype.condition(acc, cue), 1) end)
      end

      first = run.()
      assert first == run.()
      assert :erlang.term_to_binary(first) == :erlang.term_to_binary(run.())
      assert first.capability_iri == p.capability_iri
      assert first.policy_family == p.policy_family
      assert Map.keys(first.conditionable_axes) == Map.keys(p.conditionable_axes)

      for {axis, value} <- first.condition do
        assert value >= 0.0 and value <= 1.0, "#{axis} escaped its range: #{value}"
      end
    end

    test "declaration order of axes and norms does not change the result", ctx do
      forward = fn m -> m |> Enum.sort() end
      reverse = fn m -> m |> Enum.sort() |> Enum.reverse() end

      results =
        for order <- [forward, reverse] do
          {:ok, p} =
            PolicyPhenotype.new(
              capability_iri: @cap,
              policy_family: "planner:MCTS",
              conditionable_axes: order.(ctx.axes),
              condition: order.(ctx.condition),
              reaction_norms: order.(ctx.norms)
            )

          {:ok, conditioned} = PolicyPhenotype.condition(p, 0.8)
          conditioned
        end

      assert [same, same] = results
    end

    test "clamping is idempotent at the bounds for extreme cues", ctx do
      {:ok, p} =
        PolicyPhenotype.new(
          capability_iri: @cap,
          policy_family: "planner:MCTS",
          conditionable_axes: ctx.axes,
          reaction_norms: ctx.norms
        )

      {:ok, hi} = PolicyPhenotype.condition(p, 1.0e12)
      {:ok, hi2} = PolicyPhenotype.condition(hi, 1.0e12)
      assert hi.condition == hi2.condition
      assert Enum.all?(Map.values(hi.condition), &(&1 in [0.0, 1.0]))
    end
  end
end

# ==============================================================================
# SECTION 18: Original test/ash_a2a_semantic_policy_phenotype_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Semantic.PolicyPhenotypeTest do
  use ExUnit.Case, async: true

  alias AshA2A.Semantic.PolicyPhenotype

  test "same capability can expose distinct behavioral phenotypes without becoming distinct grants" do
    common = [
      capability_iri: "urn:sa2a:capability:Example.Search.read",
      policy_family: "planner:Astar",
      conditionable_axes: %{
        "exploration" => %{min: 0.0, max: 1.0},
        "initiative" => %{min: 0.0, max: 1.0}
      }
    ]

    assert {:ok, conservative} =
             PolicyPhenotype.new(
               common ++ [condition: %{"exploration" => 0.1, "initiative" => 0.2}]
             )

    assert {:ok, exploratory} =
             PolicyPhenotype.new(
               common ++ [condition: %{"exploration" => 0.9, "initiative" => 0.8}]
             )

    assert conservative.capability_iri == exploratory.capability_iri
    assert conservative.policy_family == exploratory.policy_family
    refute conservative.condition == exploratory.condition
    refute PolicyPhenotype.grant?(conservative)
    refute PolicyPhenotype.grant?(exploratory)
    assert PolicyPhenotype.actuation_boundary() == :external_command_bus_brce
  end

  test "reaction norm changes only behavioral condition and clamps it to declared bounds" do
    assert {:ok, phenotype} =
             PolicyPhenotype.new(
               capability_iri: "urn:sa2a:capability:Example.Search.read",
               policy_family: "planner:MCTS",
               conditionable_axes: %{
                 "exploration" => %{min: 0.0, max: 1.0},
                 "initiative" => %{min: 0.0, max: 0.75}
               },
               condition: %{"exploration" => 0.25, "initiative" => 0.4},
               reaction_norms: %{
                 "exploration" => %{slope: 0.75, reference_cue: 0.0},
                 "initiative" => %{slope: 1.0, reference_cue: 0.0}
               },
               evidence_refs: ["urn:evidence:temperament-engineering"]
             )

    assert {:ok, conditioned} = PolicyPhenotype.condition(phenotype, 1.0)

    assert conditioned.capability_iri == phenotype.capability_iri
    assert conditioned.policy_family == phenotype.policy_family
    assert conditioned.evidence_refs == phenotype.evidence_refs
    assert conditioned.condition == %{"exploration" => 1.0, "initiative" => 0.75}
    refute PolicyPhenotype.grant?(conditioned)
  end

  test "authority-like axes are refused before they can become phenotype state" do
    for axis <- [
          "authority",
          "permission",
          "execution_grant",
          "execution_authority",
          "do",
          " Authority ",
          "EXECUTION_GRANT"
        ] do
      assert {:error, %{code: :temperament_cannot_encode_authority, detail: ^axis}} =
               PolicyPhenotype.new(
                 capability_iri: "urn:sa2a:capability:Example.Search.read",
                 policy_family: "planner:Astar",
                 conditionable_axes: %{axis => %{min: 0.0, max: 1.0}},
                 condition: %{axis => 1.0}
               )
    end
  end

  test "reaction norm cannot name an undeclared behavioral axis" do
    assert {:error, %{code: :unknown_condition_axis, detail: "sociability"}} =
             PolicyPhenotype.new(
               capability_iri: "urn:sa2a:capability:Example.Search.read",
               policy_family: "planner:Astar",
               conditionable_axes: %{"exploration" => %{min: 0.0, max: 1.0}},
               reaction_norms: %{"sociability" => %{slope: 0.5}}
             )
  end

  test "phenotype refusal codes enter the existing S42 taxonomy" do
    alias AshA2A.Semantic.Refusal

    assert Refusal.classify(:invalid_policy_phenotype) == :refused_structure
    assert Refusal.classify(:invalid_reaction_norm) == :refused_structure
    assert Refusal.classify(:unknown_condition_axis) == :refused_namespace

    assert Refusal.classify(:temperament_cannot_encode_authority) ==
             :refused_authority

    assert Refusal.classify(:invalid_condition_axis_range) == :refused_bounds
    assert Refusal.classify(:condition_out_of_range) == :refused_bounds
  end

  test "default vocabulary is behavioral and contains no authority axis" do
    axes = PolicyPhenotype.default_axes()

    assert PolicyPhenotype.vocabulary_provenance() == "https://arxiv.org/abs/2609.29423"
    assert "initiative" in axes
    assert "expressiveness" in axes
    refute "authority" in axes
    refute "permission" in axes
    refute "execution_grant" in axes
  end
end

# ==============================================================================
# SECTION 19: Original test/ash_a2a_semantic_policy_phenotype_transport_fence_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Semantic.PolicyPhenotypeTransportFenceTest do
  @moduledoc """
  Merge court for the phenotype transport fence: `from_map/2` must refuse
  every authority-key disguise main's #45 fence refuses (homoglyph, leetspeak,
  split token, camelCase, invisible mark, non-string key), not only the
  branch's original seven exact words. Real PolicyPhenotype, no doubles.
  """
  use ExUnit.Case, async: true

  alias AshA2A.Semantic.PolicyPhenotype

  defp transport_map do
    {:ok, phenotype} =
      PolicyPhenotype.new(
        capability_iri: "urn:sa2a:capability:Example.Search.read",
        policy_family: "planner:Astar",
        conditionable_axes: %{"exploration" => %{min: 0.0, max: 1.0}},
        condition: %{"exploration" => 0.25},
        reaction_norms: %{"exploration" => %{slope: 0.5}},
        evidence_refs: ["urn:evidence:paper"]
      )

    PolicyPhenotype.to_map(phenotype)
  end

  test "clean transport map still round-trips" do
    map = transport_map()
    assert {:ok, %PolicyPhenotype{}} = PolicyPhenotype.from_map(map)
  end

  for key <- [
        "grant",
        "execution_grant",
        "аuthority",
        "auth0rity",
        "gr4nt",
        "executionGrant",
        "gr_ant",
        "auth​ority",
        "leaseHolder",
        "sudo"
      ] do
    test "top-level disguised authority key #{inspect(key)} is refused" do
      map = Map.put(transport_map(), unquote(key), true)

      assert {:error, %{code: :phenotype_authority_smuggling, detail: unquote(key)}} =
               PolicyPhenotype.from_map(map)
    end
  end

  test "disguised authority key nested inside a reaction norm is refused" do
    map =
      put_in(transport_map(), ["reaction_norms", "exploration", "l3ase"], "forever")

    assert {:error, %{code: :phenotype_authority_smuggling, detail: "l3ase"}} =
             PolicyPhenotype.from_map(map)
  end

  test "forged authority_semantics is refused" do
    map = put_in(transport_map(), ["authority_semantics", "phenotype_has_authority"], true)

    assert {:error, %{code: :phenotype_authority_smuggling}} = PolicyPhenotype.from_map(map)
  end

  test "forged atom-keyed authority_semantics next to the canonical string key is refused" do
    map = Map.put(transport_map(), :authority_semantics, %{"phenotype_has_authority" => true})

    assert {:error, %{code: :phenotype_authority_smuggling, detail: {:authority_semantics, _}}} =
             PolicyPhenotype.from_map(map)
  end

  test "a field given as both string and atom key is refused, not silently shadowed" do
    map = Map.put(transport_map(), :capability_iri, "urn:sa2a:capability:Other.Thing.write")

    assert {:error,
            %{
              code: :invalid_policy_phenotype_transport,
              detail: {:duplicate_key, ["capability_iri"]}
            }} =
             PolicyPhenotype.from_map(map)
  end

  test "extra key inside a range is refused by main's closed shape after transport" do
    map = put_in(transport_map(), ["conditionable_axes", "exploration", "step"], 0.1)

    assert {:error, %{code: :invalid_condition_axis_range}} = PolicyPhenotype.from_map(map)
  end

  test "extra key inside a reaction norm is refused, not dropped" do
    map = put_in(transport_map(), ["reaction_norms", "exploration", "gain"], 2.0)

    assert {:error, %{code: :invalid_reaction_norm}} = PolicyPhenotype.from_map(map)
  end

  test "unknown top-level transport key is refused, not ignored" do
    map = Map.put(transport_map(), "notes", "benign")

    assert {:error, %{code: :invalid_policy_phenotype_transport, detail: {:unknown_key, "notes"}}} =
             PolicyPhenotype.from_map(map)
  end

  test "atom-keyed transport map is still admitted" do
    map =
      transport_map()
      |> Map.new(fn {k, v} -> {String.to_existing_atom(k), v} end)

    assert {:ok, %PolicyPhenotype{}} = PolicyPhenotype.from_map(map)
  end

  test "digest mismatch is refused" do
    assert {:error, %{code: :policy_phenotype_digest_mismatch}} =
             PolicyPhenotype.from_map(transport_map(), String.duplicate("0", 64))
  end
end

# ==============================================================================
# SECTION 20: Original test/ash_a2a_semantic_policy_phenotype_transport_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Semantic.PolicyPhenotypeTransportTest do
  use ExUnit.Case, async: true

  alias AshA2A.Semantic.PolicyPhenotype
  alias AshA2A.Semantic.Refusal

  defp phenotype do
    assert {:ok, phenotype} =
             PolicyPhenotype.new(
               capability_iri: "urn:sa2a:capability:Example.Search.read",
               policy_family: "planner:Astar",
               conditionable_axes: %{
                 "exploration" => %{min: 0.0, max: 1.0},
                 "initiative" => %{min: 0.0, max: 1.0}
               },
               condition: %{
                 "exploration" => 0.25,
                 "initiative" => 0.75
               },
               reaction_norms: %{
                 "exploration" => %{slope: 0.5, reference_cue: 0.0}
               },
               evidence_refs: ["urn:evidence:paper"]
             )

    phenotype
  end

  test "canonical map round-trips with exact digest" do
    source = phenotype()
    map = PolicyPhenotype.to_map(source)
    digest = PolicyPhenotype.digest(source)

    assert {:ok, decoded} = PolicyPhenotype.from_map(map, digest)
    assert decoded == source
    assert PolicyPhenotype.digest(decoded) == digest

    assert map["authority_semantics"] == %{
             "candidate_only" => true,
             "phenotype_has_authority" => false,
             "execution_authority" => "external_command_bus_brce"
           }
  end

  test "map encoding is deterministic independent of source map insertion order" do
    source = phenotype()
    first = PolicyPhenotype.to_map(source)

    reordered =
      first
      |> Enum.reverse()
      |> Map.new()

    assert {:ok, decoded} = PolicyPhenotype.from_map(reordered)
    assert PolicyPhenotype.digest(decoded) == PolicyPhenotype.digest(source)
  end

  test "tampered expected digest is a typed identity refusal" do
    source = phenotype()

    assert {:error, %{code: :policy_phenotype_digest_mismatch}} =
             PolicyPhenotype.from_map(PolicyPhenotype.to_map(source), "sha256:tampered")

    assert Refusal.classify(:policy_phenotype_digest_mismatch) == :refused_identity
  end

  test "caller cannot add credential-shaped transport state" do
    source =
      phenotype()
      |> PolicyPhenotype.to_map()
      |> Map.put("credential", "secret")

    assert {:error, %{code: :phenotype_authority_smuggling, detail: "credential"}} =
             PolicyPhenotype.from_map(source)

    assert Refusal.classify(:phenotype_authority_smuggling) == :refused_authority
  end

  test "caller cannot mutate the fixed authority semantic declaration" do
    source =
      phenotype()
      |> PolicyPhenotype.to_map()
      |> put_in(["authority_semantics", "phenotype_has_authority"], true)

    assert {:error,
            %{
              code: :phenotype_authority_smuggling,
              detail: {:authority_semantics, _}
            }} = PolicyPhenotype.from_map(source)
  end

  test "transport parser accepts atom-keyed host maps without changing semantics" do
    source = phenotype()

    atom_map = %{
      capability_iri: source.capability_iri,
      policy_family: source.policy_family,
      conditionable_axes: source.conditionable_axes,
      condition: source.condition,
      reaction_norms: source.reaction_norms,
      evidence_refs: source.evidence_refs,
      authority_semantics: %{
        "candidate_only" => true,
        "phenotype_has_authority" => false,
        "execution_authority" => "external_command_bus_brce"
      }
    }

    assert {:ok, decoded} = PolicyPhenotype.from_map(atom_map)
    assert decoded == source
  end
end

# ==============================================================================
# SECTION 21: Original test/ash_a2a_semantic_policy_population_rdf_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Semantic.PolicyPopulationRDFTest do
  use ExUnit.Case, async: true

  alias AshA2A.Semantic.PolicyPhenotype
  alias AshA2A.Semantic.PolicyPopulation
  alias AshA2A.Semantic.PolicyPopulationRDF
  alias AshA2A.Semantic.Serialize

  defp population do
    assert {:ok, first} =
             PolicyPhenotype.new(
               capability_iri: "urn:sa2a:capability:Example.Search.read",
               policy_family: "planner:Astar",
               conditionable_axes: %{
                 "exploration" => %{min: 0.0, max: 1.0},
                 "initiative" => %{min: 0.0, max: 1.0}
               },
               condition: %{"exploration" => 0.1, "initiative" => 0.9},
               evidence_refs: ["urn:evidence:paper"]
             )

    assert {:ok, second} =
             PolicyPhenotype.new(
               capability_iri: "urn:sa2a:capability:Example.Search.read",
               policy_family: "planner:Astar",
               conditionable_axes: %{
                 "exploration" => %{min: 0.0, max: 1.0},
                 "initiative" => %{min: 0.0, max: 1.0}
               },
               condition: %{"exploration" => 0.9, "initiative" => 0.1},
               evidence_refs: ["urn:evidence:paper"]
             )

    assert {:ok, population} =
             PolicyPopulation.new(
               :engineered,
               [{first, 1.0}, {second, 2.0}],
               evidence_refs: ["https://arxiv.org/abs/2609.29423"]
             )

    population
  end

  test "public RDF projection independently parse-back verifies" do
    source = population()
    triples = PolicyPopulationRDF.to_triples(source)

    assert :ok = PolicyPopulationRDF.verify_public_vocabulary(triples)
    assert {:ok, ntriples} = Serialize.to_ntriples(triples)
    assert {:ok, count} = Serialize.verify(triples, ntriples, format: :ntriples)
    assert count > 0

    assert {:ok, decoded} =
             PolicyPopulationRDF.from_triples(
               triples,
               PolicyPopulation.digest(source)
             )

    assert decoded == source
  end

  test "Turtle is emitted only after the real RDF.ex parse-back gate" do
    assert {:ok, turtle} = PolicyPopulationRDF.to_turtle(population())
    assert turtle =~ "policy_population"
    assert turtle =~ "policy_phenotype"
    assert turtle =~ "temperament_measurement"
  end

  test "projection uses no SA2A-private RDF predicate or class" do
    triples = PolicyPopulationRDF.to_triples(population())

    refute Enum.any?(triples, fn triple ->
             String.starts_with?(to_string(triple.predicate), "urn:sa2a:")
           end)

    refute Enum.any?(triples, fn
             %{
               predicate: "http://www.w3.org/1999/02/22-rdf-syntax-ns#type",
               object: {:iri, "urn:sa2a:" <> _}
             } ->
               true

             _ ->
               false
           end)
  end

  test "tampered population root identity is refused" do
    triples = PolicyPopulationRDF.to_triples(population())
    root = PolicyPopulationRDF.population_iri(population())

    tampered =
      Enum.map(triples, fn triple ->
        if triple.subject == root,
          do: %{triple | subject: "urn:sa2a:policy-population:tampered"},
          else: triple
      end)

    assert {:error, %{code: :policy_population_rdf_identity_mismatch}} =
             PolicyPopulationRDF.from_triples(tampered)
  end

  test "custom predicate is refused even when lossless value remains intact" do
    source = population()

    triples =
      PolicyPopulationRDF.to_triples(source) ++
        [
          %{
            subject: PolicyPopulationRDF.population_iri(source),
            predicate: "urn:sa2a:privatePredicate",
            object: {:literal, "no"}
          }
        ]

    assert {:error, %{code: :policy_population_custom_rdf_predicate}} =
             PolicyPopulationRDF.from_triples(triples)
  end
end

# ==============================================================================
# SECTION 22: Original test/ash_a2a_semantic_policy_population_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Semantic.PolicyPopulationTest do
  use ExUnit.Case, async: true

  alias AshA2A.Semantic.PolicyPhenotype
  alias AshA2A.Semantic.PolicyPopulation
  alias AshA2A.Semantic.Refusal

  defp phenotype(value, opts \\ []) do
    reaction_norms =
      if Keyword.get(opts, :adaptive, false),
        do: %{"exploration" => %{slope: 0.5, reference_cue: 0.0}},
        else: %{}

    assert {:ok, phenotype} =
             PolicyPhenotype.new(
               capability_iri: "urn:sa2a:capability:Example.Search.read",
               policy_family: "planner:Astar",
               conditionable_axes: %{"exploration" => %{min: 0.0, max: 1.0}},
               condition: %{"exploration" => value},
               reaction_norms: reaction_norms,
               evidence_refs: ["urn:evidence:paper"]
             )

    phenotype
  end

  test "engineered population separates disparity from effective complexity" do
    assert {:ok, population} =
             PolicyPopulation.new(
               :engineered,
               [
                 {phenotype(0.0), 1.0},
                 {phenotype(1.0), 1.0}
               ]
             )

    assert PolicyPopulation.diversity(population).disparity == 1.0
    assert PolicyPopulation.diversity(population).complexity == 2.0
    refute PolicyPopulation.grant?(population)
    assert PolicyPopulation.standing(population) == :candidate
    assert PolicyPopulation.actuation_boundary() == :external_command_bus_brce
  end

  test "weighted complexity is inverse Simpson effective member count" do
    assert {:ok, population} =
             PolicyPopulation.new(
               :engineered,
               [
                 {phenotype(0.0), 1.0},
                 {phenotype(0.5), 1.0},
                 {phenotype(1.0), 2.0}
               ]
             )

    assert PolicyPopulation.normalized_weights(population) == [0.25, 0.25, 0.5]
    assert_in_delta PolicyPopulation.diversity(population).complexity, 8.0 / 3.0, 1.0e-12
  end

  test "homogeneous population refuses multiple phenotypes" do
    assert {:error, %{code: :homogeneous_population_requires_one_phenotype}} =
             PolicyPopulation.new(
               :homogeneous,
               [{phenotype(0.25), 1.0}, {phenotype(0.75), 1.0}]
             )
  end

  test "adaptive population requires reaction norms on every member" do
    assert {:error, %{code: :adaptive_population_requires_reaction_norm}} =
             PolicyPopulation.new(:adaptive, [{phenotype(0.25), 1.0}])

    assert {:ok, _population} =
             PolicyPopulation.new(
               :adaptive,
               [{phenotype(0.25, adaptive: true), 1.0}]
             )
  end

  test "adaptive population conditions every member without changing weights" do
    assert {:ok, population} =
             PolicyPopulation.new(
               :adaptive,
               [
                 {phenotype(0.25, adaptive: true), 1.0},
                 {phenotype(0.5, adaptive: true), 2.0}
               ]
             )

    assert {:ok, conditioned} = PolicyPopulation.condition(population, 1.0)

    assert Enum.map(conditioned.members, & &1.weight) == [1.0, 2.0]

    assert Enum.map(
             conditioned.members,
             & &1.phenotype.condition["exploration"]
           ) == [0.75, 1.0]
  end

  test "canonical population transport round-trips with member digests" do
    assert {:ok, population} =
             PolicyPopulation.new(
               :engineered,
               [{phenotype(0.1), 1.0}, {phenotype(0.9), 3.0}],
               evidence_refs: ["urn:evidence:population-design"]
             )

    map = PolicyPopulation.to_map(population)
    digest = PolicyPopulation.digest(population)

    assert {:ok, decoded} = PolicyPopulation.from_map(map, digest)
    assert decoded == population
    assert PolicyPopulation.digest(decoded) == digest

    assert Enum.all?(map["members"], fn member ->
             is_binary(member["phenotype_digest"])
           end)
  end

  test "population transport cannot grant authority" do
    assert {:ok, population} =
             PolicyPopulation.new(:engineered, [{phenotype(0.5), 1.0}])

    map =
      population
      |> PolicyPopulation.to_map()
      |> Map.put("credential", "secret")

    assert {:error, %{code: :population_authority_smuggling}} =
             PolicyPopulation.from_map(map)

    assert Refusal.classify(:population_authority_smuggling) == :refused_authority
  end

  test "tampered population digest is refused as identity mismatch" do
    assert {:ok, population} =
             PolicyPopulation.new(:engineered, [{phenotype(0.5), 1.0}])

    assert {:error, %{code: :policy_population_digest_mismatch}} =
             PolicyPopulation.from_map(PolicyPopulation.to_map(population), "sha256:no")

    assert Refusal.classify(:policy_population_digest_mismatch) == :refused_identity
  end
end

