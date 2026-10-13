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
    @tag skip: if(File.exists?(@sibling_ontology),
      do: nil,
      else: "sibling checkout absent: #{@sibling_ontology} — crosswalk pin live-check skipped"
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
